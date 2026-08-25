{ pznet - threaded TCP plumbing shared by pizarra (hub) and tiza (daemon).

  Server: wraps TInetServer but spawns one detached thread per connection
  (the thread OWNS and frees the TSocketStream — v1 leaked it), so long-lived
  connections (watch streams) cannot freeze the accept loop.

  Shutdown: InstallShutdownHandler hooks SIGTERM/SIGINT; the handler sets a
  flag and fpshutdown()s the listening socket, which wakes the blocked
  accept() with an error; OnAcceptError then answers aeaStop and Run returns.
  (Verified against fcl-net/ssockets.pp: StartAccepting -> HandleAcceptError
  -> OnAcceptError decides; the accepted stream is never freed by ssockets.)

  Client: RequestLine = connect with timeout (TInetSocket 3-arg constructor),
  one request line, one reply line, close. IOTimeout maps to SO_RCVTIMEO.    }
unit pznet;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ssockets, Sockets, BaseUnix, pzproto;

type
  TPzLineHandler = procedure(Stream: TSocketStream) of object;

  TPzServer = class
  private
    FServer:  TInetServer;
    FHandler: TPzLineHandler;
    FIOTimeoutMs: Integer;
    procedure DoConnect(Sender: TObject; Data: TSocketStream);
    procedure DoAcceptError(Sender: TObject; ASocket: Longint; E: Exception;
      var ErrorAction: TAcceptErrorAction);
    procedure DoIdle(Sender: TObject);
  public
    constructor Create(const AListen: string; APort: Word;
      AHandler: TPzLineHandler; AIOTimeoutMs: Integer = 10000);
    destructor Destroy; override;
    procedure Run;   { blocks until shutdown is requested }
  end;

{ Wait (up to TimeoutMs) for all connection handler threads to finish. Call
  after Run returns and BEFORE freeing any state the handlers touch — the
  threads are detached and would otherwise use freed locks/objects. Returns
  True once idle, False if the timeout elapsed with handlers still active. }
function WaitConnectionsIdle(TimeoutMs: Integer): Boolean;

{ SIGTERM/SIGINT -> flag + wake the accept loop. Call once, before Run. }
procedure InstallShutdownHandler;
function  ShutdownRequested: Boolean;

{ One-shot request/reply with connect + IO timeout. False + Err on failure. }
function RequestLine(const Host: string; Port: Word; TimeoutMs: Integer;
  const Req: string; out Reply, Err: string): Boolean; overload;

{ Variant that also reports whether the request was actually written (Sent). A
  caller may safely RETRY a connect failure (Sent=False — nothing was sent), but
  must NOT retry once Sent=True (the request is on the wire; a retry would
  duplicate a non-idempotent op like send/task add). }
function RequestLine(const Host: string; Port: Word; TimeoutMs: Integer;
  const Req: string; out Reply, Err: string; out Sent: Boolean): Boolean; overload;

{ Variant with an OVERALL DEADLINE for callers that must always respond.
  TimeoutMs applies PER OPERATION: SO_RCVTIMEO restarts on every read, so a peer
  that drips one byte occasionally can hold its slot forever. Waiting is valid
  for a slow console command, but not for a web server, where one hung request
  consumes its worker and enough such requests consume the whole service.
  TotalMs is the deadline for the COMPLETE exchange. Once exceeded, abandon the
  read and return False with a deadline error so the caller can report a timeout
  instead of never responding.
  Sent retains its meaning and matters even more here: reaching the deadline
  AFTER writing does not prove that the request was not applied. }
function RequestLine(const Host: string; Port: Word; TimeoutMs, TotalMs: Integer;
  const Req: string; out Reply, Err: string; out Sent: Boolean): Boolean; overload;

implementation

const
  SHUT_RDWR_BOTH = 2;   { shutdown(2) 'how': SHUT_RDWR }

var
  GShutdown: Boolean = False;
  GListenFd: LongInt = -1;
  GActiveConns: LongInt = 0;

type
  TConnThread = class(TThread)
  private
    FStream:  TSocketStream;
    FHandler: TPzLineHandler;
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TSocketStream; AHandler: TPzLineHandler;
      AIOTimeoutMs: Integer);
  end;

constructor TConnThread.Create(AStream: TSocketStream; AHandler: TPzLineHandler;
  AIOTimeoutMs: Integer);
begin
  FStream := AStream;
  FHandler := AHandler;
  if AIOTimeoutMs > 0 then
    FStream.IOTimeout := AIOTimeoutMs;
  { count the connection BEFORE the thread starts, so WaitConnectionsIdle can
    never see 0 while a just-created thread is about to touch shared state }
  InterLockedIncrement(GActiveConns);
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TConnThread.Execute;
begin
  try
    try
      FHandler(FStream);
    except
      { a broken connection must never take the daemon down }
    end;
  finally
    FStream.Free;
    InterLockedDecrement(GActiveConns);
  end;
