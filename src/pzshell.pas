{ pzshell - the internal shell: `tiza shell <team>`.

  Opens an interactive LOGIN SHELL on the HOST where a team runs, relayed by
  the hub over the same three routes as attach (local, push, dial). One JSON
  handshake, one JSON reply, then the connection is bytes both ways.

  It is NOT `tiza attach`. Attach joins a team's tmux pane; this opens a shell
  on the machine underneath it, so an operator can administer a host that has
  no inbound SSH at all - the dial-in endpoints reach the hub outbound, and
  this rides that same reverse channel back.

  It is NOT named `console` either: `tiza console <text>` already means SEND to
  the operator identity, which is the documented way a team replies, so a verb
  of that name would shadow it for every team.

  Two halves live here. ShellSpawnPlan is the HOST side, shared by the hub's
  local route and the daemon's push and dial routes so both refuse with the
  same words and spawn exactly the same thing. RunShell is the CLIENT.

  The shell always runs as an ordinary configured account, never root: the
  operator becomes root with sudo su inside it, which leaves the escalation in
  the host's own sudo trail rather than making the daemon a root vending
  machine.

  Never RequestLine: it frees the socket after one reply. Never
  pzproto.ReadLine on the raw side: it reads one byte per syscall and cannot
  tell a timeout from a close. }
unit pzshell;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, pzconfig;

{ HOST SIDE. Build the spawn of a login shell for Account on THIS machine.
  Nothing is interpolated into a shell string: Exe is exec'd directly with
  Argv, so the account name never passes through /bin/sh - stronger than the
  su - <user> -c <quoted> pattern in pztmux, which must quote because it does
  run a command line.

  False plus Why when this host cannot serve a shell for Account: an empty or
  invalid name, root, no such account, no su, or a process that is neither
  root nor that account, where su would sit on the pty asking for a password.
  Fail closed, and say which of those it was. }
function ShellSpawnPlan(const Account, Term: string; out Exe: string;
  out Argv, Env: TStringArray; out Why: string): Boolean;

{ CLIENT. Returns the process exit code: 0 after a clean exit, 1 when the hub
  or the host refused, the connection failed, or stdin is not a terminal. }
function RunShell(const Cfg: TTizaConfig; const Team: string): Integer;

implementation

uses
  BaseUnix, Unix, termio, ssockets, fpjson,
  pzproto, pznet, pzpty, pztmux;

const
  ESC_KEY  = #29;      { Ctrl-] - then q to leave a wedged shell.
                         Ctrl-b is deliberately NOT an escape here: unlike
                         attach, the far side is a shell, where Ctrl-b is
                         readline's backward-char and where the operator may
                         well run tmux. It must pass through untouched. }
  REPLY_MS = 15000;    { the hub must answer the handshake within this }
  TICK_US  = 500000;

{ ---------------------------------------------------------------- host side }

function ShellSpawnPlan(const Account, Term: string; out Exe: string;
  out Argv, Env: TStringArray; out Why: string): Boolean;
var
  Out_, PathV, HomeV, ShellV: string;
  Uid: LongInt;
