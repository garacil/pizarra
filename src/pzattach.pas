{ pzattach - the `tiza attach <team> [--write]` client.

  Opens a raw terminal into a team's tmux session through the hub. One JSON
  handshake, one JSON reply, then the connection is bytes both ways: what the
  far tmux client draws comes to this terminal, what is typed here goes to it
  (write mode) or nowhere (read-only, the default).

  The local terminal goes fully raw with termio's own CFMakeRaw - not the
  console's partial raw mode, which keeps ISIG so Ctrl-C ends the chat. Here
  Ctrl-C is a byte that belongs to the remote pane. Two sequences this client
  interprets locally to detach: Ctrl-b then d (tmux's own prefix + detach, the
  familiar key and typeable on every layout) and Ctrl-] then q. Both work in
  read-only too, where every other key is dropped. Everything else is forwarded
  verbatim in write mode, or read and dropped in read-only.

  Never RequestLine: it frees the socket after one reply. Never
  pzproto.ReadLine on the raw side: it reads one byte per syscall and cannot
  tell a timeout from a close. }
unit pzattach;

{$mode objfpc}{$H+}

interface

uses
  pzconfig;

{ Returns the process exit code: 0 after a clean detach, 1 when the hub
  refused, the connection failed, or stdin is not a terminal. }
function RunAttach(const Cfg: TTizaConfig; const Team: string;
  Write: Boolean): Integer;

implementation

uses
  SysUtils, BaseUnix, termio, ssockets, fpjson,
  pzproto, pznet, pzpty;

const
  ESC_KEY      = #29;      { Ctrl-]  - classic escape, then q to detach }
  TMUX_PFX     = #2;       { Ctrl-b  - tmux's own prefix, then d to detach.
                            The familiar key, and typeable on every keyboard
                            layout (Ctrl-] is AltGr gymnastics on e.g. a Spanish
                            layout). Works read-only too: it detaches HERE, it
                            is not forwarded, so it never reaches the far tmux
                            as a switch-client that would let a viewer browse
                            other sessions. }
  REPLY_MS     = 15000;    { the hub must answer the handshake within this }
  TICK_US      = 500000;

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

{ Read the hub's one reply line. Whatever arrives after the newline is
  already terminal output and is handed back in Surplus, never lost. }
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

function RunAttach(const Cfg: TTizaConfig; const Team: string;
  Write: Boolean): Integer;
var
  Old, Raw: Termios;   { Termios, not TTermios: TTermios is Linux-only; the daemon that pulls in pzattach is compiled on the macOS endpoint }
  Sock: TInetSocket;
  Line, Surplus, Term, Mode, ErrText: string;
  Obj: TJSONObject;
  Granted: Boolean;
  Cols, Rows: Integer;
  MyCols, MyRows: Word;
  FDS: TFDSet;
  TV: TTimeVal;
  MaxFd: cint;
  Buf: array[0..8191] of Char;
  Out_: array[0..8191] of Char;
  n, i, o: Integer;
  EscPending, PfxPending, Quit, RawOn: Boolean;
  FromTerm, Sent: Int64;
