{ pztmux - deliver a wrapped message into a LOCAL tmux session, and keep that
  session alive. Used by the pizarra hub (local teams) and by the tiza daemon
  on each team host (its own sessions).

  Delivery uses a buffer + bracketed paste so multi-line text lands as a
  single input in an interactive agent TUI, then one Enter submits:
      printf '<text>' | tmux load-buffer -b <buf> -    (stdin: no length limit)
      tmux paste-buffer -b <buf> -d -p -t <session>
      (300 ms)
      tmux send-keys   -t <session> Enter
  This sequence has been validated with interactive agent sessions.
  (load-buffer via stdin replaced 'set-buffer -- <text>', which tmux rejected
  as 'command too long' once a delivery exceeded ~16 KB.)

  Remote (ssh) and headless delivery were removed in v2: remote teams run
  their own tiza daemon and the hub pushes over TCP (see pznet). The v1 code
  lives in git history if ever needed.                                       }
unit pztmux;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Process;

{ Returns True if the tmux session currently exists. }
function SessionExists(const Session: string): Boolean;

{ Capture the VISIBLE pane of the session (no scrollback) as plain text.
  Returns '' if the session is gone or tmux fails. Read-only, no side effects —
  used by the activity sampler to diff successive frames. }
function CapturePane(const Session: string): string;

{ Classify a QUIET pane by its bottom lines: 'blocked' (a permission prompt),
  'busy' (a recognized working footer), or 'idle' (anything else quiet). Built-in
  markers cover common permission and activity prompts; ExtraIdle/ExtraBlock are
  optional '|'-separated substrings from config. Only meaningful once a pane is quiet —
  a working agent whose counters tick is 'moving' and never reaches here. }
function ClassifyPane(const Pane, ExtraIdle, ExtraBlock: string): string;

{ Create the tmux session running Launch if it is missing. Workdir (optional)
  is the session start directory (tmux -c). Returns True if the session
  exists afterwards. }
function EnsureSession(const Session, Launch: string;
  const Workdir: string = ''; const User: string = ''): Boolean;

{ Deliver FullText into the session (bracketed paste + Enter). }
function DeliverTmux(const Session, FullText: string): Boolean;

{ Press a single Enter in the pane (no text) - the daemon's opt-in auto_enter
  uses it to clear a permission prompt by accepting its highlighted default. }
function SendEnter(const Session: string): Boolean;

{ The team-config path the daemon tagged THIS tmux session with (@pizarra_conf),
  or '' when not inside tmux or untagged. Lets a bare `tiza` sign as the session's
  team BY CONSTRUCTION even when the child process did not carry TIZA_CONF in
  its environment. }
function TmuxSessionConf: string;

{ Tag a session with the config path a bare `tiza` there must use. }
procedure TagSessionConf(const Session, ConfPath: string);

{ OTHER tmux sessions that may represent the same team: sessions beginning with
  its name and a dash, or carrying the same ownership tag. Return '' when there
  is no ambiguity.

  A restarted agent can move to a NEW session while the old one remains alive.
  The hub then keeps delivering to the old pane and logs success even though no
  one reads it. Surface the ambiguity instead of silently guessing. }
function OtherSessionsLike(const TeamName, Configured: string): string;

{ Mark a session as belonging to a team through the tmux user option
  @pizarra_team. This is a verifiable FACT, not a naming convention. }
procedure TagSession(const Session, TeamName: string);

implementation

{ Run a process, inherit stdio, wait, return exit status (-1 on spawn failure). }
function RunStatus(const Exe: string; const Args: array of string): Integer;
var
  P: TProcess;
  i: Integer;
begin
  Result := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do
      P.Parameters.Add(Args[i]);
    P.Options := [poWaitOnExit];
    try
      P.Execute;
      Result := P.ExitStatus;
    except
      Result := -1;
    end;
  finally
    P.Free;
  end;
end;