end;

function WaitConnectionsIdle(TimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while (GActiveConns > 0) and (Waited < TimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  Result := GActiveConns <= 0;
end;

{ ---------- TPzServer ---------- }

constructor TPzServer.Create(const AListen: string; APort: Word;
  AHandler: TPzLineHandler; AIOTimeoutMs: Integer);
begin
  inherited Create;
  FHandler := AHandler;
  FIOTimeoutMs := AIOTimeoutMs;
  FServer := TInetServer.Create(AListen, APort, nil);
  FServer.ReuseAddress := True;
  FServer.OnConnect := @DoConnect;
  FServer.OnAcceptError := @DoAcceptError;
end;

destructor TPzServer.Destroy;
begin
  FServer.Free;
  inherited Destroy;
end;

procedure TPzServer.DoConnect(Sender: TObject; Data: TSocketStream);
begin
  TConnThread.Create(Data, FHandler, FIOTimeoutMs);
end;

procedure TPzServer.DoAcceptError(Sender: TObject; ASocket: Longint;
  E: Exception; var ErrorAction: TAcceptErrorAction);
begin
  if GShutdown then
    ErrorAction := aeaStop
  else
    ErrorAction := aeaIgnore;   { transient accept errors never kill the bus }
end;

{ THE ONLY THING THAT USED TO WAKE THE ACCEPT LOOP WAS SHUTTING DOWN THE
  LISTENING SOCKET, and on darwin that does not wake it. The consequence is
  wider than it looks: SIGTERM *and* SIGINT run their handler, set the flag,
  shut the socket - and the process stays alive anyway, so on that platform
  there is NO graceful stop at all and every stop is effectively a crash. Any
  cleanup on an orderly-exit path would simply never run there. The self-update
  path already carries a SIGKILL escalation for this platform behavior, but
  that only treats the symptom.
  Read in the RTL rather than guessed (ssockets.pp:600-620,691): with
  AcceptIdleTimeOut set, StartAccepting stops blocking in accept() and instead
  selects with that timeout, calling OnIdle when nothing arrives and looping
  'Until Result or (Not FAccepting)'. So asking to stop from OnIdle ends the
  loop on EVERY platform, without depending on a socket shutdown to interrupt
  a blocking call. The socket shutdown stays: where it does work it makes the
  stop immediate instead of costing up to one timeout. }
procedure TPzServer.DoIdle(Sender: TObject);
begin
  if GShutdown then
    FServer.StopAccepting;
end;

procedure TPzServer.Run;
begin
  GListenFd := FServer.Socket;
  { half a second: short enough that stopping feels immediate to a human or a
    supervisor, long enough not to spin }
  FServer.AcceptIdleTimeOut := 500;
  FServer.OnIdle := @DoIdle;
  FServer.StartAccepting;
end;

{ ---------- shutdown handling ---------- }

procedure SigHandler(sig: cint); cdecl;
var
  fd: LongInt;
begin
  GShutdown := True;
  { take-and-clear: a second signal must not shutdown() a since-reused fd }
  fd := InterlockedExchange(GListenFd, -1);
  if fd >= 0 then
    fpshutdown(fd, SHUT_RDWR_BOTH);   { wakes the blocked accept() }
end;

procedure InstallShutdownHandler;
begin
  FpSignal(SIGTERM, @SigHandler);
  FpSignal(SIGINT, @SigHandler);
  { a write to a dead client must return EPIPE, not kill the daemon }
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
end;

function ShutdownRequested: Boolean;
begin
  Result := GShutdown;
end;

{ ---------- client ---------- }

function RequestLine(const Host: string; Port: Word; TimeoutMs: Integer;
  const Req: string; out Reply, Err: string; out Sent: Boolean): Boolean;
var
  Sock: TInetSocket;
begin
  Result := False;
  Reply := '';
  Err := '';
  Sent := False;
  { FPC RTL trap (fcl-net/ssockets.pp CheckSocketConnectTimeout): the connect
    timeout is converted with `tv_sec := ConnectTimeout div 1000; tv_usec := 0`
    — SUB-SECOND VALUES BECOME ZERO, and select() with a zero timeout on a
    non-blocking connect returns "timed out" every time, even against a host
    answering in 14 ms. Any caller asking for less than a second really means
    "be quick", never "fail always", so clamp to the smallest value the RTL
    can actually express. }
  if TimeoutMs < 1000 then
    TimeoutMs := 1000;
  try
    Sock := TInetSocket.Create(Host, Port, TimeoutMs);
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit;   { connect failed: nothing sent, safe for the caller to retry }
    end;
  end;
  try
    try
      Sock.IOTimeout := TimeoutMs;
      WriteLine(Sock, Req);
      Sent := True;   { request is on the wire — retrying now could duplicate it }
      Reply := ReadLine(Sock);
      if Reply = '' then
        Err := 'no reply'
      else
        Result := True;
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    Sock.Free;
  end;
end;

function RequestLine(const Host: string; Port: Word; TimeoutMs: Integer;
  const Req: string; out Reply, Err: string): Boolean;
var
  Sent: Boolean;
begin
  Result := RequestLine(Host, Port, TimeoutMs, Req, Reply, Err, Sent);
end;

{ Read one line WITHOUT passing StopAt. This is more than ReadLine plus a clock:
  it distinguishes why no byte arrived using RTL behavior rather than an
  assumption. In fcl-net/ssockets.pp, TSocketHandler.Recv leaves Result < 0 and
  FLastError = SocketError when fprecv fails, but Result = 0 and FLastError = 0
  when the peer closes. Therefore:
    n = 0                  -> peer CLOSED; no more bytes will arrive
    n < 0 and EAGAIN       -> THIS read timed out, not the overall exchange;
                              keep waiting if budget remains
    n < 0 and anything else -> real failure; stop
  Treating all three alike either accepted a partial reply or waited forever.
  On Linux EWOULDBLOCK is the SAME value as EAGAIN (rtl/linux/errno.inc), so
  checking both would duplicate the same test. }
function ReadLineBefore(Sock: TSocketStream; StopAt: QWord;
  out TimedOut: Boolean): string;
var
  c: AnsiChar;
  n: LongInt;
  RemainingMs, NowMs: QWord;
begin
  Result := '';
  TimedOut := False;
  repeat
    if GetTickCount64 >= StopAt then
    begin
      TimedOut := True;
      Result := '';
      Exit;
    end;
    n := Sock.Read(c, 1);
    if n <= 0 then
    begin
      if n = 0 then
        Exit;
      if Sock.LastError = ESysEAGAIN then
      begin
        { LIMIT THE NEXT READ TO THE REMAINING BUDGET. Otherwise the overall
          deadline can overrun by one full read timeout: with a 5 s read limit
          and a 12 s budget, the reply arrived at 15 s. A 25 percent overrun is
          not a deadline. Adjust here rather than on every byte; this path runs
          only after the uncommon event of a read timeout, avoiding a system
          call per byte.
          Read the clock ONCE. Reading it twice leaves a window in which the
          remaining value can reach zero, and a zero SO_RCVTIMEO means WAIT
          FOREVER, not "do not wait" (fcl-net/ssockets.pp sets both tv_sec and
          tv_usec to zero). }
        NowMs := GetTickCount64;
        if NowMs < StopAt then
        begin
          RemainingMs := StopAt - NowMs;
          if RemainingMs < QWord(Sock.IOTimeout) then
            Sock.IOTimeout := Integer(RemainingMs);
        end;
        Continue;   { The next pass decides whether any budget remains. }
      end;
      Exit;
    end;
    if c = #10 then
      Exit;
    if c <> #13 then
      Result := Result + c;
    if Length(Result) > MAX_LINE_BYTES then
    begin
      { As in ReadLine, stop accumulating and let the caller report the error. }
      Result := '';
      Exit;
    end;
  until False;
end;

function RequestLine(const Host: string; Port: Word; TimeoutMs, TotalMs: Integer;
  const Req: string; out Reply, Err: string; out Sent: Boolean): Boolean;
var
  Sock: TInetSocket;
  StopAt: QWord;
  TimedOut: Boolean;
begin
  Result := False;
  Reply := '';
  Err := '';
  Sent := False;
  { Same RTL trap as above: below one second, the connect timeout becomes zero
    and select() always reports expiration. }
  if TimeoutMs < 1000 then
    TimeoutMs := 1000;
  { An overall deadline shorter than one operation is meaningless: the first
    read would consume it before a genuine wait. }
  if TotalMs < TimeoutMs then
    TotalMs := TimeoutMs;
  StopAt := GetTickCount64 + QWord(TotalMs);
  try
    Sock := TInetSocket.Create(Host, Port, TimeoutMs);
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit;   { Connect failed before sending; the caller may retry safely. }
    end;
  end;
  try
    try
      Sock.IOTimeout := TimeoutMs;
      WriteLine(Sock, Req);
      Sent := True;
      Reply := ReadLineBefore(Sock, StopAt, TimedOut);
      if TimedOut then
        Err := Format('no reply within %d ms', [TotalMs])
      else if Reply = '' then
        Err := 'no reply'
      else
        Result := True;
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    Sock.Free;
  end;
end;

end.
