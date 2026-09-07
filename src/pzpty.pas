{ pzpty - spawn a program under a pseudo-terminal and manage its lifetime.

  Used by `tiza attach`: the daemon runs `tmux attach-session` as a child that
  believes it owns a real terminal, and relays that terminal's bytes over the
  bus. TProcess cannot do this (fcl-process gives the child pipes, never a
  tty - packages/fcl-process/src/unix/process.inc), and tmux refuses pipes with
  "open terminal failed: not a terminal", so this unit does the fork/exec by
  hand.

  Three rules, each learned from a real failure and enforced here:

  1. EVERYTHING THE CHILD NEEDS IS BUILT BEFORE FORK. This process is threaded;
     between fork() and execve() the child holds a copy of every lock in the
     state it was in, including the RTL heap lock. Allocating there can deadlock
     forever. The child path below performs only system calls.

  2. THE CHILD CLOSES EVERY DESCRIPTOR IT DID NOT ASK FOR. Nothing in fcl-net
     marks sockets close-on-exec, so a child would otherwise inherit the
     daemon's listening socket and every live connection. An attach child lives
     for hours: it would keep a dead listener bound across a self-update and
     hold closed peers open. Descriptors >= 3 are closed up to RLIMIT_NOFILE.

  3. THE ENVIRONMENT IS THE CALLER'S, VERBATIM. FpExecv would hand the child
     this process's STARTUP environment (rtl/linux/bunxsysc.inc:448-451), which
     in production contains TMUX - and a tmux client started with TMUX set does
     not attach, it switches the daemon's OWN client. The caller passes the
     exact 'NAME=value' list; nothing is inherited.

  openpty(3) is not in the FPC RTL (only the deprecated Linux/i386 `libc`
  unit declares it). It is bound here the way pizarra binds fchmod - but with
  one thing that binding gets for free and this unit must ask for: an FPC
  program on Linux links NO libc unless a unit requests it. pizarra and tiza
  get theirs through cthreads; a program that uses only this unit would get
  none and fail to link. Hence the LINKLIB c directive below. On glibc >= 2.34
  openpty lives in libc itself (libutil.so.1 is an empty compatibility shim);
  on older glibc it is only in libutil, hence the second directive. Darwin
  links libSystem always and needs neither. The /dev/ptmx route was rejected
  on purpose: FPC defines TIOCGPTN only for sparc, and Darwin's pty ioctls
  differ. (No brace inside this comment: FPC nests a brace in a block comment
  and -Sew turns that warning into a build failure.) }
unit pzpty;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, BaseUnix, termio;

{$IFDEF LINUX}
  {$LINKLIB c}
  {$LINKLIB util}
{$ENDIF}

type
  TPtyChild = record
    Pid:    TPid;   { 0 = none }
    Master: cint;   { -1 = none; the side this process reads and writes }
  end;

{ Spawn Exe with Argv (Argv[0] included, as the program will see it) and the
  environment Env (each entry 'NAME=value', nothing else is inherited) under a
  new pseudo-terminal whose window is Cols x Rows. On success Child holds the
  pid and the master descriptor. Err names the failing step. }
function PtySpawn(const Exe: string; const Argv, Env: array of string;
  Cols, Rows: Word; out Child: TPtyChild; out Err: string): Boolean;

{ Set or clear O_NONBLOCK on a descriptor. A relay must never block inside a
  write it cannot interrupt: TSocketHandler.Send retries EINTR forever, so a
  shutdown signal alone does not free a thread stuck in one. }
function PtySetNonBlock(Fd: cint; On_: Boolean): Boolean;

{ Reap without waiting. True once the child has exited; Status is then valid
  and Child.Pid is cleared. }
function PtyReap(var Child: TPtyChild; out Status: cint): Boolean;

{ End the child and release everything: SIGHUP, up to GraceMs of polling for
  a clean exit, then SIGKILL. The master is closed last. Safe to call twice. }
procedure PtyClose(var Child: TPtyChild; GraceMs: Integer);

{ Current size of the terminal on Fd, or False when Fd is not a terminal.
  TIOCGWINSZ and TWinSize come from termio, which carries the platform's own
  values (Linux $5413, Darwin $40087468) - never hardcode the Linux number. }