{ Run a process, feed Input to its stdin, wait, return exit status. Used to hand
  tmux the paste text via 'load-buffer -' (stdin) instead of as a command
  argument, which tmux rejects with 'command too long' past ~16 KB. }
function RunStatusStdin(const Exe: string; const Args: array of string;
  const Input: string): Integer;
var
  P: TProcess;
  i, n: Integer;
  Buf: array[0..4095] of Byte;
begin
  Result := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do
      P.Parameters.Add(Args[i]);
    P.Options := [poUsePipes, poStderrToOutPut];
    try
      P.Execute;
      if Input <> '' then
        P.Input.WriteBuffer(Input[1], Length(Input));
      P.CloseInput;   { EOF so 'load-buffer -' stops reading }
      { drain output so the child can never block on a full stdout pipe }
      repeat
        n := P.Output.Read(Buf, SizeOf(Buf));
      until (n = 0) and (not P.Running);
      Result := P.ExitStatus;
    except
      Result := -1;
    end;
  finally
    P.Free;
  end;
end;

{ Run a process capturing stdout+stderr; return exit status, output in Output. }
function RunCapture(const Exe: string; const Args: array of string; out Output: string): Integer;
var
  P: TProcess;
  i, n: Integer;
  Buf: array[0..4095] of Byte;
  MS: TMemoryStream;
begin
  Result := -1;
  Output := '';
  P := TProcess.Create(nil);
  MS := TMemoryStream.Create;
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do
      P.Parameters.Add(Args[i]);
    P.Options := [poUsePipes, poStderrToOutPut];
    try
      P.Execute;
      repeat
        n := P.Output.Read(Buf, SizeOf(Buf));
        if n > 0 then
          MS.Write(Buf, n);
      until (n = 0) and (not P.Running);
      { drain any tail }
      repeat
        n := P.Output.Read(Buf, SizeOf(Buf));
        if n > 0 then
          MS.Write(Buf, n);
      until n = 0;
      SetString(Output, PChar(MS.Memory), MS.Size);
      Result := P.ExitStatus;
    except
      Result := -1;
    end;
  finally
    MS.Free;
    P.Free;
  end;
end;

