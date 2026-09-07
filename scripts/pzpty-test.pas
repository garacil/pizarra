{ pzpty-test - proves the three rules of src/pzpty.pas on a real child.

  Spawns /bin/sh under a pty of a known size with a clean environment while
  this process itself carries a poisoned TMUX variable, then checks what the
  child actually saw: its window size, its descriptors, its environment, byte
  round-trip through the master, and that PtyClose leaves no zombie.

  Driven by scripts/test-pzpty.sh. Prints one `ok:` line per proof and exits 1
  on the first `not ok:`. }
program pzpty_test;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, BaseUnix, Sockets, pzpty;

const
  WANT_COLS = 120;
  WANT_ROWS = 40;

var
  Child: TPtyChild;
  Err: string;
  Seen: string;

procedure Fail(const S: string);
begin
  Writeln('not ok: ', S);
  if Child.Pid > 0 then
    PtyClose(Child, 500);
  Halt(1);
end;

procedure Ok(const S: string);
begin
  Writeln('ok: ', S);
end;

{ Append whatever the master has to Seen, waiting up to MaxMs for Needle. }
function ReadUntil(const Needle: string; MaxMs: Integer): Boolean;
var
  FDS: TFDSet;
  TV: TTimeVal;
  Buf: array[0..4095] of Char;
  n: TSsize;
  waited: Integer;
begin
  Result := Pos(Needle, Seen) > 0;
  waited := 0;
  while (not Result) and (waited < MaxMs) do
  begin
    fpFD_ZERO(FDS);
    fpFD_SET(Child.Master, FDS);
    TV.tv_sec := 0;
    TV.tv_usec := 100000;
    if FPSelect(Child.Master + 1, @FDS, nil, nil, @TV) > 0 then
    begin
      n := FpRead(Child.Master, @Buf[0], SizeOf(Buf));
      if n <= 0 then
        Exit(Pos(Needle, Seen) > 0);
      SetLength(Seen, Length(Seen) + n);
      Move(Buf[0], Seen[Length(Seen) - n + 1], n);
      Result := Pos(Needle, Seen) > 0;
    end
    else
      Inc(waited, 100);
  end;
end;

{$IFDEF LINUX}
function ProcDir(const Sub: string): string;
begin
  Result := '/proc/' + IntToStr(Child.Pid) + '/' + Sub;
end;

function CountFds: Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(ProcDir('fd') + '/*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        Inc(Result);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ procfs files report size 0, which defeats a size-driven TFileStream read;
  read with plain syscalls until EOF instead. The open can transiently fail
  while the child is mid-exec (sh replacing its image with cat), so retry
  briefly - a race, not a fault. }
function ChildEnviron: string;
var
  fd: cint;
  Buf: array[0..4095] of Char;
  n: TSsize;
  tries: Integer;