function PtyWindowSize(Fd: cint; out Cols, Rows: Word): Boolean;

type
  { Asked on every tick; True ends the pump (the caller's shutdown flag). }
  TPumpStop = function: Boolean;

{ Relay bytes both ways between descriptors A and B until either side ends,
  a write fails, or Stop says so. Both descriptors are switched to
  non-blocking and driven by select, with ONE pending buffer per direction:
  a side is read only while the opposite pending buffer is empty, and a
  descriptor is polled for writability only while there is something to give
  it. That is what makes the relay unable to deadlock when both peers are
  full at once, and unable to sit in a write that a signal cannot interrupt.

  DropAtoB: bytes arriving from A are discarded instead of forwarded - the
  read-only attach, where a viewer's keystrokes must never reach the terminal.
  FromA/FromB count the bytes read from each side, for the closing log line. }
procedure PtyPump(A, B: cint; DropAtoB: Boolean; Stop: TPumpStop;
  out FromA, FromB: Int64);

implementation

uses
  unixutil;

{ int openpty(int *amaster, int *aslave, char *name,
              const struct termios *termp, const struct winsize *winp) }
function C_OpenPty(var AMaster, ASlave: cint; AName: PChar;
  TermP, WinP: Pointer): cint; cdecl; external name 'openpty';

const
  { RLIMIT_NOFILE can be "infinity" or millions; a close loop that long in every
    spawn is pointless. Anything a daemon really holds is far below this. }
  MAX_CLOSE_FD = 65536;

function PtySpawn(const Exe: string; const Argv, Env: array of string;
  Cols, Rows: Word; out Child: TPtyChild; out Err: string): Boolean;
var
  Master, Slave: cint;
  Ws: TWinSize;
  ExePath: PChar;
  ArgvRaw, EnvRaw: array of RawByteString;
  ArgvP, EnvP: PPChar;
  i, FdMax: Integer;
  Lim: TRLimit;
  Pid: TPid;
begin
  Result := False;
  Err := '';
  Child.Pid := 0;
  Child.Master := -1;
  if (Exe = '') or (Length(Argv) = 0) then
  begin
    Err := 'pty: nothing to run';
    Exit;
  end;

  { Rule 1: every allocation happens here, in the parent, before fork. }
  SetLength(ArgvRaw, Length(Argv));
  for i := 0 to High(Argv) do
    ArgvRaw[i] := Argv[i];
  SetLength(EnvRaw, Length(Env));
  for i := 0 to High(Env) do
    EnvRaw[i] := Env[i];
  ExePath := PChar(Exe);
  ArgvP := ArrayStringToPPchar(ArgvRaw, 0);
  EnvP := ArrayStringToPPchar(EnvRaw, 0);
  try
    FillChar(Ws, SizeOf(Ws), 0);
    Ws.ws_col := Cols;
    Ws.ws_row := Rows;
    { The size exists at creation: no later TIOCSWINSZ, no SIGWINCH, no
      window between exec and the program's first size query. }
    if C_OpenPty(Master, Slave, nil, nil, @Ws) <> 0 then
    begin
      Err := 'pty: openpty failed (errno ' + IntToStr(fpgeterrno) + ')';
      Exit;
    end;

    FdMax := 1024;
    if FpGetRLimit(RLIMIT_NOFILE, @Lim) = 0 then
      if (Lim.rlim_cur > 0) and (Lim.rlim_cur < MAX_CLOSE_FD) then
        FdMax := Lim.rlim_cur
      else
        FdMax := MAX_CLOSE_FD;

    Pid := FpFork;
    if Pid < 0 then
    begin
      Err := 'pty: fork failed (errno ' + IntToStr(fpgeterrno) + ')';
      FpClose(Master);
      FpClose(Slave);
      Exit;
    end;

    if Pid = 0 then
    begin
      { CHILD. System calls only from here to execve - see rule 1. }
      FpSetsid;
      FpIOCtl(Slave, TIOCSCTTY, nil);
      FpDup2(Slave, 0);
      FpDup2(Slave, 1);
      FpDup2(Slave, 2);
      { Rule 2. Slave and Master are both >= 3 and go with the rest. }
      for i := 3 to FdMax - 1 do
        FpClose(i);
      FpExecve(ExePath, ArgvP, EnvP);
      { Only reached when execve failed. Never Halt: that would run this
        process's exit code and flush its buffers from inside the child. }
      FpExit(127);
    end;

    { PARENT }
    FpClose(Slave);
    Child.Pid := Pid;
    Child.Master := Master;
    Result := True;
  finally
    if ArgvP <> nil then
      FreeMem(ArgvP);
    if EnvP <> nil then
      FreeMem(EnvP);
  end;
end;

function PtySetNonBlock(Fd: cint; On_: Boolean): Boolean;
var
  Flags: cint;
begin
  Result := False;
  if Fd < 0 then
    Exit;
  Flags := FpFcntl(Fd, F_GetFl);
  if Flags < 0 then
    Exit;
  if On_ then
    Flags := Flags or O_NONBLOCK
  else
    Flags := Flags and (not O_NONBLOCK);
  Result := FpFcntl(Fd, F_SetFl, Flags) >= 0;
end;

function PtyReap(var Child: TPtyChild; out Status: cint): Boolean;
var
  r: TPid;
begin
  Result := False;
  Status := 0;
  if Child.Pid <= 0 then
    Exit(True);
  r := FpWaitpid(Child.Pid, @Status, WNOHANG);
  if r = Child.Pid then
  begin
    Child.Pid := 0;
    Result := True;
  end
  else if r < 0 then
  begin
    { ECHILD: already reaped elsewhere, or never ours. Either way it is gone. }
    Child.Pid := 0;
    Result := True;
  end;
end;

procedure PtyClose(var Child: TPtyChild; GraceMs: Integer);
var
  Status: cint;
  waited: Integer;
begin
  if Child.Pid > 0 then
  begin
    { HUP first: it is what a closing terminal would send, and a tmux client
      detaches cleanly on it. }
    FpKill(Child.Pid, SIGHUP);
    waited := 0;
    while (Child.Pid > 0) and (waited < GraceMs) do
    begin
      if PtyReap(Child, Status) then
        Break;
      Sleep(50);
      Inc(waited, 50);
    end;
    if Child.Pid > 0 then
    begin
      { This is the attach client, never an agent: killing it is safe. }
      FpKill(Child.Pid, SIGKILL);
      waited := 0;
      while (Child.Pid > 0) and (waited < 2000) do
      begin
        if PtyReap(Child, Status) then
          Break;
        Sleep(50);
        Inc(waited, 50);
      end;
    end;
    Child.Pid := 0;
  end;
  if Child.Master >= 0 then
  begin
    FpClose(Child.Master);
    Child.Master := -1;
  end;
end;

function PtyWindowSize(Fd: cint; out Cols, Rows: Word): Boolean;
var
  Ws: TWinSize;
begin
  Cols := 0;
  Rows := 0;
  Result := False;
  if Fd < 0 then
    Exit;
  FillChar(Ws, SizeOf(Ws), 0);
  if fpIOCtl(Fd, TIOCGWINSZ, @Ws) < 0 then
    Exit;
  Cols := Ws.ws_col;
  Rows := Ws.ws_row;
  Result := (Cols > 0) and (Rows > 0);
end;

const
  PUMP_BUF     = 65536;
  PUMP_TICK_US = 500000;   { select granularity: shutdown is noticed within this }

procedure PtyPump(A, B: cint; DropAtoB: Boolean; Stop: TPumpStop;
  out FromA, FromB: Int64);
var
  RFds, WFds: TFDSet;
  TV: TTimeVal;
  MaxFd, Sel: cint;
  { pending bytes read from A (to write to B) and from B (to write to A) }
  PendAB, PendBA: array of Byte;
  LenAB, OffAB, LenBA, OffBA: Integer;
  EofA, EofB, Done: Boolean;
  n: TSsize;
  e: cint;

  { True when the errno of a failed read/write means "try again later". }
  function Transient(Err: cint): Boolean;
  begin
    Result := (Err = ESysEAGAIN) or (Err = ESysEWOULDBLOCK) or (Err = ESysEINTR);
  end;

begin
  FromA := 0;
  FromB := 0;
  SetLength(PendAB, PUMP_BUF);
  SetLength(PendBA, PUMP_BUF);
  LenAB := 0; OffAB := 0;
  LenBA := 0; OffBA := 0;
  EofA := False;
  EofB := False;
  Done := False;
  PtySetNonBlock(A, True);
  PtySetNonBlock(B, True);
  if A > B then MaxFd := A else MaxFd := B;

  while not Done do
  begin
    if Assigned(Stop) and Stop() then
      Break;
    fpFD_ZERO(RFds);
    fpFD_ZERO(WFds);
    { read a side only while its outgoing buffer is empty; poll a side for
      writing only while there is something for it }
    if (not EofA) and (LenAB = 0) then
      fpFD_SET(A, RFds);
    if (not EofB) and (LenBA = 0) then
      fpFD_SET(B, RFds);
    if LenAB > 0 then
      fpFD_SET(B, WFds);
    if LenBA > 0 then
      fpFD_SET(A, WFds);
    TV.tv_sec := 0;
    TV.tv_usec := PUMP_TICK_US;
    Sel := FPSelect(MaxFd + 1, @RFds, @WFds, nil, @TV);
    if Sel < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        Continue;
      Break;
    end;
    if Sel = 0 then
      Continue;

    { A -> (drop | PendAB) }
    if fpFD_ISSET(A, RFds) > 0 then
    begin
      { PChar on purpose: FpRead/FpWrite also have an UNTYPED var overload,
        and a PByte expression selects it - which passes the address of a
        temporary holding the pointer, not the buffer. Silent garbage. }
      n := FpRead(A, PChar(@PendAB[0]), PUMP_BUF);
      if n > 0 then
      begin
        Inc(FromA, n);
        if not DropAtoB then
        begin
          LenAB := n;
          OffAB := 0;
        end;
      end
      else if n = 0 then
        EofA := True
      else
      begin
        e := fpgeterrno;
        if not Transient(e) then
          EofA := True;   { EIO from a pty master = the child is gone }
      end;
    end;

    { B -> PendBA }
    if fpFD_ISSET(B, RFds) > 0 then
    begin
      n := FpRead(B, PChar(@PendBA[0]), PUMP_BUF);
      if n > 0 then
      begin
        Inc(FromB, n);
        LenBA := n;
        OffBA := 0;
      end
      else if n = 0 then
        EofB := True
      else
      begin
        e := fpgeterrno;
        if not Transient(e) then
          EofB := True;
      end;
    end;

    { PendAB -> B, partial writes loop through later ticks }
    if (LenAB > 0) and (fpFD_ISSET(B, WFds) > 0) then
    begin
      n := FpWrite(B, PChar(@PendAB[OffAB]), LenAB - OffAB);
      if n > 0 then
      begin
        Inc(OffAB, n);
        if OffAB >= LenAB then
        begin
          LenAB := 0;
          OffAB := 0;
        end;
      end
      else if n < 0 then
      begin
        e := fpgeterrno;
        if not Transient(e) then
          Done := True;   { EPIPE/ECONNRESET: the peer is gone }
      end;
    end;

    { PendBA -> A }
    if (LenBA > 0) and (fpFD_ISSET(A, WFds) > 0) then
    begin
      n := FpWrite(A, PChar(@PendBA[OffBA]), LenBA - OffBA);
      if n > 0 then
      begin
        Inc(OffBA, n);
        if OffBA >= LenBA then
        begin
          LenBA := 0;
          OffBA := 0;
        end;
      end
      else if n < 0 then
      begin
        e := fpgeterrno;
        if not Transient(e) then
          Done := True;
      end;
    end;

    { An ended side finishes the relay once nothing is left to flush toward
      the other one; the caller closes both. }
    if EofA and (LenAB = 0) then
      Done := True;
    if EofB and (LenBA = 0) then
      Done := True;
  end;
  { leave the descriptors as we found them for whoever closes them }
  PtySetNonBlock(A, False);
  PtySetNonBlock(B, False);
end;

end.
