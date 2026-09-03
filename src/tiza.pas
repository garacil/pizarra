{ tiza - the chalk. Client + team-host daemon for the pizarra blackboard.

  Send:   tiza <recipient> <message...>
          tiza <recipient> --file PATH        (multi-line body from a file; - = stdin)
  Inbox:  tiza inbox [--keep] [--all]
  Daemon: tiza daemon        (team host: receives pushes from pizarra and
                              injects them into the local tmux sessions
                              declared in [session:NAME]; watchdogs them)
  Flags:  --config PATH   (identity is ALWAYS the config's self=; --from is IGNORED)

  Everything else (host, port, secret, self, [daemon], [session:*]) comes
  from tiza.conf.                                                            }
program tiza;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, ssockets, Sockets, resolve, BaseUnix, Unix,
  SyncObjs, fpjson,
  base64, process, ctypes, sqlite3dyn,
  pzproto, pzconfig, pztmux, pznet, pzshare, pzmanual, pzchat, pzver,
  pzupdate, pzbox, pzsha256, termio, pzansi, pzlayout;

procedure Fail(const Msg: string);
begin
  Writeln(StdErr, 'tiza: ', Msg);
  Flush(StdErr);
  Halt(1);
end;

{ True if Flag appears as a standalone token in P. Command-scoped flags are
  matched only in the right command, never inside a message body. }
function HasFlag(P: TStringList; const Flag: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to P.Count - 1 do
    if P[i] = Flag then Exit(True);
end;

{ The wf command block - shared by the global usage and 'tiza wf help'
  (which must work OFFLINE: no hub, no valid config needed). }
procedure WfUsage;
begin
  Writeln('  tiza wf create <name> <group>      dependency-tree milestone plan (wf = workflow)');
  Writeln('  tiza wf step <name> <team> <milestone...> [--after K[,K...] | 0] [--eta 4h]');
  Writeln('     --after also takes steps of ANOTHER plan: --after otherplan#3');
  Writeln('  tiza wf start <name>               activate the roots; members get the plan');
  Writeln('  tiza wf done <name> [step|-] ["how tested..."]  finish your ACTIVE milestone');
  Writeln('     step must be a NUMBER; use - for "my single active step" when');
  Writeln('     you want to give proof without naming the step');
  Writeln('  tiza wf error <name> <why...> [--step N]    halt the whole workflow');
  Writeln('  tiza wf fixed <name> <what fixed + how tested...>');
  Writeln('  tiza wf verify <name> ok|fail [why...]      (never the fixer itself)');
  Writeln('  tiza wf show <name> [--from K] [--depth N] [--detail]   the tree');
  Writeln('  tiza wf tasks <name>               linked tasks in dependency order');
  Writeln('  tiza wf insert <name> <team> <milestone...> --after K [--eta 4h]  splice in');
  Writeln('                                 (K''s dependents re-hang on the new step; 0=front)');
  Writeln('  tiza wf remove <name> <step>   splice out (dependents inherit its deps)');
  Writeln('  tiza wf set <name> <step> team|milestone|after|eta <value...>  edit a step');
  Writeln('                                 (eta also on a RUNNING step: 30s|45m|4h|2d|off)');
  Writeln('  tiza wf set <name> eta <dur>|off|factory    workflow default stall threshold');
  Writeln('  tiza wf set <name> strict on|off            done requires a how-tested proof');
  Writeln('  tiza wf list [--mine|--team T] | abort <name> [why...] | delete <name> [why...]');
  Writeln('  tiza wf clone <src> <new> [group]  copy a plan into a pristine new draft');
  Writeln('  tiza wf history <name> | undo <name> [snap] time-travel: every change is');
  Writeln('                                 snapshotted; jump back (or forward) to any point');
  Writeln('  tiza wf save <name> [f] | restore <name> f  manual card backup / restore');
  Writeln('  tiza wf export <name> [f.sqlite|f.sql|f.mmd|f.dot]  SQLite/SQL/Mermaid/DOT');
  Writeln('  stalled ACTIVE steps are nudged automatically (owner + group admin) after');
  Writeln('  their eta (step -> workflow default -> 24h); a task note resets the clock');
end;

procedure Usage;
begin
  Writeln('usage:');
  Writeln('  tiza <dest> <message...>          send a message to a team (id or name)');
  Writeln('  tiza all <message...>              broadcast to every team (except you)');
  Writeln('  tiza <dest> --file PATH           send the contents of a file (- = stdin)');
  Writeln('  tiza inbox                         show unread messages addressed to you');
  Writeln('    inbox flags: --keep (do not mark read)  --all (full history)');
  Writeln('  tiza tree                          show the team hierarchy');
  Writeln('  tiza task add <team|-> <title...> [--milestone H] [--parent N]');
  Writeln('  tiza task done|reopen|show <id>    tiza task note <id> <text...>');
  Writeln('  tiza task list [open|done|all] [team|@group]');
  Writeln('  tiza team add <name> <spec...> [--parent X] [--remote ip[:port]]');
  Writeln('                                 [--session S | --session -] [--launch CMD]');
  Writeln('                                 [--prompt ...]   (-: inbox-only, no tmux —');
  Writeln('                                  the member polls: config self=N, tiza inbox)');
  Writeln('  tiza team remove|show <name> [--detail]   (detail: apps, repos, manuals)');
  Writeln('  tiza team set <name> <field> <value...>');
  Writeln('     fields: prompt|speciality|parent|launch|session|user|project|slave|workdir');
  Writeln('             hold_when_blocked|host|dial|delegate|secret');
  Writeln('     secret: prefer `tiza team set NAME secret --file PATH` to avoid argv history');
  Writeln('     workdir = the team''s source dir; its tmux session opens there');
  Writeln('     slave on = READ-ONLY team that reports only to its parent');
  Writeln('  tiza team list');
  Writeln('  tiza share <team|console> <file> [note...]   copy into the shared dir + notify');
  Writeln('  tiza files [team]                  list a shared directory (default: yours)');
  Writeln('  tiza put [<dest>] <file> [note]    upload a file over the bus (no NFS needed)');
  Writeln('  tiza get <shared-path> [local]     download a shared file over the bus');
  Writeln('  tiza cat <shared-path>             print a shared file''s content to stdout');
  Writeln('  tiza manual                        print the embedded agent quick guide');
  Writeln('  tiza ver                           release version (this binary + the hub)');
  Writeln('  tiza --health [--wait SECONDS]     strict authenticated hub readiness');
  Writeln('  tiza fleet                         every host: release + ONLINE/OFFLINE');
  Writeln('  tiza app add <name> --team <t> [--repo U] [--path P]');
  Writeln('                      [--purpose "one line"] [--detail "what it does"]');
  Writeln('  tiza app list [team]   tiza app show <name>   (who is responsible)');
  Writeln('  tiza app set <name> team|repo|path|purpose|detail <value...>');
  Writeln('  tiza app doc <name>                read an app manual (any team)');
  Writeln('  tiza app doc <name> --file F       write it (responsible team)');
  Writeln('  tiza app doc <name> --at <snap>    read an earlier version');
  Writeln('  tiza app history <name>            every change: who, when, what');
  Writeln('  tiza app undo <name> <snap>        roll it back to that point');
{ The app<->project relationship from BOTH ends: the app shows which projects
  it belongs to, and the project shows which apps build it. }
  Writeln('  tiza app project <name> <project> [--role "what it does there"]');
  Writeln('  tiza app unproject <name> <project>   take it out of that one');
  Writeln('  tiza backup [dir]                  core-state backup (contains secrets)');
  Writeln('  tiza backup verify <dir>           check a backup (sha256 + that it would boot)');
  Writeln('  tiza restore <dir> [--dry-run]     roll the hub back to that backup (hub STOPPED)');
  Writeln('  tiza app remove <name>');
  Writeln('  tiza update <team|all> [--force]   tell tiza daemons to SELF-UPDATE to');
  Writeln('                                     the hub''s release (console only)');
  Writeln('  tiza group add <name> <team...>    tiza group remove <name> [team...]');
  Writeln('  tiza group project <name> <proj>   tiza group boss <name> <team>');
  Writeln('  tiza group exclude <name> [team...] mute members from @group sends');
  Writeln('                                     (replaces the set; none = clear)');
  Writeln('  tiza group onblock <name> alarm|log|default');
  Writeln('  tiza group list                    tiza project boss <name> <team>');
  Writeln('  tiza project show <name>           its admin, teams, groups + apps');
  Writeln('  tiza project list');
  WfUsage;
  Writeln('  tiza @<group> <message...>         send to all members of a group');
  Writeln('  tiza <group> <message...>          bare group name works too (team wins clash)');
  Writeln('  tiza daemon                        run the team-host delivery daemon');
  Writeln('  tiza chat [--plain]                the human console (live feed + commands)');
  Writeln('  options: --config PATH   (identity is the config self=; --from is ignored)');
  Halt(0);
end;

const
  MAX_FILE_BYTES = 262144;   { 256 KB body cap }

{ Read a whole stream into a string, enforcing the size cap. }
function ReadAllStream(S: TStream): string;
var
  Buf: array[0..4095] of Byte;
  n, Len: Integer;
begin
  Result := '';
  Len := 0;
  repeat
    n := S.Read(Buf, SizeOf(Buf));
    if n > 0 then
    begin
      SetLength(Result, Len + n);
      Move(Buf, Result[Len + 1], n);
      Inc(Len, n);
      if Len > MAX_FILE_BYTES then
        Fail(Format('file too big (max %d KB)', [MAX_FILE_BYTES div 1024]));
    end;
  until n <= 0;
end;

{ Body from --file: regular file or '-' for stdin; trailing newlines stripped
  (the delivery wrapper adds its own). }
function ReadMsgFile(const Path: string): string;
var
  FS: TStream;
begin
  if Path = '-' then
    FS := THandleStream.Create(0)
  else
  begin
    if not FileExists(Path) then
      Fail('file not found: ' + Path);
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  end;
  try
    Result := ReadAllStream(FS);
  finally
    FS.Free;
  end;
  while (Result <> '') and (Result[Length(Result)] in [#10, #13]) do
    SetLength(Result, Length(Result) - 1);
  if Result = '' then
    Fail('file is empty: ' + Path);
end;

{ Text already styled by the hub: display it as-is on a terminal and strip the
  styling everywhere else. }
function Vis(const S: string): string;
begin
  if ColorsOn then
    Result := S
  else
    Result := StripAnsi(S);
end;

function SendRequest(const Cfg: TTizaConfig; const Req: string; out Reply: string): Boolean;
var
  Err: string;
  Sent: Boolean;
  attempt: Integer;
begin
  { ENFORCE NETWORK IDENTITY AT THE COMMON GATE. Identity comes ONLY from the
    configuration (self=); --from no longer changes it. Every command that
    talks to the hub passes here, so none can bypass the rule. Nothing is sent
    without a name; previously a missing self defaulted to CONSOLE identity. }
  if Trim(Cfg.SelfId) = '' then
    Fail('missing identity: the configuration has no self= value (set ' +
      'self=<name> in the configuration, or point TIZA_CONF to a file that ' +
      'contains it)');
  { 5 s connect + IO timeout: the CLI must never hang a model forever. Retry
    ONLY the connect (Sent=False): under a restricted process sandbox the LAN
    connect to the hub can fail transiently. Never retry once the
    request was written (Sent=True) — that would duplicate a send/task add. }
  Err := '';
  Result := False;
  for attempt := 1 to 5 do
  begin
    Result := RequestLine(Cfg.Host, Cfg.Port, 5000, Req, Reply, Err, Sent);
    if Result or Sent then
      Break;
    Sleep(300);   { brief backoff before re-attempting the connect }
  end;
  if not Result then
    Fail(Format('cannot connect to pizarra %s:%d (%s)',
      [Cfg.Host, Cfg.Port, Err]));
end;

procedure PrintInbox(const Reply: string);
var
  Obj: TJSONObject;
  Arr: TJSONArray;
  M: TJSONObject;
  i: Integer;
  Acc: string;
begin
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    Arr := Obj.Get('messages', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      Writeln('(inbox empty)');
      Exit;
    end;
    Acc := '';
    for i := 0 to Arr.Count - 1 do
    begin
      M := TJSONObject(Arr.Items[i]);
      Acc := Acc + Format('#%d [%s] %s: %s'#10,
        [M.Get('seq', Int64(0)), M.Get('ts', ''), M.Get('from', '?'),
         M.Get('text', '')]);
    end;
  { The frame appears only on a terminal; redirected output stays unchanged. }
    Writeln(Frame('inbox', TrimRight(Acc), 118));
  finally
    Obj.Free;
  end;
end;

{ ======================= daemon mode ======================= }

type
  TTizaDaemon = class;

  { Keeps the declared local sessions alive (like the hub's watchdog). }
  TDmnWatchdog = class(TThread)
  private
    FOwner: TTizaDaemon;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTizaDaemon);
  end;

  { Reverse delivery channel (dial-in): dials the hub, holds the connection, and
    injects the deliveries the hub streams over it — for hosts behind NAT or with
    a roaming (DHCP/VPN) IP, where the hub cannot reach in. Reconnects on drop. }
  TDialThread = class(TThread)
  private
    FOwner: TTizaDaemon;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTizaDaemon);
  end;

  { Samples the pane of each activity=on session ~1/s, diffs it against the last
    frame, and reports moving/quiet TRANSITIONS to the hub. Read-only: it only
    captures panes, never injects. Opt-in per session (default off), so a daemon
    with no activity sessions never starts this thread. }
  TActivityThread = class(TThread)
  private
    FOwner: TTizaDaemon;
    FSeen:  array of Boolean;   { baseline captured for this session yet? }
    FPane:  array of string;    { last pane text per session index }
    FQuiet: array of Integer;   { consecutive unchanged samples }
    FState: array of string;    { last state reported to the hub ('' = none) }
    procedure ReportState(const Team, State, Note: string; Hold: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTizaDaemon);
  end;

  TTizaDaemon = class
  private
    FCfg:  TTizaDaemonConfig;
    FLock: TCriticalSection;   { serialises injections + FLastSeq }
    FLastSeq: TStringList;     { team=last injected seq (dedupe on retry) }
    FStatePath: string;        { where FLastSeq is persisted across restarts }
    { An acknowledgement is recorded in memory but has NOT reached disk. }
    FSeqDirty: Boolean;
    { team -> '1' while its pane is a permission prompt: DeliverOne refuses to
      inject (pasting there would ANSWER the prompt). Set only from a reliable
      source — a session-hook hint file — so a heuristic never freezes delivery.
      Guarded by FLock, like FLastSeq. }
    FHold: TStringList;
    function SaveSeqState: Boolean;
    procedure HandleConn(Stream: TSocketStream);
    { Inject one delivery into the team's tmux session (dedup by seq, respawn if
      missing). True when delivered (injected OR already-injected duplicate),
      False when the session is unavailable. Shared by push (HandleConn) and the
      dial channel (TDialThread). }
    function DeliverOne(const Team: string; Seq: Int64; const Text: string): Boolean;
  public
    procedure RetrySeqState;
    constructor Create(const ACfg: TTizaDaemonConfig; const StatePath: string);
    destructor Destroy; override;
    procedure Run;
  end;

{ ---------- self-update trigger (1.0.3) ----------
  One update at a time; the work runs off-thread so the connection handler /
  dial loop stay responsive. On success the thread reports to the console and
  SIGTERMs its own process: the clean-shutdown path runs and systemd (or the
  mac guard loop) relaunches the NEW binary. On failure nothing was touched. }
var
  GUpdateBusy: LongInt = 0;
  { last release the AUTO path attempted: a persistently failing update must
    not retry (and re-report) on every keepalive — one auto attempt per hub
    release; manual triggers always run. Only touched while holding
    GUpdateBusy, so no separate lock is needed. }
  GLastAutoVer: string = '';

type
  TUpdateThread = class(TThread)
  private
    FCfg: TTizaDaemonConfig;
    FVer: string;
    FForce: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACfg: TTizaDaemonConfig; const AVer: string;
      AForce: Boolean);
  end;

constructor TUpdateThread.Create(const ACfg: TTizaDaemonConfig;
  const AVer: string; AForce: Boolean);
begin
  FCfg := ACfg;
  FVer := AVer;
  FForce := AForce;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TUpdateThread.Execute;
var
  U: TUpdateOutcome;
  R, E2, SelfName, Msg: string;
  i: Integer;

  procedure Report(const Text: string);
  begin
    Writeln('tiza daemon: ', Text);
    Flush(Output);
    if SelfName <> '' then
      RequestLine(FCfg.HubHost, FCfg.HubPort, 3000,
        BuildSend(FCfg.HubSecret, SelfName, 'console', Text), R, E2);
  end;

begin
  try
    SelfName := FCfg.SelfId;
    if (SelfName = '') and (Length(FCfg.Sessions) > 0) then
      SelfName := FCfg.Sessions[0].Team;
    U := RunSelfUpdate(FCfg, FVer, FForce);
    if U.Ok and U.SelfImage then
    begin
      Report(Format('selfupdate: %s -> %s installed and verified; restarting' +
        ' on the new binary', [PizarraVersion, FVer]));
      FpKill(FpGetpid, SIGTERM);   { clean exit; the supervisor relaunches }
      { VERIFY we actually go down. On macOS the accept() loop does not wake
        on the listening socket shutdown, so SIGTERM can leave the daemon alive
        with the busy latch set. Escalate rather than hang or silently stop
        future updates. }
      for i := 1 to 60 do
        Sleep(100);
      Writeln('tiza daemon: SIGTERM did not stop this process after 6s' +
        ' (host ignores it); escalating to SIGKILL so the supervisor' +
        ' relaunches the new binary');
      Flush(Output);
      FpKill(FpGetpid, SIGKILL);
      Exit;
    end;
    if U.Ok then
      { installed, but this process runs a DIFFERENT image: restarting would
        bring the old code back up and (with autoupdate) loop forever }
      Report(Format('selfupdate: %s installed at %s, but this daemon runs %s' +
        ' - NOT restarting; fix [daemon] update_path',
        [FVer, FCfg.UpdatePath, ParamStr(0)]))
    else
    begin
      if U.RolledBack then
        Msg := 'selfupdate FAILED, ROLLED BACK to the previous binary: '
      else if U.Changed then
        Msg := 'selfupdate FAILED, the installed binary was MODIFIED - CHECK THIS HOST: '
      else
        Msg := 'selfupdate not performed (binary untouched): ';
      Writeln('tiza daemon: ', Msg, U.Err);
      Flush(Output);
      if (SelfName <> '') and (Pos('already at', U.Err) = 0) then
        Report(Msg + U.Err);
      { Transient: the hub was mid-release (publish before restart), briefly
        unreachable, or served another release. Those are not this host's
        fault and WILL fix themselves, so release the one-attempt latch and
        let the next beacon retry. A real failure (build, self-test, install)
        keeps the latch so a broken release cannot loop the fleet. }
      if (Pos('re-publish', U.Err) > 0) or
         (Pos('no artifact published', U.Err) > 0) or
         (Pos('retrigger', U.Err) > 0) or
         (Pos('hub unreachable', U.Err) > 0) then
        GLastAutoVer := '';
    end;
    InterlockedExchange(GUpdateBusy, 0);
  except
    on E: Exception do
    begin
      Writeln('tiza daemon: self-update crashed: ', E.Message);
      Flush(Output);
      InterlockedExchange(GUpdateBusy, 0);
    end;
  end;
end;

{ True when this connection comes from the configured hub host. Used to gate
  cmd=update: the shared bus secret is held by every agent, so it cannot be
  the only thing standing between a rogue caller and a fleet restart loop.
  A hub host given as a name resolves to its address before comparing. }
function FromHub(Stream: TSocketStream; const HubHost: string): Boolean;
var
  Peer, Want: string;
  HR: THostResolver;
begin
  Result := False;
  try
    Peer := NetAddrToStr(Stream.RemoteAddress.sin_addr);
  except
    Exit;
  end;
  if Peer = '' then
    Exit;
  Want := Trim(HubHost);
  if (Want = 'localhost') or (Want = '') then
    Want := '127.0.0.1';
  if Peer = Want then
    Exit(True);
  { HubHost may be a name: resolve once and compare }
  if StrToHostAddr(Want).s_addr = 0 then
  begin
    HR := THostResolver.Create(nil);
    try
      if HR.NameLookup(Want) then
        Result := Peer = NetAddrToStr(HR.HostAddress);
    finally
      HR.Free;
    end;
  end;
end;

procedure TriggerSelfUpdate(const Cfg: TTizaDaemonConfig; const Ver: string;
  Force, Auto: Boolean);
begin
  if InterlockedCompareExchange(GUpdateBusy, 1, 0) <> 0 then
    Exit;   { an update is already running }
  if Auto and (GLastAutoVer = Ver) then
  begin
    InterlockedExchange(GUpdateBusy, 0);
    Exit;   { this release already had its one automatic attempt }
  end;
  if Auto then
    GLastAutoVer := Ver;
  TUpdateThread.Create(Cfg, Ver, Force);
end;

constructor TDmnWatchdog.Create(AOwner: TTizaDaemon);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

{ pull the TIZA_CONF=<path> a session's launch exports, so the daemon can tag its
  tmux session with it (@pizarra_conf) - the identity a bare `tiza` there must use }
function ConfFromLaunch(const Launch: string): string;
var p, q: Integer;
begin
  Result := '';
  p := Pos('TIZA_CONF=', Launch);
  if p = 0 then
    Exit;
  Inc(p, Length('TIZA_CONF='));
  q := p;
  while (q <= Length(Launch)) and
        (not (Launch[q] in [';', ' ', #39, '"', #10, #9])) do
    Inc(q);
  Result := Copy(Launch, p, q - p);
end;

procedure TDmnWatchdog.Execute;
var
  i, waited: Integer;
  StartWhy: string;
begin
  while not Terminated do
  begin
    try
      { Retry an acknowledgement that did not reach disk on every pass;
        otherwise it remains only in memory until a restart loses it. }
      FOwner.RetrySeqState;
      for i := 0 to High(FOwner.FCfg.Sessions) do
      begin
        FOwner.FLock.Enter;
        try
          if SessionExists(FOwner.FCfg.Sessions[i].TmuxSession) then
          begin
            { Tag only an existing session. The watchdog never replaces it or
              invokes its launch command a second time. }
            TagSessionConf(FOwner.FCfg.Sessions[i].TmuxSession,
              ConfFromLaunch(FOwner.FCfg.Sessions[i].Launch));
          end
          else if Trim(FOwner.FCfg.Sessions[i].Launch) <> '' then
          begin
            Writeln('tiza: watchdog: creating missing session ',
              FOwner.FCfg.Sessions[i].TmuxSession);
            Flush(Output);
            if EnsureSessionDetailed(FOwner.FCfg.Sessions[i].TmuxSession,
              FOwner.FCfg.Sessions[i].Launch,
              FOwner.FCfg.Sessions[i].Workdir,
              FOwner.FCfg.Sessions[i].User, StartWhy) then
              TagSessionConf(FOwner.FCfg.Sessions[i].TmuxSession,
                ConfFromLaunch(FOwner.FCfg.Sessions[i].Launch))
            else
            begin
              Writeln(StdErr, 'tiza: watchdog: session ',
                FOwner.FCfg.Sessions[i].TmuxSession,
                ' not started: ', StartWhy);
              Flush(StdErr);
            end;
          end;
          { Empty launch means manually managed/inject-only. Its absence is not
            a respawn attempt and must not produce a false success message. }
        finally
          FOwner.FLock.Leave;
        end;
      end;
    except
      { a transient tmux/IO error must never stop the respawn loop }
    end;
    waited := 0;
    while (waited < 15) and (not Terminated) do
    begin
      Sleep(1000);
      Inc(waited);
    end;
  end;
end;

constructor TActivityThread.Create(AOwner: TTizaDaemon);
var
  n: Integer;
begin
  FOwner := AOwner;
  n := Length(FOwner.FCfg.Sessions);
  SetLength(FSeen, n);
  SetLength(FPane, n);
  SetLength(FQuiet, n);
  SetLength(FState, n);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TActivityThread.ReportState(const Team, State, Note: string; Hold: Boolean);
var
  R, E: string;
begin
  { report over an OUTBOUND connection to the hub, the same primitive the
    self-update path uses (tiza.pas Report). No hub configured -> nothing to
    tell. The daemon presents the hub secret and names the team in 'from'. }
  if FOwner.FCfg.HubHost = '' then
    Exit;
  RequestLine(FOwner.FCfg.HubHost, FOwner.FCfg.HubPort, 3000,
    BuildActivity(FOwner.FCfg.HubSecret, Team, State, Note, Hold), R, E);
end;

procedure TActivityThread.Execute;
const
  QUIET_SAMPLES = 3;   { ~3 unchanged samples (~3s) before we call it quiet }
var
  i, waited: Integer;
  Pane, NewState, hintState, note: string;
  holdElig, useHint: Boolean;

  { a session hook may write a state hint file; if present it is authoritative
    (idle|busy|blocked|moving) and a 'blocked' from it is auto-hold-eligible }
  function ReadHint(const Path: string): string;
  var
    sl: TStringList;
    s: string;
  begin
    Result := '';
    if (Path = '') or (not FileExists(Path)) then
      Exit;
    sl := TStringList.Create;
    try
      try
        sl.LoadFromFile(Path);
      except
        Exit;
      end;
      s := LowerCase(Trim(sl.Text));
    finally
      sl.Free;
    end;
    if (s = 'idle') or (s = 'busy') or (s = 'blocked') or (s = 'moving') then
      Result := s;
  end;

  function LastLine(const P: string): string;
  var
    sl: TStringList;
    k: Integer;
  begin
    Result := '';
    sl := TStringList.Create;
    try
      sl.Text := P;
      for k := sl.Count - 1 downto 0 do
        if Trim(sl[k]) <> '' then
        begin
          Result := Trim(sl[k]);
          Break;
        end;
    finally
      sl.Free;
    end;
  end;

  procedure SetHold(const Team: string; On_: Boolean);
  begin
    FOwner.FLock.Enter;
    try
      if On_ then
        FOwner.FHold.Values[LowerCase(Team)] := '1'
      else
        FOwner.FHold.Values[LowerCase(Team)] := '';
    finally
      FOwner.FLock.Leave;
    end;
  end;

begin
  while not Terminated do
  begin
    for i := 0 to High(FOwner.FCfg.Sessions) do
    begin
      if not FOwner.FCfg.Sessions[i].Activity then
        Continue;
      try
        note := '';
        holdElig := False;
        hintState := ReadHint(FOwner.FCfg.Sessions[i].Hint);
        useHint := hintState <> '';
        if useHint then
        begin
          { the hook is the reliable signal: use it, and a hook 'blocked' may
            auto-hold delivery }
          NewState := hintState;
          holdElig := (hintState = 'blocked');
          if NewState = 'blocked' then
            note := LastLine(CapturePane(FOwner.FCfg.Sessions[i].TmuxSession));
        end
        else
        begin
          Pane := CapturePane(FOwner.FCfg.Sessions[i].TmuxSession);
          if Pane = '' then
            Continue;   { session gone / capture failed: leave state as-is }
          if not FSeen[i] then
          begin
            { first frame is only a baseline — no spurious 'moving' }
            FSeen[i] := True;
            FPane[i] := Pane;
            FQuiet[i] := 0;
            Continue;
          end;
          if Pane <> FPane[i] then
          begin
            FPane[i] := Pane;
            FQuiet[i] := 0;
            NewState := 'moving';
          end
          else
          begin
            Inc(FQuiet[i]);
            if FQuiet[i] >= QUIET_SAMPLES then
              { quiet long enough: is it idle, a permission prompt, or working? }
              NewState := ClassifyPane(Pane,
                FOwner.FCfg.Sessions[i].IdleMatch,
                FOwner.FCfg.Sessions[i].BlockMatch)
            else
              NewState := FState[i];   { not quiet long enough yet; hold }
          end;
          if NewState = 'blocked' then
            note := LastLine(Pane);   { heuristic block: alarm only, not hold }
        end;

        { local auto-hold gate: ON only for a RELIABLE (hook) block; any non-
          blocked state clears it. A heuristic block never freezes delivery. }
        if (NewState = 'blocked') and holdElig then
          SetHold(FOwner.FCfg.Sessions[i].Team, True)
        else if NewState <> 'blocked' then
          SetHold(FOwner.FCfg.Sessions[i].Team, False);

        if (NewState <> '') and (NewState <> FState[i]) then
        begin
          { opt-in auto_enter: when the pane JUST became blocked, press Enter to
            clear the prompt (accepts its default). ONLY on the transition, so it
            is one keystroke per block, never a storm. Reported as usual below. }
          if (NewState = 'blocked') and FOwner.FCfg.Sessions[i].AutoEnter then
            SendEnter(FOwner.FCfg.Sessions[i].TmuxSession);
          FState[i] := NewState;
          ReportState(FOwner.FCfg.Sessions[i].Team, NewState, note, holdElig);
        end;
      except
        { a transient tmux/capture error must never stop the sampler }
      end;
    end;
    { ~1s cadence, but woken in short slices so shutdown is responsive }
    waited := 0;
    while (waited < 4) and (not Terminated) do
    begin
      Sleep(250);
      Inc(waited);
    end;
  end;
end;

constructor TTizaDaemon.Create(const ACfg: TTizaDaemonConfig; const StatePath: string);
begin
  inherited Create;
  FCfg := ACfg;
  FLock := TCriticalSection.Create;
  FLastSeq := TStringList.Create;
  FHold := TStringList.Create;
  FStatePath := StatePath;
  { Survive a restart: a message already injected whose acknowledgement was
    lost should not be pasted again. This is not a guarantee: if the
    acknowledgement did NOT reach disk (which is now reported clearly), this
    file cannot contain it, and the text MAY be pasted again after a restart.
    Delivery is at least once. }
  if (FStatePath <> '') and FileExists(FStatePath) then
    try FLastSeq.LoadFromFile(FStatePath); except end;
end;

destructor TTizaDaemon.Destroy;
begin
  FLastSeq.Free;
  FHold.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TTizaDaemon.HandleConn(Stream: TSocketStream);
var
  Line, Cmd, Team, HV: string;
  Obj: TJSONObject;
  Sess: TPzSession;
  Seq: Int64;
  AllUp: Boolean;
  i: Integer;
begin
  try
    Line := ReadLine(Stream);
    Obj := ParseObj(Line);
    if Obj = nil then
    begin
      WriteLine(Stream, ReplyErr('bad json'));
      Exit;
    end;
    try
      if Obj.Get('secret', '') <> FCfg.Secret then
      begin
        WriteLine(Stream, ReplyErr('unauthorized'));
        Exit;
      end;
      Cmd := Obj.Get('cmd', '');
      if Cmd = CMD_DELIVER then
      begin
        Team := Obj.Get('team', '');
        Seq  := Obj.Get('seq', Int64(0));
        if not FindSession(FCfg, Team, Sess) then
        begin
          WriteLine(Stream, ReplyErr('session not declared: ' + Team));
          Exit;
        end;
        if DeliverOne(Team, Seq, Obj.Get('text', '')) then
          WriteLine(Stream, ReplySent(Seq, False))
        else
          WriteLine(Stream, ReplyErr('tmux session unavailable: ' + Sess.TmuxSession));
      end
      else if Cmd = CMD_PING then
      begin
        AllUp := True;
        for i := 0 to High(FCfg.Sessions) do
          if not SessionExists(FCfg.Sessions[i].TmuxSession) then
            AllUp := False;
        if AllUp then
          WriteLine(Stream, ReplyOk)
        else
          WriteLine(Stream, ReplyErr('some session down'));
        { the hub advertises its release in pings: the autoupdate path }
        HV := Obj.Get('hubver', '');
        if (HV <> '') and FCfg.AutoUpdate and VerNewer(HV, PizarraVersion) then
          TriggerSelfUpdate(FCfg, HV, False, True);
      end
      else if Cmd = CMD_VER then
        { the hub's fleet probe: report this daemon's release }
        WriteLine(Stream, ReplyVer(PizarraVersion))
      else if Cmd = CMD_UPDATE then
      begin
        { Only the hub may order a self-update. The bus secret alone is not
          enough: every agent host holds it, and a restart loop of every
          daemon would take the fleet down. Check the peer address. }
        if not FromHub(Stream, FCfg.HubHost) then
          WriteLine(Stream, ReplyErr('update: only the hub may trigger this'))
        else
        begin
          { reply first so the hub sees the trigger accepted, then work
            off-thread }
          WriteLine(Stream, ReplyOk);
          TriggerSelfUpdate(FCfg, Obj.Get('ver', ''), Obj.Get('force', False),
            False);
        end;
      end
      else
        WriteLine(Stream, ReplyErr('unknown cmd'));
    finally
      Obj.Free;
    end;
  except
    { connection errors: nothing to do, the hub will retry }
  end;
end;

function TTizaDaemon.SaveSeqState: Boolean;
begin
  Result := True;
  if FStatePath = '' then
    Exit;   { With no state file there is no acknowledgement to save. }
  Result := False;
  try
    FLastSeq.SaveToFile(FStatePath + '.tmp');
    { Check rename: ignoring its failure left the acknowledgement only in
      memory while the hub treated the delivery as successful. }
    Result := RenameFile(FStatePath + '.tmp', FStatePath);
  except
    on E: Exception do
    begin
      Writeln(StdErr, 'tiza: cannot save the delivery receipt: ', E.Message);
      Flush(StdErr);
    end;
  end;
end;

procedure TTizaDaemon.RetrySeqState;
begin
  if not FSeqDirty then
    Exit;
  FLock.Enter;
  try
    if SaveSeqState then
    begin
      Writeln(StdErr, 'tiza: receipt backlog persisted');
      Flush(StdErr);
      FSeqDirty := False;
    end;
  finally
    FLock.Leave;
  end;
end;

function TTizaDaemon.DeliverOne(const Team: string; Seq: Int64;
  const Text: string): Boolean;
var
  Sess: TPzSession;
  Last: Int64;
  StartWhy: string;
begin
  Result := False;
  if not FindSession(FCfg, Team, Sess) then
    Exit;
  FLock.Enter;
  try
    { HOLD: the pane is a permission prompt. Pasting the message would ANSWER it
      (auto-approve/deny), so refuse to inject and NAK — the hub keeps the message
      pending and redelivers it once the block clears. This gate is the zero-
      latency safety belt; the hub also stops pushing once it learns of the hold. }
    if FHold.Values[LowerCase(Team)] = '1' then
      Exit(False);
    Last := StrToInt64Def(FLastSeq.Values[LowerCase(Team)], 0);
    { duplicate ONLY when it equals the last injected seq (a retry after a lost
      ack — the hub retries head-of-line, one at a time). Seq < Last means the
      hub's store was reset: re-inject rather than black-hole new messages. A
      duplicate still counts as delivered. }
    if (Seq > 0) and (Seq = Last) then
      Exit(True);
    { If the session is missing and cannot be created, do NOT paste. Otherwise
      execution continued and the text landed wherever tmux chose. }
    if not EnsureSessionDetailed(Sess.TmuxSession, Sess.Launch, Sess.Workdir,
      Sess.User, StartWhy) then
    begin
      Writeln(StdErr, 'tiza: delivery queued for ', Team, ': session ',
        Sess.TmuxSession, ' unavailable: ', StartWhy);
      Flush(StdErr);
      Exit(False);
    end;
    if DeliverTmux(Sess.TmuxSession, Text) then
    begin
      FLastSeq.Values[LowerCase(Team)] := IntToStr(Seq);
      { THE TEXT HAS ALREADY BEEN PASTED. Saving this is the acknowledgement,
        not the delivery. A disk failure does NOT undo anything because doing
        so would repeat the paste immediately, but it must not be hidden either.
        Report it once and leave it pending for the watchdog to retry. The
        remaining guarantee is visible, at-least-once delivery. }
      if not SaveSeqState then
      begin
        if not FSeqDirty then
        begin
          Writeln(StdErr, 'tiza: receipt NOT durable for ', Team,
            ' (the text WAS pasted; after a restart it may be pasted again). ',
            'Will retry.');
          Flush(StdErr);
        end;
        FSeqDirty := True;
      end
      else if FSeqDirty then
      begin
        Writeln(StdErr, 'tiza: receipt backlog persisted');
        Flush(StdErr);
        FSeqDirty := False;
      end;
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

{ ---------- dial-in (reverse delivery channel) ---------- }

constructor TDialThread.Create(AOwner: TTizaDaemon);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDialThread.Execute;
var
  Sock: TInetSocket;
  Teams, Cmd, Team, Reply, Line, Buf, HV: string;
  Obj, ROk: TJSONObject;
  Seq: Int64;
  i, n, p, IdleMs: Integer;
  Ok, Connected: Boolean;
  Raw: array[0..4095] of Byte;
  fds: TFDSet;
  tv:  TTimeVal;
begin
  { the comma list of teams this daemon hosts (claimed on the hub) }
  Teams := '';
  for i := 0 to High(FOwner.FCfg.Sessions) do
  begin
    if Teams <> '' then Teams := Teams + ',';
    Teams := Teams + FOwner.FCfg.Sessions[i].Team;
  end;
  while (not Terminated) and (not ShutdownRequested) do
  begin
    Sock := nil;
    Buf := '';
    Connected := False;
    try
      try
        Sock := TInetSocket.Create(FOwner.FCfg.HubHost, FOwner.FCfg.HubPort, 5000);
        WriteLine(Sock, BuildDial(FOwner.FCfg.HubSecret, FOwner.FCfg.SelfId,
          Teams, FOwner.FCfg.KeepAlive, -1, PizarraVersion));
        Reply := ReadLine(Sock);
        ROk := ParseObj(Reply);
        Ok := (ROk <> nil) and ROk.Get('ok', False);
        if ROk <> nil then
          ROk.Free;
        if not Ok then
          raise Exception.Create('dial refused: ' + Reply);
        Connected := True;
        Writeln(Format('tiza daemon: dial-in to %s:%d established (teams: %s)',
          [FOwner.FCfg.HubHost, FOwner.FCfg.HubPort, Teams]));
        Flush(Output);
        IdleMs := 0;
        { receive loop: the hub streams deliveries + pings; we select with a 1s
          timeout so shutdown is prompt and a silent hub is detected }
        while (not Terminated) and (not ShutdownRequested) do
        begin
          fpFD_ZERO(fds);
          fpFD_SET(Sock.Handle, fds);
          tv.tv_sec := 1;
          tv.tv_usec := 0;
          if fpSelect(Sock.Handle + 1, @fds, nil, nil, @tv) > 0 then
          begin
            n := Sock.Read(Raw, SizeOf(Raw));
            if n <= 0 then
              raise Exception.Create('hub closed the dial connection');
            SetLength(Line, n);
            Move(Raw, Line[1], n);
            Buf := Buf + Line;
            IdleMs := 0;
            repeat
              p := Pos(#10, Buf);
              if p = 0 then
                Break;
              Line := Copy(Buf, 1, p - 1);
              Delete(Buf, 1, p);
              if (Line <> '') and (Line[Length(Line)] = #13) then
                SetLength(Line, Length(Line) - 1);
              if Line <> '' then
              begin
                Obj := ParseObj(Line);
                if Obj <> nil then
                  try
                    Cmd := Obj.Get('cmd', '');
                    if Cmd = CMD_DELIVER then
                    begin
                      Team := Obj.Get('team', '');
                      Seq  := Obj.Get('seq', Int64(0));
                      Ok := FOwner.DeliverOne(Team, Seq, Obj.Get('text', ''));
                      WriteLine(Sock, BuildDeliverAck(Team, Seq, Ok));
                    end
                    else if Cmd = CMD_UPDATE then
                    begin
                      { the hub expects an ack per pushed line; ok=false makes
                        it skip its delivered-mark (this is a control line) }
                      WriteLine(Sock, BuildDeliverAck('', 0, False));
                      TriggerSelfUpdate(FOwner.FCfg, Obj.Get('ver', ''),
                        Obj.Get('force', False), False);
                    end
                    else if Cmd = CMD_PING then
                    begin
                      HV := Obj.Get('hubver', '');
                      if (HV <> '') and FOwner.FCfg.AutoUpdate and
                         VerNewer(HV, PizarraVersion) then
                        TriggerSelfUpdate(FOwner.FCfg, HV, False, True);
                    end;
                    { anything else: ignore — the traffic holds NAT open }
                  finally
                    Obj.Free;
                  end;
              end;
            until False;
          end
          else
          begin
            Inc(IdleMs, 1000);
            if IdleMs >= FOwner.FCfg.KeepAlive * 2 * 1000 then
              raise Exception.Create('dial idle: no keepalive from hub');
          end;
        end;
      except
        on E: Exception do
          if Connected or (not Terminated) then
          begin
            Writeln('tiza daemon: dial-in down (', E.Message, '); retrying...');
            Flush(Output);
          end;
      end;
    finally
      FreeAndNil(Sock);
    end;
    { backoff before reconnect, staying responsive to shutdown }
    i := 0;
    while (i < 15) and (not Terminated) and (not ShutdownRequested) do
    begin
      Sleep(200);
      Inc(i);
    end;
  end;
end;

procedure TTizaDaemon.Run;
var
  Server: TPzServer;
  wd: TDmnWatchdog;
  dial: TDialThread;
  act: TActivityThread;
  i: Integer;
  hasActivity: Boolean;
begin
  InstallShutdownHandler;
  Server := TPzServer.Create(FCfg.Listen, FCfg.Port, @HandleConn);
  try
    { A port collision must fail before any watchdog, dial thread, activity
      sampler, or managed session can start. }
    Server.Prepare;
    Writeln(Format('tiza daemon: listening on %s:%d, %d session(s)',
      [FCfg.Listen, FCfg.Port, Length(FCfg.Sessions)]));
    for i := 0 to High(FCfg.Sessions) do
      Writeln(Format('  %-12s tmux=%s', [FCfg.Sessions[i].Team,
        FCfg.Sessions[i].TmuxSession]));
    Flush(Output);

    wd := TDmnWatchdog.Create(Self);
    dial := nil;
    if FCfg.Dial then
    begin
      Writeln(Format('tiza daemon: dial-in mode -> hub %s:%d, keepalive %ds',
        [FCfg.HubHost, FCfg.HubPort, FCfg.KeepAlive]));
      Flush(Output);
      dial := TDialThread.Create(Self);
    end;
    { activity sampler: only when at least one session opts in (activity=on) }
    act := nil;
    hasActivity := False;
    for i := 0 to High(FCfg.Sessions) do
      if FCfg.Sessions[i].Activity then
        hasActivity := True;
    if hasActivity then
    begin
      Writeln('tiza daemon: activity sampling ON for opt-in session(s)');
      Flush(Output);
      act := TActivityThread.Create(Self);
    end;
    try
      Server.Run;
    finally
      Writeln('tiza daemon: stopping');
      wd.Terminate;
      wd.WaitFor;
      wd.Free;
      if dial <> nil then
      begin
        dial.Terminate;
        dial.WaitFor;
        dial.Free;
      end;
      if act <> nil then
      begin
        act.Terminate;
        act.WaitFor;
        act.Free;
      end;
      { an in-flight deliver holds FLock across tmux ops — it must finish
        before RunDaemon frees this object (freeing a held lock is UB) }
      WaitConnectionsIdle(5000);
    end;
  finally
    Server.Free;
  end;
end;

{ Commands that talk to nobody are answered locally and therefore need no
  configuration or identity. If one ever sends anything over the bus, it no
  longer belongs in this list. }
function IsLocalOnly(P: TStringList): Boolean;
var
  A, B: string;
begin
  Result := False;
  if (P = nil) or (P.Count = 0) then
    Exit;
  A := LowerCase(P[0]);
  B := '';
  if P.Count > 1 then
    B := LowerCase(P[1]);
  Result := (A = 'help') or (A = 'ayuda') or (A = 'manual') or
            (A = 'agents') or
            (((A = 'wf') or (A = 'workflow')) and
             ((B = 'help') or (B = 'ayuda') or (B = '--help') or
              (B = '-h') or (B = '?')));
end;

{ Test with a REAL WRITE, not permission bits: receipt persistence uses
  temporary-file-plus-rename, so the daemon must be able to create a file in
  THAT directory. Permission bits can appear to allow this and still fail in
  practice (different owner, ACL, or a read-only mount). }
function CanWritePath(const TargetPath: string): Boolean;
var
  F: TextFile;
  ProbePath: string;
begin
  Result := False;
  ProbePath := TargetPath + '.tmp';
  try
    AssignFile(F, ProbePath);
    Rewrite(F);
    CloseFile(F);
    DeleteFile(ProbePath);
    Result := True;
  except
    Result := False;
  end;
end;

procedure RunDaemon(const ConfigArg: string);
var
  Path, ConfigReason, ReceiptPath: string;
  Cfg: TTizaDaemonConfig;
  D: TTizaDaemon;
begin
  Path := ResolveConfigStrict(ConfigArg, 'TIZA_CONF', 'tiza.conf', ConfigReason);
  if Path = '' then
  begin
    if ConfigReason <> '' then
      Fail(ConfigReason)
    else
      Fail('no config found (looked for tiza.conf; use --config)');
  end;
  try
    Cfg := LoadTizaDaemonConfig(Path);
  except
    on E: Exception do
    begin
      Fail(E.Message);
      Exit;
    end;
  end;
  if Length(Cfg.Sessions) = 0 then
  begin
    Writeln(StdErr, 'tiza: warning: no [session:NAME] sections yet - daemon '
      + 'runs idle; add sessions and restart (no crash-loop)');
    Flush(StdErr);
  end;
  if Cfg.Secret = '' then
    Fail('tiza.conf has no secret for the daemon');
  { Store the receipt where configured; by default, beside the configuration. }
  if Cfg.StatePath <> '' then
    ReceiptPath := Cfg.StatePath
  else
    ReceiptPath := Path + '.state';
  { Check this AT STARTUP, not on every delivery. Per-message checks would
    repeat the same warning and arrive too late, after injection. Report it once
    with the remedy. Do not abort: delivery still works, but receipt memory is
    lost across restarts and the operator must know. }
  if not CanWritePath(ReceiptPath) then
  begin
    Writeln(StdErr, 'tiza: WARNING: cannot write the delivery receipt to ',
      ReceiptPath, ': a completed delivery may be repeated after a restart.',
      ' Fix: [daemon] state = <path writable by this daemon>');
    { Flush or the warning may never be seen. StdErr is block-buffered when sent
      to a file, as with LaunchAgent StandardErrorPath or another supervisor,
      rather than line-buffered as on a terminal. A short line can remain in the
      buffer until an unclean stop discards it. }
    Flush(StdErr);
  end;
  D := TTizaDaemon.Create(Cfg, ReceiptPath);
  try
    D.Run;
  finally
    D.Free;
  end;
end;

{ =================== task / tree CLI =================== }

procedure PrintTaskLine(T: TJSONObject);
var
  H, Team, P: string;
begin
  H := T.Get('hito', '');
  if H <> '' then
    H := '[' + H + '] ';
  Team := T.Get('team', '');
  if Team = '' then
    Team := 'backlog';
  P := '';
  if T.Get('parent', 0) > 0 then
    P := Format('  (subtask of #%d)', [T.Get('parent', 0)]);
  { Use %-10s, not %-6s: 'superseded' is 10 characters and shifted the column. }
  Writeln(Format('#%d %s%-10s %-12s %s%s',
    [T.Get('id', 0), H, T.Get('state', '?'), Team, T.Get('title', ''), P]));
end;

{ Full task card, including NOTES. The CLI used to print only the summary line,
  so the reason for a state change (for example, a task superseded when a plan
  branch was abandoned) was visible only in chat. }
procedure PrintTaskCard(T: TJSONObject);
var
  CK, CV: TCells;
  Notes: TJSONArray;
  N: TJSONObject;
  i: Integer;
  Team, S: string;
begin
  Team := T.Get('team', '');
  if Team = '' then
    Team := 'backlog';
  CK := TCells.Create('state', 'team');
  CV := TCells.Create(T.Get('state', '?'), Team);
  S := T.Get('hito', '');
  if S <> '' then
  begin
    CK := Concat(CK, TCells.Create('milestone'));
    CV := Concat(CV, TCells.Create(S));
  end;
  S := T.Get('wf_name', '');
  if S <> '' then
  begin
    CK := Concat(CK, TCells.Create('workflow'));
    CV := Concat(CV, TCells.Create(Format('%s (step id %d)',
      [S, T.Get('wf_step_uid', 0)])));
  end;
  if T.Get('parent', 0) > 0 then
  begin
    CK := Concat(CK, TCells.Create('subtask of'));
    CV := Concat(CV, TCells.Create('#' + IntToStr(T.Get('parent', 0))));
  end;
  CK := Concat(CK, TCells.Create('task', 'created'));
  CV := Concat(CV, TCells.Create(T.Get('title', ''), T.Get('created', '')));
  S := T.Get('closed', '');
  if S <> '' then
  begin
    CK := Concat(CK, TCells.Create('closed'));
    CV := Concat(CV, TCells.Create(S));
  end;
  Notes := T.Get('notes', TJSONArray(nil));
  if Notes <> nil then
    for i := 0 to Notes.Count - 1 do
    begin
      N := TJSONObject(Notes.Items[i]);
      CK := Concat(CK, TCells.Create(Format('note %s',
        [Copy(N.Get('ts', ''), 1, 16)])));
      CV := Concat(CV, TCells.Create(N.Get('by', '?') + ': ' +
        N.Get('text', '')));
    end;
  Writeln(Card(Format('task #%d', [T.Get('id', 0)]), CK, CV, 118));
end;

{ One task request/reply; prints the returned card or list. }
procedure RunTaskCli(const Cfg: TTizaConfig; P: TStringList);
var
  Sub, TeamName, Title, Hito, Reply: string;
  Id, Parent, i: Integer;
  Obj, T: TJSONObject;
  Arr: TJSONArray;
  TT: TRows;
begin
  if P.Count < 2 then
    Fail('usage: tiza task add|done|reopen|note|list|show ... (tiza --help)');
  Sub := LowerCase(P[1]);


  if Sub = 'add' then
  begin
    if P.Count < 4 then
      Fail('usage: tiza task add <team|-> <title...> [--milestone H] [--parent N]');
    TeamName := P[2];
    Title := '';
    Hito := '';
    Parent := 0;
    i := 3;
    while i < P.Count do
    begin
      if ((P[i] = '--milestone') or (P[i] = '--hito')) and
         (i + 1 < P.Count) then
      begin
        Hito := P[i + 1]; Inc(i);
      end
      else if (P[i] = '--parent') and (i + 1 < P.Count) then
      begin
        { A nonnumeric --parent used to become 0, meaning "no parent", so a
          typo silently created a ROOT task instead of the intended subtask. }
        if StrToIntDef(P[i + 1], -1) < 0 then
          Fail('--parent needs a task id (a number); omit it for a root task');
        Parent := StrToIntDef(P[i + 1], 0); Inc(i);
      end
      else
      begin
        if Title <> '' then
          Title := Title + ' ';
        Title := Title + P[i];
      end;
      Inc(i);
    end;
    if not SendRequest(Cfg, BuildTaskAdd(Cfg.Secret, Cfg.SelfId, Title,
      TeamName, Hito, Parent), Reply) then
      Exit;
  end
  else if (Sub = 'done') or (Sub = 'reopen') then
  begin
    if P.Count < 3 then
      Fail('usage: tiza task ' + Sub + ' <id>');
    Id := StrToIntDef(P[2], -1);
    if Sub = 'done' then
      Title := 'done'
    else
      Title := 'open';
    if not SendRequest(Cfg, BuildTaskState(Cfg.Secret, Cfg.SelfId, Id, Title),
      Reply) then
      Exit;
  end
  else if Sub = 'delete' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza task delete <id>');
    Id := StrToIntDef(P[2], -1);
    if not SendRequest(Cfg, BuildTaskDelete(Cfg.Secret, Cfg.SelfId, Id), Reply) then
      Exit;
  end
  else if Sub = 'note' then
  begin
    if P.Count < 4 then
      Fail('usage: tiza task note <id> <text...>');
    Id := StrToIntDef(P[2], -1);
    Title := '';
    for i := 3 to P.Count - 1 do
    begin
      if Title <> '' then
        Title := Title + ' ';
      Title := Title + P[i];
    end;
    if not SendRequest(Cfg, BuildTaskNote(Cfg.Secret, Cfg.SelfId, Id, Title),
      Reply) then
      Exit;
  end
  else if Sub = 'list' then
  begin
    Title := 'open';
    TeamName := '';
    if P.Count > 3 then
    begin
      { two args: always <filter> <team|@group> — any word is a filter
        (open|done|all or an exact state like 'error') }
      Title := LowerCase(P[2]);
      TeamName := P[3];
    end
    else if P.Count > 2 then
    begin
      if (LowerCase(P[2]) = 'open') or (LowerCase(P[2]) = 'done') or
         (LowerCase(P[2]) = 'all') then
        Title := LowerCase(P[2])
      else
        TeamName := P[2];   { team, @group, or an exact state (hub resolves) }
    end;
    if not SendRequest(Cfg, BuildTaskList(Cfg.Secret, Cfg.SelfId, Title,
      TeamName), Reply) then
      Exit;
  end
  else if Sub = 'show' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza task show <id>');
    Id := StrToIntDef(P[2], -1);
    if not SendRequest(Cfg, BuildTaskShow(Cfg.Secret, Cfg.SelfId, Id), Reply) then
      Exit;
  end
  else if (Sub = 'assign') or (Sub = 'asignar') then
  begin
    if P.Count < 4 then
      Fail('usage: tiza task assign <id> <team|->');
    Id := StrToIntDef(P[2], -1);
    if not SendRequest(Cfg, BuildTaskAssign(Cfg.Secret, Cfg.SelfId, Id, P[3]),
      Reply) then
      Exit;
  end
  else
    Fail('unknown task subcommand: ' + Sub);

  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    T := Obj.Get('task', TJSONObject(nil));
    if T <> nil then
    begin
      if Sub = 'show' then
        PrintTaskCard(T)   { The full card with notes, as shown in chat. }
      else
        PrintTaskLine(T);
    end;
    Arr := Obj.Get('tasks', TJSONArray(nil));
    if Arr <> nil then
    begin
      if Arr.Count = 0 then
        Writeln('(no tasks)')
      else if Pretty then
      begin
        SetLength(TT, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          T := TJSONObject(Arr.Items[i]);
          SetLength(TT[i], 5);
          TT[i][0] := '#' + IntToStr(T.Get('id', 0));
          TT[i][1] := T.Get('state', '?');
          TT[i][2] := BoolToStr(T.Get('team', '') = '', 'backlog',
            T.Get('team', ''));
          TT[i][3] := T.Get('hito', '');
          TT[i][4] := T.Get('title', '');
        end;
        Writeln(Table(TCells.Create('id', 'state', 'team', 'milestone', 'task'),
          TT, 118));
      end
      else
        for i := 0 to Arr.Count - 1 do
          PrintTaskLine(TJSONObject(Arr.Items[i]));
    end;
    Arr := Obj.Get('subtasks', TJSONArray(nil));
    if (Arr <> nil) and (Arr.Count > 0) then
    begin
      Title := '';
      for i := 0 to Arr.Count - 1 do
      begin
        if Title <> '' then
          Title := Title + ' ';
        Title := Title + '#' + IntToStr(Arr.Items[i].AsInteger);
      end;
      Writeln('subtasks: ', Title);
    end;
  finally
    Obj.Free;
  end;
end;

procedure PrintTeamCard(const Reply: string; Detail: Boolean = False);
var
  Obj, T, AO: TJSONObject;
  AD: TJSONArray;
  Kind: string;
  i: Integer;
begin
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    T := Obj.Get('team', TJSONObject(nil));
    if T = nil then
    begin
      if Obj.Get('note', '') <> '' then
        Writeln(Obj.Get('note', ''))
      else
        Writeln('ok');
      Exit;
    end;
    Writeln(Format('#%d %s', [T.Get('id', 0), T.Get('name', '')]));
    Writeln('  speciality: ', T.Get('speciality', ''));
    if T.Get('apps', '') <> '' then
      Writeln('  apps:       ', T.Get('apps', ''),
        '   (tiza app show <name>)');
    if Detail then
    begin
      if T.Get('project', '') <> '' then
        Writeln('  project:    ', T.Get('project', ''));
      if T.Get('groups', '') <> '' then
        Writeln('  groups:     ', T.Get('groups', ''));
      AD := T.Get('appsdetail', TJSONArray(nil));
      if (AD <> nil) and (AD.Count > 0) then
      begin
        Writeln('  applications it is responsible for:');
        for i := 0 to AD.Count - 1 do
        begin
          AO := TJSONObject(AD.Items[i]);
          Writeln('    - ', AO.Get('name', ''), ': ',
            BoolToStr(AO.Get('purpose', '') = '', '(no purpose recorded)',
              AO.Get('purpose', '')));
          if AO.Get('repo', '') <> '' then
            Writeln('        repo: ', AO.Get('repo', ''));
          if AO.Get('path', '') <> '' then
            Writeln('        path: ', AO.Get('path', ''));
          Writeln('        manual: ',
            BoolToStr(AO.Get('hasdoc', False),
              'tiza app doc ' + AO.Get('name', ''), '(none yet)'));
        end;
      end;
    end;
    if T.Get('prompt', '') <> '' then
      Writeln('  prompt:     ', T.Get('prompt', ''));
    if T.Get('parent', '') <> '' then
      Writeln('  parent:     ', T.Get('parent', ''));
    if T.Get('workdir', '') <> '' then
      Writeln('  workdir:    ', T.Get('workdir', ''));
    if T.Get('slave', False) then
      Writeln('  slave:      on — READ-ONLY, replies only to ',
        T.Get('parent', '(no master)'));
    if T.Get('other_sessions', '') <> '' then
      Writeln('  AMBIGUOUS:  other tmux session(s) could be this team: ',
        T.Get('other_sessions', ''),
        ' — pizarra delivers ONLY to the one above');
    Kind := T.Get('kind', '');
    if Kind = '' then   { pre-1.0.4 hub: infer as well as it can be inferred }
      if T.Get('host', '') <> '' then Kind := 'push' else Kind := 'local';
    if Kind = 'push' then
      Writeln('  delivery:   remote push to ', T.Get('host', ''))
    else if Kind = 'dial' then
      Writeln('  delivery:   dial-in (the host dials the hub and the hub',
        ' delivers over that held connection)')
    else if Kind = 'inbox' then
      Writeln('  delivery:   inbox-only (pull: config self=',
        T.Get('name', ''), ', then tiza inbox)')
    else
      Writeln(Format('  delivery:   local (tmux %s, launch: %s)',
        [T.Get('session', ''), T.Get('launch', '(none)')]));
    if T.Get('user', '') <> '' then
      Writeln('  run as:     ', T.Get('user', ''), '  (su - user)');
  finally
    Obj.Free;
  end;
end;

procedure RunTreeCli(const Cfg: TTizaConfig); forward;
procedure RunAppCli(const Cfg: TTizaConfig; P: TStringList); forward;
procedure RunBackupVerify(const Dir: string); forward;

const
  TIOCGWINSZ_REQ = $5413;   { Linux TIOCGWINSZ }
type
  TWinSz = record ws_row, ws_col, ws_xpixel, ws_ypixel: Word; end;

{ terminal width in columns; 100 (a wrapping default) if it cannot be queried
  (for example when piped) — so members still wrap into short, visible lines. }
function CliTermWidth: Integer;
var ws: TWinSz;
begin
  if fpIOCtl(1, TIOCGWINSZ_REQ, @ws) >= 0 then
    Result := ws.ws_col
  else
    Result := 0;
  if Result <= 0 then
    Result := 100;
end;

procedure PrintGroups(const Reply: string; const Filter: string = '');
var
  Obj, G: TJSONObject;
  Arr, M, MI, EX: TJSONArray;
  i, j, mid, tw: Integer;
  Want, Cell, Hdr, Line, OnIdleP, OnBlockP: string;
  Found, AnyMuted, AllIdle, AnyBlocked: Boolean;
  Cells: array of string;

  function EsMuted(Ex: TJSONArray; const Nm: string): Boolean;
  var k: Integer;
  begin
    Result := False;
    if Ex = nil then Exit;
    for k := 0 to Ex.Count - 1 do
      if SameText(Ex.Items[k].AsString, Nm) then
      begin Result := True; Exit; end;
  end;

  { members wrapped to the width, indented — every member always visible, no
    truncated column. ANSI-aware width (a muted member is reverse-video). }
  procedure WrapMembers(const Cs: array of string; MaxW: Integer);
  var k, w, wln: Integer; ln: string;
  begin
    ln := ''; wln := 0;
    for k := 0 to High(Cs) do
    begin
      w := VisCells(Cs[k]);
      if (ln <> '') and (wln + 2 + w > MaxW) then
      begin Writeln('  ', ln); ln := ''; wln := 0; end;
      if ln <> '' then begin ln := ln + '  '; wln := wln + 2; end;
      ln := ln + Cs[k]; wln := wln + w;
    end;
    if ln <> '' then Writeln('  ', ln);
  end;

  function OnIdleText(const P: string): string;
  begin
    if (P = '') or (P = 'off') then Result := 'on idle: off'
    else if P = 'boss' then Result := 'on idle: wake the boss'
    else if P = 'all' then Result := 'on idle: wake all members'
    else Result := 'on idle: wake ' + P;
  end;

begin
  Want := Filter;
  if (Want <> '') and (Want[1] = '@') then
    Delete(Want, 1, 1);
  Found := False;
  AnyMuted := False;
  tw := CliTermWidth;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    Arr := Obj.Get('groups', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      Writeln('(no groups)');
      Exit;
    end;
    { ONE BLOCK per group: header (name/admin/project/on-idle + live "all
      stopped" indicator) then members wrapped to the width. }
    for i := 0 to Arr.Count - 1 do
    begin
      G := TJSONObject(Arr.Items[i]);
      if (Want <> '') and not SameText(G.Get('name', ''), Want) then
        Continue;
      Found := True;
      M := G.Get('members', TJSONArray(nil));
      MI := G.Get('member_ids', TJSONArray(nil));
      EX := G.Get('excluded', TJSONArray(nil));
      OnIdleP := LowerCase(Trim(G.Get('on_idle', '')));
      OnBlockP := LowerCase(Trim(G.Get('on_block', '')));
      AllIdle := G.Get('all_idle', False);
      AnyBlocked := G.Get('any_blocked', False);

      Hdr := '@' + G.Get('name', '');
      if G.Get('boss', '') <> '' then
        Hdr := Hdr + '   admin ' + G.Get('boss', '');
      if G.Get('project', '') <> '' then
        Hdr := Hdr + '   project ' + G.Get('project', '');
      Writeln(Hdr);

      SetLength(Cells, 0);
      if M <> nil then
        for j := 0 to M.Count - 1 do
        begin
          mid := 0;
          if (MI <> nil) and (j < MI.Count) then
            mid := MI.Items[j].AsInteger;
          if mid > 0 then
            Cell := Format('#%d %s', [mid, M.Items[j].AsString])
          else
            Cell := M.Items[j].AsString;
          if EsMuted(EX, M.Items[j].AsString) then
          begin
            { reverse video on a TTY; a text tag when piped, where
              ANSI is off and reverse video would be invisible }
            if ColorsOn then Cell := Inverse(Cell) else Cell := Cell + ' (muted)';
            AnyMuted := True;
          end;
          SetLength(Cells, Length(Cells) + 1);
          Cells[High(Cells)] := Cell;
        end;
      if Length(Cells) = 0 then
        Writeln('  (no members)')
      else
        WrapMembers(Cells, tw - 4);

      Line := '  ' + OnIdleText(OnIdleP);
      if AllIdle then
      begin
        if (OnIdleP <> '') and (OnIdleP <> 'off') then
          Line := Line + '   ' + Inverse(' ALL STOPPED - signal armed ')
        else
          Line := Line + '   [ALL STOPPED]';
      end
      else if AnyBlocked then
        Line := Line + '   (a member is BLOCKED on a prompt)';
      Writeln(Line);
      if OnBlockP = 'log' then
        Writeln('  on block: log only (operator alarm suppressed)')
      else
        Writeln('  on block: alarm');
      if Trim(G.Get('header', '')) <> '' then
        Writeln('  RULE (in every member''s header): ' + G.Get('header', ''));
    end;
    if (Want <> '') and not Found then
      Writeln('(no such group: ', Want, ')')
    else if AnyMuted then
      Writeln('  (reverse video / "(muted)" = excluded from @group sends)');
  finally
    Obj.Free;
  end;
end;

{ tiza group add|remove|project|list, or 'tiza group <name>' for one group }
procedure RunGroupCli(const Cfg: TTizaConfig; P: TStringList);
var
  Sub, Name, Members, Reply, Msg: string;
  i: Integer;
begin
  { a bare 'tiza group' / 'tiza groups' lists, like the chat /groups }
  if (P.Count < 2) or (LowerCase(P[1]) = 'list') then
  begin
    Name := '';
    if P.Count >= 3 then
      Name := P[2];                     { 'tiza group list <name>' filters }
    if SendRequest(Cfg, BuildGroupList(Cfg.Secret, Cfg.SelfId), Reply) then
      PrintGroups(Reply, Name);
    Exit;
  end;
  Sub := LowerCase(P[1]);
  { 'tiza group show <name>' / bare 'tiza group <name>' — only that group }
  if (Sub = 'show') or (Sub = 'ver') then
  begin
    if P.Count < 3 then
      Fail('usage: tiza group show <name>');
    if SendRequest(Cfg, BuildGroupList(Cfg.Secret, Cfg.SelfId), Reply) then
      PrintGroups(Reply, P[2]);
    Exit;
  end;
  if (P.Count = 2) and (Sub <> 'add') and (Sub <> 'remove') and
     (Sub <> 'project') and (Sub <> 'boss') and (Sub <> 'admin') and
     (Sub <> 'exclude') and (Sub <> 'onidle') and (Sub <> 'idle') and
     (Sub <> 'onidlemsg') and (Sub <> 'idlemsg') and
     (Sub <> 'onidlefrom') and (Sub <> 'idlefrom') and
     (Sub <> 'onidlereply') and (Sub <> 'idlereply') and
     (Sub <> 'header') and (Sub <> 'rule') and
     (Sub <> 'onblock') and (Sub <> 'block') then
  begin
    if SendRequest(Cfg, BuildGroupList(Cfg.Secret, Cfg.SelfId), Reply) then
      PrintGroups(Reply, P[1]);
    Exit;
  end;
  if P.Count < 3 then
    Fail('usage: tiza group ' + Sub + ' <name> ...');
  Name := P[2];
  Members := '';
  for i := 3 to P.Count - 1 do
  begin
    if Members <> '' then Members := Members + ',';
    Members := Members + P[i];
  end;
  if Sub = 'add' then
  begin
    if Members = '' then
      Fail('usage: tiza group add <name> <team...>');
    if SendRequest(Cfg, BuildGroupAdd(Cfg.Secret, Cfg.SelfId, Name, Members), Reply) then
      PrintGroups(Reply);
  end
  else if Sub = 'remove' then
  begin
    if SendRequest(Cfg, BuildGroupRemove(Cfg.Secret, Cfg.SelfId, Name, Members), Reply) then
      PrintGroups(Reply);
  end
  else if Sub = 'project' then
  begin
    if P.Count < 4 then
      Fail('usage: tiza group project <name> <project>');
    if SendRequest(Cfg, BuildGroupProject(Cfg.Secret, Cfg.SelfId, Name, P[3]), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'boss') or (Sub = 'admin') then
  begin
    if P.Count < 4 then
      Fail('usage: tiza group boss <name> <team>');
    if SendRequest(Cfg, BuildGroupBoss(Cfg.Secret, Cfg.SelfId, Name, P[3]), Reply) then
      PrintGroups(Reply);
  end
  else if Sub = 'exclude' then
  begin
    { the teams (Members here) are the WHOLE muted set; naming none clears it.
      Muted members stay in the group, they just do not receive @group sends. }
    if SendRequest(Cfg, BuildGroupExclude(Cfg.Secret, Cfg.SelfId, Name, Members), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'onidle') or (Sub = 'idle') then
  begin
    { what to do when the whole group goes idle: off | boss | all | team[,team] }
    if P.Count < 4 then
      Fail('usage: tiza group onidle <name> off|boss|all|team[,team]');
    if SendRequest(Cfg, BuildGroupOnIdle(Cfg.Secret, Cfg.SelfId, Name, P[3]), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'onidlemsg') or (Sub = 'idlemsg') then
  begin
    { the text sent when the group quiesces; the rest of the line is the message
      (naming none clears it, back to the generic default) }
    Msg := '';
    for i := 3 to P.Count - 1 do
    begin
      if Msg <> '' then Msg := Msg + ' ';
      Msg := Msg + P[i];
    end;
    if SendRequest(Cfg, BuildGroupOnIdleMsg(Cfg.Secret, Cfg.SelfId, Name, Msg), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'header') or (Sub = 'rule') then
  begin
    { a standing instruction shown in EVERY member's delivery header; the rest of
      the line is the text (naming none clears it) }
    Msg := '';
    for i := 3 to P.Count - 1 do
    begin
      if Msg <> '' then Msg := Msg + ' ';
      Msg := Msg + P[i];
    end;
    if SendRequest(Cfg, BuildGroupHeader(Cfg.Secret, Cfg.SelfId, Name, Msg), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'onidlefrom') or (Sub = 'idlefrom') then
  begin
    { who the on-idle nudge reads as: console | <team> | (none = pizarra) }
    Msg := '';
    if P.Count >= 4 then Msg := P[3];
    if SendRequest(Cfg, BuildGroupOnIdleFrom(Cfg.Secret, Cfg.SelfId, Name, Msg), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'onidlereply') or (Sub = 'idlereply') then
  begin
    { who the recipient is told to answer: console | <team> | (none = the sender) }
    Msg := '';
    if P.Count >= 4 then Msg := P[3];
    if SendRequest(Cfg, BuildGroupOnIdleReply(Cfg.Secret, Cfg.SelfId, Name, Msg), Reply) then
      PrintGroups(Reply);
  end
  else if (Sub = 'onblock') or (Sub = 'block') then
  begin
    if P.Count < 4 then
      Fail('usage: tiza group onblock <name> alarm|log|default');
    Msg := LowerCase(Trim(P[3]));
    if (Msg <> 'alarm') and (Msg <> 'log') and (Msg <> 'default') then
      Fail('onblock must be alarm, log, or default');
    if SendRequest(Cfg, BuildGroupOnBlock(Cfg.Secret, Cfg.SelfId, Name, Msg), Reply) then
      PrintGroups(Reply);
  end
  else
    Fail('unknown group subcommand: ' + Sub);
end;

procedure PrintWfReply(const Reply: string);
var
  Obj, W: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    if Obj.Get('tree', '') <> '' then
      Writeln(Vis(Obj.Get('tree', '')))
    else if Obj.Get('text', '') <> '' then
      Writeln(Obj.Get('text', ''));
    Arr := Obj.Get('workflows', TJSONArray(nil));
    if Arr <> nil then
    begin
      if Arr.Count = 0 then
        Writeln('(no workflows)');
      for i := 0 to Arr.Count - 1 do
      begin
        W := TJSONObject(Arr.Items[i]);
        Writeln(W.Get('line', W.Get('name', '?')));
      end;
    end;
    Arr := Obj.Get('history', TJSONArray(nil));
    if Arr <> nil then
    begin
      if Arr.Count = 0 then
        Writeln('(no snapshots yet - one is taken before every change)');
      for i := 0 to Arr.Count - 1 do
        Writeln(Arr.Items[i].AsString);
    end;
  finally
    Obj.Free;
  end;
end;

{ tiza wf save <name> [file] - write the full workflow card (JSON) to a file;
  tiza wf restore <name> <file> feeds it back. Pairs with the hub's automatic
  wfhistory snapshots (wf history / wf undo). }
procedure RunWfSave(const Cfg: TTizaConfig; P: TStringList);
var
  Reply, OutPath, S: string;
  Obj, W: TJSONObject;
  FS: TFileStream;
begin
  if P.Count < 3 then
    Fail('usage: tiza wf save <name> [file.wf.json]');
  if not SendRequest(Cfg, BuildWfShow(Cfg.Secret, Cfg.SelfId, P[2]), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    W := Obj.Get('workflow', TJSONObject(nil));
    if W = nil then
      Fail('bad reply from pizarra (no workflow card)');
    S := W.FormatJSON();
    if P.Count > 3 then
      OutPath := P[3]
    else
      OutPath := W.Get('name', 'workflow') + '.wf.json';
    FS := TFileStream.Create(OutPath, fmCreate);
    try
      FS.WriteBuffer(S[1], Length(S));
    finally
      FS.Free;
    end;
    Writeln('saved workflow card: ', OutPath,
      '   (restore: tiza wf restore ', W.Get('name', '?'), ' ', OutPath, ')');
  finally
    Obj.Free;
  end;
end;

procedure RunWfRestore(const Cfg: TTizaConfig; P: TStringList);
var
  SL: TStringList;
  Reply: string;
begin
  if P.Count < 4 then
    Fail('usage: tiza wf restore <name> <file.wf.json>');
  if not FileExists(P[3]) then
    Fail('file not found: ' + P[3]);
  SL := TStringList.Create;
  try
    SL.LoadFromFile(P[3]);
    if Length(SL.Text) > 900000 then
      Fail('card too big for one request (max ~900 KB)');
    if SendRequest(Cfg, BuildWfRestore(Cfg.Secret, Cfg.SelfId, P[2], SL.Text),
      Reply) then
      PrintWfReply(Reply);
  finally
    SL.Free;
  end;
end;

function SqlQ(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

{ tiza wf export <name> [file] - READ-ONLY SQLite snapshot of one workflow
  (tables: workflow, member, step, dep, log, outbox). The live state stays in
  the hub's workflows.json and moves ONLY via tiza commands - never edit the
  export; regenerate it. A .sql target writes the plain dump (no sqlite3
  needed); otherwise the sqlite3 CLI builds the database file. }
procedure RunWfExport(const Cfg: TTizaConfig; P: TStringList);
var
  Reply, OutPath, SQL, DumpErr: string;
  Obj, W, E: TJSONObject;
  A, D: TJSONArray;
  i, j: Integer;
  Proc: TProcess;
  FS: TFileStream;
begin
  if P.Count < 3 then
    Fail('usage: tiza wf export <name> [f.sqlite|f.sql|f.mmd|f.dot]');
  if not SendRequest(Cfg, BuildWfShow(Cfg.Secret, Cfg.SelfId, P[2]), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    W := Obj.Get('workflow', TJSONObject(nil));
    if W = nil then
      Fail('bad reply from pizarra (no workflow card)');
    if P.Count > 3 then
      OutPath := P[3]
    else
      OutPath := W.Get('name', 'workflow') + '.sqlite';
    { diagram exports: Mermaid flowchart / Graphviz DOT, straight from the
      card - one node per step, one edge per dependency, START as source }
    if (LowerCase(ExtractFileExt(OutPath)) = '.mmd') or
       (LowerCase(ExtractFileExt(OutPath)) = '.dot') then
    begin
      DumpErr := LowerCase(ExtractFileExt(OutPath));
      if DumpErr = '.mmd' then
      begin
        SQL := 'flowchart TD'#10 +
          '  classDef pending fill:#eee,stroke:#999,color:#333'#10 +
          '  classDef active fill:#ffe9a8,stroke:#b8860b,color:#333'#10 +
          '  classDef done fill:#d3f0d3,stroke:#3a7d3a,color:#333'#10 +
          '  classDef error fill:#f6cfc7,stroke:#a33,color:#333'#10 +
          '  classDef fixed fill:#cfe0f6,stroke:#369,color:#333'#10 +
          '  START((START))'#10;
        A := W.Get('steps', TJSONArray(nil));
        if A <> nil then
          for i := 0 to A.Count - 1 do
          begin
            E := TJSONObject(A.Items[i]);
            SQL := SQL + Format('  s%d["#%d %s%s(%s)"]:::%s'#10,
              [E.Get('n', 0), E.Get('n', 0),
               StringReplace(E.Get('hito', ''), '"', '#quot;',
                 [rfReplaceAll]) + '&nbsp;',
               '', E.Get('team', ''), LowerCase(E.Get('state', 'pending'))]);
            D := E.Get('deps', TJSONArray(nil));
            if (D = nil) or (D.Count = 0) then
              SQL := SQL + Format('  START --> s%d'#10, [E.Get('n', 0)])
            else
              for j := 0 to D.Count - 1 do
                SQL := SQL + Format('  s%d --> s%d'#10,
                  [D.Items[j].AsInteger, E.Get('n', 0)]);
            D := E.Get('xdeps', TJSONArray(nil));
            if D <> nil then
              for j := 0 to D.Count - 1 do
                SQL := SQL + Format('  x%s%d(["%s#%d"]) -.-> s%d'#10,
                  [TJSONObject(D.Items[j]).Get('wf', ''),
                   TJSONObject(D.Items[j]).Get('n', 0),
                   TJSONObject(D.Items[j]).Get('wf', ''),
                   TJSONObject(D.Items[j]).Get('n', 0), E.Get('n', 0)]);
          end;
      end
      else
      begin
        SQL := 'digraph "' + W.Get('name', 'workflow') + '" {'#10 +
          '  rankdir=TB; node [shape=box,style=filled,fontname="monospace"];'#10 +
          '  START [shape=circle,fillcolor=white];'#10;
        A := W.Get('steps', TJSONArray(nil));
        if A <> nil then
          for i := 0 to A.Count - 1 do
          begin
            E := TJSONObject(A.Items[i]);
            case LowerCase(E.Get('state', 'pending')) of
              'active': Reply := '#ffe9a8';
              'done':   Reply := '#d3f0d3';
              'error':  Reply := '#f6cfc7';
              'fixed':  Reply := '#cfe0f6';
            else
              Reply := '#eeeeee';
            end;
            SQL := SQL + Format('  s%d [label="#%d %s\n(%s)",fillcolor="%s"];'#10,
              [E.Get('n', 0), E.Get('n', 0),
               StringReplace(StringReplace(E.Get('hito', ''), '\', '\\',
                 [rfReplaceAll]), '"', '\"', [rfReplaceAll]),
               E.Get('team', ''), Reply]);
            D := E.Get('deps', TJSONArray(nil));
            if (D = nil) or (D.Count = 0) then
              SQL := SQL + Format('  START -> s%d;'#10, [E.Get('n', 0)])
            else
              for j := 0 to D.Count - 1 do
                SQL := SQL + Format('  s%d -> s%d;'#10,
                  [D.Items[j].AsInteger, E.Get('n', 0)]);
            D := E.Get('xdeps', TJSONArray(nil));
            if D <> nil then
              for j := 0 to D.Count - 1 do
                SQL := SQL + Format(
                  '  "x_%s_%d" [label="%s#%d",style=dashed]; "x_%s_%d" -> s%d [style=dashed];'#10,
                  [TJSONObject(D.Items[j]).Get('wf', ''),
                   TJSONObject(D.Items[j]).Get('n', 0),
                   TJSONObject(D.Items[j]).Get('wf', ''),
                   TJSONObject(D.Items[j]).Get('n', 0),
                   TJSONObject(D.Items[j]).Get('wf', ''),
                   TJSONObject(D.Items[j]).Get('n', 0), E.Get('n', 0)]);
          end;
        SQL := SQL + '}'#10;
      end;
      FS := TFileStream.Create(OutPath, fmCreate);
      try
        FS.WriteBuffer(SQL[1], Length(SQL));
      finally
        FS.Free;
      end;
      Writeln('wrote diagram: ', OutPath,
        '   (Mermaid renders in artifacts/markdown; DOT via graphviz)');
      Exit;
    end;
    SQL :=
      'BEGIN;'#10 +
      'CREATE TABLE workflow(name TEXT, grp TEXT, state TEXT, errstep INTEGER,' +
      ' errby TEXT, created TEXT, started TEXT, closed TEXT);'#10 +
      'CREATE TABLE member(team TEXT);'#10 +
      'CREATE TABLE step(n INTEGER PRIMARY KEY, hito TEXT, team TEXT,' +
      ' state TEXT, prior TEXT, task INTEGER, started TEXT, closed TEXT);'#10 +
      'CREATE TABLE dep(step INTEGER, depends_on INTEGER);'#10 +
      'CREATE TABLE log(ts TEXT, by TEXT, text TEXT);'#10 +
      'CREATE TABLE outbox(id INTEGER, kind TEXT, step INTEGER, team TEXT,' +
      ' text TEXT);'#10 +
      Format('INSERT INTO workflow VALUES(%s,%s,%s,%d,%s,%s,%s,%s);'#10,
        [SqlQ(W.Get('name', '')), SqlQ(W.Get('group', '')),
         SqlQ(W.Get('state', '')), W.Get('errstep', 0),
         SqlQ(W.Get('errby', '')), SqlQ(W.Get('created', '')),
         SqlQ(W.Get('started', '')), SqlQ(W.Get('closed', ''))]);
    A := W.Get('members', TJSONArray(nil));
    if A <> nil then
      for i := 0 to A.Count - 1 do
        SQL := SQL + Format('INSERT INTO member VALUES(%s);'#10,
          [SqlQ(A.Items[i].AsString)]);
    A := W.Get('steps', TJSONArray(nil));
    if A <> nil then
      for i := 0 to A.Count - 1 do
      begin
        E := TJSONObject(A.Items[i]);
        SQL := SQL + Format(
          'INSERT INTO step VALUES(%d,%s,%s,%s,%s,%d,%s,%s);'#10,
          [E.Get('n', 0), SqlQ(E.Get('hito', '')), SqlQ(E.Get('team', '')),
           SqlQ(E.Get('state', '')), SqlQ(E.Get('prior', '')),
           E.Get('task', 0), SqlQ(E.Get('started', '')),
           SqlQ(E.Get('closed', ''))]);
        D := E.Get('deps', TJSONArray(nil));
        if D <> nil then
          for j := 0 to D.Count - 1 do
            SQL := SQL + Format('INSERT INTO dep VALUES(%d,%d);'#10,
              [E.Get('n', 0), D.Items[j].AsInteger]);
      end;
    A := W.Get('log', TJSONArray(nil));
    if A <> nil then
      for i := 0 to A.Count - 1 do
      begin
        E := TJSONObject(A.Items[i]);
        SQL := SQL + Format('INSERT INTO log VALUES(%s,%s,%s);'#10,
          [SqlQ(E.Get('ts', '')), SqlQ(E.Get('by', '')),
           SqlQ(E.Get('text', ''))]);
      end;
    A := W.Get('outbox', TJSONArray(nil));
    if A <> nil then
      for i := 0 to A.Count - 1 do
      begin
        E := TJSONObject(A.Items[i]);
        SQL := SQL + Format('INSERT INTO outbox VALUES(%d,%s,%d,%s,%s);'#10,
          [E.Get('id', 0), SqlQ(E.Get('kind', '')), E.Get('step', 0),
           SqlQ(E.Get('team', '')), SqlQ(E.Get('text', ''))]);
      end;
    SQL := SQL + 'COMMIT;'#10;
  finally
    Obj.Free;
  end;

  if LowerCase(ExtractFileExt(OutPath)) = '.sql' then
  begin
    FS := TFileStream.Create(OutPath, fmCreate);
    try
      FS.WriteBuffer(SQL[1], Length(SQL));
    finally
      FS.Free;
    end;
    Writeln('wrote SQL dump: ', OutPath);
    Exit;
  end;

  { fresh snapshot: never append into a stale database }
  if FileExists(OutPath) then
    DeleteFile(OutPath);
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := 'sqlite3';
    Proc.Parameters.Add('-bail');
    Proc.Parameters.Add(OutPath);
    Proc.Options := [poUsePipes];
    try
      Proc.Execute;
    except
      Fail('cannot run sqlite3 (install it, or export a .sql dump: ' +
        'tiza wf export ' + P[2] + ' ' + P[2] + '.sql)');
    end;
    Proc.Input.WriteBuffer(SQL[1], Length(SQL));
    Proc.CloseInput;
    while Proc.Running do
      Sleep(20);
    if Proc.ExitStatus <> 0 then
    begin
      DumpErr := '';
      SetLength(DumpErr, 512);
      i := Proc.Stderr.Read(DumpErr[1], 512);
      SetLength(DumpErr, i);
      Fail('sqlite3 failed: ' + Trim(DumpErr));
    end;
    Writeln('wrote SQLite snapshot: ', OutPath,
      '   (read-only export; the live state moves only via tiza commands)');
  finally
    Proc.Free;
  end;
end;

{ tiza workflow ... / tiza wf ... - dependency-tree milestone plans.
  Bare 'tiza wf' lists; bare 'tiza wf <name>' shows the tree. }
{ Do these strings differ by exactly ONE edit (one extra, missing, or changed
  character)? This is enough to distinguish a verb typo ('lst' for 'list')
  from a genuine plan name without carrying a full Levenshtein implementation. }
function NearWord(const A, B: string): Boolean;
var
  i, j, d: Integer;
begin
  Result := False;
  if Abs(Length(A) - Length(B)) > 1 then
    Exit;
  if Length(A) = Length(B) then
  begin
    d := 0;
    for i := 1 to Length(A) do
      if A[i] <> B[i] then
        Inc(d);
    Exit(d = 1);
  end;
  { One-character difference: the shorter must equal the longer minus one. }
  if Length(A) < Length(B) then
  begin
    for i := 1 to Length(B) do
      if Copy(B, 1, i - 1) + Copy(B, i + 1, Length(B)) = A then
        Exit(True);
  end
  else
    for j := 1 to Length(A) do
      if Copy(A, 1, j - 1) + Copy(A, j + 1, Length(A)) = B then
        Exit(True);
end;

{ Does this token look like a misspelled verb rather than a plan name? Compare
  it with known verbs by prefix and short edit distance: 'crea' for 'create',
  'lst' for 'list', and 'hecho' as the retained Spanish alias. A genuine plan
  name (relv2, softphone) resembles none of them. }
function IsWfVerbTypo(const Tok: string): Boolean;
const
  VERBS: array[0..25] of string = (
    'create', 'step', 'start', 'done', 'error', 'fixed', 'verify', 'show',
    'tasks', 'list', 'insert', 'remove', 'set', 'clone', 'history', 'undo',
    'save', 'restore', 'export', 'help',
    'crear', 'iniciar', 'hecho', 'lista', 'arreglado', 'verificar');
var
  i: Integer;
  T: string;
begin
  Result := False;
  T := LowerCase(Trim(Tok));
  if Length(T) < 3 then
    Exit;
  for i := 0 to High(VERBS) do
  begin
    { Prefix of a verb ('crea' from 'create') ... }
    if (Pos(T, VERBS[i]) = 1) or (Pos(VERBS[i], T) = 1) then
      Exit(True);
    { ... or one edit away ('lst' from 'list', 'donw' from 'done'). Those are
      the mistakes that otherwise slipped through as plan names. }
    if NearWord(T, VERBS[i]) then
      Exit(True);
  end;
end;

procedure RunWorkflowCli(const Cfg: TTizaConfig; P: TStringList);
var
  Sub, Name, AfterS, Text, Reply, EtaS, TeamF, Field: string;
  StepN, FromN, DepthN, i: Integer;
  Detail, MineF: Boolean;

  { join P[FromIdx..] into Text, capturing the option flags }
  procedure Collect(FromIdx: Integer);
  begin
    Text := '';
    i := FromIdx;
    while i < P.Count do
    begin
      if (P[i] = '--after') and (i + 1 < P.Count) then
      begin
        AfterS := P[i + 1];
        Inc(i);
      end
      else if (P[i] = '--step') and (i + 1 < P.Count) then
      begin
        { As in `wf done`, a nonnumeric value used to become 0. The engine
          interprets 0 as "my only active step", so a --step typo marked the
          caller's step as ERROR and stopped the ENTIRE plan. An explicitly
          named step must be numeric. }
        if StrToIntDef(P[i + 1], -1) < 0 then
          Fail('--step must be a number: --step <n>  (got: ' + P[i + 1] + ')');
        StepN := StrToIntDef(P[i + 1], 0);
        Inc(i);
      end
      else if (P[i] = '--from') and (i + 1 < P.Count) then
      begin
        FromN := StrToIntDef(P[i + 1], 0);
        Inc(i);
      end
      else if (P[i] = '--depth') and (i + 1 < P.Count) then
      begin
        DepthN := StrToIntDef(P[i + 1], 0);
        Inc(i);
      end
      else if (P[i] = '--eta') and (i + 1 < P.Count) then
      begin
        EtaS := P[i + 1];
        Inc(i);
      end
      else if (P[i] = '--team') or (P[i] = '--equipo') then
      begin
        if i + 1 < P.Count then
        begin
          TeamF := P[i + 1];
          Inc(i);
        end;
      end
      else if (P[i] = '--mine') or (P[i] = '--mio') then
        MineF := True
      else if P[i] = '--detail' then
        Detail := True
      else
      begin
        if Text <> '' then
          Text := Text + ' ';
        Text := Text + P[i];
      end;
      Inc(i);
    end;
  end;

begin
  AfterS := '';
  Text := '';
  EtaS := '';
  TeamF := '';
  StepN := 0;
  FromN := 0;
  DepthN := 0;
  Detail := False;
  MineF := False;
  { local help first: works offline, no hub round-trip }
  if (P.Count >= 2) and ((LowerCase(P[1]) = 'help') or (P[1] = '--help') or
     (P[1] = '-h') or (P[1] = '?') or (LowerCase(P[1]) = 'ayuda')) then
  begin
    Writeln('tiza wf - dependency-tree milestone plans');
    Writeln('  full manual: docs/workflows.md');
    Writeln('  web: https://github.com/garacil/pizarra/blob/main/docs/workflows.md');
    Writeln('  console: /help workflow');
    Writeln('  structure edits (step/insert/remove/set/clone/restore) = console');
    Writeln('  + the group admin only. Legacy command aliases remain accepted.');
    WfUsage;
    Exit;
  end;
  if (P.Count < 2) or (LowerCase(P[1]) = 'list') then
  begin
    Collect(2);
    if SendRequest(Cfg, BuildWfList(Cfg.Secret, Cfg.SelfId, MineF, TeamF),
      Reply) then
      PrintWfReply(Reply);
    Exit;
  end;
  Sub := LowerCase(P[1]);
  { Spanish aliases were only partially implemented: chat accepted nearly all
    of them while the CLI accepted only 'ver' and 'clonar'. Keep both command
    surfaces aligned so bilingual operators do not encounter inconsistent
    behavior. }
  if Sub = 'crear' then Sub := 'create'
  else if Sub = 'paso' then Sub := 'step'
  else if Sub = 'iniciar' then Sub := 'start'
  else if (Sub = 'hecho') or (Sub = 'hecha') then Sub := 'done'
  else if Sub = 'fallo' then Sub := 'error'
  else if (Sub = 'arreglado') or (Sub = 'arreglada') then Sub := 'fixed'
  else if Sub = 'verificar' then Sub := 'verify'
  else if (Sub = 'lista') or (Sub = 'listar') then Sub := 'list'
  else if Sub = 'tareas' then Sub := 'tasks'
  else if (Sub = 'insertar') or (Sub = 'meter') then Sub := 'insert'
  else if (Sub = 'quitar') or (Sub = 'borrar') then Sub := 'remove'
  else if (Sub = 'definir') or (Sub = 'cambiar') then Sub := 'set'
  else if (Sub = 'historial') or (Sub = 'hist') then Sub := 'history'
  else if Sub = 'deshacer' then Sub := 'undo'
  else if (Sub = 'proyecto') or (Sub = 'asignar') then Sub := 'project'
  else if (Sub = 'desasignar') or (Sub = 'quitar') then Sub := 'unproject'
  else if Sub = 'guardar' then Sub := 'save'
  else if Sub = 'restaurar' then Sub := 'restore'
  else if Sub = 'exportar' then Sub := 'export'
  else if Sub = 'abortar' then Sub := 'abort';

  if Sub = 'create' then
  begin
    if P.Count < 4 then
      Fail('usage: tiza wf create <name> <group>');
    if SendRequest(Cfg, BuildWfCreate(Cfg.Secret, Cfg.SelfId, P[2], P[3]),
      Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'step' then
  begin
    if P.Count < 5 then
      Fail('usage: tiza wf step <name> <team> <milestone...> [--after K[,K...]]');
    Name := P[2];
    Collect(4);
    if Text = '' then
      Fail('empty milestone title');
    if SendRequest(Cfg, BuildWfStep(Cfg.Secret, Cfg.SelfId, Name, P[3], Text,
      AfterS, EtaS), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'start' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf start <name>');
    if SendRequest(Cfg, BuildWfStart(Cfg.Secret, Cfg.SelfId, P[2]), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'done' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf done <name> [step|-] ["how tested..."]');
    i := 3;
    if (P.Count > 3) and (StrToIntDef(P[3], -1) >= 0) then
    begin
      StepN := StrToIntDef(P[3], 0);
      i := 4;
    end
    else if (P.Count > 3) and (P[3] = '-') then
      i := 4        { '-' explicitly means my only active step. }
    else if P.Count > 3 then
      { The grammar was ambiguous in a dangerous way: a nonnumeric token was
        treated as evidence while StepN remained 0, which means "my only active
        step". A TYPO ('onw' for '1') therefore closed the step silently. In
        strict mode the typo itself even counted as evidence because only a
        nonempty value was required. A token other than a number or '-' is now
        an error. }
      Fail('the step must be a number: tiza wf done ' + P[2] +
        ' <step> ["how tested..."]  |  to close your ONLY active step and ' +
        'give proof, use a dash: tiza wf done ' + P[2] + ' - "how tested"');
    Text := '';
    while i < P.Count do
    begin
      if Text <> '' then
        Text := Text + ' ';
      Text := Text + P[i];
      Inc(i);
    end;
    if SendRequest(Cfg, BuildWfDone(Cfg.Secret, Cfg.SelfId, P[2], StepN,
      Text), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'error' then
  begin
    if P.Count < 4 then
      Fail('usage: tiza wf error <name> <why...> [--step N]');
    Name := P[2];
    Collect(3);
    if SendRequest(Cfg, BuildWfError(Cfg.Secret, Cfg.SelfId, Name, Text,
      StepN), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'fixed' then
  begin
    if P.Count < 4 then
      Fail('usage: tiza wf fixed <name> <what fixed + how tested...>');
    Name := P[2];
    Collect(3);
    if SendRequest(Cfg, BuildWfFixed(Cfg.Secret, Cfg.SelfId, Name, Text),
      Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'verify' then
  begin
    if (P.Count < 4) or
       ((LowerCase(P[3]) <> 'ok') and (LowerCase(P[3]) <> 'fail')) then
      Fail('usage: tiza wf verify <name> ok|fail [why...]');
    Name := P[2];
    Collect(4);
    if SendRequest(Cfg, BuildWfVerify(Cfg.Secret, Cfg.SelfId, Name,
      LowerCase(P[3]) = 'ok', Text), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'delete' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf delete <name> [why...]');
    Name := P[2];
    Collect(3);   { the rest of the line is the WHY, recorded in the log/history }
    if SendRequest(Cfg, BuildWfDelete(Cfg.Secret, Cfg.SelfId, Name, Text), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'abort' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf abort <name> [why...]');
    Name := P[2];
    Collect(3);
    if SendRequest(Cfg, BuildWfAbort(Cfg.Secret, Cfg.SelfId, Name, Text),
      Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'insert' then
  begin
    if P.Count < 5 then
      Fail('usage: tiza wf insert <name> <team> <milestone...> --after K' +
        '   (dependents of K re-hang on the new step; 0 = before everything)');
    Name := P[2];
    Collect(4);
    if (Text = '') or (AfterS = '') then
      Fail('usage: tiza wf insert <name> <team> <milestone...> --after K');
    if SendRequest(Cfg, BuildWfInsert(Cfg.Secret, Cfg.SelfId, Name, P[3],
      Text, StrToIntDef(AfterS, -1), EtaS), Reply) then
      PrintWfReply(Reply);
  end
  else if (Sub = 'remove') or (Sub = 'rm') then
  begin
    if P.Count < 4 then
      Fail('usage: tiza wf remove <name> <step>');
    if SendRequest(Cfg, BuildWfRemove(Cfg.Secret, Cfg.SelfId, P[2],
      StrToIntDef(P[3], 0)), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'set' then
  begin
    { two forms: 'set <name> <step> <field> <value...>' (step-level) and
      'set <name> eta|strict <value...>' (workflow-level, step token absent) }
    if (P.Count >= 4) and (StrToIntDef(P[3], -1) < 0) then
    begin
      if P.Count < 5 then
        Fail('usage: tiza wf set <name> eta <dur>|off|factory  |  ' +
          'tiza wf set <name> strict on|off');
      Name := P[2];
      Text := '';
      for i := 4 to P.Count - 1 do
      begin
        if Text <> '' then
          Text := Text + ' ';
        Text := Text + P[i];
      end;
      if SendRequest(Cfg, BuildWfSet(Cfg.Secret, Cfg.SelfId, Name, 0, P[3],
        Text), Reply) then
        PrintWfReply(Reply);
      Exit;
    end;
    if P.Count < 6 then
      Fail('usage: tiza wf set <name> <step> team|milestone|after|eta <value...>' +
        '   (after: comma list of step ids, 0 = root; or wf-level: ' +
        'tiza wf set <name> eta|strict <value>)');
    Name := P[2];
    Text := '';
    for i := 5 to P.Count - 1 do
    begin
      if Text <> '' then
        Text := Text + ' ';
      Text := Text + P[i];
    end;
    Field := LowerCase(P[4]);
    if Field = 'milestone' then
      Field := 'hito';
    if SendRequest(Cfg, BuildWfSet(Cfg.Secret, Cfg.SelfId, Name,
      StrToIntDef(P[3], 0), Field, Text), Reply) then
      PrintWfReply(Reply);
  end
  else if (Sub = 'clone') or (Sub = 'clonar') then
  begin
    if P.Count < 4 then
      Fail('usage: tiza wf clone <src> <new> [group]');
    Text := '';
    if P.Count > 4 then
      Text := P[4];
    if SendRequest(Cfg, BuildWfClone(Cfg.Secret, Cfg.SelfId, P[2], P[3],
      Text), Reply) then
      PrintWfReply(Reply);
  end
  else if (Sub = 'tasks') or (Sub = 'tareas') then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf tasks <name>');
    if SendRequest(Cfg, BuildWfTasks(Cfg.Secret, Cfg.SelfId, P[2]), Reply) then
      PrintWfReply(Reply);
  end
  else if (Sub = 'show') or (Sub = 'ver') then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf show <name> [--from K] [--depth N] [--detail]');
    Name := P[2];
    Collect(3);
    if SendRequest(Cfg, BuildWfShow(Cfg.Secret, Cfg.SelfId, Name, FromN,
      DepthN, Detail), Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'export' then
    RunWfExport(Cfg, P)
  else if Sub = 'save' then
    RunWfSave(Cfg, P)
  else if Sub = 'restore' then
    RunWfRestore(Cfg, P)
  else if (Sub = 'history') or (Sub = 'hist') then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf history <name>');
    if SendRequest(Cfg, BuildWfHistory(Cfg.Secret, Cfg.SelfId, P[2]),
      Reply) then
      PrintWfReply(Reply);
  end
  else if Sub = 'undo' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza wf undo <name> [snap]   (no snap = one step back; ' +
        'a snap number from wf history = jump to that point)');
    StepN := 0;
    if P.Count > 3 then
    begin
      { Same rule as `wf done`: a typo must not become snapshot 0, the default
        undo target. }
      if StrToIntDef(P[3], -1) < 0 then
        Fail('the snapshot must be a number (see tiza wf history ' + P[2] +
          '): tiza wf undo ' + P[2] + ' [snap]');
      StepN := StrToIntDef(P[3], 0);
    end;
    if SendRequest(Cfg, BuildWfUndo(Cfg.Secret, Cfg.SelfId, P[2], StepN),
      Reply) then
      PrintWfReply(Reply);
  end
  else if P.Count >= 2 then
  begin
  { Bare 'tiza wf <name> [--from K] [--depth N] [--detail]' means show. A verb
    typo used to fall through here as a plan NAME, producing "unknown workflow:
    crea" and directing attention to the wrong problem. If a token resembles a
    known verb, report it as such. }
    Name := P[1];
    if IsWfVerbTypo(Name) then
      Fail('unknown workflow subcommand: ' + Name +
        ' (verbs: create step start done error fixed verify show tasks list ' +
        'insert remove set clone history undo save restore export)');
    Collect(2);
    if Text <> '' then
      Fail('unknown workflow subcommand: ' + Sub);
    if SendRequest(Cfg, BuildWfShow(Cfg.Secret, Cfg.SelfId, Name, FromN,
      DepthN, Detail), Reply) then
      PrintWfReply(Reply);
  end
  else
    Fail('unknown workflow subcommand: ' + Sub);
end;

procedure PrintProjects(const Reply: string);
var Obj, P: TJSONObject; Arr: TJSONArray; i: Integer; line: string;
begin
  Obj := ParseObj(Reply);
  if Obj = nil then Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then Fail('server: ' + Obj.Get('error', 'unknown'));
    Arr := Obj.Get('projects', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then begin Writeln('(no projects)'); Exit; end;
    line := '';
    for i := 0 to Arr.Count - 1 do
    begin
      P := TJSONObject(Arr.Items[i]);
      line := line + P.Get('name', '');
      if P.Get('boss', '') <> '' then line := line + '  (admin: ' + P.Get('boss', '') + ')';
      line := line + #10;
    end;
    { Frame returns the body UNCHANGED when output is not a terminal: the frame
      is for people, while parsers continue to see the original format. }
    Writeln(Frame('projects', TrimRight(line), 100));
  finally Obj.Free; end;
end;

{ ONE project's card: boss, who has it assigned, and the apps that build it
  with what each one does THERE. The role is printed next to its app because the
  functionality belongs to neither the project nor the app: it is the PAIR's. }
procedure PrintProjectCard(const Reply: string);
var
  Obj, J, A: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  Body, Line: string;
begin
  Obj := ParseObj(Reply);
  if Obj = nil then Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then Fail('server: ' + Obj.Get('error', 'unknown'));
    J := Obj.Get('project', TJSONObject(nil));
    if J = nil then Fail('no project in reply');
    Body := 'name:   ' + J.Get('name', '');
    if J.Get('boss', '') <> '' then
      Body := Body + #10 + 'admin:  ' + J.Get('boss', '');
    Arr := J.Get('teams', TJSONArray(nil));
    Line := '';
    if Arr <> nil then
      for i := 0 to Arr.Count - 1 do
        Line := Line + ' ' + Arr.Items[i].AsString;
    if Line <> '' then
      Body := Body + #10 + 'teams: ' + Line;
    Arr := J.Get('groups', TJSONArray(nil));
    Line := '';
    if Arr <> nil then
      for i := 0 to Arr.Count - 1 do
        Line := Line + ' @' + Arr.Items[i].AsString;
    if Line <> '' then
      Body := Body + #10 + 'groups:' + Line;
    Arr := J.Get('apps', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then
      Body := Body + #10 + 'apps:   (none)'
    else
    begin
      Body := Body + #10 + 'apps:';
      for i := 0 to Arr.Count - 1 do
      begin
        A := TJSONObject(Arr.Items[i]);
        Line := '  ' + A.Get('name', '');
        if A.Get('role', '') <> '' then
          Line := Line + ' - ' + A.Get('role', '');
        Body := Body + #10 + Line;
      end;
    end;
    Writeln(Frame('project ' + J.Get('name', ''), Body, 100));
  finally Obj.Free; end;
end;

{ tiza project boss|list|show }
procedure RunProjectCli(const Cfg: TTizaConfig; P: TStringList);
var
  Sub, Reply, Boss: string;
  Pos_: TStringList;
  i: Integer;

  { 'project' was PURELY POSITIONAL: a flag slipped in as one more argument, so
    'project boss planA --admin uno' created a project and made '--admin' its
    boss. Flags are read from the ORIGINAL list - Pos_ no longer has them - and
    the positional arguments are counted without them. }
  function Flag(const F: string): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 1 to P.Count - 2 do
      if SameText(P[k], F) then
        Exit(P[k + 1]);
  end;

begin
  Pos_ := TStringList.Create;
  try
    i := 0;
    while i < P.Count do
    begin
      if (Length(P[i]) > 2) and (Copy(P[i], 1, 2) = '--') then
        Inc(i)   { the flag is skipped WITH its value }
      else
        Pos_.Add(P[i]);
      Inc(i);
    end;
    { a bare 'tiza project' / 'tiza projects' lists }
    if (Pos_.Count < 2) or (LowerCase(Pos_[1]) = 'list') then
    begin
      if SendRequest(Cfg, BuildProjectList(Cfg.Secret, Cfg.SelfId), Reply) then
        PrintProjects(Reply);
      Exit;
    end;
    Sub := LowerCase(Pos_[1]);
    if (Sub = 'boss') or (Sub = 'admin') then
    begin
      if Pos_.Count < 3 then
        Fail('usage: tiza project boss <name> <team>');
      { the team may come positionally or by flag; with neither, the boss
        would be CLEARED silently, so one is required }
      Boss := '';
      if Pos_.Count >= 4 then
        Boss := Pos_[3];
      if Boss = '' then
        Boss := Flag('--boss');
      if Boss = '' then
        Boss := Flag('--admin');
      if Boss = '' then
        Fail('usage: tiza project boss <name> <team>   (or: --boss <team>)');
      if SendRequest(Cfg, BuildProjectBoss(Cfg.Secret, Cfg.SelfId, Pos_[2],
        Boss), Reply) then PrintProjects(Reply);
    end
    else if (Sub = 'remove') or (Sub = 'delete') then
    begin
      if Pos_.Count < 3 then Fail('usage: tiza project remove <name>');
      if SendRequest(Cfg, BuildProjectRemove(Cfg.Secret, Cfg.SelfId, Pos_[2]),
        Reply) then PrintProjects(Reply);
    end
    else if (Sub = 'show') or (Sub = 'ver') or (Sub = 'ficha') then
    begin
      if Pos_.Count < 3 then Fail('usage: tiza project show <name>');
      if SendRequest(Cfg, BuildProjectShow(Cfg.Secret, Cfg.SelfId, Pos_[2]),
        Reply) then PrintProjectCard(Reply);
    end
    else
      { an unknown subcommand must NOT fall through silently: there is nothing
        to fall back to here - 'project <name>' does not exist - so it is named }
      Fail('unknown project subcommand: ' + Sub);
  finally
    Pos_.Free;
  end;
end;

procedure PrintHeader(const Reply: string);
var
  Obj, H: TJSONObject;
  function OnOff(const K: string): string;
  begin if H.Get(K, False) then Result := 'on' else Result := 'off'; end;
begin
  Obj := ParseObj(Reply);
  if Obj = nil then Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then Fail('server: ' + Obj.Get('error', 'unknown'));
    H := Obj.Get('header', TJSONObject(nil));
    if H = nil then Fail('no header config in reply');
    Writeln(Frame('delivery header',
      'delivery header: ' + H.Get('mode', '?') +
      '   (short = compact default | full = legacy long)'#10 +
      Format('  style=%s  orders=%s  tasks=%s  teams=%s  group=%s'#10,
        [OnOff('style'), OnOff('orders'), OnOff('tasks'), OnOff('teams'),
         H.Get('group', '?')]) +
      Format('  project=%s  subs=%s  shared=%s  workflow=%s  manual=%s'#10,
        [OnOff('project'), OnOff('subs'), OnOff('shared'), OnOff('workflow'),
         H.Get('manual', '?')]) +
      '  change: tiza header set <key> <value>  ' +
      '(mode short|full; toggles on|off; group own|off; manual first|off|always)',
      110));
  finally
    Obj.Free;
  end;
end;

{ tiza header [show|list] | set <key> <value> | note <text...> | short | full }
procedure RunHeaderCli(const Cfg: TTizaConfig; P: TStringList);
var Sub, Reply, Note: string; i: Integer;
begin
  if (P.Count < 2) or (LowerCase(P[1]) = 'list') or (LowerCase(P[1]) = 'show') then
  begin
    if SendRequest(Cfg, BuildHeaderList(Cfg.Secret, Cfg.SelfId), Reply) then
      PrintHeader(Reply);
    Exit;
  end;
  Sub := LowerCase(P[1]);
  if (Sub = 'short') or (Sub = 'full') then    { shortcut for 'set mode <x>' }
  begin
    if SendRequest(Cfg, BuildHeaderSet(Cfg.Secret, Cfg.SelfId, 'mode', Sub), Reply) then
      PrintHeader(Reply);
    Exit;
  end;
  if Sub = 'set' then
  begin
    if P.Count < 4 then Fail('usage: tiza header set <key> <value>');
    if SendRequest(Cfg, BuildHeaderSet(Cfg.Secret, Cfg.SelfId, P[2], P[3]), Reply) then
      PrintHeader(Reply);
    Exit;
  end;
  if (Sub = 'note') or (Sub = 'rule') then
  begin
    { a GLOBAL standing rule shown in EVERY delivery header; the rest of the line
      is the text (naming none clears it) }
    Note := '';
    for i := 2 to P.Count - 1 do
    begin
      if Note <> '' then Note := Note + ' ';
      Note := Note + P[i];
    end;
    if SendRequest(Cfg, BuildHeaderNote(Cfg.Secret, Cfg.SelfId, Note), Reply) then
      PrintHeader(Reply);
    Exit;
  end;
  Fail('unknown header subcommand: ' + Sub +
    ' (show | set <key> <value> | note <text...> | short | full)');
end;

{ Ask the hub for the shared root and check Dest is a team (or 'console'). }
function SharedRootFor(const Cfg: TTizaConfig; const Dest: string;
  out Root, CanonDest: string): Boolean;
var
  Reply: string;
  Obj, T: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  Result := False;
  Root := '';
  CanonDest := '';
  if not SendRequest(Cfg, BuildTeams(Cfg.Secret, Cfg.SelfId), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    Root := Obj.Get('shared_dir', '');
    if Root = '' then
    begin
      Fail('shared exchange not configured on the hub ([shared] dir)');
      Exit;
    end;
    if SameText(Dest, 'console') then
    begin
      CanonDest := 'console';
      Exit(True);
    end;
    Arr := Obj.Get('teams', TJSONArray(nil));
    if Arr <> nil then
      for i := 0 to Arr.Count - 1 do
      begin
        T := TJSONObject(Arr.Items[i]);
        if SameText(T.Get('name', ''), Dest) or
           (T.Get('id', 0) = StrToIntDef(Dest, -1)) then
        begin
          CanonDest := T.Get('name', '');
          Exit(True);
        end;
      end;
    Fail('unknown team: ' + Dest);
  finally
    Obj.Free;
  end;
end;

{ tiza share <team|console> <file> [note...] }
{ Upload a file's bytes over the bus; the hub writes them into the shared dir.
  For hosts that cannot mount the shared NFS (where 'share' is unavailable).
    tiza put <file>              -> your own shared dir (no notify)
    tiza put <dest> <file> [note]-> dest's shared dir + notify dest of the path }
procedure RunPutCli(const Cfg: TTizaConfig; P: TStringList);
var
  Dest, FilePath, Note, Name, Data, Reply, Path, Msg, NErr, Content: string;
  i: Integer;
  FS: TFileStream;
  UpId, WholeSha, Piece_: string;
  Sent, Piece: Int64;
  IsLast: Boolean;
  Obj: TJSONObject;
  Notify: Boolean;
begin
  if P.Count < 2 then
    Fail('usage: tiza put [<dest>] <file> [note...]  (no <dest> = your own shared dir)');
  if P.Count = 2 then
  begin
    Dest := Cfg.SelfId;   { own dir }
    FilePath := P[1];
    Note := '';
    Notify := False;
  end
  else
  begin
    Dest := P[1];
    FilePath := P[2];
    Note := '';
    for i := 3 to P.Count - 1 do
    begin
      if Note <> '' then Note := Note + ' ';
      Note := Note + P[i];
    end;
    Notify := True;
  end;
  if not FileExists(FilePath) then
    Fail('file not found: ' + FilePath);
  Name := ExtractFileName(FilePath);
  NErr := ShareNameError(Name);
  if NErr <> '' then
    Fail(NErr);
  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Content, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Content[1], FS.Size);
  finally
    FS.Free;
  end;
  if Content = '' then
    Fail('empty file');
  if Length(Content) > SHARE_MAX_BYTES then
    Fail(Format('file too large (max %d MB)', [SHARE_MAX_BYTES div 1048576]));
  { CHUNKED TRANSFER. The entire file previously traveled in ONE bus line, so
    the real ceiling was about 750 KB despite the advertised 10 MB limit. Each
    chunk now carries its offset, and the last carries the WHOLE file's SHA-256.
    If the hub assembled anything other than what left here, discard it rather
    than publish it. A partial file with a valid-looking name is worse than no
    file. The identifier belongs to the UPLOAD, not the file, so concurrent
    uploads of the same name cannot share a temporary file. }
  UpId := Sha256OfString(Format('%s|%s|%d|%d',
    [Cfg.SelfId, Name, Length(Content), GetTickCount64]));
  UpId := Copy(UpId, 1, 32);
  WholeSha := LowerCase(Sha256OfString(Content));
  Sent := 0;
  Path := '';
  while Sent < Length(Content) do
  begin
    Piece := Length(Content) - Sent;
    if Piece > SHARE_CHUNK_MAX then
      Piece := SHARE_CHUNK_MAX;
    Data := EncodeStringBase64(Copy(Content, Sent + 1, Piece));
    IsLast := (Sent + Piece) >= Length(Content);
    if not SendRequest(Cfg, BuildPutChunk(Cfg.Secret, Cfg.SelfId, Dest, Name,
         UpId, Data, Sent, IsLast, WholeSha), Reply) then
      Exit;   { SendRequest already reported the transport failure. }
    Obj := ParseObj(Reply);
    if Obj = nil then
      Fail('bad reply: ' + Reply);
    try
      if not Obj.Get('ok', False) then
        Fail(Obj.Get('error', 'put failed'));
      if IsLast then
        Path := Obj.Get('path', '');
    finally
      Obj.Free;
    end;
    Sent := Sent + Piece;
    if (not IsLast) and (Length(Content) > SHARE_CHUNK_MAX) then
      Write(Format(#13'  subiendo %d/%d KB...',
        [Sent div 1024, Length(Content) div 1024]));
  end;
  if Length(Content) > SHARE_CHUNK_MAX then
    Writeln;
  Writeln('uploaded to ', Dest, ': ', Path);
  if Notify then
  begin
    Msg := 'FILE SHARED: ' + Path;
    if Note <> '' then
      Msg := Msg + ' - ' + Note;
    if SendRequest(Cfg, BuildSend(Cfg.Secret, Cfg.SelfId, Dest, Msg), Reply) then
      Writeln('notified ', Dest);
  end;
end;

{ Download a file from the shared dir over the bus (the inverse of put): the hub
  reads it and returns the bytes; we write them locally. For NFS-less hosts to
  read what teammates deposited.  tiza get <shared-path> [local-file] }
procedure RunGetCli(const Cfg: TTizaConfig; P: TStringList);
var
  Path, LocalDest, Reply, Name, Data, Bytes: string;
  Obj: TJSONObject;
  FS: TFileStream;
  Off, Total: Int64;
  GotSha, MineSha, Tmp: string;
  Done_: Boolean;
begin
  if P.Count < 2 then
    Fail('usage: tiza get <shared-path> [local-file]');
  Path := P[1];
  { CHUNKED TRANSFER into a TEMPORARY file beside the destination. An interrupted
    download must not leave a partial file under the final name, where it would
    be indistinguishable from a complete one. At completion, compare the hub's
    declared WHOLE-file SHA-256 with the locally assembled file. A file changed
    during download or a missing chunk causes a mismatch and is discarded. }
  Off := 0;
  Total := -1;
  Name := '';
  GotSha := '';
  LocalDest := '';
  Tmp := '';
  FS := nil;
  try
    repeat
      if not SendRequest(Cfg, BuildGetChunk(Cfg.Secret, Cfg.SelfId, Path,
           Off, SHARE_CHUNK_MAX), Reply) then
        Exit;   { SendRequest already reported the transport failure. }
      Obj := ParseObj(Reply);
      if Obj = nil then
        Fail('bad reply: ' + Reply);
      try
        if not Obj.Get('ok', False) then
          Fail(Obj.Get('error', 'get failed'));
        if Name = '' then
          Name := Obj.Get('name', '');
        Data := Obj.Get('data', '');
        if Total < 0 then
          Total := Obj.Get('size', Int64(0));
        Done_ := Obj.Get('eof', True);
        if Done_ then
          GotSha := LowerCase(Trim(Obj.Get('sha256', '')));
      finally
        Obj.Free;
      end;
      if FS = nil then
      begin
        if P.Count >= 3 then
          LocalDest := P[2]
        else
          LocalDest := Name;
        if LocalDest = '' then
          LocalDest := 'downloaded.bin';
        Tmp := LocalDest + '.part';
        FS := TFileStream.Create(Tmp, fmCreate);
      end;
      Bytes := DecodeStringBase64(Data);
      if Bytes <> '' then
        FS.WriteBuffer(Bytes[1], Length(Bytes));
      Off := Off + Length(Bytes);
      if (Total > SHARE_CHUNK_MAX) and (not Done_) then
        Write(Format(#13'  bajando %d/%d KB...', [Off div 1024, Total div 1024]));
      { A hub returning neither EOF nor bytes would otherwise hang the loop. }
      if (not Done_) and (Bytes = '') then
        Fail('the hub sent an empty chunk without closing the download');
    until Done_;
  finally
    if FS <> nil then
      FS.Free;
  end;
  if Total > SHARE_CHUNK_MAX then
    Writeln;
  { NO DIGEST, NO FILE. Checking the digest only when present was precisely the
    vulnerability: an unsigned completion (from a hub unable to read the file,
    or a forged response) was renamed into place and reported as valid. Never
    accept what cannot be verified. }
  if GotSha = '' then
  begin
    DeleteFile(Tmp);
    Fail('the hub closed the download without signing it: discarded (nothing ' +
         'was written)');
  end;
  if not Sha256OfFile(Tmp, MineSha) then
  begin
    DeleteFile(Tmp);
    Fail('cannot verify what was downloaded');
  end;
  if LowerCase(MineSha) <> GotSha then
  begin
    DeleteFile(Tmp);
    Fail('the download does not match the file on the hub (it changed while ' +
         'downloading, or a chunk was lost): discarded');
  end;
  if not RenameFile(Tmp, LocalDest) then
  begin
    DeleteFile(Tmp);
    Fail('cannot write ' + LocalDest);
  end;
  Writeln('downloaded: ', LocalDest, ' (', Off, ' bytes)');
end;

{ Print a shared-dir file's CONTENT to stdout over the bus — get without the
  temp file. Reuses the get request; status/errors go to stderr (via Fail), so
  `tiza cat X`, `tiza cat X > local` and `tiza cat X | grep` all stay clean.
    tiza cat <shared-path> }
procedure RunCatCli(const Cfg: TTizaConfig; P: TStringList);
var
  Path, Reply, Data, Bytes: string;
  Obj: TJSONObject;
begin
  if P.Count < 2 then
    Fail('usage: tiza cat <shared-path>');
  Path := P[1];
  if not SendRequest(Cfg, BuildGet(Cfg.Secret, Cfg.SelfId, Path), Reply) then
    Exit;   { SendRequest already reported the transport error }
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply: ' + Reply);
  try
    if not Obj.Get('ok', False) then
      Fail(Obj.Get('error', 'cat failed'));
    Data := Obj.Get('data', '');
  finally
    Obj.Free;
  end;
  Bytes := DecodeStringBase64(Data);
  if Bytes <> '' then
    Write(Bytes);      { raw content to stdout, byte-exact, no added newline }
  Flush(Output);
end;

procedure RunShareCli(const Cfg: TTizaConfig; P: TStringList);
var
  Root, Dest, Note, FinalPath, Err, Reply, Msg: string;
  i: Integer;
begin
  if P.Count < 3 then
    Fail('usage: tiza share <team|console> <file> [note...]');
  if not SharedRootFor(Cfg, P[1], Root, Dest) then
    Exit;
  Note := '';
  for i := 3 to P.Count - 1 do
  begin
    if Note <> '' then
      Note := Note + ' ';
    Note := Note + P[i];
  end;
  if not ShareCopy(P[2], Root + '/' + LowerCase(Dest), FinalPath, Err) then
    Fail(Err);
  { the copy is on disk: NOW tell the recipient where it is }
  Msg := 'FILE SHARED: ' + FinalPath;
  if Note <> '' then
    Msg := Msg + ' - ' + Note;
  if SendRequest(Cfg, BuildSend(Cfg.Secret, Cfg.SelfId, Dest, Msg), Reply) then
    Writeln('shared to ', Dest, ': ', FinalPath);
end;

{ tiza files [team|console] — local NFS listing, newest last. }
procedure RunFilesCli(const Cfg: TTizaConfig; P: TStringList);
var
  Root, Want, Dest, Dir, Acc: string;
  Info: TSearchRec;
  n: Integer;
  Total: Int64;
begin
  if P.Count >= 2 then
    Want := P[1]
  else
    Want := Cfg.SelfId;
  { Want and Dest must be DIFFERENT variables: an out-string parameter is
    cleared on entry, so aliasing it with the input erases the input }
  if not SharedRootFor(Cfg, Want, Root, Dest) then
    Exit;
  Dir := Root + '/' + LowerCase(Dest);
  if not DirectoryExists(Dir) then
    Fail('shared directory does not exist yet: ' + Dir);
  n := 0;
  Total := 0;
  Acc := '';
  if FindFirst(Dir + '/*', faAnyFile, Info) = 0 then
  begin
    repeat
      { Temporary files from an active copy are not team files; exposing them
        would invite someone to read an incomplete copy. }
      if ((Info.Attr and faDirectory) = 0) and
         (Copy(Info.Name, 1, 9) <> '.pzshare-') then
      begin
        Inc(n);
        Inc(Total, Info.Size);
        Acc := Acc + Format('%10d  %s  %s'#10,
          [Info.Size, FormatDateTime('yyyy-mm-dd hh:nn', Info.TimeStamp),
           Info.Name]);
      end;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  Acc := Acc + Format('shared/%s: %d file(s), %.1f MB',
    [Dest, n, Total / 1048576.0]);
  Writeln(Frame('files of ' + Dest, TrimRight(Acc), 100));
end;

{ tiza team add|remove|set|list|show — runtime team management from any host. }
procedure RunTeamCli(const Cfg: TTizaConfig; P: TStringList);
var
  Sub, Name, Spec, Parent, Host, Session, Launch, PromptV: string;
  Field, Value, Reply, W: string;
  i: Integer;
begin
  { a bare 'tiza team' / 'tiza teams' lists (the tree), like the chat /teams }
  if P.Count < 2 then
  begin
    RunTreeCli(Cfg);
    Exit;
  end;
  Sub := LowerCase(P[1]);

  if Sub = 'add' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza team add <name> <speciality...> [flags]');
    Name := P[2];
    Spec := '';
    Parent := '';
    Host := '';
    Session := '';
    Launch := '';
    PromptV := '';
    i := 3;
    while i < P.Count do
    begin
      W := P[i];
      if (W = '--parent') and (i + 1 < P.Count) then
      begin
        Parent := P[i + 1];
        Inc(i);
      end
      else if (W = '--remote') and (i + 1 < P.Count) then
      begin
        Host := P[i + 1];
        Inc(i);
      end
      else if W = '--local' then
        { default }
      else if (W = '--session') and (i + 1 < P.Count) then
      begin
        Session := P[i + 1];
        Inc(i);
      end
      else if (W = '--launch') and (i + 1 < P.Count) then
      begin
        Launch := P[i + 1];
        Inc(i);
      end
      else if W = '--prompt' then
      begin
        { take the rest of the prompt words, but STOP at the next flag so
          '--prompt "text" --remote host' still parses --remote correctly }
        while (i + 1 < P.Count) and (Copy(P[i + 1], 1, 2) <> '--') do
        begin
          if PromptV <> '' then
            PromptV := PromptV + ' ';
          PromptV := PromptV + P[i + 1];
          Inc(i);
        end;
      end
      else
      begin
        if Spec <> '' then
          Spec := Spec + ' ';
        Spec := Spec + W;
      end;
      Inc(i);
    end;
    if SendRequest(Cfg, BuildTeamAdd(Cfg.Secret, Cfg.SelfId, Name, Spec,
      Parent, Host, Session, Launch, PromptV), Reply) then
      PrintTeamCard(Reply);
  end
  else if Sub = 'remove' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza team remove <name>');
    if SendRequest(Cfg, BuildTeamRemove(Cfg.Secret, Cfg.SelfId, P[2]), Reply) then
      PrintTeamCard(Reply);
  end
  else if Sub = 'set' then
  begin
    if P.Count < 5 then
      Fail('usage: tiza team set <name> <field> <value...>');
    Name := P[2];
    Field := LowerCase(P[3]);
    Value := '';
    if (Field = 'secret') and (P[4] = '--file') then
    begin
      if P.Count <> 6 then
        Fail('usage: tiza team set <name> secret --file <path|->');
      Value := ReadMsgFile(P[5]);
    end
    else
      for i := 4 to P.Count - 1 do
      begin
        if Value <> '' then
          Value := Value + ' ';
        Value := Value + P[i];
      end;
    if SendRequest(Cfg, BuildTeamSet(Cfg.Secret, Cfg.SelfId, Name, Field,
      Value), Reply) then
      PrintTeamCard(Reply);
  end
  else if Sub = 'list' then
    RunTreeCli(Cfg)
  else if Sub = 'show' then
  begin
    if P.Count < 3 then
      Fail('usage: tiza team show <name> [--detail]');
    if SendRequest(Cfg, BuildTeamShow(Cfg.Secret, Cfg.SelfId, P[2]), Reply) then
      PrintTeamCard(Reply,
        HasFlag(P, '--detail') or HasFlag(P, '--detalle'));
  end
  else
    Fail('unknown team subcommand: ' + Sub);
end;

{ Render the team hierarchy as an indented tree. }
procedure RunTreeCli(const Cfg: TTizaConfig);
var
  Reply, Acc: string;
  Obj, T: TJSONObject;
  Arr: TJSONArray;
  i: Integer;

  procedure PrintNode(const Name: string; Depth: Integer);
  var
    j: Integer;
    N: TJSONObject;
  begin
    for j := 0 to Arr.Count - 1 do
    begin
      N := TJSONObject(Arr.Items[j]);
      if SameText(N.Get('name', ''), Name) then
        Acc := Acc + Format('%s%s (id=%d) - %s  [%d open]'#10,
          [StringOfChar(' ', Depth * 2), N.Get('name', ''), N.Get('id', 0),
           N.Get('speciality', ''), N.Get('open_tasks', 0)]);
    end;
    for j := 0 to Arr.Count - 1 do
    begin
      N := TJSONObject(Arr.Items[j]);
      if SameText(N.Get('parent', ''), Name) then
        PrintNode(N.Get('name', ''), Depth + 1);
    end;
  end;

begin
  if not SendRequest(Cfg, BuildTeams(Cfg.Secret, Cfg.SelfId), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    Arr := Obj.Get('teams', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      Writeln('(no teams)');
      Exit;
    end;
    Acc := '';
    for i := 0 to Arr.Count - 1 do
    begin
      T := TJSONObject(Arr.Items[i]);
      if T.Get('parent', '') = '' then
        PrintNode(T.Get('name', ''), 1);
    end;
    if Pretty then
      Writeln(Frame('team hierarchy', TrimRight(Acc), 118))
    else
    begin
      Writeln('team hierarchy:');
      Write(Acc);
    end;
  finally
    Obj.Free;
  end;
end;


{ tiza app — the application registry: who owns which program, where it lives
  and what it does. Reads like team/group management on purpose. }
procedure RunAppCli(const Cfg: TTizaConfig; P: TStringList);
var
  Reply, Sub, Name, Op, Team, Repo, PathS, Purpose, Detail, Field, Value: string;
  DocText, Proj: string;
  SnapN, AtN: Integer;
  WantWrite: Boolean;
  Obj, A, AO, PO: TJSONObject;
  Rows, PArr: TJSONArray;
  TRs: TRows;
  CK, CV: TCells;
  Lines: TStringList;
  i, k: Integer;

  function Flag(const F: string): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 2 to P.Count - 2 do
      if SameText(P[k], F) then
        Exit(P[k + 1]);
  end;

begin
  Sub := '';
  if P.Count > 1 then
    Sub := LowerCase(P[1]);
  { Spanish verbs, like every other command surface }
  if (Sub = 'alta') or (Sub = 'crear') then Sub := 'add'
  else if (Sub = 'quitar') or (Sub = 'borrar') then Sub := 'remove'
  else if (Sub = 'definir') or (Sub = 'cambiar') then Sub := 'set'
  else if (Sub = 'lista') or (Sub = 'listar') then Sub := 'list'
  else if (Sub = 'ver') or (Sub = 'ficha') then Sub := 'show'
  else if (Sub = 'manual') or (Sub = 'doc') then Sub := 'doc'
  else if (Sub = 'historial') or (Sub = 'hist') then Sub := 'history'
  else if (Sub = 'deshacer') then Sub := 'undo'
  else if (Sub = 'proyecto') or (Sub = 'asignar') then Sub := 'project'
  else if (Sub = 'desasignar') or (Sub = 'quitar') then Sub := 'unproject';
  if Sub = '' then
    Sub := 'list';
  { bare `tiza app <name>` = show that app (same as the console) }
  { A subverb missing HERE does not raise an error: it is interpreted as an app
    NAME and converted to 'show', so the command targets a nonexistent app.
    This documents the failure mode of adding a verb above but not here. }
  if (Sub <> 'list') and (Sub <> 'add') and (Sub <> 'set') and
     (Sub <> 'remove') and (Sub <> 'show') and (Sub <> 'doc') and
     (Sub <> 'history') and (Sub <> 'undo') and
     (Sub <> 'project') and (Sub <> 'unproject') then
  begin
    P.Insert(1, 'show');
    Sub := 'show';
  end;

  Name := '';
  if P.Count > 2 then
    Name := P[2];
  Op := Sub;
  Team := Flag('--team'); if Team = '' then Team := Flag('--equipo');
  Repo := Flag('--repo');
  PathS := Flag('--path'); if PathS = '' then PathS := Flag('--ruta');
  Purpose := Flag('--purpose'); if Purpose = '' then Purpose := Flag('--utilidad');
  Detail := Flag('--detail'); if Detail = '' then Detail := Flag('--detalle');
  Field := '';
  Value := '';
  if (Sub = 'set') then
  begin
    if P.Count < 5 then
      Fail('usage: tiza app set <name> team|repo|path|purpose|detail <value...>');
    Field := LowerCase(P[3]);
    Value := '';
    for i := 4 to P.Count - 1 do
    begin
      if Value <> '' then
        Value := Value + ' ';
      Value := Value + P[i];
    end;
  end;
  if (Sub = 'list') and (Name = '') and (P.Count > 2) then
    Name := P[2];

  { app doc <name>            -> print the manual (any team may read)
    app doc <name> --file F    -> replace it from a file (owner/console)
    app doc <name> "text..."   -> replace it inline }
  DocText := '';
  if Sub = 'doc' then
  begin
    if Name = '' then
      Fail('usage: tiza app doc <name> [--file F | "text"]');
    WantWrite := False;
    for i := 3 to P.Count - 1 do
      if SameText(P[i], '--file') then
      begin
        WantWrite := True;
        if i = P.Count - 1 then
          Fail('--file needs a path: tiza app doc <name> --file <file>');
        if not FileExists(P[i + 1]) then
          Fail('no such file: ' + P[i + 1]);
        Lines := TStringList.Create;
        try
          Lines.LoadFromFile(P[i + 1]);
          DocText := Lines.Text;
        finally
          Lines.Free;
        end;
        if Trim(DocText) = '' then
          Fail('that file is empty - refusing to erase the manual');
      end;
    if not WantWrite then
      for i := 3 to P.Count - 1 do
      begin
        if DocText <> '' then
          DocText := DocText + ' ';
        DocText := DocText + P[i];
      end;
    if DocText <> '' then
      Op := 'setdoc';
  end;
  { snap: history point for undo, or manual version for doc --at. }
  SnapN := 0;
  AtN := 0;
  if Sub = 'undo' then
  begin
    if P.Count > 3 then
      SnapN := StrToIntDef(P[3], 0);
    if SnapN <= 0 then
      Fail('usage: tiza app undo <name> <snap>   (see: tiza app history <name>)');
  end;
  if (Sub = 'doc') and (Flag('--at') <> '') then
  begin
    AtN := StrToIntDef(Flag('--at'), 0);
    DocText := '';
    Op := 'doc';
  end;
  { For 'app project <app> <project>', P[2] is the APP and P[3] the project.
    Using P[2] for both asked to assign the app to a project with its own name.
    Both fields remain at the END of BuildAppOp with defaults because all calls
    pass its 11 parameters POSITIONALLY. }
  Proj := '';
  if ((Op = 'project') or (Op = 'unproject')) and (P.Count > 3) then
    Proj := P[3];
  if not SendRequest(Cfg, BuildAppOp(Cfg.Secret, Cfg.SelfId, Op, Name, Team,
    Repo, PathS, Purpose, Detail, Field, Value, DocText, SnapN, AtN,
    Proj, Flag('--role')),
    Reply) then
    Fail('no reply from pizarra');
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('bad reply from pizarra');
  try
    if not Obj.Get('ok', False) then
      Fail('server: ' + Obj.Get('error', 'unknown'));
    Rows := Obj.Get('rows', TJSONArray(nil));
    if Rows <> nil then
    begin
      if Rows.Count = 0 then
      begin
        Writeln('(no applications registered yet - tiza app add <name> --team <team>)');
        Exit;
      end;
      SetLength(TRs, Rows.Count);
      for i := 0 to Rows.Count - 1 do
      begin
        AO := TJSONObject(Rows.Items[i]);
        SetLength(TRs[i], 4);
        TRs[i][0] := AO.Get('name', '');
        TRs[i][1] := AO.Get('team', '');
        TRs[i][2] := BoolToStr(AO.Get('hasdoc', False), 'yes', '-');
        TRs[i][3] := AO.Get('purpose', '');
      end;
      Writeln(Table(TCells.Create('APP', 'OWNER', 'MANUAL',
        'PURPOSE'), TRs, 118));
      Exit;
    end;
    if Obj.Get('tree', '') <> '' then
    begin
      Writeln(Frame('', Vis(Obj.Get('tree', '')), 118));
      Exit;
    end;
    A := Obj.Get('app', TJSONObject(nil));
    if A = nil then
    begin
      Writeln('ok');
      Exit;
    end;
    CK := TCells.Create('team', 'purpose', 'projects', 'repo', 'path',
      'detail', 'manual');
    SetLength(CV, 7);
    CV[0] := BoolToStr(A.Get('team', '') = '', '(unassigned)',
      A.Get('team', ''));
    CV[1] := A.Get('purpose', '');
    { WHICH PROJECTS it takes part in, and what it does in each. On ONE line
      with ';' because the frameless card writes each field on its own row: a
      value with newlines would break the table exactly when output is piped. }
    PArr := A.Get('projects', TJSONArray(nil));
    CV[2] := '';
    if PArr <> nil then
      for k := 0 to PArr.Count - 1 do
      begin
        PO := TJSONObject(PArr.Items[k]);
        if CV[2] <> '' then
          CV[2] := CV[2] + '; ';
        CV[2] := CV[2] + PO.Get('name', '');
        if PO.Get('role', '') <> '' then
          CV[2] := CV[2] + ' (' + PO.Get('role', '') + ')';
      end;
    if CV[2] = '' then
      CV[2] := '(none - tiza app project ' + A.Get('name', '') +
        ' <project> --role "<what it does there>")';
    CV[3] := A.Get('repo', '');
    CV[4] := A.Get('path', '');
    CV[5] := A.Get('detail', '');
    if A.Get('hasdoc', False) then
      CV[6] := 'tiza app doc ' + A.Get('name', '')
    else
      CV[6] := '(none yet - tiza app doc ' + A.Get('name', '') +
        ' --file <file>)';
    Writeln(Card('app ' + A.Get('name', ''), CK, CV, 118));
  finally
    Obj.Free;
  end;
end;


{ Does anything answer on this port? Restore refuses to proceed while the hub
  is live because replacing databases beneath a process that holds them open
  corrupts them. }
function PortAnswers(const Host: string; Port: Integer): Boolean;
var
  C: TInetSocket;
begin
  Result := False;
  try
    C := TInetSocket.Create(Host, Port);
    try
      Result := True;
    finally
      C.Free;
    end;
  except
    Result := False;
  end;
end;

{ The HUB configuration (not the client configuration): restore runs on the hub
  host while the hub is stopped. Return '' when it cannot be found. }
function LocalConfPath: string;
begin
  Result := ResolveConfig('', 'PIZARRA_CONF', 'pizarra.conf');
  if (Result <> '') and (not FileExists(Result)) then
    Result := '';
end;

{ Address of the hub that OWNS this store, taken from ITS configuration. The
  client address is not valid here: `tiza restore` changes the LOCAL store, but
  used to test the hub named by tiza.conf. If that file pointed to an old port,
  another host, or localhost while the hub listened on a LAN address, the check
  reported "stopped" while the local hub remained live, and databases were
  replaced beneath the process holding them open. }
procedure HubAddrOf(const ConfPath: string; out Host: string; out Port: Integer);
var
  HubCfg: TPizarraConfig;
begin
  Host := '127.0.0.1';
  Port := 7010;
  if (ConfPath = '') or (not FileExists(ConfPath)) then
    Exit;
  try
    { Use the hub's real loader. In FPC 3.2.2 ReadInteger does not strip inline
      comments, while LoadPizarraConfig/IniInt does; probing a default port in
      that case could replace databases under the still-running real hub. }
    HubCfg := LoadPizarraConfig(ConfPath);
    Host := HubCfg.Listen;
    Port := HubCfg.Port;
  except
    on E: Exception do
      Fail('cannot parse hub config for the live-process check: ' + E.Message);
  end;
  if (Host = '') or (Host = '0.0.0.0') or (Host = '::') then
    Host := '127.0.0.1';
end;

{ Read the secret declared by a configuration so replacement can be warned. }
function SecretOf(const ConfPath: string): string;
var
  HubCfg: TPizarraConfig;
begin
  Result := '';
  if (ConfPath = '') or (not FileExists(ConfPath)) then
    Exit;
  try
    { Match startup byte-for-byte and reuse its descriptor-pinned parser. A
      quoted secret may intentionally contain leading/trailing spaces; Trim
      would compare a different credential. }
    HubCfg := LoadPizarraConfig(ConfPath);
    Result := HubCfg.Secret;
  except
    on E: Exception do
      Fail('cannot parse hub config ' + ConfPath + ': ' + E.Message);
  end;
end;

{ Cheap SQLite signature precheck before loading libsqlite3 for full integrity
  and foreign-key verification. }
function IsSqliteFile(const Path: string): Boolean;
var
  F: TFileStream;
  Buf: array[0..15] of Char;
begin
  Result := False;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    if F.Size < 512 then
      Exit;
    if F.Read(Buf, 16) <> 16 then
      Exit;
    Result := (Copy(Buf, 1, 15) = 'SQLite format 3') and (Buf[15] = #0);
  finally
    F.Free;
  end;
end;

function FileSizeByName(const Path: string): Int64;
var
  F: TFileStream;
begin
  Result := -1;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := F.Size;
    finally
      F.Free;
    end;
  except
    Result := -1;
  end;
end;

function VerifySqliteFile(const Path: string; NeedRegistryMarker: Boolean;
  out Why: string): Boolean;
var
  Db: psqlite3;
  St: psqlite3_stmt;
  A: AnsiString;
  rc, CloseRc: cint;
  P: PAnsiChar;
  V: string;

  function ImmutableUri(const FileName: string): AnsiString;
  const
    Hex = '0123456789ABCDEF';
  var
    Raw: RawByteString;
    i: Integer;
    B: Byte;
  begin
    { A plain SQLITE_OPEN_READONLY connection may still create -wal/-shm when
      the database header names WAL mode. Verification must never mutate the
      backup it is authenticating. SQLite's documented immutable URI mode
      disables locking, change detection, and journal side files. Percent-
      encode the filesystem bytes so ?, #, %, and non-ASCII bytes cannot be
      interpreted as URI syntax. }
    Raw := ExpandFileName(FileName);
    Result := 'file:';
    for i := 1 to Length(Raw) do
    begin
      B := Byte(Raw[i]);
      if ((B >= Ord('a')) and (B <= Ord('z'))) or
         ((B >= Ord('A')) and (B <= Ord('Z'))) or
         ((B >= Ord('0')) and (B <= Ord('9'))) or
         (B = Ord('/')) or (B = Ord('-')) or (B = Ord('_')) or
         (B = Ord('.')) or (B = Ord('~')) then
        Result := Result + AnsiChar(B)
      else
        Result := Result + '%' + Hex[(B shr 4) + 1] + Hex[(B and $0f) + 1];
    end;
    Result := Result + '?mode=ro&immutable=1';
  end;

  function Prepare(const SQL: string): Boolean;
  begin
    A := SQL;
    St := nil;
    Result := sqlite3_prepare_v2(Db, PAnsiChar(A), -1, @St, nil) = SQLITE_OK;
    if not Result then
      Why := string(sqlite3_errmsg(Db));
  end;

  function TextCol(Col: Integer): string;
  begin
    P := sqlite3_column_text(St, Col);
    if P = nil then
      Result := ''
    else
      SetString(Result, P, sqlite3_column_bytes(St, Col));
  end;

begin
  Result := False;
  Why := '';
  Db := nil;
  A := ImmutableUri(Path);
  rc := sqlite3_open_v2(PAnsiChar(A), @Db,
    SQLITE_OPEN_READONLY or SQLITE_OPEN_FULLMUTEX or SQLITE_OPEN_URI, nil);
  if rc <> SQLITE_OK then
  begin
    if Db <> nil then
      Why := string(sqlite3_errmsg(Db))
    else
      Why := 'sqlite open code ' + IntToStr(rc);
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;
  try
    if not Prepare('PRAGMA quick_check;') then
      Exit;
    try
      rc := sqlite3_step(St);
      if rc <> SQLITE_ROW then
      begin
        Why := 'quick_check returned no result';
        Exit;
      end;
      while rc = SQLITE_ROW do
      begin
        V := TextCol(0);
        if V <> 'ok' then
        begin
          Why := 'quick_check: ' + V;
          Exit;
        end;
        rc := sqlite3_step(St);
      end;
      if rc <> SQLITE_DONE then
      begin
        Why := 'quick_check failed: ' + string(sqlite3_errmsg(Db));
        Exit;
      end;
    finally
      sqlite3_finalize(St);
      St := nil;
    end;
    if not Prepare('PRAGMA foreign_key_check;') then
      Exit;
    try
      rc := sqlite3_step(St);
      if rc = SQLITE_ROW then
      begin
        Why := 'foreign_key_check found a violation in table ' + TextCol(0);
        Exit;
      end;
      if rc <> SQLITE_DONE then
      begin
        Why := 'foreign_key_check failed: ' + string(sqlite3_errmsg(Db));
        Exit;
      end;
    finally
      sqlite3_finalize(St);
      St := nil;
    end;
    if NeedRegistryMarker then
    begin
      if not Prepare('SELECT v FROM meta WHERE k=' +
        '''registry_authority'';') then
        Exit;
      try
        if sqlite3_step(St) <> SQLITE_ROW then
        begin
          Why := 'missing registry_authority marker';
          Exit;
        end;
        if TextCol(0) <> 'sqlite-v1' then
        begin
          Why := 'unsupported registry_authority marker ' + TextCol(0);
          Exit;
        end;
      finally
        sqlite3_finalize(St);
        St := nil;
      end;
    end;
    Result := True;
  finally
    CloseRc := sqlite3_close(Db);
    if CloseRc <> SQLITE_OK then
    begin
      Result := False;
      Why := 'sqlite close failed with code ' + IntToStr(CloseRc);
    end;
  end;
end;

{ `tiza backup verify <dir>` checks a backup WITHOUT restoring anything: every
  manifest entry must exist and match its SHA-256. This is local directory
  access and does not contact the hub. }
procedure RunBackupVerify(const Dir: string);
var
  L: TStringList;
  i, j, bad, n: Integer;
  Parts: TStringList;
  Seen: TStringList;
  P, Hex, Why, Rel: string;
  St: TStat;
  BackupCfg: TPizarraConfig;
  SeenConf, SqliteLoaded: Boolean;
  SeenDb: array[0..2] of Boolean;
  ExpectedBytes: Int64;
const
  DBS: array[0..2] of string = ('apps.sqlite', 'org.sqlite', 'work.sqlite');
  STORE_FILES: array[0..3] of string =
    ('store/messages.jsonl', 'store/state.json', 'store/tareas.json',
     'store/workflows.json');
  LIBS: array[0..3] of UnicodeString =
    ('libsqlite3.so.0', 'libsqlite3.so', 'libsqlite3.dylib', 'libsqlite3.so.3');

  function AllowedRel(const ARel: string): Boolean;
  var
    k: Integer;
  begin
    Result := (ARel = 'pizarra.conf');
    for k := 0 to High(DBS) do
      if ARel = DBS[k] then
        Exit(True);
    for k := 0 to High(STORE_FILES) do
      if ARel = STORE_FILES[k] then
        Exit(True);
  end;

  procedure CheckPhysicalDir(const Base, Prefix: string; Root: Boolean);
  var
    LocalInfo: TSearchRec;
    LocalFull, LocalRel: string;
  begin
    if not DirectoryExists(Base) then
      Exit;
    if FindFirst(IncludeTrailingPathDelimiter(Base) + '*', faAnyFile,
      LocalInfo) <> 0 then
      Exit;
    try
      repeat
        if (LocalInfo.Name = '.') or (LocalInfo.Name = '..') then
          Continue;
        LocalFull := IncludeTrailingPathDelimiter(Base) + LocalInfo.Name;
        LocalRel := Prefix + LocalInfo.Name;
        St := Default(TStat);
        if FpLStat(LocalFull, St) <> 0 then
        begin
          Writeln('UNREADABLE physical backup entry ', LocalRel);
          Inc(bad);
          Continue;
        end;
        if Root and (LocalInfo.Name = 'store') then
        begin
          if fpS_ISLNK(St.st_mode) or (not fpS_ISDIR(St.st_mode)) then
          begin
            Writeln('UNSAFE TYPE store (must be a real directory)');
            Inc(bad);
          end
          else
            CheckPhysicalDir(LocalFull, 'store/', False);
          Continue;
        end;
        if Root and (LocalInfo.Name = 'MANIFEST') then
        begin
          if fpS_ISLNK(St.st_mode) or (not fpS_ISREG(St.st_mode)) then
          begin
            Writeln('UNSAFE TYPE MANIFEST (must be a regular file)');
            Inc(bad);
          end;
          Continue;
        end;
        if fpS_ISLNK(St.st_mode) or (not fpS_ISREG(St.st_mode)) then
        begin
          Writeln('UNSAFE TYPE ', LocalRel,
            ' (backup payload must contain regular files only)');
          Inc(bad);
        end
        else if Seen.IndexOf(LocalRel) < 0 then
        begin
          { Restore must never replay an unverified WAL/SHM or copy an
            operator-added file that the manifest did not authenticate. }
          Writeln('UNLISTED ', LocalRel);
          Inc(bad);
        end;
      until FindNext(LocalInfo) <> 0;
    finally
      FindClose(LocalInfo);
    end;
  end;
begin
  P := IncludeTrailingPathDelimiter(Dir) + 'MANIFEST';
  St := Default(TStat);
  if (FpLStat(P, St) <> 0) or fpS_ISLNK(St.st_mode) or
     (not fpS_ISREG(St.st_mode)) then
    Fail('no pizarra backup there (MANIFEST missing): ' + Dir);
  L := TStringList.Create;
  Parts := TStringList.Create;
  Seen := TStringList.Create;
  SqliteLoaded := False;
  try
    L.LoadFromFile(P);
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := False;
    Seen.CaseSensitive := True;
    bad := 0;
    n := 0;
    SeenConf := False;
    for i := 0 to High(SeenDb) do
      SeenDb[i] := False;
    for i := 0 to L.Count - 1 do
    begin
      if (Trim(L[i]) = '') or (Copy(Trim(L[i]), 1, 1) = '#') then
        Continue;
      Parts.DelimitedText := L[i];
      if Parts.Count < 3 then
      begin
        Writeln('MALFORMED manifest line ', i + 1);
        Inc(bad);
        Continue;
      end;
      Inc(n);
      Rel := Parts[0];
      if not AllowedRel(Rel) then
      begin
        Writeln('UNSUPPORTED manifest entry ', Rel);
        Inc(bad);
        Continue;
      end;
      if Seen.IndexOf(Rel) >= 0 then
      begin
        Writeln('DUPLICATE manifest entry ', Rel);
        Inc(bad);
        Continue;
      end;
      Seen.Add(Rel);
      if Rel = 'pizarra.conf' then
        SeenConf := True;
      for j := 0 to High(DBS) do
        if Rel = DBS[j] then
          SeenDb[j] := True;
      P := IncludeTrailingPathDelimiter(Dir) + Rel;
      St := Default(TStat);
      if (FpLStat(P, St) <> 0) then
      begin
        Writeln('MISSING  ', Parts[0]);
        Inc(bad);
        Continue;
      end;
      if fpS_ISLNK(St.st_mode) or (not fpS_ISREG(St.st_mode)) then
      begin
        Writeln('UNSAFE TYPE ', Parts[0], ' (must be a regular file)');
        Inc(bad);
        Continue;
      end;
      if not Sha256OfFile(P, Hex) then
      begin
        Writeln('UNREADABLE ', Parts[0]);
        Inc(bad);
        Continue;
      end;
      if Hex <> Parts[Parts.Count - 1] then
      begin
        Writeln('CHANGED  ', Parts[0]);
        Inc(bad);
      end;
      if (not TryStrToInt64(Parts[1], ExpectedBytes)) or
         (ExpectedBytes <> FileSizeByName(P)) then
      begin
        Writeln('BAD SIZE ', Rel);
        Inc(bad);
      end;
    end;
    { The manifest is an allow-list as well as a checksum list. In particular,
      reject an unlisted store/org.sqlite-wal or *-shm: restore must not replay
      bytes that were never part of the verified SQLite online backup. }
    CheckPhysicalDir(Dir, '', True);
    if not SeenConf then
    begin
      Writeln('MISSING  pizarra.conf (mandatory manifest entry)');
      Inc(bad);
    end;
    for i := 0 to High(DBS) do
      if not SeenDb[i] then
      begin
        Writeln('MISSING  ', DBS[i], ' (mandatory manifest entry)');
        Inc(bad);
      end;
    { Matching bytes do not prove that a backup is usable: a truncated
      pizarra.conf is consistent with its own manifest. Also check the minimum
      requirements for STARTUP: a readable configuration containing a secret,
      and an SQLite signature on every .sqlite file. Full dynamic SQLite checks
      follow after these cheap truncation/empty-file checks. }
    if bad = 0 then
    begin
      P := IncludeTrailingPathDelimiter(Dir) + 'pizarra.conf';
      if FileExists(P) then
      begin
        try
          { Use exactly the hub parser: it applies the same defaults, quote
            handling, inline-comment rules, ranges, and authority validation. }
          BackupCfg := LoadPizarraConfig(P);
          if BackupCfg.Secret = '' then
          begin
            Writeln('NO SECRET   pizarra.conf carries no [server] secret: ' +
              'the hub would NOT start from this backup');
            Inc(bad);
          end;
        except
          on E: Exception do
          begin
            Writeln('BAD CONFIG pizarra.conf: ', E.Message);
            Inc(bad);
          end;
        end;
      end;
      for i := 0 to High(DBS) do
      begin
        P := IncludeTrailingPathDelimiter(Dir) + DBS[i];
        if not FileExists(P) then
        begin
          Inc(bad);
          Continue;
        end;
        if not IsSqliteFile(P) then
        begin
          Writeln('NOT SQLITE  ', DBS[i], ' (truncated or corrupt)');
          Inc(bad);
        end;
      end;
      if bad = 0 then
      begin
        for i := 0 to High(LIBS) do
          if TryInitializeSqlite(LIBS[i]) > 0 then
          begin
            SqliteLoaded := True;
            Break;
          end;
        if not SqliteLoaded then
        begin
          Writeln('NO SQLITE  libsqlite3 is required for integrity verification');
          Inc(bad);
        end;
      end;
      if bad = 0 then
        for i := 0 to High(DBS) do
        begin
          P := IncludeTrailingPathDelimiter(Dir) + DBS[i];
          if not VerifySqliteFile(P, DBS[i] = 'org.sqlite', Why) then
          begin
            Writeln('DB INVALID ', DBS[i], ': ', Why);
            Inc(bad);
          end;
        end;
    end;
    if bad = 0 then
      Writeln(Format('backup intact and bootable: %d pieces by sha256, ' +
        'conf carries a secret, %d databases pass SQLite integrity/FK checks',
        [n, Length(DBS)]))
    else
    begin
      Writeln(Format('BACKUP DAMAGED: %d of %d pieces do not match', [bad, n]));
      Halt(1);
    end;
  finally
    if SqliteLoaded then
      ReleaseSqlite;
    Seen.Free;
    Parts.Free;
    L.Free;
  end;
end;

{ RunBackupVerify has already rejected malformed, duplicate, unsupported, or
  unlisted payload. Restore uses this exact-membership helper only to decide
  which OPTIONAL store files were captured. }
function BackupManifestHas(const Dir, Wanted: string): Boolean;
var
  L, Parts: TStringList;
  i: Integer;
begin
  Result := False;
  L := TStringList.Create;
  Parts := TStringList.Create;
  try
    L.LoadFromFile(IncludeTrailingPathDelimiter(Dir) + 'MANIFEST');
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := False;
    for i := 0 to L.Count - 1 do
    begin
      if (Trim(L[i]) = '') or (Copy(Trim(L[i]), 1, 1) = '#') then
        Continue;
      Parts.DelimitedText := L[i];
      if (Parts.Count >= 3) and (Parts[0] = Wanted) then
        Exit(True);
    end;
  finally
    Parts.Free;
    L.Free;
  end;
end;

{ `tiza restore <dir> [--dry-run]` restores hub state from a backup.

  Order is mandatory:

  1. The hub must be STOPPED. Refuse while its port answers because copying
     databases beneath a live process can corrupt them.
  2. Verify the backup BEFORE touching live state.
  3. Move live files to <store>/.pre-restore-<ts>/ instead of deleting them, so
     an accidental restore remains recoverable.
  4. MOVE ASIDE every *.sqlite-wal and *.sqlite-shm with the rest of the live
     root files. An old WAL whose salt still matches a restored database could
     replay newer data over the backup. A clean SIGTERM normally leaves neither
     file; abrupt stops are the danger.
  5. The three .sqlite files live at the backup ROOT, while JSON and other store
     files live under store/. Preserve this intentional asymmetry.
  6. APPLICATION MANUALS LIVE IN THE DATABASE. Since 1.0.85 that database is
     org.sqlite, not apps.sqlite: applications moved alongside teams, groups,
     and projects so application-project relations can use real foreign keys.
     apps.sqlite remains as a migration fallback and is still copied. A restore
     that skips databases and rebuilds registries from INI would silently lose
     every manual, so databases are mandatory here. }
procedure RunRestore(const Dir: string; Dry, Confirmed, Forced: Boolean);
var
  StoreDir, ConfPath, Aside, Stamp, Src, Dst, HubHost, LiveSecret: string;
  BkConf, BkSecret, BkStore, Residual, SyncErr: string;
  Info: TSearchRec;
  LiveNames: TStringList;
  i, n, HubPort, StoreLock: Integer;
  St: TStat;
  StoreUid, ConfUid: TUid;
  StoreGid, ConfGid: TGid;
const
  STORE_FILES: array[0..3] of string =
    ('messages.jsonl', 'state.json', 'tareas.json', 'workflows.json');

  procedure Step(const Msg: string);
  begin
    if Dry then
      Writeln('  [dry run] ', Msg)
    else
      Writeln('  ', Msg);
  end;

  procedure CopyOne(const From_, To_: string; OwnerUid: TUid;
    OwnerGid: TGid);
  var
    FS, TS: TFileStream;
    TmpPath, Parent: string;
    H, ErrNo: Integer;
  begin
    if not FileExists(From_) then
    begin
      { A missing item MID-RESTORE is not a no-op: that database would return
        empty without warning. Verify catches listed pieces; this covers the
        remainder. }
      Fail('missing ' + ExtractFileName(From_) + ' in the backup - restore is ' +
        'INCOMPLETE, check ' + Dir);
      Exit;
    end;
    Step('copy ' + ExtractFileName(From_) + ' -> ' + To_);
    if Dry then
      Exit;
    Parent := ExtractFileDir(ExpandFileName(To_));
    TmpPath := To_ + '.restore-tmp-' + IntToStr(FpGetpid);
    if FileExists(TmpPath) then
      Fail('stale restore temporary file exists: ' + TmpPath);
    FS := TFileStream.Create(From_, fmOpenRead or fmShareDenyNone);
    try
      TS := TFileStream.Create(TmpPath, fmCreate, &600);
      try
        if FS.Size > 0 then
          TS.CopyFrom(FS, FS.Size);
      finally
        TS.Free;
      end;
    finally
      FS.Free;
    end;
    { A restore is commonly run through sudo while the hub runs as a dedicated
      account. A root-owned 0600 database/config would make the restored hub
      unbootable. Publish every replacement with the ownership of the live
      object tree it replaces; non-root callers already create as themselves. }
    if (FpGeteuid = 0) and (FpChown(TmpPath, OwnerUid, OwnerGid) <> 0) then
    begin
      DeleteFile(TmpPath);
      Fail('cannot set restore ownership on ' + TmpPath);
    end;
    if FpChmod(TmpPath, &600) <> 0 then
    begin
      DeleteFile(TmpPath);
      Fail('cannot protect restore temporary ' + TmpPath);
    end;
    H := FpOpen(TmpPath, O_RDONLY);
    if H < 0 then
    begin
      DeleteFile(TmpPath);
      Fail('cannot reopen restore temporary ' + TmpPath);
    end;
    try
      if PzFsync(H) <> 0 then
      begin
        ErrNo := fpgeterrno;
        DeleteFile(TmpPath);
        Fail('cannot fsync restore temporary: ' + SysErrorMessage(ErrNo));
      end;
    finally
      FpClose(H);
    end;
    if not RenameFile(TmpPath, To_) then
    begin
      DeleteFile(TmpPath);
      Fail('cannot publish restored file ' + To_);
    end;
    H := PzOpenDirFd(Parent);
    if H < 0 then
      Fail('cannot open restore parent directory for fsync: ' + Parent);
    try
      if PzFsync(H) <> 0 then
        Fail('cannot fsync restore parent directory ' + Parent);
    finally
      FpClose(H);
    end;
  end;

  function ConfigStore(const Path: string): string;
  var
    HubCfg: TPizarraConfig;
  begin
    Result := '';
    try
      { Match startup defaults and parsing exactly. A missing store key means
        PZ_STATE_DIR to the hub; restore must not interpret it as empty. }
      HubCfg := LoadPizarraConfig(Path);
      Result := Trim(HubCfg.StoreDir);
    except
      on E: Exception do
        Fail('cannot parse hub config ' + Path + ': ' + E.Message);
    end;
    while (Length(Result) > 1) and
          (Result[Length(Result)] = PathDelim) do
      Delete(Result, Length(Result), 1);
    if Result <> '' then
      Result := ExpandFileName(Result);
  end;

begin
  StoreLock := -1;
  if not FileExists(IncludeTrailingPathDelimiter(Dir) + 'MANIFEST') then
    Fail('no pizarra backup there (MANIFEST missing): ' + Dir);
  ConfPath := LocalConfPath;
  if ConfPath = '' then
    Fail('cannot find the hub config: run this on the hub machine, ' +
      'or point $PIZARRA_CONF at the pizarra.conf you mean to restore');
  StoreDir := ConfigStore(ConfPath);
  if (StoreDir = '') or (StoreDir = PathDelim) then
    Fail('hub config has an unsafe/empty [store] dir: ' + ConfPath);
  St := Default(TStat);
  if (FpLStat(StoreDir, St) <> 0) or fpS_ISLNK(St.st_mode) or
     (not fpS_ISDIR(St.st_mode)) then
    Fail('refusing unsafe/non-directory restore store: ' + StoreDir);
  StoreUid := St.st_uid;
  StoreGid := St.st_gid;
  St := Default(TStat);
  if (FpLStat(ConfPath, St) <> 0) or fpS_ISLNK(St.st_mode) or
     (not fpS_ISREG(St.st_mode)) then
    Fail('refusing symlink/non-regular hub config target: ' + ConfPath);
  ConfUid := St.st_uid;
  ConfGid := St.st_gid;
  { The listener check below is useful diagnostics but is not mutual
    exclusion: the hub opens SQLite before it begins listening. Hold the same
    non-blocking flock as TPizarra for the complete restore/dry-run. }
  if not PzAcquireHubStoreLock(StoreDir, False, StoreLock, SyncErr) then
    Fail('the hub/store is still active: ' + SyncErr);
  try
  StoreDir := IncludeTrailingPathDelimiter(StoreDir);
  { ResolveConfig discovers the TARGET automatically, so SHOW it before making
    changes: an operator expecting a test hub may be pointing at production.
    This is the project's only command that replaces live state, and therefore
    requires explicit confirmation. }
  Writeln('RESTORE - this OVERWRITES the live state of THIS hub:');
  Writeln('  from backup:  ', Dir);
  Writeln('  config:       ', ConfPath);
  Writeln('  store:        ', StoreDir);
  if not (Dry or Confirmed) then
  begin
    Writeln;
    Writeln('If this is the hub you meant, repeat it with --confirm.');
    Writeln('To see what it would do without touching anything: --dry-run.');
    Writeln('To aim at ANOTHER hub: PIZARRA_CONF=<its pizarra.conf> tiza restore ...');
    Exit;
  end;
  { 1. The hub must be stopped. Test the hub THAT OWNS THIS STORE, not the one
       referenced by the client configuration. }
  HubAddrOf(ConfPath, HubHost, HubPort);
  if PortAnswers(HubHost, HubPort) or PortAnswers('127.0.0.1', HubPort) then
    Fail(Format('the hub that owns THIS store is still alive at %s:%d - stop it before ' +
      'restoring (copying its databases from under it breaks them)',
      [HubHost, HubPort]));
  { 2. Verify before changing anything. }
  Writeln('checking the backup...');
  RunBackupVerify(Dir);
  { 3. Move live state aside without deleting it. }
  LiveSecret := SecretOf(ConfPath);   { Before replacing it. }
  { Check the bus secret BEFORE moving even one file. This check used to sit by
    the final configuration copy and had two flaws. First, it compared only if
    BOTH secrets could be read, so an unreadable live configuration, wrong path,
    or permission failure silently continued and disconnected the entire fleet.
    Treating absence as exempt is unsafe precisely because it prevents verifying
    the operation. Second, checking at the end turned a startup objection into
    another partial operation: restored store, old configuration. }
  BkConf := IncludeTrailingPathDelimiter(Dir) + 'pizarra.conf';
  BkStore := ConfigStore(BkConf);
  if ExcludeTrailingPathDelimiter(StoreDir) <> BkStore then
    Fail('backup [store] dir is ' + BkStore + ' but this hub uses ' +
      ExcludeTrailingPathDelimiter(StoreDir) + '; migrate the backup/layout ' +
      'first instead of restoring databases to one path and config to another');
  if FileExists(BkConf) and (ConfPath <> '') then
  begin
    BkSecret := SecretOf(BkConf);
    if (BkSecret = '') or (LiveSecret = '') then
    begin
      Writeln;
      Writeln('WARNING: the bus secret could NOT be compared.');
      if BkSecret = '' then
        Writeln('  The BACKUP has no readable [server] secret.');
      if LiveSecret = '' then
        Writeln('  The CURRENT config has no readable [server] secret (',
          ConfPath, ').');
      Writeln('  Restoring may hand the fleet a different secret than the one');
      Writeln('  in use, and every host loses its link until each is given the');
      Writeln('  same one. It cannot be checked for you.');
      if not Forced then
        Fail('NOTHING restored: repeat with --force to restore without that ' +
          'check (or fix the unreadable config first)');
    end
    else if BkSecret <> LiveSecret then
    begin
      Writeln;
      Writeln('WARNING: the bus secret in this backup is NOT the one in use now.');
      Writeln('  Restoring rolls the hub back to the backup secret, and EVERY ');
      Writeln('  host in the fleet loses its link until each one is given the');
      Writeln('  same secret. If you rotated it after this backup, this undoes');
      Writeln('  that rotation.');
      { --confirm means "yes, THIS hub". Reverting the fleet secret is a
        DIFFERENT consequence that the operator may not expect, so it requires
        its own consent through --force. }
      if not Forced then
        Fail('NOTHING restored: repeat with --force if you really want the ' +
          'old secret back (or hand-copy just what you need from ' +
          BkConf + ')');
    end;
  end;
  Stamp := FormatDateTime('yyyymmdd-hhnnss', Now);
  Aside := StoreDir + '.pre-restore-' + Stamp + '-' + IntToStr(FpGetpid);
  Step('move the current state aside to ' + Aside);
  { Verify the safety net before relying on it. Previously, failure to create
    the directory or move a file did not stop the operation: live state was
    overwritten and the final message promised that "the previous state remains
    in <Aside>", even if that location was empty or absent. The only command
    capable of losing data must stop when its safety net is unavailable. }
  if not Dry then
  begin
    if DirectoryExists(Aside) or FileExists(Aside) then
      Fail('restore safety directory already exists: ' + Aside);
    if not ForceDirectories(Aside) then
      Fail('cannot create ' + Aside + ' - NOTHING is restored: without that safety copy ' +
        'there is no way back');
    if (FpGeteuid = 0) and (FpChown(Aside, StoreUid, StoreGid) <> 0) then
      Fail('cannot set restore safety-directory ownership on ' + Aside +
        ' - NOTHING is restored');
    if FpChmod(Aside, &700) <> 0 then
      Fail('cannot protect ' + Aside + ' - NOTHING is restored: without that safety copy ' +
        'there is no way back');
  end;
  n := 0;
  LiveNames := TStringList.Create;
  try
    { FPC 3.2.2 FindFirst/FindNext is a live opendir/readdir cursor. Renaming
      entries while traversing it can skip a later name, including a WAL. Take
      an immutable name snapshot first, close the cursor, then mutate. }
    if FindFirst(StoreDir + '*', faAnyFile, Info) = 0 then
    begin
      try
        repeat
          if (Info.Name = '.') or (Info.Name = '..') then
            Continue;
          if Info.Name = PZ_HUB_LOCK_NAME then
            Continue;
          St := Default(TStat);
          Src := StoreDir + Info.Name;
          if FpLStat(Src, St) <> 0 then
            Fail('cannot inspect live store entry before restore: ' + Src);
          if not fpS_ISDIR(St.st_mode) then
            LiveNames.Add(Info.Name);
        until FindNext(Info) <> 0;
      finally
        FindClose(Info);
      end;
    end;
    for i := 0 to LiveNames.Count - 1 do
    begin
      Src := StoreDir + LiveNames[i];
      if not Dry then
        if not RenameFile(Src, IncludeTrailingPathDelimiter(Aside) + LiveNames[i]) then
          Fail('cannot move aside ' + LiveNames[i] + ' - NOTHING is restored ' +
            '(what was already moved is in ' + Aside + ')');
      Inc(n);
    end;
  finally
    LiveNames.Free;
  end;
  { Defense in depth against cursor omissions and a concurrent stray writer:
    no root-level file, especially *.sqlite-wal/*-shm, may survive before the
    verified databases are copied in. Directories such as backups/wfhistory and
    the safety directory itself are intentionally retained. }
  if not Dry then
  begin
    Residual := '';
    if FindFirst(StoreDir + '*', faAnyFile, Info) = 0 then
    begin
      try
        repeat
          if (Info.Name = '.') or (Info.Name = '..') then
            Continue;
          if Info.Name = PZ_HUB_LOCK_NAME then
            Continue;
          St := Default(TStat);
          Src := StoreDir + Info.Name;
          if FpLStat(Src, St) <> 0 then
          begin
            Residual := Info.Name;
            Break;
          end;
          if not fpS_ISDIR(St.st_mode) then
          begin
            Residual := Info.Name;
            Break;
          end;
        until FindNext(Info) <> 0;
      finally
        FindClose(Info);
      end;
    end;
    if Residual <> '' then
      Fail('live store changed during restore safety move; residual file ' +
        Residual + ' was NOT overwritten (previous files are in ' + Aside + ')');
    if not PzSyncDirectory(Aside, SyncErr) then
      Fail('cannot make restore safety copy durable: ' + SyncErr);
    if not PzSyncDirectory(StoreDir, SyncErr) then
      Fail('cannot make emptied store durable: ' + SyncErr);
  end;
  Step(Format('%d file(s) moved aside (including the *-wal and *-shm, which must NOT ' +
    'survive a restore)', [n]));
  { Preserve the current bootstrap config beside the moved state before the
    mandatory backup config replaces it. }
  CopyOne(ConfPath, IncludeTrailingPathDelimiter(Aside) +
    'pizarra.conf.before-restore', StoreUid, StoreGid);
  { 5. Databases live at the backup root. }
  CopyOne(IncludeTrailingPathDelimiter(Dir) + 'apps.sqlite',
    StoreDir + 'apps.sqlite', StoreUid, StoreGid);
  CopyOne(IncludeTrailingPathDelimiter(Dir) + 'org.sqlite',
    StoreDir + 'org.sqlite', StoreUid, StoreGid);
  CopyOne(IncludeTrailingPathDelimiter(Dir) + 'work.sqlite',
    StoreDir + 'work.sqlite', StoreUid, StoreGid);
  { Optional JSON/log state is a closed allow-list and is copied only when its
    exact path was authenticated by MANIFEST. Never enumerate/copy arbitrary
    backup/store files: an unlisted WAL/SHM must not be replayed. }
  Src := IncludeTrailingPathDelimiter(Dir) + 'store';
  for i := 0 to High(STORE_FILES) do
    if BackupManifestHas(Dir, 'store/' + STORE_FILES[i]) then
      CopyOne(IncludeTrailingPathDelimiter(Src) + STORE_FILES[i],
        StoreDir + STORE_FILES[i], StoreUid, StoreGid);
  { Finally, restore the configuration. }
  Dst := IncludeTrailingPathDelimiter(Dir) + 'pizarra.conf';
  { The secret decision was made ABOVE before moving anything; verification
    guarantees this mandatory file exists. }
  CopyOne(Dst, ConfPath, ConfUid, ConfGid);
  if Dry then
    Writeln('dry run: NOTHING was touched. Drop --dry-run to do it for real.')
  else
  begin
    Writeln('restored. Start the hub and check: tiza teams / tiza app list');
    Writeln('The previous state is still in ', Aside, ' just in case.');
  end;
  finally
    PzReleaseHubStoreLock(StoreLock);
  end;
end;

{ Strict, read-only readiness. A transport reply is not success: both protocol
  replies must be typed, authenticated successes, and the live hub must run the
  exact same suite release as this client. Caps additionally proves that the
  credential is bound as configured (or is the unrestricted master credential).
  Remote endpoints are deliberately outside core hub health. }
function ProbeHubHealth(const Cfg: TTizaConfig; out HubVer, Why: string): Boolean;
var
  Reply, Err: string;
  Sent: Boolean;
  Obj: TJSONObject;
  D: TJSONData;
  Families: TJSONArray;
  i: Integer;
  Bound: string;
  Unrestricted: Boolean;

  function RequestTyped(const Req, LabelText: string;
    out Parsed: TJSONObject): Boolean;
  var
    OkData: TJSONData;
  begin
    Result := False;
    Parsed := nil;
    if not RequestLine(Cfg.Host, Cfg.Port, 1000, 1500, Req, Reply, Err, Sent) then
    begin
      Why := LabelText + ' transport failed: ' + Err;
      Exit;
    end;
    Parsed := ParseObj(Reply);
    if Parsed = nil then
    begin
      Why := LabelText + ' reply is not a JSON object';
      Exit;
    end;
    OkData := Parsed.Find('ok');
    if (OkData = nil) or (OkData.JSONType <> jtBoolean) then
    begin
      Why := LabelText + ' reply has no boolean ok field';
      Exit;
    end;
    if not OkData.AsBoolean then
    begin
      Why := LabelText + ' rejected by hub: ' + Parsed.Get('error', 'unknown');
      Exit;
    end;
    Result := True;
  end;

begin
  Result := False;
  HubVer := '';
  Why := '';
  Obj := nil;
  if not RequestTyped(BuildVer(Cfg.Secret, Cfg.SelfId), 'version', Obj) then
  begin
    Obj.Free;
    Exit;
  end;
  try
    D := Obj.Find('ver');
    if (D = nil) or (D.JSONType <> jtString) or (Trim(D.AsString) = '') then
    begin
      Why := 'version reply has no non-empty string ver field';
      Exit;
    end;
    HubVer := D.AsString;
    if HubVer <> PizarraVersion then
    begin
      Why := 'suite version skew: tiza=' + PizarraVersion + ', hub=' + HubVer;
      Exit;
    end;
  finally
    Obj.Free;
  end;

  Obj := nil;
  if not RequestTyped(BuildCaps(Cfg.Secret, Cfg.SelfId), 'capability', Obj) then
  begin
    Obj.Free;
    Exit;
  end;
  try
    D := Obj.Find('bound');
    if (D = nil) or (D.JSONType <> jtString) then
    begin
      Why := 'capability reply has no string bound field';
      Exit;
    end;
    Bound := D.AsString;
    D := Obj.Find('unrestricted');
    if (D = nil) or (D.JSONType <> jtBoolean) then
    begin
      Why := 'capability reply has no boolean unrestricted field';
      Exit;
    end;
    Unrestricted := D.AsBoolean;
    D := Obj.Find('families');
    if (D = nil) or (D.JSONType <> jtArray) then
    begin
      Why := 'capability reply has no array families field';
      Exit;
    end;
    Families := TJSONArray(D);
    for i := 0 to Families.Count - 1 do
      if Families.Items[i].JSONType <> jtString then
      begin
        Why := 'capability family is not a string';
        Exit;
      end;
    if Unrestricted then
    begin
      if Bound <> '' then
      begin
        Why := 'hub reports an unrestricted credential bound to ' + Bound;
        Exit;
      end;
    end
    else if not SameText(Bound, Cfg.SelfId) then
    begin
      Why := 'credential is bound to ' + Bound + ', not configured identity ' +
        Cfg.SelfId;
      Exit;
    end;
  finally
    Obj.Free;
  end;
  Result := True;
end;

procedure RunHubHealth(const ConfigArg: string; WaitSeconds: Integer);
var
  Path, ConfigReason, HubVer, Why: string;
  Cfg: TTizaConfig;
  StopAt: QWord;
begin
  Path := ResolveConfigStrict(ConfigArg, 'TIZA_CONF', 'tiza.conf', ConfigReason);
  if Path = '' then
  begin
    if ConfigReason <> '' then
      Fail(ConfigReason)
    else
      Fail('no config found (looked for tiza.conf; use --config)');
  end;
  try
    Cfg := LoadTizaConfig(Path);
  except
    on E: Exception do
      Fail(E.Message);
  end;
  if Trim(Cfg.SelfId) = '' then
    Fail('missing identity: the configuration has no self= value');
  StopAt := GetTickCount64 + QWord(WaitSeconds) * 1000;
  repeat
    if ProbeHubHealth(Cfg, HubVer, Why) then
    begin
      Writeln(Format('pizarra health: ok hub=%s identity=%s endpoint=%s:%d',
        [HubVer, Cfg.SelfId, Cfg.Host, Cfg.Port]));
      Exit;
    end;
    if GetTickCount64 >= StopAt then
      Break;
    Sleep(200);
  until False;
  Fail('health check failed: ' + Why);
end;

{ ======================= main ======================= }

var
  ConfigArg, FromArg, FileArg, Dest, Msg, Path, Reply, ConfigReason: string;
  Positionals: TStringList;
  Cfg: TTizaConfig;
  Obj, FO: TJSONObject;
  FRows: TJSONArray;
  FTab: TRows;
  i, HealthWait: Integer;
  HealthMode: Boolean;
begin
  { UTF-8 for all AnsiString<->Unicode conversions regardless of LANG — the
    tiza daemon runs under systemd (LANG=C) where fpjson would otherwise mangle
    accented text into '?' when decoding a delivery before injecting it. }
  SetMultiByteConversionCodePage(CP_UTF8);
  { Draw frames ONLY when stdout is a terminal. Pipes, files, and external
    processes receive stable plain text for parsing. }
  SetPretty(IsATTY(StdOutputHandle) = 1);
  { The hub styles rendered text because it cannot know who will read it. Here
    the output target is known, so Vis() strips codes outside a terminal. }
  AnsiInit(cmAuto);
  ConfigArg := '';
  FromArg := '';
  FileArg := '';
  HealthMode := False;
  HealthWait := 0;
  Positionals := TStringList.Create;
  try
    { --config/--help are recognized ONLY in leading position (before the
      destination/command). After the first positional, every token is literal
      or a subcommand flag — so '--file'/'--all' in a task note or message stay
      literal. }
    { --config is global (needed after subcommands, e.g. `daemon --config`).
      --from is still PARSED in leading position (so `tiza --from X <cmd>` does
      not misread X as the destination), but it is IGNORED: identity comes ONLY
      from the config's self= (operator request — a command-line override let a
      global-secret caller claim any team). --file/--keep/--all/--plain are
      command-scoped (parsed by their own command), never global. Note: the
      command-scoped `wf show --from K` (subtree root) is a DIFFERENT flag and
      is unaffected. }
    i := 1;
    while i <= ParamCount do
    begin
      if ParamStr(i) = '--config' then
      begin
        if i >= ParamCount then
          Fail('--config requires a path');
        ConfigArg := ParamStr(i + 1); Inc(i);
      end
      else if (Positionals.Count = 0) and (ParamStr(i) = '--from') and (i < ParamCount) then
      begin
        FromArg := ParamStr(i + 1); Inc(i);
      end
      else if (Positionals.Count = 0) and (ParamStr(i) = '--health') then
        HealthMode := True
      else if (Positionals.Count = 0) and (ParamStr(i) = '--wait') then
      begin
        if not HealthMode then
          Fail('--wait is valid only after --health');
        if (i >= ParamCount) or (not TryStrToInt(ParamStr(i + 1), HealthWait)) or
           (HealthWait < 0) or (HealthWait > 120) then
          Fail('--wait requires seconds between 0 and 120');
        Inc(i);
      end
      else if (Positionals.Count = 0) and (ParamStr(i) = '--version') then
      begin
        { HERMETIC by contract: prints this binary's release and exits — no
          config resolution, no hub call, no side effects. The self-update
          engine runs exactly this on a candidate binary before installing
          it, so it must never depend on the environment. }
        Writeln('tiza ', PizarraVersion);
        Halt(0);
      end
      else if (Positionals.Count = 0) and ((ParamStr(i) = '--help') or
              (ParamStr(i) = '-h') or (LowerCase(ParamStr(i)) = 'help') or
              (LowerCase(ParamStr(i)) = 'ayuda')) then
        { The delivery header advertises bare `tiza help`, so resolve it before
          the parser can treat `help` as a destination. }
        Usage
      else
        Positionals.Add(ParamStr(i));
      Inc(i);
    end;

    { IDENTITY BY CONSTRUCTION on a multi-team host. Without --config or
      TIZA_CONF, bare `tiza` would fall back to the host default and could sign
      as ANOTHER team when the parent process does not propagate its environment.
      Inside a tmux session tagged by the daemon, use that team's @pizarra_conf.
      The flag and environment variable still take precedence. }
    if (Trim(ConfigArg) = '') and
       (Trim(GetEnvironmentVariable('TIZA_CONF')) = '') then
      ConfigArg := TmuxSessionConf;   { '' when not tagged / not in tmux }

    if HealthMode then
    begin
      if Positionals.Count <> 0 then
        Fail('--health does not accept a destination or command');
      RunHubHealth(ConfigArg, HealthWait);
      Exit;
    end;

    if Positionals.Count = 0 then
      Usage;

    if SameText(Positionals[0], 'daemon') then
    begin
      RunDaemon(ConfigArg);
      Exit;
    end;
    { the manual is static text — never needs a config or the hub }
    if SameText(Positionals[0], 'manual') then
    begin
      Writeln(AgentsManualText);
      Exit;
    end;
    { release version: the local binary always prints; the hub's is queried
      when a config resolves and the hub answers (drift check across hosts) }
    if SameText(Positionals[0], 'ver') or SameText(Positionals[0], 'version') then
    begin
      Writeln('tiza ', PizarraVersion);
      Path := ResolveConfigStrict(ConfigArg, 'TIZA_CONF', 'tiza.conf', ConfigReason);
      if (Path = '') and (ConfigReason <> '') then
        Fail(ConfigReason);
      if Path = '' then
        Writeln('pizarra hub: (no config, not queried)')
      else
      begin
        try
          Cfg := LoadTizaConfig(Path);
          if (FromArg <> '') and (GetEnvironmentVariable('TIZA_ALLOW_FROM') <> '') then
            Cfg.SelfId := FromArg;
          if SendRequest(Cfg, BuildVer(Cfg.Secret, Cfg.SelfId), Reply) then
          begin
            Obj := ParseObj(Reply);
            if Obj <> nil then
            try
              if Obj.Get('ok', False) then
                Writeln('pizarra hub ', Obj.Get('ver', '?'))
              else
                Writeln('pizarra hub: ', Obj.Get('error', 'unknown'));
            finally
              Obj.Free;
            end;
          end
          else
            Writeln('pizarra hub: unreachable');
        except
          on E: Exception do
            Writeln('pizarra hub: ', E.Message);
        end;
      end;
      Exit;
    end;

    { THE GUARD APPLIES ONLY TO COMMANDS THAT COMMUNICATE. A missing explicit
      path is an identity error because falling back to the neighboring
      configuration could expose master authority. Help is LOCAL: it does not
      touch the hub or assert an identity and must work without configuration.
      Requiring one would turn an identity safeguard into an unrelated burden. }
    Path := ResolveConfigStrict(ConfigArg, 'TIZA_CONF', 'tiza.conf', ConfigReason);
    if (Path = '') and (ConfigReason <> '') and (not IsLocalOnly(Positionals)) then
      Fail(ConfigReason);
    if SameText(Positionals[0], 'chat') then
    begin
      if Path = '' then
        Fail('no config found (looked for tiza.conf; use --config)');
      try
        Cfg := LoadTizaConfig(Path);
      except
        on E: Exception do Fail(E.Message);
      end;
      if FromArg <> '' then
        if GetEnvironmentVariable('TIZA_ALLOW_FROM') <> '' then
          Cfg.SelfId := FromArg
        else
          Writeln(StdErr, '-- tiza: --from is ignored; identity comes from ' +
            'self= in the config (' + Path + ') --');
      RunChat(Cfg, HasFlag(Positionals, '--plain'));
      Exit;
    end;
    { Answer help here without configuration; it is the only operation that
      needs no caller identity. }
    if (Path = '') and IsLocalOnly(Positionals) then
    begin
      Cfg := Default(TTizaConfig);
      if (LowerCase(Positionals[0]) = 'wf') or
         (LowerCase(Positionals[0]) = 'workflow') then
        RunWorkflowCli(Cfg, Positionals)
      else
        Usage;
      Exit;
    end;
    if Path = '' then
      Fail('no config found (looked for tiza.conf; use --config)');
    try
      Cfg := LoadTizaConfig(Path);
    except
      on E: Exception do Fail(E.Message);
    end;
    { --from no longer changes ordinary request identity: the speaker is ALWAYS
      the configuration's self=. A TRUSTED local console integration may opt in
      through TIZA_ALLOW_FROM when it must sign explicitly as the console.
      Otherwise ignore --from and warn; trusting it on a multi-team host could
      silently send as the default team. This exception only helps a caller with
      the GLOBAL secret; the hub still rejects a mismatched per-team credential. }
    if FromArg <> '' then
      if GetEnvironmentVariable('TIZA_ALLOW_FROM') <> '' then
        Cfg.SelfId := FromArg
      else
        Writeln(StdErr, '-- tiza: --from is ignored; identity comes from self= ' +
          'in the config (' + Path + '); use that team''s own config (self= or ' +
          'TIZA_CONF) to speak as another team --');
    { EVERY CALLER MUST HAVE A NAME. A configuration without self previously
      defaulted to CONSOLE identity: anyone loading a minimal host/port/secret
      file spoke as the operator, and a global secret gave the hub no way to
      refute it. Stop now and explain where to fix the identity. }
    if Trim(Cfg.SelfId) = '' then
      Fail('missing identity: the configuration has no self= value (set ' +
        'self=<name> in ' + Path + ', or point TIZA_CONF to a file that ' +
        'contains it)');

    Dest := Positionals[0];
    { Restore is LOCAL while the hub is stopped; it does not use the bus. }
    if SameText(Dest, 'restore') or SameText(Dest, 'restaurar') then
    begin
      if Positionals.Count < 2 then
        Fail('usage: tiza restore <backup-dir> [--dry-run] [--confirm] [--force]');
      RunRestore(Positionals[1],
        HasFlag(Positionals, '--dry-run') or HasFlag(Positionals, '--en-seco'),
        HasFlag(Positionals, '--confirm') or HasFlag(Positionals, '--confirmar'),
        HasFlag(Positionals, '--force') or HasFlag(Positionals, '--forzar'));
      Exit;
    end;
    if SameText(Dest, 'backup') or SameText(Dest, 'copia') then
    begin
      { Backup verification is local and does not require the hub. }
      if (Positionals.Count > 1) and
         (SameText(Positionals[1], 'verify') or
          SameText(Positionals[1], 'comprobar')) then
      begin
        if Positionals.Count < 3 then
          Fail('usage: tiza backup verify <directory>');
        RunBackupVerify(Positionals[2]);
        Exit;
      end;
      Msg := '';
      for i := 1 to Positionals.Count - 1 do
        if (Positionals[i] <> '--force') and (Positionals[i] <> '--out') then
          Msg := Positionals[i];
      if not SendRequest(Cfg, BuildBackup(Cfg.Secret, Cfg.SelfId, Msg,
        HasFlag(Positionals, '--force')), Reply) then
        Fail('no reply from pizarra');
      Obj := ParseObj(Reply);
      if Obj = nil then
        Fail('bad reply from pizarra');
      try
        if not Obj.Get('ok', False) then
          Fail('server: ' + Obj.Get('error', 'unknown'));
        Writeln(Vis(Obj.Get('tree', '')));
      finally
        Obj.Free;
      end;
      Exit;
    end;
    if SameText(Dest, 'fleet') or SameText(Dest, 'flota') then
    begin
      if not SendRequest(Cfg, BuildFleet(Cfg.Secret, Cfg.SelfId), Reply) then
        Fail('no reply from pizarra');
      Obj := ParseObj(Reply);
      if Obj = nil then
        Fail('bad reply from pizarra');
      try
        if not Obj.Get('ok', False) then
          Fail('server: ' + Obj.Get('error', 'unknown'));
        FRows := Obj.Get('rows', TJSONArray(nil));
        if (FRows <> nil) and Pretty then
        begin
          SetLength(FTab, FRows.Count);
          for i := 0 to FRows.Count - 1 do
          begin
            FO := TJSONObject(FRows.Items[i]);
            SetLength(FTab[i], 5);
            FTab[i][0] := FO.Get('kind', '');
            FTab[i][1] := FO.Get('host', '');
            FTab[i][2] := FO.Get('state', '');
            FTab[i][3] := FO.Get('ver', '');
            FTab[i][4] := FO.Get('teams', '');
          end;
          Writeln(Table(TCells.Create('TYPE', 'HOST', 'STATE',
            'RELEASE', 'TEAMS'), FTab, 118));
        end
        else
          Writeln(Vis(Obj.Get('tree', '')));
      finally
        Obj.Free;
      end;
      Exit;
    end;
    if SameText(Dest, 'update') or SameText(Dest, 'actualizar') then
    begin
      if Positionals.Count < 2 then
        Fail('usage: tiza update <team|all> [--force]');
      { the hub answers only after probing every push host (1 s per dead one),
        so this call gets its own budget instead of SendRequest's 5 s }
      if not RequestLine(Cfg.Host, Cfg.Port, 20000,
        BuildUpdate(Cfg.Secret, Cfg.SelfId, Positionals[1], '',
          HasFlag(Positionals, '--force')), Reply, Msg) then
        Fail('no reply from pizarra: ' + Msg);
      Obj := ParseObj(Reply);
      if Obj = nil then
        Fail('bad reply from pizarra');
      try
        if not Obj.Get('ok', False) then
          Fail('server: ' + Obj.Get('error', 'unknown'));
        Writeln(Vis(Obj.Get('tree', '')));
      finally
        Obj.Free;
      end;
      Exit;
    end;
    if SameText(Dest, 'hold') then
    begin
      { operator's manual delivery gate for a blocked agent (console only) }
      if Positionals.Count < 3 then
        Fail('usage: tiza hold <team> on|off');
      if not (SameText(Positionals[2], 'on') or SameText(Positionals[2], 'off')) then
        Fail('usage: tiza hold <team> on|off');
      if not SendRequest(Cfg, BuildHold(Cfg.Secret, Cfg.SelfId, Positionals[1],
        SameText(Positionals[2], 'on')), Reply) then
        Fail('no reply from pizarra');
      Obj := ParseObj(Reply);
      if Obj = nil then
        Fail('bad reply from pizarra');
      try
        if not Obj.Get('ok', False) then
          Fail('server: ' + Obj.Get('error', 'unknown'));
        Writeln(Obj.Get('note', 'ok'));
      finally
        Obj.Free;
      end;
      Exit;
    end;
    if SameText(Dest, 'app') or SameText(Dest, 'apps') or
       SameText(Dest, 'aplicacion') or SameText(Dest, 'aplicaciones') then
    begin
      RunAppCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'tree') then
    begin
      RunTreeCli(Cfg);
      Exit;
    end;
    if SameText(Dest, 'task') then
    begin
      RunTaskCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'workflow') or SameText(Dest, 'wf') then
    begin
      RunWorkflowCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'team') or SameText(Dest, 'teams') then
    begin
      RunTeamCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'group') or SameText(Dest, 'groups') then
    begin
      RunGroupCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'project') or SameText(Dest, 'projects') then
    begin
      RunProjectCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'header') or SameText(Dest, 'headers') then
    begin
      RunHeaderCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'share') then
    begin
      RunShareCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'files') then
    begin
      RunFilesCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'put') then
    begin
      RunPutCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'get') then
    begin
      RunGetCli(Cfg, Positionals);
      Exit;
    end;
    if SameText(Dest, 'cat') then
    begin
      RunCatCli(Cfg, Positionals);
      Exit;
    end;

    if SameText(Dest, 'inbox') then
    begin
      if SendRequest(Cfg, BuildInbox(Cfg.Secret, Cfg.SelfId,
        HasFlag(Positionals, '--keep'), HasFlag(Positionals, '--all')), Reply) then
        PrintInbox(Reply);
      Exit;
    end;

    { send: '--file PATH' only right after the dest (documented form) }
    FileArg := '';
    if (Positionals.Count = 3) and (Positionals[1] = '--file') then
      FileArg := Positionals[2];
    if FileArg <> '' then
      Msg := ReadMsgFile(FileArg)
    else
    begin
      if Positionals.Count < 2 then
        Fail('nothing to send (usage: tiza <dest> <message>)');
      Msg := '';
      for i := 1 to Positionals.Count - 1 do
      begin
        if Msg <> '' then Msg := Msg + ' ';
        Msg := Msg + Positionals[i];
      end;
    end;

    if SendRequest(Cfg, BuildSend(Cfg.Secret, Cfg.SelfId, Dest, Msg), Reply) then
    begin
      Obj := ParseObj(Reply);
      if Obj = nil then
        Fail('bad reply from pizarra');
      try
        if Obj.Get('ok', False) then
        begin
          if Obj.Get('broadcast', 0) > 0 then
            Writeln(Format('sent to %s (%d teams, %d queued)',
              [Dest, Obj.Get('broadcast', 0), Obj.Get('queued_count', 0)]))
          else if Obj.Get('queued', False) then
          begin
            if Obj.Get('note', '') <> '' then
              Writeln(Format('queued for %s: %s', [Dest, Obj.Get('note', '')]))
            else
              Writeln(Format('queued for %s (pending delivery)', [Dest]));
          end
          else
            Writeln(Format('sent to %s', [Dest]));
        end
        else
          Fail('server: ' + Obj.Get('error', 'unknown'));
      finally
        Obj.Free;
      end;
    end;
  finally
    Positionals.Free;
  end;
end.