begin
  Result := '';
  { /proc/<pid>/environ exists as soon as the process does, but READS EMPTY in
    the window between fork and the child's execve - the kernel exposes the new
    environment only once exec completes. So the open succeeding is not enough;
    retry the whole open+read until it actually yields the environment. }
  for tries := 1 to 60 do
  begin
    Result := '';
    fd := FpOpen(ProcDir('environ'), O_RDONLY);
    if fd >= 0 then
    begin
      repeat
        n := FpRead(fd, @Buf[0], SizeOf(Buf));
        if n > 0 then
        begin
          SetLength(Result, Length(Result) + n);
          Move(Buf[0], Result[Length(Result) - n + 1], n);
        end;
      until n <= 0;
      FpClose(fd);
    end;
    if Result <> '' then
      Break;
    Sleep(50);
  end;
  { NUL-separated; make it searchable }
  Result := StringReplace(Result, #0, #10, [rfReplaceAll]);
end;
{$ENDIF}

var
  Status: cint;
  Pid: TPid;
  Line: string;
  SV: array[0..1] of cint;
  FromSock, FromPty: Int64;
  Got: string;
  RFDS: TFDSet;
  RTV: TTimeVal;
  RBuf: array[0..1023] of Char;
  rn: TSsize;
  rwait: Integer;
begin
  Child.Pid := 0;
  Child.Master := -1;
  Seen := '';

  if GetEnvironmentVariable('TMUX') = '' then
    Fail('driver must poison TMUX in this process for the test to mean anything');

  if not PtySpawn('/bin/sh',
       ['sh', '-c', 'stty size; echo PTY_READY; cat'],
       ['PATH=/usr/bin:/bin', 'HOME=/tmp', 'TERM=xterm'],
       WANT_COLS, WANT_ROWS, Child, Err) then
    Fail('PtySpawn: ' + Err);
  Ok('spawned pid ' + IntToStr(Child.Pid) + ' on master fd ' + IntToStr(Child.Master));

  if not ReadUntil('PTY_READY', 5000) then
    Fail('child never became ready; saw: ' + Seen);
  { stty prints "rows cols" }
  Line := IntToStr(WANT_ROWS) + ' ' + IntToStr(WANT_COLS);
  if Pos(Line, Seen) = 0 then
    Fail('child window size is not ' + Line + '; saw: ' + Seen);
  Ok('child sees a ' + IntToStr(WANT_COLS) + 'x' + IntToStr(WANT_ROWS) +
     ' terminal at creation');

{$IFDEF LINUX}
  if CountFds <> 3 then
    Fail('child holds ' + IntToStr(CountFds) + ' descriptors, expected exactly 3');
  Ok('child holds exactly fds 0,1,2 - nothing of the parent leaked');

  Line := ChildEnviron;
  if Line = '' then
    Fail('could not read the child environment');
  if Pos(#10'TMUX=', #10 + Line) > 0 then
    Fail('child inherited TMUX from the parent');
  if Pos(#10'TERM=xterm'#10, #10 + Line + #10) = 0 then
    Fail('child did not receive the TERM it was given; environ: ' + Line);
  Ok('child environment is exactly the caller''s: TERM present, TMUX absent');
{$ELSE}
  Ok('descriptor and environment checks skipped (not Linux)');
{$ENDIF}

  Line := 'hello-pty'#10;
  if FpWrite(Child.Master, @Line[1], Length(Line)) <> Length(Line) then
    Fail('write to master failed');
  if not ReadUntil('hello-pty', 3000) then
    Fail('bytes written to the master never came back');
  Ok('byte round-trip through the master works');

  if not PtySetNonBlock(Child.Master, True) then
    Fail('could not set O_NONBLOCK on the master');
  if not PtySetNonBlock(Child.Master, False) then
    Fail('could not clear O_NONBLOCK on the master');
  Ok('non-blocking flag can be set and cleared');

  Pid := Child.Pid;
  PtyClose(Child, 2000);
  if (Child.Pid <> 0) or (Child.Master <> -1) then
    Fail('PtyClose left state behind');
{$IFDEF LINUX}
  if DirectoryExists('/proc/' + IntToStr(Pid)) then
    Fail('child ' + IntToStr(Pid) + ' still exists after PtyClose (zombie?)');
{$ENDIF}
  if PtyReap(Child, Status) <> True then
    Fail('PtyReap on a closed child should report gone');
  Ok('PtyClose ended pid ' + IntToStr(Pid) + ' and reaped it: no zombie');

  { PtyPump round trip: a line written into one end of a socketpair must reach
    the pty child, and the child's answer must come back out of that same end.
    This is the check that catches the FpRead/FpWrite untyped-overload trap -
    a PByte argument relays the pointer's own bytes instead of the buffer, and
    nothing short of an end-to-end round trip notices. The child exits after
    one line, which ends the pump on its own. }
  if fpsocketpair(AF_UNIX, SOCK_STREAM, 0, @SV[0]) <> 0 then
    Fail('socketpair failed');
  if not PtySpawn('/bin/sh', ['sh', '-c', 'read x; echo "got:$x"'],
       ['PATH=/usr/bin:/bin', 'HOME=/tmp', 'TERM=dumb'], 80, 24, Child, Err) then
    Fail('PtySpawn (pump child): ' + Err);
  Line := 'pump-check'#10;
  if FpWrite(SV[1], @Line[1], Length(Line)) <> Length(Line) then
    Fail('write into the socketpair failed');
  PtyPump(SV[0], Child.Master, False, nil, FromSock, FromPty);
  Got := '';
  rwait := 0;
  while (Pos('got:pump-check', Got) = 0) and (rwait < 3000) do
  begin
    fpFD_ZERO(RFDS);
    fpFD_SET(SV[1], RFDS);
    RTV.tv_sec := 0;
    RTV.tv_usec := 100000;
    if FPSelect(SV[1] + 1, @RFDS, nil, nil, @RTV) > 0 then
    begin
      rn := FpRead(SV[1], @RBuf[0], SizeOf(RBuf));
      if rn <= 0 then
        Break;
      SetLength(Got, Length(Got) + rn);
      Move(RBuf[0], Got[Length(Got) - rn + 1], rn);
    end
    else
      Inc(rwait, 100);
  end;
  PtyClose(Child, 1000);
  FpClose(SV[0]);
  FpClose(SV[1]);
  if Pos('got:pump-check', Got) = 0 then
    Fail('PtyPump did not relay the round trip; came back: ' + Got);
  if FromSock < Length(Line) then
    Fail('PtyPump miscounted the bytes it read from the socket');
  Ok(Format('PtyPump relays both ways (%d bytes in, %d bytes out)',
    [FromSock, FromPty]));

  Writeln('all pzpty checks passed');
end.