begin
  Result := False;
  Exe := '';
  Argv := nil;
  Env := nil;
  Why := '';

  if Account = '' then
  begin
    Why := 'shell: no account configured on this host (set shell_user)';
    Exit;
  end;
  { Defence in depth. The name is one argv element and never reaches a shell,
    but it also reaches log lines and the JSON reply, and a typo should fail
    here rather than as a confusing su error on the far pty. }
  if not LooksSafeName(Account) then
  begin
    Why := 'shell: shell_user "' + Account + '" is not a valid account name';
    Exit;
  end;
  if SameText(Account, 'root') then
  begin
    Why := 'shell: shell_user must not be root; the shell opens as an ' +
      'ordinary account and the operator becomes root with sudo su inside it';
    Exit;
  end;
  { Existence through `id`, not /etc/passwd: it consults the same name service
    su will use, so a macOS local account resolves too. }
  if RunCapture('id', ['-u', Account], Out_) <> 0 then
  begin
    Why := 'shell: no account "' + Account + '" on this host';
    Exit;
  end;
  Uid := StrToIntDef(Trim(Out_), -1);
  if Uid < 0 then
  begin
    Why := 'shell: cannot resolve account "' + Account + '" on this host';
    Exit;
  end;

  PathV := GetEnvironmentVariable('PATH');
  if PathV = '' then
    PathV := '/usr/local/bin:/usr/bin:/bin';
  HomeV := GetEnvironmentVariable('HOME');
  if HomeV = '' then
    HomeV := '/root';

  if FpGeteuid = 0 then
  begin
    { The production path: a root daemon drops to the account. su - performs
      the login, so it resets HOME, PATH, USER, LOGNAME and the working
      directory from the account itself and runs PAM - none of which we have
      to reimplement. No -c: a bare interactive login shell on the pty. }
    Exe := SuPath;
    if Exe = '' then
    begin
      Why := 'shell: su not found on this host';
      Exit;
    end;
    SetLength(Argv, 3);
    Argv[0] := 'su';
    Argv[1] := '-';
    Argv[2] := Account;
    SetLength(Env, 4);
  end
  else if Uid = LongInt(FpGetuid) then
  begin
    { Not root, but the target IS us: exec the login shell directly. su would
      only sit on the pty asking for a password. This is what lets the macOS
      endpoint serve a shell, and what makes the whole path testable without
      root - the harness sets shell_user to the account running the test. }
    ShellV := GetEnvironmentVariable('SHELL');
    if (ShellV = '') or (not FileExists(ShellV)) then
      if FileExists('/bin/bash') then
        ShellV := '/bin/bash'
      else
        ShellV := '/bin/sh';
    if not FileExists(ShellV) then
    begin
      Why := 'shell: no usable login shell for "' + Account + '"';
      Exit;
    end;
    Exe := ShellV;
    SetLength(Argv, 1);
    { The universal login-shell convention: argv0 prefixed with a dash. }
    Argv[0] := '-' + ExtractFileName(ShellV);
    SetLength(Env, 7);
    Env[4] := 'USER=' + Account;
    Env[5] := 'LOGNAME=' + Account;
    Env[6] := 'SHELL=' + ShellV;
  end
  else
  begin
    Why := 'shell: cannot open a shell as "' + Account + '" here: this ' +
      'daemon runs as uid ' + IntToStr(FpGetuid) + ' and is not root';
    Exit;
  end;

  { pzpty rule 3: the environment is built here and passed verbatim, never
    inherited. TMUX and TMUX_PANE are absent by construction. TMUX_TMPDIR is
    absent ON PURPOSE, unlike ServeAttach which forwards it: an attach child
    must reach the agent's tmux server, an administrative shell must not find
    it by accident. su - would discard it anyway, so forwarding it would make
    the two branches behave differently for no gain. }
  Env[0] := 'PATH=' + PathV;
  Env[1] := 'HOME=' + HomeV;
  Env[2] := 'TERM=' + SafeTerm(Term);
  Env[3] := 'LANG=C.UTF-8';
  Result := True;
end;

{ -------------------------------------------------------------- client side }

{ Write all of Buf to Fd, looping on partial writes and EINTR. False on a
  real error (the peer is gone). }