{ tmux buffer names allow letters/digits/_; keep it simple and safe. }
function BufName(const Session: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := 'pz_';
  for i := 1 to Length(Session) do
  begin
    c := Session[i];
    if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
       ((c >= '0') and (c <= '9')) then
      Result := Result + c
    else
      Result := Result + '_';
  end;
end;

function SessionExists(const Session: string): Boolean;
var
  Ignore: string;
begin
  if Session = '' then
    Exit(False);
  { RunCapture swallows tmux's "can't find session" stderr noise }
  Result := RunCapture('tmux', ['has-session', '-t', Session], Ignore) = 0;
end;

function CapturePane(const Session: string): string;
var
  Out_: string;
begin
  Result := '';
  if Session = '' then
    Exit;
  { -p prints to stdout; no -S/-E so it captures the VISIBLE pane only, not the
    scrollback — the current screen is what tells moving from frozen. }
  if RunCapture('tmux', ['capture-pane', '-p', '-t', Session], Out_) = 0 then
    Result := Out_;
end;

function ClassifyPane(const Pane, ExtraIdle, ExtraBlock: string): string;
const
  { Common interactive markers; a session can add its own via *_match.
    Permission prompts include 'do you want to', numbered choices, '(y/n)' and
    'esc dismiss'. Working footers commonly contain an interrupt/cancel hint. }
  BUILTIN_BLOCK = 'do you want to|❯ 1.|1. yes|(y/n|[y/n]|esc dismiss';
  BUILTIN_BUSY  = 'esc to interrupt|esc to cancel|esc interrupt';
var
  Lines: TStringList;
  tail: string;
  i, kept: Integer;

  { true if any '|'-separated needle (lowercased, trimmed) is in the tail }
  function HasAny(const NeedlesPipe: string): Boolean;
  var
    s, nd: string;
    p: Integer;
  begin
    Result := False;
    s := NeedlesPipe;
    while s <> '' do
    begin
      p := Pos('|', s);
      if p > 0 then
      begin
        nd := Copy(s, 1, p - 1);
        Delete(s, 1, p);
      end
      else
      begin
        nd := s;
        s := '';
      end;
      nd := LowerCase(Trim(nd));
      if (nd <> '') and (Pos(nd, tail) > 0) then
        Exit(True);
    end;
  end;

begin
  { the prompt lives at the bottom: fold the last ~6 non-empty lines, lowercased }
  Lines := TStringList.Create;
  try
    Lines.Text := Pane;
    tail := '';
    kept := 0;
    for i := Lines.Count - 1 downto 0 do
    begin
      if Trim(Lines[i]) = '' then
        Continue;
      tail := LowerCase(Lines[i]) + #10 + tail;
      Inc(kept);
      if kept >= 6 then
        Break;
    end;
  finally
    Lines.Free;
  end;
  if HasAny(BUILTIN_BLOCK) or HasAny(ExtraBlock) then
    Result := 'blocked'
  else if HasAny(ExtraIdle) then
    Result := 'idle'                { explicit idle override beats a busy footer }
  else if HasAny(BUILTIN_BUSY) then
    Result := 'busy'
  else
    Result := 'idle';              { quiet, no prompt, no working footer = free }
end;

{ single-quote S safely for /bin/sh (wrap in '...', escape inner ' as '\'') }
function ShQuote(const S: string): string;
const Q = #39;
begin
  Result := Q + StringReplace(S, Q, Q + '\' + Q + Q, [rfReplaceAll]) + Q;
end;

function EnsureSession(const Session, Launch: string;
  const Workdir, User: string): Boolean;
var
  Cmd: string;
begin
  if Session = '' then
    Exit(False);
  if SessionExists(Session) then
    Exit(True);
  if Launch = '' then
    Exit(False);
  if (Workdir <> '') and (not DirectoryExists(Workdir)) then
  begin
    { a configured workdir that is not there yet (NFS not mounted, typo) —
      do NOT launch in the wrong dir; the watchdog retries next tick }
    Writeln(StdErr, 'tiza: workdir not present, deferring session ',
      Session, ': ', Workdir);
    Exit(False);
  end;
  { When a user is set, run the launch AS that user via a login shell (su -,
    so HOME/env are the user's), cd-ing into the workdir. This
    is how a team's session is confined to a non-root user without hand-writing
    the su wrapper in 'launch'. '' or 'root' = run as the daemon user (as-is). }
  if (User <> '') and (User <> 'root') then
  begin
    Cmd := Launch;
    if Workdir <> '' then
      Cmd := 'cd ' + ShQuote(Workdir) + ' && exec ' + Launch;
    Cmd := 'su - ' + User + ' -c ' + ShQuote(Cmd);
    if Workdir <> '' then
      RunStatus('tmux', ['new-session', '-d', '-s', Session, '-c', Workdir, Cmd])
    else
      RunStatus('tmux', ['new-session', '-d', '-s', Session, Cmd]);
  end
  else if Workdir <> '' then
    RunStatus('tmux', ['new-session', '-d', '-s', Session, '-c', Workdir, Launch])
  else
    RunStatus('tmux', ['new-session', '-d', '-s', Session, Launch]);
  Result := SessionExists(Session);
end;

{ Remove C0 control bytes that could break out of the bracketed paste (a raw
  ESC can inject the paste-end sequence; a NUL truncates the argv string), while
  keeping TAB and the newlines that make multi-line delivery land as one block. }
function SanitizeForPaste(const S: string): string;
var
  i: Integer;
  c: Byte;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := Byte(S[i]);
    if (c >= 32) or (c = 9) or (c = 10) or (c = 13) then
      Result := Result + S[i];
  end;
end;

procedure TagSession(const Session, TeamName: string);
begin
  if (Trim(Session) = '') or (Trim(TeamName) = '') then
    Exit;
  RunStatus('tmux', ['set-option', '-t', Session, '@pizarra_team', TeamName]);
end;

function OtherSessionsLike(const TeamName, Configured: string): string;
var
  Outp, Line, LName, Tag: string;
  L: TStringList;
  i, j: Integer;
  Base: string;
begin
  Result := '';
  if Trim(TeamName) = '' then
    Exit;
  { Ask for the @pizarra_team TAG, not just the session name. Inferring identity
    from a name is unsafe because session names need not resemble team names.
    A tag is verifiable state; a name is convention. Name similarity remains
    only as a fallback for sessions created before tagging existed. }
  if RunCapture('tmux',
     ['list-sessions', '-F', '#{session_name}' + #9 + '#{@pizarra_team}'],
     Outp) <> 0 then
    Exit;
  Base := LowerCase(Trim(TeamName));
  L := TStringList.Create;
  try
    L.Text := Outp;
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if Line = '' then
        Continue;
      Tag := '';
      j := Pos(#9, Line);
      if j > 0 then
      begin
        Tag := Trim(Copy(Line, j + 1, Length(Line)));
        Line := Trim(Copy(Line, 1, j - 1));
      end;
      if SameText(Line, Configured) then
        Continue;              { This is the intended session, not another one. }
      LName := LowerCase(Line);
      if SameText(Tag, TeamName) or
         (LName = Base) or (Copy(LName, 1, Length(Base) + 1) = Base + '-') then
      begin
        if Result <> '' then
          Result := Result + ', ';
        Result := Result + Line;
      end;
    end;
  finally
    L.Free;
  end;
end;

function DeliverTmux(const Session, FullText: string): Boolean;
var
  Buf: string;
begin
  { NEVER accept an empty or '-' target. tmux may resolve both -t '' and -t '-'
    to the ACTIVE session, so an unnamed destination can succeed in ANOTHER
    agent's terminal. Reject it at the destructive boundary as well as during
    configuration loading. }
  if (Trim(Session) = '') or (Trim(Session) = '-') then
  begin
    Writeln(StdErr, 'tiza: refusing to paste into an unnamed tmux target');
    Flush(StdErr);
    Exit(False);
  end;
  { every step must succeed — a failed set/paste with a succeeding Enter
    would confirm a delivery that never reached the pane }
  Buf := BufName(Session);
  { load-buffer reads the text from stdin, so it has no command-length limit;
    'set-buffer -- <text>' passes it as an argument, which tmux rejects with
    'command too long' past ~16 KB (a full delivery header can exceed that) }
  if RunStatusStdin('tmux', ['load-buffer', '-b', Buf, '-'],
    SanitizeForPaste(FullText)) <> 0 then
    Exit(False);
  if RunStatus('tmux', ['paste-buffer', '-b', Buf, '-d', '-p', '-t', Session]) <> 0 then
    Exit(False);
  Sleep(300);
  Result := RunStatus('tmux', ['send-keys', '-t', Session, 'Enter']) = 0;
end;

function SendEnter(const Session: string): Boolean;
begin
  Result := (Trim(Session) <> '') and SessionExists(Session) and
    (RunStatus('tmux', ['send-keys', '-t', Session, 'Enter']) = 0);
end;

function TmuxSessionConf: string;
var
  Outp: string;
begin
  Result := '';
  if GetEnvironmentVariable('TMUX') = '' then
    Exit;   { not inside tmux: no session to ask }
  { -v prints just the value; scoped to the current session via $TMUX }
  if RunCapture('tmux', ['show-options', '-v', '@pizarra_conf'], Outp) = 0 then
    Result := Trim(Outp);
end;

procedure TagSessionConf(const Session, ConfPath: string);
begin
  if (Trim(Session) = '') or (Trim(ConfPath) = '') then
    Exit;
  RunStatus('tmux', ['set-option', '-t', Session, '@pizarra_conf', ConfPath]);
end;

end.