begin
  Result := 1;
  RawOn := False;
  Sock := nil;
  if TCGetAttr(0, Old) <> 0 then
  begin
    Writeln(StdErr, 'tiza attach: stdin is not a terminal');
    Exit;
  end;
  { SIGPIPE must not kill this process with the terminal left raw; the same
    handler also lets SIGTERM end the loop cleanly through ShutdownRequested. }
  InstallShutdownHandler;

  Term := GetEnvironmentVariable('TERM');
  if Term = '' then
    Term := 'xterm-256color';
  try
    try
      Sock := TInetSocket.Create(Cfg.Host, Cfg.Port, 3000);
    except
      on E: Exception do
      begin
        Writeln(StdErr, 'tiza attach: cannot reach the hub at ', Cfg.Host, ':',
          Cfg.Port, ': ', E.Message);
        Exit;
      end;
    end;
    WriteLine(Sock, BuildAttach(Cfg.Secret, Cfg.SelfId, Team, Write, Term));
    if not ReadReply(Sock.Handle, Line, Surplus) then
    begin
      Writeln(StdErr, 'tiza attach: no answer from the hub');
      Exit;
    end;
    Obj := ParseObj(Line);
    if Obj = nil then
    begin
      Writeln(StdErr, 'tiza attach: unreadable answer from the hub');
      Exit;
    end;
    try
      if not Obj.Get('ok', False) then
      begin
        ErrText := Obj.Get('error', 'refused');
        if ErrText = 'unknown cmd' then
          ErrText := 'this hub is too old for attach (needs 1.1.28 or newer)';
        Writeln(StdErr, 'tiza attach: ', ErrText);
        Exit;
      end;
      Granted := Obj.Get('write', False);
      Cols := Obj.Get('cols', 0);
      Rows := Obj.Get('rows', 0);
    finally
      Obj.Free;
    end;
    if Granted then
      Mode := 'write'
    else
      Mode := 'read-only';
    if Write and (not Granted) then
      Writeln(StdErr, 'tiza attach: write was not granted; this session is read-only');
    Writeln(StdErr, Format('tiza attach: %s (%s) %dx%d - detach with Ctrl-b d ' +
      '(or Ctrl-] then q)', [Team, Mode, Cols, Rows]));
    if PtyWindowSize(1, MyCols, MyRows) then
      if (Integer(MyCols) < Cols) or (Integer(MyRows) < Rows) then
        Writeln(StdErr, Format('tiza attach: your terminal is %dx%d and the ' +
          'session is %dx%d: output will wrap or clip here; the session is ' +
          'never resized to fit a viewer', [MyCols, MyRows, Cols, Rows]));
    { FPC block-buffers a text file that is not a terminal: with stderr
      redirected, the banner would sit in the buffer for the whole session. }
    Flush(StdErr);

    { RAW. From here every byte on stdin is the remote pane's, except the
      escape sequence. }
    Raw := Old;
    CFMakeRaw(Raw);
    if TCSetAttr(0, TCSANOW, Raw) <> 0 then
    begin
      Writeln(StdErr, 'tiza attach: cannot put the terminal in raw mode');
      Exit;
    end;
    RawOn := True;
    FromTerm := 0;
    Sent := 0;
    if Surplus <> '' then
    begin
      WriteAll(1, Surplus[1], Length(Surplus));
      Inc(FromTerm, Length(Surplus));
    end;

    EscPending := False;
    PfxPending := False;
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
          Break;   { the hub or the far side ended the session }
        Inc(FromTerm, n);
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
    PfxPending := False;
            if Buf[i] = 'q' then
            begin
              Quit := True;
              Break;
            end;
            { not the escape: both bytes were the user's, forward them }
            if Granted then
            begin
              Out_[o] := ESC_KEY; Inc(o);
              Out_[o] := Buf[i]; Inc(o);
            end;
          end
          else if PfxPending then
          begin
            PfxPending := False;
            if Buf[i] = 'd' then
            begin
              Quit := True;
              Break;
            end;
            { Ctrl-b then something other than d was a real tmux prefix command;
              forward BOTH bytes so the far tmux still sees it (write mode). In
              read-only nothing is forwarded, as with any other key. }
            if Granted then
            begin
              Out_[o] := TMUX_PFX; Inc(o);
              Out_[o] := Buf[i]; Inc(o);
            end;
          end
          else if Buf[i] = ESC_KEY then
            EscPending := True
          else if Buf[i] = TMUX_PFX then
            PfxPending := True
          else if Granted then
          begin
            Out_[o] := Buf[i];
            Inc(o);
          end;
        end;
        if (o > 0) and Granted then
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
      Writeln(StdErr, Format('attach closed: %s (%s, %d bytes from the ' +
        'terminal, %d bytes sent)', [Team, Mode, FromTerm, Sent]));
      Flush(StdErr);
    end;
  end;
end;

end.