function WriteAll(Fd: cint; const Buf; Len: Integer): Boolean;
var
  { PChar, not PByte: FpWrite has an untyped-var overload that a PByte
    argument selects, passing the pointer's own bytes instead of the buffer }
  p: PChar;
  left: Integer;
  n: TSsize;
begin
  Result := True;
  p := PChar(@Buf);
  left := Len;
  while left > 0 do
  begin
    n := FpWrite(Fd, p, left);
    if n > 0 then
    begin
      Inc(p, n);
      Dec(left, n);
    end
    else if (n < 0) and (fpgeterrno = ESysEINTR) then
      Continue
    else
      Exit(False);
  end;
end;

{ Read the one reply line. Whatever arrives after the newline is already
  terminal output - the login banner and the first prompt commonly land in
  the same packet - and is handed back in Surplus, never lost. }
function ReadReply(Fd: cint; out Line, Surplus: string): Boolean;
var
  FDS: TFDSet;
  TV: TTimeVal;
  Buf: array[0..4095] of Char;
  Acc: string;
  n: TSsize;
  waited, nl: Integer;
begin
  Result := False;
  Line := '';
  Surplus := '';
  Acc := '';
  waited := 0;
  while waited < REPLY_MS do
  begin
    fpFD_ZERO(FDS);
    fpFD_SET(Fd, FDS);
    TV.tv_sec := 0;
    TV.tv_usec := TICK_US;
    if FPSelect(Fd + 1, @FDS, nil, nil, @TV) > 0 then
    begin
      n := FpRead(Fd, @Buf[0], SizeOf(Buf));
      if n <= 0 then
        Break;   { the hub closed: it may have written its refusal first }
      SetLength(Acc, Length(Acc) + n);
      Move(Buf[0], Acc[Length(Acc) - n + 1], n);
      nl := Pos(#10, Acc);
      if nl > 0 then
      begin
        Line := Copy(Acc, 1, nl - 1);
        Surplus := Copy(Acc, nl + 1, Length(Acc));
        Exit(True);
      end;
      if Length(Acc) > MAX_LINE_BYTES then
        Break;
    end
    else
      Inc(waited, TICK_US div 1000);
  end;
  { no newline: treat what we have as the line (a refusal cut short) }
  Line := Acc;
  Result := Acc <> '';
end;

function RunShell(const Cfg: TTizaConfig; const Team: string): Integer;
var
  Old, Raw: Termios;   { Termios, not TTermios: TTermios is Linux-only and the
                         macOS endpoint compiles this unit }
  Sock: TInetSocket;
  Line, Surplus, Term, ErrText, User, Host: string;
  Obj: TJSONObject;
  Cols, Rows: Integer;
  MyCols, MyRows: Word;
  FDS: TFDSet;
  TV: TTimeVal;
  MaxFd: cint;
  Buf: array[0..8191] of Char;
  Out_: array[0..8191] of Char;
  n, i, o: Integer;
  EscPending, Quit, RawOn: Boolean;
  FromShell, Sent: Int64;
begin
  Result := 1;
  RawOn := False;
  Sock := nil;
  User := '?';
  Host := '?';
  if TCGetAttr(0, Old) <> 0 then
  begin
    Writeln(StdErr, 'tiza shell: stdin is not a terminal');
    Exit;
  end;
  { SIGPIPE must not kill this process with the terminal left raw; the same
    handler also lets SIGTERM end the loop cleanly through ShutdownRequested. }
  InstallShutdownHandler;

  Term := GetEnvironmentVariable('TERM');
  if Term = '' then
    Term := 'xterm-256color';
  { A shell has no session to inherit a size from, so the far pty is created
    at the size of the terminal that will draw it. }
  if not PtyWindowSize(0, MyCols, MyRows) then
    if not PtyWindowSize(1, MyCols, MyRows) then
    begin
      MyCols := 80;
      MyRows := 24;
    end;
  try
    try
      Sock := TInetSocket.Create(Cfg.Host, Cfg.Port, 3000);
    except
      on E: Exception do
      begin
        Writeln(StdErr, 'tiza shell: cannot reach the hub at ', Cfg.Host, ':',
          Cfg.Port, ': ', E.Message);
        Exit;
      end;
    end;
    WriteLine(Sock, BuildShell(Cfg.Secret, Cfg.SelfId, Team, Term,
      MyCols, MyRows));
    if not ReadReply(Sock.Handle, Line, Surplus) then
    begin
      Writeln(StdErr, 'tiza shell: no answer from the hub');
      Exit;
    end;
    Obj := ParseObj(Line);
    if Obj = nil then
    begin
      Writeln(StdErr, 'tiza shell: unreadable answer from the hub');
      Exit;
    end;
    try
      if not Obj.Get('ok', False) then
      begin
        ErrText := Obj.Get('error', 'refused');
        if ErrText = 'unknown cmd' then
          ErrText := 'this hub is too old for shell (needs 1.1.33 or newer)';
        Writeln(StdErr, 'tiza shell: ', ErrText);
        Exit;
      end;
      User := Obj.Get('user', '?');
      Host := Obj.Get('host', '?');
      Cols := Obj.Get('cols', 0);
      Rows := Obj.Get('rows', 0);
    finally
      Obj.Free;
    end;
    Writeln(StdErr, Format('tiza shell: %s@%s via %s %dx%d - leave with ' +
      'exit or Ctrl-D (wedged: Ctrl-] then q)', [User, Host, Team, Cols, Rows]));
    Writeln(StdErr, 'tiza shell: you are not root here - use sudo su. The ' +
      'far terminal does not follow a resize: run stty rows R cols C inside.');
    { FPC block-buffers a text file that is not a terminal: with stderr
      redirected, the banner would sit in the buffer for the whole session. }
    Flush(StdErr);

    { RAW. From here every byte on stdin belongs to the remote shell, except
      the escape sequence. }
    Raw := Old;
    CFMakeRaw(Raw);
    if TCSetAttr(0, TCSANOW, Raw) <> 0 then
    begin
      Writeln(StdErr, 'tiza shell: cannot put the terminal in raw mode');
      Exit;
    end;
    RawOn := True;
    FromShell := 0;
    Sent := 0;
    if Surplus <> '' then
    begin
      WriteAll(1, Surplus[1], Length(Surplus));
      Inc(FromShell, Length(Surplus));
    end;

    EscPending := False;
    Quit := False;
    if Sock.Handle > 0 then MaxFd := Sock.Handle else MaxFd := 0;
    while (not Quit) and (not ShutdownRequested) do
    begin
      fpFD_ZERO(FDS);
      fpFD_SET(0, FDS);
      fpFD_SET(Sock.Handle, FDS);
      TV.tv_sec := 0;
      TV.tv_usec := TICK_US;
      n := FPSelect(MaxFd + 1, @FDS, nil, nil, @TV);
      if n < 0 then
      begin
        if fpgeterrno = ESysEINTR then
          Continue;
        Break;
      end;
      if n = 0 then
        Continue;

      if fpFD_ISSET(Sock.Handle, FDS) > 0 then
      begin
        n := FpRead(Sock.Handle, @Buf[0], SizeOf(Buf));
        if n <= 0 then
          Break;   { the shell exited, or the hub ended the session }
        Inc(FromShell, n);
        if not WriteAll(1, Buf[0], n) then
          Break;
      end;

      if fpFD_ISSET(0, FDS) > 0 then
      begin
        n := FpRead(0, @Buf[0], SizeOf(Buf));
        if n <= 0 then
          Break;   { stdin closed under us }
        o := 0;
        for i := 0 to n - 1 do
        begin
          if EscPending then
          begin
            EscPending := False;
            if Buf[i] = 'q' then
            begin
              Quit := True;
              Break;
            end;
            { not the escape: both bytes were the user's, forward them so
              readline's character-search still works }
            Out_[o] := ESC_KEY; Inc(o);
            Out_[o] := Buf[i]; Inc(o);
          end
          else if Buf[i] = ESC_KEY then
            EscPending := True
          else
          begin
            Out_[o] := Buf[i];
            Inc(o);
          end;
        end;
        if o > 0 then
        begin
          if not WriteAll(Sock.Handle, Out_[0], o) then
            Break;
          Inc(Sent, o);
        end;
      end;
    end;
    Result := 0;
  finally
    if RawOn then
      TCSetAttr(0, TCSANOW, Old);
    if Sock <> nil then
      Sock.Free;
    if RawOn then
    begin
      Writeln(StdErr, Format('shell closed: %s (%s@%s, %d bytes from the ' +
        'shell, %d bytes sent)', [Team, User, Host, FromShell, Sent]));
      Flush(StdErr);
    end;
  end;
end;

end.
