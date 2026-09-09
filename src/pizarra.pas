{ pizarra - the blackboard daemon (hub).

  - Listens on a TCP socket for the tiza wire protocol; one thread per
    connection (pznet), so long-lived streams cannot freeze the bus.
  - Routes each `send` to the destination team: local teams get the wrapped
    text injected into their tmux session; remote teams (host=ip:port) get it
    pushed to the tiza daemon on that host.
  - Journals every message durably (pzstore); failed deliveries stay pending
    and the watchdog redelivers them oldest-first.
  - Keeps local teams' tmux sessions alive; SIGTERM/SIGINT shut down cleanly.

  Usage: pizarra [--config PATH]                                             }
program pizarra;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, IniFiles, ssockets, SyncObjs, BaseUnix,
  Unix{$IFDEF LINUX}, Linux{$ENDIF}, Types, StrUtils,
  fpjson, base64,
  pzproto, pzconfig, pzlog, pzstore, pztasks, pzworkflow, pztmux, pznet,
  pzmanual, pzshare, pzver, pzsha256, pzdb, pzansi, pzlayout, pzpty, pzshell;

{ BaseUnix 3.2.2 exposes chmod(path) but no fchmod(fd) wrapper. Linux/glibc
  declares int fchmod(int, mode_t) in sys/stat.h; use it so a pathname swap
  cannot redirect permission changes after a directory has been opened. }
function C_FChmod(Fd: LongInt; Mode: TMode): LongInt; cdecl;
  external name 'fchmod';

var
  { watchdog tick in seconds; PIZARRA_TICK env overrides (min 1) so the
    smoke suite can drive time-based behavior (stall nudges) deterministically }
  WATCHDOG_INTERVAL: Integer = 15;
  { Artificial delay, in milliseconds, between the configuration snapshot and
    the `team set` lock. PIZARRA_TEST_SETDELAY enables it; production uses 0.
    Tests use it to open the deleted-team race window deterministically. It
    only sleeps and does not alter any decision. }
  TEAMSET_TEST_DELAY: Integer = 0;

const
  WATCH_QUEUE_MAX   = 1000;  { per-watcher/dial-channel event queue bound }
  WATCH_REPLAY_MAX  = 200;   { catch-up events on subscribe }
  WATCH_PING_MS     = 60000;
  DIAL_ACK_MS       = 15000;  { dial-in: max wait for a daemon's per-delivery ack }

type
  TPizarra = class;

  { One subscribed watch connection; its conn thread drains the queue.
    Each queued line carries its msg seq (0 for sys/gap/task events) so the
    drain loop can skip events already sent during the catch-up replay. }
  { A watcher with Scope<>'' sees only durable messages whose sender or
    destination is that team. The authenticated credential fixes the scope at
    subscription time; it is never inferred from request fields or event text.
    Scope='' is the global console and also receives sys and task events.

    DroppedMax records the greatest visible sequence discarded on overflow.
    Registration intentionally precedes the replay snapshot, so queue and
    replay overlap; a discarded item already present in replay is not a gap. }
  TWatcher = class
  public
    Queue: TStringList;   { line + seq in Objects }
    Lock:  TCriticalSection;
    Scope: string;
    DroppedMax: Int64;
    DroppedUnseq: Boolean;
    constructor Create(const AScope: string = '');
    destructor Destroy; override;
    function Sees(const M: TPzMsg): Boolean;
    procedure Push(const Line: string; Seq: Int64);
    procedure PushMsg(const M: TPzMsg);
    function Pop(out Line: string; out Seq: Int64): Boolean;
    function TakeDropped(out Unsequenced: Boolean): Int64;
  end;

  { One dial-in delivery channel: a tiza daemon that dialed the hub (reverse
    connection) and hosts Teams. TryDeliver enqueues full BuildDeliver envelopes
    here; the DoDial thread drains them to the socket and MarkDelivered on the
    daemon's ack. Mirrors TWatcher, but carries deliveries (not feed events) and
    dedupes by seq (RetryPending may re-offer a still-queued message). }
  { A queued dial-channel line carries its exact team. The acknowledgement is
    checked against the line just written, never against a client-supplied
    team list. }
  TDialItem = record
    Line: string;
    Team: string;   { canonical name; '' = control line, marks nothing }
    Seq:  Int64;
  end;

  TDialChannel = class
  public
    Teams: TStringArray;   { canonical names served, selected by the hub }
    From:  string;         { hello identity, used to evict its stale channel }
    Bound: string;         { team bound by the credential; '' = global }
    Ver:   string;         { daemon release from the dial hello (fleet view) }
    Items: array of TDialItem;
    Lock:  TCriticalSection;
    constructor Create(const ATeams: TStringArray; const AFrom, ABound: string);
    destructor Destroy; override;
    function  Serves(const Team: string): Boolean;
    procedure Drop(const Team: string);
    procedure Push(const Line, Team: string; Seq: Int64);
    function  Pop(out Line, Team: string; out Seq: Int64): Boolean;
  end;

  { A viewer's attach to a DIAL team, waiting for the daemon to dial the hub
    back. The viewer thread creates it, registers it by Token, and sends
    attach_open down the reverse channel; the daemon dials back a fresh
    connection carrying Token; the CMD_ATTACH_JOIN thread finds this record by
    Token, claims it (by removing it from the list under the list lock — list
    membership IS the unclaimed flag), and performs the relay. Two events
    hand the record safely between the two threads: Arrived (the join claimed
    it) and Finished (the relay ended). ExpectFrom pins the claim to the one
    daemon that serves this team. }
  TAttachWait = class
  public
    { Caller asked for the attach; ExpectFrom is the daemon that dials back. }
    Token, ExpectFrom, Caller, Term: string;
    Write: Boolean;
    ClientData, JoinData: TSocketStream;
    Arrived, Finished: TEvent;
    constructor Create(const AToken, AExpectFrom, ACaller, ATerm: string;
      AWrite: Boolean; AClient: TSocketStream);
    destructor Destroy; override;
  end;

  { The same rendezvous for a SHELL on a dial host. Separate class rather than
    a reused one: a shell carries no write flag and does carry the viewer's
    window size, and the two features must stay independently changeable.
    Ownership protocol is identical and equally load-bearing - list membership
    IS the unclaimed flag, the join thread claims by removing under the list
    lock, and the two auto-reset events hand the record between threads. }
  TShellWait = class
  public
    { Caller is the team that ASKED for the shell. ExpectFrom is the daemon that
      dials back. They are different, and logging the second one as if it were
      the first is how the dial route lost its audit trail until 1.1.34. }
    Token, ExpectFrom, Caller, Term: string;
    Cols, Rows: Integer;
    ClientData, JoinData: TSocketStream;
    Arrived, Finished: TEvent;
    constructor Create(const AToken, AExpectFrom, ACaller, ATerm: string;
      ACols, ARows: Integer; AClient: TSocketStream);
    destructor Destroy; override;
  end;

  { Periodically (re)creates missing tmux team sessions. }
  TWatchdog = class(TThread)
  private
    FOwner: TPizarra;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TPizarra);
  end;

  { Live pane-activity of a team, reported by its daemon over CMD_ACTIVITY. Held
    only in memory: it re-derives from the next report after a hub restart. }
  TActState = record
    Team:  string;      { lowercased key }
    State: string;      { moving | quiet | idle | blocked | busy }
    Since: TDateTime;   { when this state began — for "quiet 3m" }
    Note:  string;      { optional detail, e.g. the matched prompt line }
    HoldAuto:   Boolean;   { delivery held from a RELIABLE (hook) block report }
    HoldManual: Boolean;   { delivery held by the operator (tiza <team> hold on) }
    NotifyN:    Integer;   { alarms already sent THIS blocked episode (rate-limit) }
    LastNotify: TDateTime; { when the last alarm for this episode fired }
  end;

  { Per-group quiescence tracking for the on_idle barrier. Touched only by the
    watchdog thread (ActivityMaintain), so it needs no lock. }
  TGrpIdleState = record
    Name:  string;      { lowercased group name }
    Since: TDateTime;   { when the group became fully idle (0 = not idle now) }
    Fired: Boolean;     { the continue-signal already went out this quiescence }
  end;

  TPizarra = class
  private
    FCfg:   TPizarraConfig;
    FCfgPath: string;
    FCfgLock: TCriticalSection;  { guards FCfg swaps and config-file writes }
    { Serializes chunked uploads. The shared tree may be on NFS without working
      flock semantics, while this process is the only writer, so the lock is
      deliberately process-local. }
    FPutLock: TCriticalSection;
    FLog:   TPzLog;
    FStore: TPzStore;
    FTasks: TTaskStore;
    FWf:    TWorkflowStore;
    FDb:    TPzDb;              { authoritative SQLite registries }
    FHubStoreLock: Integer;     { lifetime flock: hub/restore mutual exclusion }
    FLock:  TCriticalSection;   { serialises local tmux delivery }
    FServer: TPzServer;
    FWatchers: TThreadList;     { of TWatcher }
    FDialChannels: TThreadList; { of TDialChannel — reverse delivery channels }
    { tiza attach (1.2.0): live raw-terminal relays. Bounded, because the
      native bus has no per-connection limit of its own and each attach holds
      a thread, two descriptors and a tmux client for as long as a human
      leaves it open. }
    FAttachLock:  TCriticalSection;
    FAttachTotal: Integer;
    FAttachPer:   TStringList;  { team name -> open attach count }
    FAttachWaits: TThreadList;  { of TAttachWait — dial attaches awaiting a join }
    { tiza shell (1.1.33): the same, for login shells on team HOSTS. Its own
      lock and counters throughout: four open attaches must never be able to
      make the fleet unadministrable, and vice versa. Keyed by HOST, not by
      team, so two teams on one box share one budget there. }
    FShellLock:  TCriticalSection;
    FShellTotal: Integer;
    FShellPer:   TStringList;   { host key -> open shell count }
    FShellWaits: TThreadList;   { of TShellWait — dial shells awaiting a join }
    FActLock: TCriticalSection; { guards FActivity }
    FActivity: array of TActState; { team -> live pane-activity (CMD_ACTIVITY) }
    FGrpIdle: array of TGrpIdleState; { per-group quiescence (watchdog-only) }
    procedure OpenRegistryDb;   { opens, creates schemas, and migrates once }
    procedure HandleConnect(Stream: TSocketStream);
    { Ident is 'proven' for a team-bound credential and 'claimed' when a
      global credential supplied a team identity. }
    procedure DoSend(const From, Dest, Text: string; Data: TSocketStream;
      const Ident: string = '');
    { A comma-separated destination list. Resolves every element to teams,
      refuses the WHOLE send if any element is unknown, then fans out exactly
      as a group does. Reached only from DoSend, and only when the destination
      really holds more than one name. }
    procedure SendMulti(const C: TPizarraConfig; const From, Dest, Text: string;
      Data: TSocketStream; const Ident: string);
    procedure DoWatch(Data: TSocketStream; Since: Int64; const Scope: string);
    procedure DoDial(Data: TSocketStream; const From, BoundTeam, TeamsCsv: string;
      KeepAlive: Integer; const DaemonVer: string);
    procedure HandleFleet(Data: TSocketStream);
    { tiza attach: authorise, route, spawn or relay, pump, account. }
    procedure HandleAttach(Obj: TJSONObject; const From, BoundTeam: string;
      Data: TSocketStream);
    { Route the authorised attach to a PUSH team: connect to its daemon, hand
      over the handshake, and pipe the two sockets. The daemon emits the reply. }
    procedure RelayPushAttach(Data: TSocketStream; const From: string;
      const T: TTeam; Write: Boolean; const Term: string);
    { Route to a DIAL team: register a token, push attach_open down the reverse
      channel, and wait for the daemon's CMD_ATTACH_JOIN to be paired here. }
    procedure RelayDialAttach(Data: TSocketStream; const From: string;
      const T: TTeam; Write: Boolean; const Term: string);
    { The dial daemon's dial-back connection for a pending attach. }
    procedure HandleAttachJoin(Obj: TJSONObject; const From: string;
      Data: TSocketStream);
    { Push a control line to the reverse channel serving Team. False when no
      channel currently serves it (the dial host is not connected). }
    function  PushToDial(const Team, Line: string): Boolean;
    function  AttachAcquire(const Team: string; out Why: string): Boolean;
    procedure AttachRelease(const Team: string);
    { tiza shell: authorise, route, spawn or relay, pump, account. Mirrors the
      attach four, minus every write-mode branch - a shell is always
      interactive - and keyed by host rather than by team. }
    procedure HandleShell(Obj: TJSONObject; const From: string;
      Data: TSocketStream);
    procedure RelayPushShell(Data: TSocketStream; const From: string;
      const T: TTeam; const Term: string; Cols, Rows: Integer);
    procedure RelayDialShell(Data: TSocketStream; const From: string;
      const T: TTeam; const Term: string; Cols, Rows: Integer);
    procedure HandleShellJoin(Obj: TJSONObject; const From: string;
      Data: TSocketStream);
    function  ShellAcquire(const HostKey: string; out Why: string): Boolean;
    procedure ShellRelease(const HostKey: string);
    procedure HandleUpget(Obj: TJSONObject; Data: TSocketStream);
    procedure HandleUpdate(Obj: TJSONObject; const From: string;
      Data: TSocketStream);
    procedure HandleApp(Obj: TJSONObject; const From: string; Data: TSocketStream);
    { Refresh the in-memory projection after an assignment changes. The
      relation lives only in SQLite, while the delivery-header builder consumes
      a config snapshot and intentionally has no database dependency. }
    procedure MirrorAppProjects(const AppName: string);
    procedure HandleBackup(Obj: TJSONObject; const From: string;
      Data: TSocketStream);
    procedure DialEnqueue(const Team, Envelope: string; Seq: Int64);
    procedure HandleTask(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandleWorkflow(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandleTeam(Obj: TJSONObject; const From: string; Data: TSocketStream);
    function ConsoleFor(const From, Family: string): Boolean;
    procedure HandleGroup(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandleProject(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandleHeader(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandlePut(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandleGet(Obj: TJSONObject; const From: string; Data: TSocketStream);
    procedure HandleActivity(Obj: TJSONObject; const From, BoundTeam: string;
      Data: TSocketStream);
    procedure HandleHold(Obj: TJSONObject; const From: string; Data: TSocketStream);
    { true if delivery to this team is currently held (auto or manual) }
    function  IsHeld(const Team: string): Boolean;
    { hold decision for a TEAM record (adds the opt-in hold_when_blocked case)
      and the reason, so the sender can be told why its message was queued }
    function  HeldForTeam(const Team: TTeam; out Why: string): Boolean;
    { operator's manual hold on/off for a team's delivery }
    procedure SetHoldManual(const Team: string; On_: Boolean);
    { compose the loud alarm line for a blocked team (host/session/prompt) }
    function  AlarmText(const Team, Note: string): string;
    { a member of a group whose on_block=log wants a quiet log line on a block,
      not the loud operator alarm (detection/hold/auto_enter unchanged) }
    function  BlockLogOnly(const C: TPizarraConfig; const Team: string): Boolean;
    { watchdog tick: re-fire blocked alarms up to the per-episode cap }
    procedure ActivityMaintain;
    { watchdog tick: detect a group that has gone fully idle and, once it has
      held the barrier for the dwell, fire its on_idle continue-signal }
    procedure GroupIdleMaintain;
    { send the continue-signal to a quiesced group's configured target(s) }
    procedure FireGroupContinue(const C: TPizarraConfig; const G: TGroup);
    { current state + age in seconds and optional note; '' when unknown }
    function  ActivityOf(const Team: string; out AgeSecs: Integer;
      out Note: string): string;
    { human display label: 'moving', 'quiet 3m', 'blocked 1m'... '' when unknown }
    function  ActivityLabel(const Team: string): string;
    { annotate a space-separated team list with each team's activity, e.g.
      "frontend(quiet 3m) api(moving)" — teams without a report pass through }
    function  TeamsWithActivity(const TeamList: string): string;
    function  FanOne(const C: TPizarraConfig; const Team: TTeam;
      const From, Text: string; out Stored, Queued: Boolean;
      out Why: string; const Ident: string = ''): Boolean;
    function  ReplyGroups: string;
    function  ReplyProjects: string;
    { ONE project's card: its boss, who has it assigned, and the apps that
      build it with what each one does THERE. Found=False when it does not
      exist, and the caller decides the error: no empty project is invented. }
    function  ReplyProjectCard(const Name: string; out Found: Boolean): string;
    function  ReplyHeader: string;
    function  Snap: TPizarraConfig;
    function  TryDeliver(const C: TPizarraConfig; const Team: TTeam;
      const FromName, Text: string; Seq: Int64;
      const Ident: string = ''; MinimalHdr: Boolean = False;
      const ReplyTo: string = ''): Boolean;
    procedure RetryPending;
    procedure PingPushHosts(const C: TPizarraConfig);
    function  PublishedVer(const C: TPizarraConfig): string;
    procedure OnStoreAppend(const M: TPzMsg);
    procedure EnsureSharedDirs;
    function  WfBossOf(const C: TPizarraConfig; const WfName: string): string;
    function  WfHeaderBlock(const C: TPizarraConfig;
      const TeamName: string; const Wfs: TWorkflowArray;
      const Cleanup: TWfStrings): string;
    procedure WfFeed(const R: TWfResult);
    function  WfNotify(const C: TPizarraConfig; const Team: TTeam;
      const Text: string): Boolean;
    { a plain system nudge to a team: journalled (durable + shows in /log) and
      delivered with a MINIMAL header, sent AS FromName with the recipient told
      to answer ReplyTo (''=FromName). }
    function  SendGroupNudge(const C: TPizarraConfig; const Team: TTeam;
      const FromName, ReplyTo, Text: string): Boolean;
    procedure DrainWfOutbox(const C: TPizarraConfig; const WfName: string);
    procedure WfMaintain;
    procedure Broadcast(const Line: string; Seq: Int64);
    procedure BroadcastMsg(const M: TPzMsg);
    function  ReplyTeams(const Asker: string): string;
  public
    constructor Create(const ConfigPath: string);
    destructor Destroy; override;
    procedure Run;
  end;

{ Path-safe identifier: letters/digits/._- , first char alphanumeric. Team
  names become tmux session + shared-dir path components, so this blocks
  traversal (../) and shell/path surprises. }
function SafeName(const N: string): Boolean;
begin
  Result := LooksSafeName(N);   { the single validator lives in pzconfig }
end;

{ True if Name is in the (case-insensitive) string list. }
function TeamInList(const L: array of string; const Name: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(L) do
    if SameText(L[i], Name) then Exit(True);
end;

{ Names a team (or group/workflow) may never take: CLI verbs, bus keywords
  and the hub's own authoring identity ('pizarra' signs workflow notices). }
function ReservedName(const N: string): Boolean;
begin
  { Keep this list in pzconfig beside configuration loading so hub and client
    cannot diverge. A CLI verb cannot also be an addressable destination. }
  Result := IsCommandWord(N);
end;

{ Use the SAME validator for every name that becomes an INI section or disk
  path. Teams, applications, and workflows already required it; groups and
  projects did not, and their names were concatenated directly into
  '[group:<name>]'. A ']' and newline could therefore create ARBITRARY sections,
  including [header] and [server], in the file that holds the bus secret. This
  is structural injection, not merely inconsistent naming. }
function BadRegistryName(const Kind, N: string; out Why: string): Boolean;
begin
  Result := True;
  if Trim(N) = '' then
    Why := Kind + ' name required'
  else if not SafeName(N) then
    Why := 'invalid ' + Kind + ' name "' + N + '": only letters, digits, ' +
      '. _ - and it must start with a letter or digit'
  { Lexical validation is common to every kind because it prevents section
    injection. Reserved words are different: they apply only when the name is
    a message DESTINATION. Teams and groups are addressed by their bare names,
    so they cannot be named after commands. A project is not a destination, so
    forbidding names such as 'task' or 'app' would be an artificial restriction. }
  else if (not SameText(Kind, 'project')) and ReservedName(N) then
    Why := '"' + N + '" is a reserved word and cannot name a ' + Kind
  else
    Result := False;
end;


{ delivery transport tag for the journal/log }
function ViaOf(const Team: TTeam): string;
begin
  if Team.Dial then
    Result := 'dial'
  else if Team.Host <> '' then
    Result := 'push'
  else if Team.TmuxSession = '' then
    Result := 'inbox'
  else
    Result := 'tmux';
end;

{ ---------- TWatchdog ---------- }

constructor TWatchdog.Create(AOwner: TPizarra);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TWatchdog.Execute;
var
  i, waited: Integer;
  C: TPizarraConfig;
  StartWhy: string;
begin
  while not Terminated do
  begin
    C := FOwner.Snap;
    { local teams only: remote (host push) and dial-in teams live on their tiza
      daemon, not here — never try to manage a tmux session they do not have }
    for i := 0 to High(C.Teams) do
      if (C.Teams[i].Host = '') and (not C.Teams[i].Dial)
         and (C.Teams[i].TmuxSession <> '') then
      begin
        FOwner.FLock.Enter;
        try
          if SessionExists(C.Teams[i].TmuxSession) then
            TagSession(C.Teams[i].TmuxSession, C.Teams[i].Name)
          else if C.Teams[i].Launch <> '' then
          begin
            FOwner.FLog.Info('watchdog: respawning session ' +
              C.Teams[i].TmuxSession);
            { Start the worker in its own source tree, not the hub directory. }
            if EnsureSessionDetailed(C.Teams[i].TmuxSession,
              C.Teams[i].Launch, C.Teams[i].Workdir, C.Teams[i].User,
              StartWhy) then
              TagSession(C.Teams[i].TmuxSession, C.Teams[i].Name);
            if StartWhy <> '' then
              FOwner.FLog.Info('watchdog: session ' +
                C.Teams[i].TmuxSession + ' not started: ' + StartWhy);
          end;
          { An empty launch deliberately describes a manually managed session:
            deliver/tag it when present, but do not claim a respawn that cannot
            happen or hammer tmux every tick while it is absent. }
        finally
          FOwner.FLock.Leave;
        end;
      end;
    FOwner.EnsureSharedDirs;
    { redeliver anything still pending (team was down / session broken) }
    try
      FOwner.RetryPending;
    except
      on E: Exception do
        FOwner.FLog.Info('watchdog: retry error: ' + E.Message);
    end;
    { workflow upkeep - own guard so a workflow bug can never starve the
      session respawn or the redelivery duty above }
    try
      FOwner.WfMaintain;
    except
      on E: Exception do
        FOwner.FLog.Info('watchdog: workflow error: ' + E.Message);
    end;
    { activity upkeep: re-fire blocked alarms (rate-limited) and, in Phase 3,
      detect group quiescence — own guard, never starves the duties above }
    try
      FOwner.ActivityMaintain;
    except
      on E: Exception do
        FOwner.FLog.Info('watchdog: activity error: ' + E.Message);
    end;
    { advertise the hub release to every push daemon (one ping per unique
      host:port, fire-and-forget): an autoupdate daemon self-updates within
      one tick of a new hub build. Dial daemons get it via keepalives. }
    try
      FOwner.PingPushHosts(C);
    except
      on E: Exception do
        FOwner.FLog.Info('watchdog: ping error: ' + E.Message);
    end;
    { interruptible sleep }
    waited := 0;
    while (waited < WATCHDOG_INTERVAL) and (not Terminated) do
    begin
      Sleep(1000);
      Inc(waited);
    end;
  end;
end;

{ ---------- TWatcher ---------- }

constructor TWatcher.Create(const AScope: string = '');
begin
  inherited Create;
  Queue := TStringList.Create;
  Lock := TCriticalSection.Create;
  Scope := AScope;
  DroppedMax := -1;   { -1 = nothing discarded; 0 is a valid sequence }
  DroppedUnseq := False;
end;

{ The contract predicate and sole decision point for durable-message
  visibility. Group sends create one durable record per concrete recipient, so
  no group-membership lookup is needed here. }
function TWatcher.Sees(const M: TPzMsg): Boolean;
begin
  Result := (Scope = '') or
            SameText(M.Dest, Scope) or SameText(M.From, Scope);
end;

destructor TWatcher.Destroy;
begin
  Lock.Free;
  Queue.Free;
  inherited Destroy;
end;

procedure TWatcher.Push(const Line: string; Seq: Int64);
var
  Dropped: Int64;
begin
  Lock.Enter;
  try
    if Queue.Count >= WATCH_QUEUE_MAX then
    begin
      { For a slow client, retain the discarded sequence rather than a flag.
        Replay overlap later determines whether it was an actual loss. }
      Dropped := Int64(PtrInt(Queue.Objects[0]));
      if Dropped = 0 then
        DroppedUnseq := True   { sys/task events cannot be replayed; dropping
                                  them is a real loss }
      else if Dropped > DroppedMax then
        DroppedMax := Dropped;
      Queue.Delete(0);
    end;
    Queue.AddObject(Line, TObject(PtrInt(Seq)));
  finally
    Lock.Leave;
  end;
end;

{ Typed entry point: enforce scope before serialization and queuing. The
  generic Push path no longer has structured sender/destination fields and must
  never reparse generated JSON for authorization. }
procedure TWatcher.PushMsg(const M: TPzMsg);
begin
  if not Sees(M) then
    Exit;
  Push(EvMsg(M), M.Seq);
end;

{ Returns and clears the greatest discarded visible sequence; -1 means none. }
function TWatcher.TakeDropped(out Unsequenced: Boolean): Int64;
begin
  Lock.Enter;
  try
    Result := DroppedMax;
    Unsequenced := DroppedUnseq;
    DroppedMax := -1;
    DroppedUnseq := False;
  finally
    Lock.Leave;
  end;
end;

function TWatcher.Pop(out Line: string; out Seq: Int64): Boolean;
begin
  Seq := 0;
  Lock.Enter;
  try
    { Pop cannot distinguish real loss from an item already included in replay.
      DoWatch makes that decision with TakeDropped. }
    Result := Queue.Count > 0;
    if Result then
    begin
      Line := Queue[0];
      Seq := PtrInt(Queue.Objects[0]);
      Queue.Delete(0);
    end
    else
      Line := '';
  finally
    Lock.Leave;
  end;
end;

{ ---------- TDialChannel ---------- }

constructor TDialChannel.Create(const ATeams: TStringArray;
  const AFrom, ABound: string);
begin
  inherited Create;
  { Names arrive canonicalized and authorized by the hub; no client claim is
    accepted here. }
  Teams := ATeams;
  From := AFrom;
  Bound := ABound;
  Items := nil;
  Lock := TCriticalSection.Create;
end;

destructor TDialChannel.Destroy;
begin
  Lock.Free;
  Items := nil;
  inherited Destroy;
end;

function TDialChannel.Serves(const Team: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Teams) do
    if SameText(Teams[i], Team) then Exit(True);
end;

procedure TDialChannel.Drop(const Team: string);
var
  i, n: Integer;
  Q: TStringArray;
begin
  { Stop serving a team. The caller holds the channel-list lock. }
  Lock.Enter;
  try
    Q := nil;
    SetLength(Q, Length(Teams));
    n := 0;
    for i := 0 to High(Teams) do
      if not SameText(Teams[i], Team) then
      begin
        Q[n] := Teams[i];
        Inc(n);
      end;
    SetLength(Q, n);
    Teams := Q;
  finally
    Lock.Leave;
  end;
end;

procedure TDialChannel.Push(const Line, Team: string; Seq: Int64);
var i: Integer;
begin
  Lock.Enter;
  try
    { A still-queued sequence (which RetryPending may re-offer) is not added
      twice. Control lines use negative Seq values and are not deduplicated. }
    if Seq >= 0 then
      for i := 0 to High(Items) do
        if Items[i].Seq = Seq then Exit;
    if Length(Items) >= WATCH_QUEUE_MAX then
      Delete(Items, 0, 1);   { bound the backlog; the daemon replays on reconnect }
    SetLength(Items, Length(Items) + 1);
    Items[High(Items)].Line := Line;
    Items[High(Items)].Team := Team;
    Items[High(Items)].Seq := Seq;
  finally
    Lock.Leave;
  end;
end;

function TDialChannel.Pop(out Line, Team: string; out Seq: Int64): Boolean;
begin
  Seq := 0;
  Line := '';
  Team := '';
  Lock.Enter;
  try
    Result := Length(Items) > 0;
    if Result then
    begin
      Line := Items[0].Line;
      Team := Items[0].Team;
      Seq := Items[0].Seq;
      Delete(Items, 0, 1);
    end;
  finally
    Lock.Leave;
  end;
end;

{ ---------- TPizarra ---------- }


function ReadLegacyAppDoc(const C: TPizarraConfig; const Name: string;
  out Present: Boolean; out Body, Err: string): Boolean; forward;

{ Credential-safe durable binary copy used by the backup artifact. }
function CopyFileTo(const Src, Dst: string; out Err: string): Boolean;
var
  A, B: TFileStream;
  H, ErrNo: Integer;
begin
  Result := False;
  Err := '';
  try
    { Open for shared reads. On Unix FileOpen always applies flock and the share
      bits select its mode; the default fmShareCompat would take LOCK_EX and
      make concurrent configuration reads fail. }
    A := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      B := TFileStream.Create(Dst, fmCreate, &600);
      try
        B.CopyFrom(A, 0);
      finally
        B.Free;
      end;
    finally
      A.Free;
    end;
    if FpChmod(Dst, &600) <> 0 then
    begin
      ErrNo := fpgeterrno;
      Err := 'cannot protect ' + Dst + ': ' + SysErrorMessage(ErrNo);
      DeleteFile(Dst);
      Exit;
    end;
    H := FpOpen(Dst, O_RDONLY);
    if H < 0 then
    begin
      Err := 'cannot reopen ' + Dst + ' for fsync';
      DeleteFile(Dst);
      Exit;
    end;
    try
      if PzFsync(H) <> 0 then
      begin
        Err := 'cannot fsync ' + Dst + ': ' + SysErrorMessage(fpgeterrno);
        DeleteFile(Dst);
        Exit;
      end;
    finally
      FpClose(H);
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      DeleteFile(Dst);
    end;
  end;
end;

{ Registry state lives in org.sqlite; pizarra.conf is bootstrap plus one-time
  legacy migration input. }

{ Open the databases, upgrade their schemas, import legacy INI declarations
  exactly once, and then replace the registry arrays from org.sqlite. SQLite
  failure is fatal: falling back to a partial INI after the cutover could
  resurrect deleted identities and discard database-only manuals/relations. }
{ Defined later but needed during startup. }
function TeamRowDb(const T: TTeam): string; forward;

procedure TPizarra.OpenRegistryDb;
var
  Err, Doc, Row, Sec, Key, Role, ConfigBackup, PrecutoverDir,
    AuthorityMarker,
    CutoverLockPath: string;
  Names, Teams, Repos, Paths, Purposes, Details, Docs, DocPresent: TStringList;
  TeamRows, GroupRows, ProjectRows, TaskRows, NoteRows: TStringList;
  Keys, Relations: TStringList;
  Tasks: TTaskArray;
  Parts: TStringArray;
  Ini: TIniFile;
  LoadedCfg, ExistingCfg: TPizarraConfig;
  F: TPzDbFile;
  i, j, N, NDocs, NTk, NNo, NImp, CutoverLockFd: Integer;
  FirstRegistry, FirstTasks, HasExistingDb, ExistingPair, HasLegacyDoc: Boolean;

  function Fld(const S: string): string;
  begin
    Result := RowFieldEncode(S);
  end;

  function Csv(const Values: TStringArray): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 0 to High(Values) do
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + Values[k];
    end;
  end;

  function SameList(const A, B: TStringArray): Boolean;
  var
    k: Integer;
  begin
    if Length(A) <> Length(B) then
      Exit(False);
    for k := 0 to High(A) do
      if A[k] <> B[k] then
        Exit(False);
    Result := True;
  end;

  { A marker-less database may already contain valuable rows. Reconciliation
    is allowed only when every overlapping legacy value agrees. New columns
    added for this cutover may still hold their schema default and are then
    filled from the INI. Database-only rows are retained; an ID collision is
    never guessed to be a rename. }
  function CutoverCompatible(const Legacy, DbCfg: TPizarraConfig;
    RequireNewFields: Boolean; out Why: string): Boolean;
  var
    a, b: Integer;
    Found: Boolean;
    LT, DT: TTeam;
    LG, DG: TGroup;
  begin
    Result := False;
    Why := '';
    for a := 0 to High(Legacy.Teams) do
    begin
      Found := False;
      LT := Legacy.Teams[a];
      for b := 0 to High(DbCfg.Teams) do
        if SameText(LT.Name, DbCfg.Teams[b].Name) then
        begin
          Found := True;
          DT := DbCfg.Teams[b];
          if (LT.Id <> DT.Id) or (LT.Speciality <> DT.Speciality) or
             (LT.Prompt <> DT.Prompt) or (LT.Parent <> DT.Parent) or
             (LT.Project <> DT.Project) or (LT.Secret <> DT.Secret) or
             (LT.Host <> DT.Host) or (LT.Port <> DT.Port) or
             (LT.Dial <> DT.Dial) or (LT.TmuxSession <> DT.TmuxSession) or
             (LT.Launch <> DT.Launch) or (LT.User <> DT.User) or
             (LT.Slave <> DT.Slave) or (LT.Workdir <> DT.Workdir) then
          begin
            Why := 'team "' + LT.Name + '" differs between INI and SQLite';
            Exit;
          end;
          if RequireNewFields then
          begin
            if (LT.Delegate <> DT.Delegate) or
               (LT.HoldBlocked <> DT.HoldBlocked) then
            begin
              Why := 'team "' + LT.Name +
                '" lost delegate/hold policy during verification';
              Exit;
            end;
          end
          else if ((DT.Delegate <> '') and (DT.Delegate <> LT.Delegate)) or
                  (DT.HoldBlocked and (not LT.HoldBlocked)) then
          begin
            Why := 'team "' + LT.Name +
              '" has conflicting SQLite-only delegate/hold policy';
            Exit;
          end;
          Break;
        end;
      if not Found then
      begin
        for b := 0 to High(DbCfg.Teams) do
          if LT.Id = DbCfg.Teams[b].Id then
          begin
            Why := Format('team id %d is "%s" in INI but "%s" in SQLite; ' +
              'refusing to guess a rename',
              [LT.Id, LT.Name, DbCfg.Teams[b].Name]);
            Exit;
          end;
        if RequireNewFields then
        begin
          Why := 'team "' + LT.Name + '" is missing after migration';
          Exit;
        end;
      end;
    end;
    for a := 0 to High(Legacy.Groups) do
    begin
      Found := False;
      LG := Legacy.Groups[a];
      for b := 0 to High(DbCfg.Groups) do
        if SameText(LG.Name, DbCfg.Groups[b].Name) then
        begin
          Found := True;
          DG := DbCfg.Groups[b];
          if (LG.Project <> DG.Project) or (LG.Boss <> DG.Boss) or
             (not SameList(LG.Members, DG.Members)) or
             (not SameList(LG.Excluded, DG.Excluded)) then
          begin
            Why := 'group "' + LG.Name +
              '" differs between INI and SQLite';
            Exit;
          end;
          if RequireNewFields then
          begin
            if (LG.OnIdle <> DG.OnIdle) or (LG.OnIdleMsg <> DG.OnIdleMsg) or
               (LG.OnIdleFrom <> DG.OnIdleFrom) or
               (LG.OnIdleReply <> DG.OnIdleReply) or
               (LG.HdrNote <> DG.HdrNote) or (LG.OnBlock <> DG.OnBlock) then
            begin
              Why := 'group "' + LG.Name +
                '" lost a policy field during verification';
              Exit;
            end;
          end
          else if ((DG.OnIdle <> '') and (DG.OnIdle <> LG.OnIdle)) or
                  ((DG.OnIdleMsg <> '') and (DG.OnIdleMsg <> LG.OnIdleMsg)) or
                  ((DG.OnIdleFrom <> '') and (DG.OnIdleFrom <> LG.OnIdleFrom)) or
                  ((DG.OnIdleReply <> '') and (DG.OnIdleReply <> LG.OnIdleReply)) or
                  ((DG.HdrNote <> '') and (DG.HdrNote <> LG.HdrNote)) or
                  ((DG.OnBlock <> '') and (DG.OnBlock <> LG.OnBlock)) then
          begin
            Why := 'group "' + LG.Name +
              '" has conflicting SQLite-only policy fields';
            Exit;
          end;
          Break;
        end;
      if RequireNewFields and (not Found) then
      begin
        Why := 'group "' + LG.Name + '" is missing after migration';
        Exit;
      end;
    end;
    for a := 0 to High(Legacy.Projects) do
    begin
      Found := False;
      for b := 0 to High(DbCfg.Projects) do
        if SameText(Legacy.Projects[a].Name, DbCfg.Projects[b].Name) then
        begin
          Found := True;
          if Legacy.Projects[a].Boss <> DbCfg.Projects[b].Boss then
          begin
            Why := 'project "' + Legacy.Projects[a].Name +
              '" differs between INI and SQLite';
            Exit;
          end;
          Break;
        end;
      if RequireNewFields and (not Found) then
      begin
        Why := 'project "' + Legacy.Projects[a].Name +
          '" is missing after migration';
        Exit;
      end;
    end;
    for a := 0 to High(Legacy.Apps) do
    begin
      Found := False;
      for b := 0 to High(DbCfg.Apps) do
        if SameText(Legacy.Apps[a].Name, DbCfg.Apps[b].Name) then
        begin
          Found := True;
          if (Legacy.Apps[a].Team <> DbCfg.Apps[b].Team) or
             (Legacy.Apps[a].Repo <> DbCfg.Apps[b].Repo) or
             (Legacy.Apps[a].Path <> DbCfg.Apps[b].Path) or
             (Legacy.Apps[a].Purpose <> DbCfg.Apps[b].Purpose) or
             (Legacy.Apps[a].Detail <> DbCfg.Apps[b].Detail) then
          begin
            Why := 'application "' + Legacy.Apps[a].Name +
              '" differs between INI and SQLite';
            Exit;
          end;
          Break;
        end;
      if RequireNewFields and (not Found) then
      begin
        Why := 'application "' + Legacy.Apps[a].Name +
          '" is missing after migration';
        Exit;
      end;
    end;
    Result := True;
  end;

begin
  if not SameText(FCfg.RegistryAuthority, 'sqlite') then
    raise Exception.Create('[registry] authority must be sqlite; the INI is ' +
      'migration input only, never a second live registry');
  FDb := TPzDb.Create(FCfg.StoreDir);
  if not FDb.Available then
    raise Exception.Create('SQLite registry unavailable: ' + FDb.Unavailable);
  { Determine authority before schema upgrades. A populated pre-cutover store
    gets an online physical snapshot before any ALTER/copy/reconciliation. }
  F := FDb.OrgDb;
  AuthorityMarker := FDb.MetaGet(F, 'registry_authority');
  FirstRegistry := AuthorityMarker = '';
  if (not FirstRegistry) and (AuthorityMarker <> 'sqlite-v1') then
    raise Exception.Create('unsupported SQLite registry authority marker: ' +
      AuthorityMarker + ' (expected sqlite-v1)');
  CutoverLockPath := '';
  if FirstRegistry then
  begin
    CutoverLockPath := IncludeTrailingPathDelimiter(FCfg.StoreDir) +
      '.registry-cutover.lock';
    CutoverLockFd := FpOpen(CutoverLockPath,
      O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW, &600);
    if CutoverLockFd < 0 then
      raise Exception.Create('cannot acquire exclusive SQLite cutover lock ' +
        CutoverLockPath + ': ' + SysErrorMessage(fpgeterrno) +
        '. Stop every other hub/migrator; remove a stale lock only after ' +
        'confirming no cutover is running.');
    FpClose(CutoverLockFd);
  end;
  try
  HasExistingDb := FDb.QueryInt(F,
    'SELECT COUNT(*) FROM sqlite_master WHERE type=''table'';') > 0;
  F := FDb.AppsDb;
  HasExistingDb := HasExistingDb or (FDb.QueryInt(F,
    'SELECT COUNT(*) FROM sqlite_master WHERE type=''table'';') > 0);
  F := FDb.WorkDb;
  HasExistingDb := HasExistingDb or (FDb.QueryInt(F,
    'SELECT COUNT(*) FROM sqlite_master WHERE type=''table'';') > 0);
  if FirstRegistry and HasExistingDb then
  begin
    PrecutoverDir := IncludeTrailingPathDelimiter(FCfg.StoreDir) +
      'backups/pre-registry-sqlite-' +
      FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + IntToStr(FpGetpid);
    if not FDb.BackupTo(PrecutoverDir, Err) then
      raise Exception.Create('could not create mandatory pre-cutover SQLite ' +
        'backup: ' + Err);
    FLog.Info('mandatory pre-cutover SQLite backup: ' + PrecutoverDir);
  end;
  if not FDb.EnsureSchema(Err) then
    raise Exception.Create('SQLite registry schema failed: ' + Err);
  FLog.Info('SQLite ' + FDb.LibVersion + ': registries in ' + FDb.Dir);
  F := FDb.WorkDb;
  FirstTasks := FDb.MetaGet(F, 'ini_migrated') = '';
  N := 0; NDocs := 0; NTk := 0; NNo := 0; NImp := 0;

  Names := TStringList.Create; Teams := TStringList.Create;
  Repos := TStringList.Create; Paths := TStringList.Create;
  Purposes := TStringList.Create; Details := TStringList.Create;
  Docs := TStringList.Create; DocPresent := TStringList.Create;
  TeamRows := TStringList.Create;
  GroupRows := TStringList.Create; ProjectRows := TStringList.Create;
  TaskRows := TStringList.Create; NoteRows := TStringList.Create;
  Keys := TStringList.Create; Relations := TStringList.Create;
  Ini := nil;
  try
    if FirstRegistry then
    begin
      ExistingCfg := FCfg;
      if not FDb.LoadRegistry(ExistingCfg, Err) then
        raise Exception.Create('could not inspect existing SQLite registry ' +
          'before cutover: ' + Err);
      if not CutoverCompatible(FCfg, ExistingCfg, False, Err) then
        raise Exception.Create('SQLite cutover conflict: ' + Err +
          '. No legacy values were applied; reconcile the two sources ' +
          'explicitly instead of allowing an automatic overwrite.');
      for i := 0 to High(FCfg.Apps) do
      begin
        Names.Add(FCfg.Apps[i].Name);
        Teams.Add(FCfg.Apps[i].Team);
        Repos.Add(FCfg.Apps[i].Repo);
        Paths.Add(FCfg.Apps[i].Path);
        Purposes.Add(FCfg.Apps[i].Purpose);
        Details.Add(FCfg.Apps[i].Detail);
        if not ReadLegacyAppDoc(FCfg, FCfg.Apps[i].Name, HasLegacyDoc,
          Doc, Err) then
          raise Exception.Create('cannot preserve legacy manual for app "' +
            FCfg.Apps[i].Name + '": ' + Err);
        Docs.Add(Doc);
        DocPresent.Add(BoolToStr(HasLegacyDoc, '1', '0'));
      end;
      for i := 0 to High(FCfg.Teams) do
        TeamRows.Add(TeamRowDb(FCfg.Teams[i]));
      for i := 0 to High(FCfg.Groups) do
      begin
        Row := FCfg.Groups[i].Name + #1 + FCfg.Groups[i].Project + #1 +
          FCfg.Groups[i].Boss + #1 + Csv(FCfg.Groups[i].Members) + #1 +
          Csv(FCfg.Groups[i].Excluded) + #1 + Fld(FCfg.Groups[i].OnIdle) + #1 +
          Fld(FCfg.Groups[i].OnIdleMsg) + #1 + Fld(FCfg.Groups[i].OnIdleFrom) +
          #1 + Fld(FCfg.Groups[i].OnIdleReply) + #1 +
          Fld(FCfg.Groups[i].HdrNote) + #1 + Fld(FCfg.Groups[i].OnBlock);
        GroupRows.Add(Row);
      end;
      for i := 0 to High(FCfg.Projects) do
        ProjectRows.Add(FCfg.Projects[i].Name + #1 + FCfg.Projects[i].Boss);

      if not FDb.ImportMissing(Names, Teams, Repos, Paths, Purposes,
        Details, TeamRows, GroupRows, ProjectRows, NImp, Err) then
        raise Exception.Create('legacy INI registry import failed: ' + Err);
      if not FDb.MigrateApps(Names, Teams, Repos, Paths, Purposes,
        Details, Docs, DocPresent, N, NDocs, Err) then
        raise Exception.Create('legacy application/manual import failed: ' + Err);

      { The old projects= line was only a mirror; role.PROJECT carried the
        relationship detail. Import the union before removing either section.
        Existing DB-only pairs remain and an omitted role never erases one. }
      Ini := OpenPrivateIniFile(FCfgPath);
      Relations.CaseSensitive := False;
      Relations.Sorted := True;
      Relations.Duplicates := dupIgnore;
      for i := 0 to High(FCfg.Apps) do
      begin
        Relations.Clear;
        Parts := SplitList(FCfg.Apps[i].Projects);
        for j := 0 to High(Parts) do
          Relations.Add(Parts[j]);
        Keys.Clear;
        Sec := 'app:' + FCfg.Apps[i].Name;
        Ini.ReadSection(Sec, Keys);
        for j := 0 to Keys.Count - 1 do
          if (Length(Keys[j]) > 5) and
             SameText(Copy(Keys[j], 1, 5), 'role.') then
            Relations.Add(Copy(Keys[j], 6, Length(Keys[j])));
        for j := 0 to Relations.Count - 1 do
        begin
          Key := Relations[j];
          F := FDb.OrgDb;
          if FDb.QueryInt(F, 'SELECT COUNT(*) FROM project WHERE name=' +
            Q(Key) + ';') = 0 then
            raise Exception.Create(Format('legacy app %s references unknown ' +
              'project %s; migration marker was not written',
              [FCfg.Apps[i].Name, Key]));
          Role := Ini.ReadString(Sec, 'role.' + Key, '');
          F := FDb.OrgDb;
          ExistingPair := FDb.QueryInt(F,
            'SELECT COUNT(*) FROM app_project WHERE app=' +
            Q(FCfg.Apps[i].Name) + ' AND project=' + Q(Key) + ';') > 0;
          if ExistingPair then
          begin
            if (Role <> '') and
               (FDb.QueryStr(F, 'SELECT role FROM app_project WHERE app=' +
                 Q(FCfg.Apps[i].Name) + ' AND project=' + Q(Key) + ';') <>
                 Role) then
              raise Exception.Create('SQLite cutover conflict: role for app "' +
                FCfg.Apps[i].Name + '" in project "' + Key +
                '" differs between legacy INI and SQLite');
            Continue;  { already preserved; do not add duplicate audit history }
          end;
          if not FDb.AppProjectSet(FCfg.Apps[i].Name, Key, Role,
            'migration', Err) then
            raise Exception.Create('legacy app/project import failed: ' + Err);
        end;
      end;
      FreeAndNil(Ini);
    end;

    if FirstTasks then
    begin
      Tasks := FTasks.List('all', '');
      for i := 0 to High(Tasks) do
      begin
        TaskRows.Add(IntToStr(Tasks[i].Id) + #1 + Fld(Tasks[i].Title) + #1 +
          Fld(Tasks[i].Team) + #1 + Fld(Tasks[i].StateS) + #1 +
          Fld(Tasks[i].Hito) + #1 + IntToStr(Tasks[i].Parent) + #1 +
          Fld(Tasks[i].Created) + #1 + Fld(Tasks[i].Closed));
        for j := 0 to High(Tasks[i].Notes) do
          NoteRows.Add(IntToStr(Tasks[i].Id) + #1 +
            Fld(Tasks[i].Notes[j].Ts) + #1 + Fld(Tasks[i].Notes[j].By) + #1 +
            Fld(Tasks[i].Notes[j].Text));
      end;
      if not FDb.MigrateTasks(TaskRows, NoteRows, NTk, NNo, Err) then
        raise Exception.Create('legacy task import failed: ' + Err);
    end;

    LoadedCfg := FCfg;
    if not FDb.LoadRegistry(LoadedCfg, Err) then
      raise Exception.Create('could not load authoritative registry: ' + Err);
    if FirstRegistry and
       (not CutoverCompatible(FCfg, LoadedCfg, True, Err)) then
      raise Exception.Create('SQLite cutover verification failed: ' + Err +
        '; migration marker was not written');
    ValidateParents(LoadedCfg);
    if not SecretsCoherent(LoadedCfg, Err) then
      raise Exception.Create('authoritative registry credentials: ' + Err);
    if FirstRegistry then
    begin
      { This marker is written LAST. Every preceding import is idempotent, so
        an interrupted cutover simply retries without declaring a partial DB
        authoritative. }
      if not StripLegacyRegistryIni(FCfgPath, ConfigBackup, Err) then
        raise Exception.Create('could not reduce pizarra.conf to bootstrap ' +
          'configuration: ' + Err);
      F := FDb.OrgDb;
      if not FDb.MetaSet(F, 'registry_authority', 'sqlite-v1', Err) then
        raise Exception.Create('could not commit SQLite registry authority: ' + Err);
      FLog.Info(Format('SQLite registry cutover verified: %d teams, %d groups, ' +
        '%d projects, %d apps (%d legacy rows reconciled)',
        [Length(LoadedCfg.Teams), Length(LoadedCfg.Groups),
         Length(LoadedCfg.Projects), Length(LoadedCfg.Apps), NImp]));
      if ConfigBackup <> '' then
        FLog.Info('legacy registry INI preserved at ' + ConfigBackup);
    end;
    FCfg := LoadedCfg;
  finally
    Ini.Free;
    Names.Free; Teams.Free; Repos.Free; Paths.Free; Purposes.Free;
    Details.Free; Docs.Free; DocPresent.Free; TeamRows.Free;
    GroupRows.Free; ProjectRows.Free;
    TaskRows.Free; NoteRows.Free; Keys.Free; Relations.Free;
  end;
  finally
    if CutoverLockPath <> '' then
      DeleteFile(CutoverLockPath);
  end;
end;

var
  GAmbigWhen: QWord = 0;
  GAmbigTeam: string = '';
  GAmbigVal: string = '';

{ OtherSessionsLike forks `tmux list-sessions`. Cache its result per team for
  30 seconds because it changes only when sessions are created or destroyed. }
function AmbiguousSessions(const TeamName, Configured: string): string;
begin
  if (GAmbigTeam = TeamName) and (GetTickCount64 < GAmbigWhen + 30000) then
    Exit(GAmbigVal);
  GAmbigVal := OtherSessionsLike(TeamName, Configured);
  GAmbigTeam := TeamName;
  GAmbigWhen := GetTickCount64;
  Result := GAmbigVal;
end;

{ Count sessions in a comma-separated list. }
function CountCommas(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if S[i] = ',' then
      Inc(Result);
end;

function LastBackupHint(const StoreDir: string): string;
var
  Info: TSearchRec;
  Best, Dir: string;
begin
  Result := '';
  if Trim(StoreDir) = '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(StoreDir) + 'backups';
  if not DirectoryExists(Dir) then
    Exit;
  Best := '';
  if FindFirst(Dir + '/*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Name <> '.') and (Info.Name <> '..') and (Info.Name > Best) then
        Best := Info.Name;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  if Best <> '' then
    Result := ' The most recent backup is ' + Dir + '/' + Best +
      ' (check it with: tiza backup verify <path>).';
end;

constructor TPizarra.Create(const ConfigPath: string);
var
  i: Integer;
  ErrS, LogDir: string;
begin
  inherited Create;
  FHubStoreLock := -1;
  FCfgPath := ExpandFileName(ConfigPath);
  FCfgLock := TCriticalSection.Create;
  FPutLock := TCriticalSection.Create;
  FActLock := TCriticalSection.Create;
  FCfg := LoadPizarraConfig(ConfigPath);
  { An empty global secret would authorize an unauthenticated request. Refuse
    startup and include a recovery hint because this often indicates a
    truncated or incorrectly edited configuration. }
  if FCfg.Secret = '' then
    raise Exception.Create('[server] secret is empty — refusing to start ' +
      '(set a shared secret in the config).' + LastBackupHint(FCfg.StoreDir));
  { Protect the state tree before TPzStore/TTaskStore/TWorkflowStore can create
    files or subdirectories in it. FPC 3.2.2 ForceDirectories creates 0777
    subject to umask; postponing this check until TPzDb made a first custom
    start create 0755 state and then reject its own directory. }
  if not EnsurePrivateRuntimeDir(FCfg.StoreDir, ErrS) then
    raise Exception.Create('unsafe [store] dir: ' + ErrS);
  if not PzAcquireHubStoreLock(FCfg.StoreDir, True, FHubStoreLock, ErrS) then
    raise Exception.Create('cannot own [store] dir: ' + ErrS);
  if Trim(FCfg.LogPath) = '' then
    raise Exception.Create('[log] path must not be empty');
  LogDir := ExtractFileDir(ExpandFileName(FCfg.LogPath));
  if not EnsurePrivateRuntimeDir(LogDir, ErrS) then
    raise Exception.Create('unsafe [log] directory: ' + ErrS);
  FLog := TPzLog.Create(FCfg.LogPath);
  FStore := TPzStore.Create(FCfg.StoreDir);
  FTasks := TTaskStore.Create(
    IncludeTrailingPathDelimiter(FCfg.StoreDir) + 'tareas.json');
  FWf := TWorkflowStore.Create(
    IncludeTrailingPathDelimiter(FCfg.StoreDir) + 'workflows.json', FTasks);
  OpenRegistryDb;
  { Team credentials now come from the authoritative database, so coherence
    must be checked AFTER the typed DB projection, never against legacy INI
    migration input. Diagnostics name teams and never reveal secrets. }
  if not SecretsCoherent(FCfg, ErrS) then
    raise Exception.Create('registry: ' + ErrS + ' — refusing to start.');
  FTasks.SetDb(FDb);   { task mutations are historical from this point }
  FLock := TCriticalSection.Create;
  FWatchers := TThreadList.Create;
  FDialChannels := TThreadList.Create;
  FAttachLock := TCriticalSection.Create;
  FAttachTotal := 0;
  FAttachPer := TStringList.Create;
  FAttachWaits := TThreadList.Create;
  FShellLock := TCriticalSection.Create;
  FShellTotal := 0;
  FShellPer := TStringList.Create;
  FShellWaits := TThreadList.Create;
  { broadcast inside the store lock: strict seq order on watch streams }
  FStore.OnAppend := @OnStoreAppend;
  { mark every team a delivery target so compaction protects undelivered
    messages by the delivered mark, not an inbox cursor }
  for i := 0 to High(FCfg.Teams) do
    FStore.EnsureDest(FCfg.Teams[i].Name);
  { 'workflow'/'wf'/'pizarra' became reserved with the workflow engine: a
    pre-existing team/group squatting one of them breaks addressing }
  for i := 0 to High(FCfg.Teams) do
    if ReservedName(FCfg.Teams[i].Name) then
      Writeln(StdErr, 'pizarra: WARNING: team name "', FCfg.Teams[i].Name,
        '" is now reserved - rename it (edit config + restart)');
  for i := 0 to High(FCfg.Groups) do
    if ReservedName(FCfg.Groups[i].Name) then
      Writeln(StdErr, 'pizarra: WARNING: group name "', FCfg.Groups[i].Name,
        '" is now reserved - rename it (edit config + restart)');
end;

destructor TPizarra.Destroy;
begin
  { Close databases first to consolidate WAL state before external copying or
    inspection. }
  FreeAndNil(FDb);
  FWatchers.Free;
  FDialChannels.Free;
  FShellWaits.Free;
  FShellPer.Free;
  FShellLock.Free;
  FAttachWaits.Free;
  FAttachPer.Free;
  FAttachLock.Free;
  FCfgLock.Free;
  FPutLock.Free;
  FActLock.Free;
  FLock.Free;
  FWf.Free;
  FTasks.Free;
  FStore.Free;
  FLog.Free;
  { Keep the ownership lock until SQLite, journals, tasks, and workflows have
    all closed. Restore can acquire it only after every state handle is gone. }
  PzReleaseHubStoreLock(FHubStoreLock);
  inherited Destroy;
end;

{ Generic path for sys/task events without a structured audience. Their free
  text and zero sequence cannot support authorization, so only an unscoped
  global-console watcher receives them. }
procedure TPizarra.Broadcast(const Line: string; Seq: Int64);
var
  L: TList;
  i: Integer;
begin
  L := FWatchers.LockList;
  try
    for i := 0 to L.Count - 1 do
      if TWatcher(L[i]).Scope = '' then
        TWatcher(L[i]).Push(Line, Seq);
  finally
    FWatchers.UnlockList;
  end;
end;

{ Typed path for durable messages with sender and destination. Each watcher
  applies its own predicate before serialization. }
procedure TPizarra.BroadcastMsg(const M: TPzMsg);
var
  L: TList;
  i: Integer;
begin
  L := FWatchers.LockList;
  try
    for i := 0 to L.Count - 1 do
      TWatcher(L[i]).PushMsg(M);
  finally
    FWatchers.UnlockList;
  end;
end;

procedure TPizarra.OnStoreAppend(const M: TPzMsg);
begin
  BroadcastMsg(M);
end;

{ Hand a full delivery envelope to the dial-in channel serving Team, if one is
  connected. No-op (message stays pending) when the daemon is offline — it is
  replayed on reconnect. Access to the channel stays under the list lock so a
  concurrent DoDial teardown cannot free it mid-Push. }
procedure TPizarra.DialEnqueue(const Team, Envelope: string; Seq: Int64);
var
  L: TList;
  i: Integer;
  Ch: TDialChannel;
begin
  L := FDialChannels.LockList;
  try
    for i := 0 to L.Count - 1 do
    begin
      Ch := TDialChannel(L[i]);
      if Ch.Serves(Team) then
      begin
        Ch.Push(Envelope, Team, Seq);
        Exit;
      end;
    end;
  finally
    FDialChannels.UnlockList;
  end;
end;

{ Reverse delivery channel: a tiza daemon dialed in (outbound from its side, so
  NAT/dynamic-IP friendly) claiming the teams it hosts. We hold the connection,
  replay each team's undelivered backlog, then stream new deliveries as they are
  enqueued — one at a time, marking delivered only when the daemon acks. When
  idle we ping every KeepAlive seconds to hold the NAT mapping open and detect a
  dead peer. }
{ cmd=fleet: one row per host — release + online/offline. Push hosts are
  probed live (daemon cmd=ver, 1.2 s each: 3 dead hosts still fit the CLI's
  5 s budget); dial hosts read the held channel + its hello ver; local teams
  check their tmux session (they run this host's tiza binary). }

{ Require physical containment, not a lexical prefix. Walk each component from
  the shared root and reject symlinks so `..` cannot escape after link
  resolution. }
{ Linux exposes the resolved path behind a descriptor in /proc/self/fd/<n>. }
function FdRealPath(Fd: LongInt): string;
begin
  Result := fpReadLink('/proc/self/fd/' + IntToStr(Fd));
end;

function InsideShared(const Root, Path: string; out Why: string): Boolean;
var
  R, P, Acc, Rest: string;
  Parts: TStringArray;
  i: Integer;
  St: Stat;
begin
  Result := False;
  Why := '';
  St := Default(Stat);
  R := ExcludeTrailingPathDelimiter(ExpandFileName(Root));
  P := ExpandFileName(Path);
  if (Length(P) <= Length(R) + 1) or
     (Copy(P, 1, Length(R) + 1) <> R + PathDelim) then
  begin
    Why := 'path is outside the shared dir';
    Exit;
  end;
  Rest := Copy(P, Length(R) + 2, Length(P));
  Parts := SplitString(Rest, PathDelim);
  Acc := R;
  for i := 0 to High(Parts) do
  begin
    if (Parts[i] = '') or (Parts[i] = '.') or (Parts[i] = '..') then
    begin
      Why := 'malformed path component';
      Exit;
    end;
    Acc := Acc + PathDelim + Parts[i];
    { A put target may not exist yet; absence is not a symlink. }
    if fpLStat(Acc, St) = 0 then
      if fpS_ISLNK(St.st_mode) then
      begin
        Why := Format('"%s" is a symlink: it would leave the shared dir',
          [Parts[i]]);
        Exit;
      end;
  end;
  Result := True;
end;

var
  { Temporary-name counter; uniqueness matters, appearance does not. }
  GScratchSeq: LongInt = 0;

procedure AddFleetRow(Arr: TJSONArray; const Kind, Host, State, Ver,
  Teams: string);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  O.Add('kind', Kind);
  O.Add('host', Host);
  O.Add('state', State);
  O.Add('ver', Ver);
  O.Add('teams', Teams);
  Arr.Add(O);
end;

function TPizarra.IsHeld(const Team: string): Boolean;
var
  key: string;
  i: Integer;
begin
  Result := False;
  key := LowerCase(Trim(Team));
  if key = '' then
    Exit;
  FActLock.Enter;
  try
    for i := 0 to High(FActivity) do
      if FActivity[i].Team = key then
        Exit(FActivity[i].HoldAuto or FActivity[i].HoldManual);
  finally
    FActLock.Leave;
  end;
end;

function TPizarra.HeldForTeam(const Team: TTeam; out Why: string): Boolean;
var
  key: string;
  i: Integer;
begin
  Result := False;
  Why := '';
  key := LowerCase(Trim(Team.Name));
  if key = '' then
    Exit;
  FActLock.Enter;
  try
    for i := 0 to High(FActivity) do
      if FActivity[i].Team = key then
      begin
        if FActivity[i].HoldManual then
        begin Why := 'delivery is held by the operator'; Exit(True); end;
        if FActivity[i].HoldAuto then
        begin Why := 'is BLOCKED on a permission prompt'; Exit(True); end;
        { opt-in: hold on the DETECTED blocked state (pane heuristic), for a team
          that accepted that risk with hold_when_blocked }
        if Team.HoldBlocked and (FActivity[i].State = 'blocked') then
        begin Why := 'is BLOCKED on a permission prompt'; Exit(True); end;
        Exit(False);
      end;
  finally
    FActLock.Leave;
  end;
end;

procedure TPizarra.SetHoldManual(const Team: string; On_: Boolean);
var
  key: string;
  i, n: Integer;
  found: Boolean;
begin
  key := LowerCase(Trim(Team));
  if key = '' then
    Exit;
  found := False;
  FActLock.Enter;
  try
    for i := 0 to High(FActivity) do
      if FActivity[i].Team = key then
      begin
        FActivity[i].HoldManual := On_;
        found := True;
        Break;
      end;
    if not found then
    begin
      { a hold can precede any activity report: create a bare entry }
      n := Length(FActivity);
      SetLength(FActivity, n + 1);
      FActivity[n].Team := key;
      FActivity[n].State := '';
      FActivity[n].Since := Now;
      FActivity[n].HoldManual := On_;
    end;
  finally
    FActLock.Leave;
  end;
end;

function TPizarra.AlarmText(const Team, Note: string): string;
var
  C: TPizarraConfig;
  T: TTeam;
  where: string;
begin
  C := Snap;
  where := 'local';
  if FindTeam(C, Team, T) then
    if T.Host <> '' then
      where := Format('%s:%d', [T.Host, T.Port])
    else if T.TmuxSession <> '' then
      where := 'local tmux ' + T.TmuxSession;
  Result := Format('%s is BLOCKED on a permission prompt — go answer it (%s)',
    [Team, where]);
  if Trim(Note) <> '' then
    Result := Result + '  | ' + Trim(Note);
end;

function TPizarra.BlockLogOnly(const C: TPizarraConfig; const Team: string): Boolean;
var
  i: Integer;
begin
  { true iff the team belongs to a non-excluded group whose on_block=log — then
    a detected block is recorded in the log only, never alarmed. }
  Result := False;
  for i := 0 to High(C.Groups) do
    if (C.Groups[i].OnBlock = 'log') and TeamInList(C.Groups[i].Members, Team)
       and (not TeamInList(C.Groups[i].Excluded, Team)) then
      Exit(True);
end;

function TPizarra.ActivityOf(const Team: string; out AgeSecs: Integer;
  out Note: string): string;
var
  key: string;
  i: Integer;
begin
  Result := '';
  AgeSecs := 0;
  Note := '';
  key := LowerCase(Trim(Team));
  if key = '' then
    Exit;
  FActLock.Enter;
  try
    for i := 0 to High(FActivity) do
      if FActivity[i].Team = key then
      begin
        Result := FActivity[i].State;
        AgeSecs := Round((Now - FActivity[i].Since) * 86400);
        if AgeSecs < 0 then
          AgeSecs := 0;
        Note := FActivity[i].Note;
        Exit;
      end;
  finally
    FActLock.Leave;
  end;
end;

function TPizarra.ActivityLabel(const Team: string): string;
var
  age: Integer;
  note, st: string;
begin
  st := ActivityOf(Team, age, note);
  if st = '' then
    Exit('');
  if st = 'moving' then
    Result := 'moving'          { motion is instantaneous — no age }
  else
    Result := st + ' ' + AgeStr(age);   { quiet 3m / idle 5m / blocked 1m }
end;

function TPizarra.TeamsWithActivity(const TeamList: string): string;
var
  i, st: Integer;
  nm, lbl: string;
begin
  Result := '';
  st := 1;
  for i := 1 to Length(TeamList) + 1 do
    if (i > Length(TeamList)) or (TeamList[i] = ' ') then
    begin
      nm := Trim(Copy(TeamList, st, i - st));
      st := i + 1;
      if nm = '' then
        Continue;
      lbl := ActivityLabel(nm);
      if lbl <> '' then
        nm := nm + '(' + lbl + ')';
      if Result = '' then
        Result := nm
      else
        Result := Result + ' ' + nm;
    end;
end;

procedure TPizarra.HandleActivity(Obj: TJSONObject; const From, BoundTeam: string;
  Data: TSocketStream);
var
  State, note, key, alarm, logLine: string;
  holdRel, nowBlocked, wasBlocked, logOnly: Boolean;
  i, idx: Integer;
  C: TPizarraConfig;
  TF, TB: TTeam;
begin
  { A daemon reports the pane-activity of a team it hosts. Only the states we
    model are accepted, so a typo never poisons the map. }
  State := LowerCase(Trim(Obj.Get('state', '')));
  if (State <> 'moving') and (State <> 'quiet') and (State <> 'idle') and
     (State <> 'blocked') and (State <> 'busy') then
  begin
    WriteLine(Data, ReplyErr('unknown activity state: ' + State));
    Exit;
  end;
  { AUTHORIZE. A report for a team OTHER than the one the secret is bound to is
    allowed only when both are hosted on the SAME daemon (same host:port) — a
    multi-team host reporting its co-tenants. A global-secret sender (BoundTeam
    empty) is trusted as-is; from=BoundTeam is always its own. This is the guard
    the dispatch deliberately skipped for CMD_ACTIVITY. }
  if (BoundTeam <> '') and (not SameText(From, BoundTeam)) then
  begin
    C := Snap;
    if not (FindTeam(C, From, TF) and FindTeam(C, BoundTeam, TB) and
            (TF.Host <> '') and SameText(TF.Host, TB.Host) and (TF.Port = TB.Port)) then
    begin
      WriteLine(Data, ReplyErr(Format(
        'activity: %s (bound to %s) may not report for %s (not co-hosted)',
        [BoundTeam, BoundTeam, From])));
      Exit;
    end;
  end;
  note := Trim(Obj.Get('note', ''));
  holdRel := Obj.Get('hold', False);   { reliable (hook) block -> auto-hold ok }
  key := LowerCase(Trim(From));
  if key = '' then
  begin
    WriteLine(Data, ReplyErr('activity report needs a from'));
    Exit;
  end;
  { does a group this team belongs to want blocks logged quietly, not alarmed? }
  logOnly := BlockLogOnly(Snap, key);

  nowBlocked := State = 'blocked';
  wasBlocked := False;
  alarm := '';
  logLine := '';
  FActLock.Enter;
  try
    idx := -1;
    for i := 0 to High(FActivity) do
      if FActivity[i].Team = key then
      begin
        idx := i;
        Break;
      end;
    if idx < 0 then
    begin
      idx := Length(FActivity);
      SetLength(FActivity, idx + 1);
      FActivity[idx].Team := key;
      FActivity[idx].Since := Now;
    end;
    wasBlocked := FActivity[idx].State = 'blocked';
    { stamp Since only on a real change, so ages keep counting from the switch }
    if FActivity[idx].State <> State then
    begin
      FActivity[idx].State := State;
      FActivity[idx].Since := Now;
    end;
    FActivity[idx].Note := note;
    { AUTO-hold follows a RELIABLE block; any non-blocked state releases it.
      The MANUAL hold is untouched here — only the operator clears that. }
    if nowBlocked and holdRel then
      FActivity[idx].HoldAuto := True
    else if not nowBlocked then
      FActivity[idx].HoldAuto := False;
    { rate-limit the alarm per blocked EPISODE: reset the counter on leaving
      blocked; fire the FIRST alarm on entering (re-alarms come from the tick). }
    if not nowBlocked then
      FActivity[idx].NotifyN := 0
    else if not wasBlocked then
    begin
      if logOnly then
        { quiet groups: record the block, leave NotifyN at 0 so the tick never
          re-fires, and never raise the loud alarm. }
        logLine := Format('%s BLOCKED on a permission prompt (log-only, group policy): %s',
          [key, note])
      else
      begin
        FActivity[idx].NotifyN := 1;
        FActivity[idx].LastNotify := Now;
        alarm := AlarmText(key, note);
      end;
    end;
  finally
    FActLock.Leave;
  end;

  { Broadcast does I/O — outside the lock. The first alarm of an episode. }
  if alarm <> '' then
    Broadcast(EvAlarm(key, alarm), 0);
  if logLine <> '' then
    FLog.Info(logLine);
  WriteLine(Data, ReplyOk);
end;

procedure TPizarra.ActivityMaintain;
var
  C: TPizarraConfig;
  i, k: Integer;
  fireTeam, fireNote: array of string;
begin
  { re-fire the alarm for still-blocked teams, spaced AlarmEvery, up to AlarmMax
    per episode — the daemon only reports the block ONCE (on transition), so the
    reminders must come from here. Collect under the lock, Broadcast outside it
    (AlarmText/Broadcast take other locks). }
  C := Snap;
  k := 0;
  FActLock.Enter;
  try
    for i := 0 to High(FActivity) do
      if (FActivity[i].State = 'blocked') and
         (FActivity[i].NotifyN >= 1) and (FActivity[i].NotifyN < C.AlarmMax) and
         (Round((Now - FActivity[i].LastNotify) * 86400) >= C.AlarmEvery) then
      begin
        Inc(FActivity[i].NotifyN);
        FActivity[i].LastNotify := Now;
        SetLength(fireTeam, k + 1);
        SetLength(fireNote, k + 1);
        fireTeam[k] := FActivity[i].Team;
        fireNote[k] := FActivity[i].Note;
        Inc(k);
      end;
  finally
    FActLock.Leave;
  end;
  for i := 0 to k - 1 do
    Broadcast(EvAlarm(fireTeam[i], AlarmText(fireTeam[i], fireNote[i])), 0);
  { same tick: detect group quiescence and fire continue-signals }
  GroupIdleMaintain;
end;

procedure TPizarra.FireGroupContinue(const C: TPizarraConfig; const G: TGroup);
var
  targets, listed: TStringArray;
  i, mi: Integer;
  T: TTeam;
  msg, woke, fromId, replyId: string;

  procedure AddTarget(const Nm: string);
  begin
    if Trim(Nm) = '' then
      Exit;
    SetLength(targets, Length(targets) + 1);
    targets[High(targets)] := Trim(Nm);
  end;

begin
  { resolve who to wake from the policy }
  targets := nil;
  if G.OnIdle = 'boss' then
    AddTarget(G.Boss)
  else if G.OnIdle = 'all' then
  begin
    for mi := 0 to High(G.Members) do
      if not TeamInList(G.Excluded, G.Members[mi]) then
        AddTarget(G.Members[mi]);
  end
  else
  begin
    { a comma list of specific teams }
    listed := SplitList(G.OnIdle);
    for i := 0 to High(listed) do
      AddTarget(listed[i]);
  end;
  if Length(targets) = 0 then
    Exit;   { e.g. on_idle=boss but the group has no boss }

  { the group-quiesced nudge: per-group configurable (on_idle_msg), with a
    generic default when unset — so the wording changes without a rebuild }
  if Trim(G.OnIdleMsg) <> '' then
    msg := G.OnIdleMsg
  else
    msg := Format('@%s: continue with the next', [G.Name]);
  { sender + reply-to identities: default sender 'pizarra' (the hub voice), or
    the configured on_idle_from (e.g. 'console'); reply-to defaults to the sender
    but can be another team through on_idle_reply. }
  fromId := Trim(G.OnIdleFrom);
  if fromId = '' then
    fromId := 'pizarra';
  replyId := Trim(G.OnIdleReply);

  woke := '';
  for i := 0 to High(targets) do
    if FindTeam(C, targets[i], T) then
    begin
      SendGroupNudge(C, T, fromId, replyId, msg);
      if woke <> '' then woke := woke + ', ';
      woke := woke + T.Name;
    end;
  FLog.Info(Format('group %s quiesced -> continue-signal to %s', [G.Name, woke]));
  Broadcast(EvTask(Format('@%s went fully idle -> woke %s', [G.Name, woke])), 0);
end;

procedure TPizarra.GroupIdleMaintain;
var
  C: TPizarraConfig;
  gi, mi, age: Integer;
  st, note: string;
  quiesced: Boolean;
  idx, n: Integer;
  gkey: string;
  hasMember: Boolean;
begin
  C := Snap;
  for gi := 0 to High(C.Groups) do
  begin
    gkey := LowerCase(C.Groups[gi].Name);
    { find/add the tracking slot (watchdog-only, no lock) }
    idx := -1;
    for n := 0 to High(FGrpIdle) do
      if FGrpIdle[n].Name = gkey then
      begin
        idx := n;
        Break;
      end;
    if idx < 0 then
    begin
      idx := Length(FGrpIdle);
      SetLength(FGrpIdle, idx + 1);
      FGrpIdle[idx].Name := gkey;
    end;

    if (C.Groups[gi].OnIdle = '') or (C.Groups[gi].OnIdle = 'off') then
    begin
      FGrpIdle[idx].Since := 0;
      FGrpIdle[idx].Fired := False;
      Continue;
    end;

    { quiesced = EVERY non-excluded member reports 'idle'. A member with no
      report (state '') is NOT idle, so a group is never called quiet on missing
      data; a blocked member is not 'idle' either, so it blocks quiescence. }
    quiesced := True;
    hasMember := False;
    for mi := 0 to High(C.Groups[gi].Members) do
    begin
      if TeamInList(C.Groups[gi].Excluded, C.Groups[gi].Members[mi]) then
        Continue;
      hasMember := True;
      st := ActivityOf(C.Groups[gi].Members[mi], age, note);
      if st <> 'idle' then
      begin
        quiesced := False;
        Break;
      end;
    end;
    if not hasMember then
      quiesced := False;

    if not quiesced then
    begin
      FGrpIdle[idx].Since := 0;
      FGrpIdle[idx].Fired := False;
      Continue;
    end;
    { quiesced now — start the dwell clock, and fire once it has been held }
    if FGrpIdle[idx].Since = 0 then
      FGrpIdle[idx].Since := Now;
    if FGrpIdle[idx].Fired then
      Continue;
    if Round((Now - FGrpIdle[idx].Since) * 86400) < C.GroupIdleDwell then
      Continue;
    FGrpIdle[idx].Fired := True;
    FireGroupContinue(C, C.Groups[gi]);
  end;
end;

procedure TPizarra.HandleHold(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  team: string;
  on_: Boolean;
begin
  { the operator's manual gate: hold a team that is (or is about to be) at a
    permission prompt, or resume it after answering. Console-only. }
  if not ConsoleFor(From, 'team') then
  begin
    WriteLine(Data, ReplyErr('only the console may hold a team''s delivery'));
    Exit;
  end;
  team := Trim(Obj.Get('team', ''));
  if team = '' then
  begin
    WriteLine(Data, ReplyErr('hold needs a team'));
    Exit;
  end;
  on_ := Obj.Get('on', False);
  SetHoldManual(team, on_);
  { on resume, the next RetryPending tick flushes the held backlog in order }
  WriteLine(Data, ReplyOkNote(Format('delivery to %s %s',
    [team, BoolToStr(on_, 'HELD', 'resumed')])));
end;

procedure TPizarra.HandleFleet(Data: TSocketStream);
type
  THostRow = record
    Host:  string;
    Port:  Integer;
    Teams: string;
  end;
var
  C: TPizarraConfig;
  Rows: array of THostRow;
  SB: TStringList;
  O, RObj: TJSONObject;
  L: TList;
  Ch: TDialChannel;
  Reply, Err, Ver, StateS: string;
  FR: TJSONArray;
  i, j, k: Integer;
  Found, OnlineB: Boolean;
begin
  C := Snap;
  SB := TStringList.Create;
  FR := TJSONArray.Create;
  O := TJSONObject.Create;
  try
    AddFleetRow(FR, 'hub', Format('%s:%d', [C.Listen, C.Port]), 'ONLINE',
      PizarraVersion, 'pizarra');
    SB.Add(Format('pizarra hub %s  (%s:%d)',
      [PizarraVersion, C.Listen, C.Port]));
    { push hosts: dedupe by host:port, probe each once }
    Rows := nil;
    for i := 0 to High(C.Teams) do
      if (C.Teams[i].Host <> '') and (not C.Teams[i].Dial) then
      begin
        Found := False;
        for j := 0 to High(Rows) do
          if SameText(Rows[j].Host, C.Teams[i].Host) and
             (Rows[j].Port = C.Teams[i].Port) then
          begin
            Rows[j].Teams := Rows[j].Teams + ' ' + C.Teams[i].Name;
            Found := True;
          end;
        if not Found then
        begin
          j := Length(Rows);
          SetLength(Rows, j + 1);
          Rows[j].Host := C.Teams[i].Host;
          Rows[j].Port := C.Teams[i].Port;
          Rows[j].Teams := C.Teams[i].Name;
        end;
      end;
    for j := 0 to High(Rows) do
    begin
      OnlineB := RequestLine(Rows[j].Host, Rows[j].Port, 1200,
        BuildVer(C.Secret, 'pizarra'), Reply, Err);
      Ver := '-';
      if OnlineB then
      begin
        Ver := '?';   { alive but pre-1.0.2: no cmd=ver in that daemon }
        RObj := ParseObj(Reply);
        if RObj <> nil then
        try
          if RObj.Get('ok', False) then
            Ver := RObj.Get('ver', '?');
        finally
          RObj.Free;
        end;
      end;
      if OnlineB then StateS := 'ONLINE ' else StateS := 'OFFLINE';
      SB.Add(Format('  push  %-21s %s  tiza %-7s teams: %s',
        [Format('%s:%d', [Rows[j].Host, Rows[j].Port]), StateS, Ver,
         TeamsWithActivity(Rows[j].Teams)]));
      AddFleetRow(FR, 'push', Format('%s:%d', [Rows[j].Host, Rows[j].Port]),
        Trim(StateS), Ver, TeamsWithActivity(Rows[j].Teams));
    end;
    { dial-in teams: online = a held reverse channel currently serves them }
    for i := 0 to High(C.Teams) do
      if C.Teams[i].Dial then
      begin
        OnlineB := False;
        Ver := '-';
        L := FDialChannels.LockList;
        try
          for k := 0 to L.Count - 1 do
          begin
            Ch := TDialChannel(L[k]);
            if Ch.Serves(C.Teams[i].Name) then
            begin
              OnlineB := True;
              if Ch.Ver <> '' then
                Ver := Ch.Ver
              else
                Ver := '?';
            end;
          end;
        finally
          FDialChannels.UnlockList;
        end;
        if OnlineB then StateS := 'ONLINE ' else StateS := 'OFFLINE';
        SB.Add(Format('  dial  %-21s %s  tiza %-7s teams: %s',
          [C.Teams[i].Name, StateS, Ver, TeamsWithActivity(C.Teams[i].Name)]));
        AddFleetRow(FR, 'dial', C.Teams[i].Name, Trim(StateS), Ver,
          TeamsWithActivity(C.Teams[i].Name));
      end;
    { local tmux teams + inbox-only pull members (both use THIS host's tiza) }
    for i := 0 to High(C.Teams) do
      if (C.Teams[i].Host = '') and (not C.Teams[i].Dial) then
        if C.Teams[i].TmuxSession = '' then
        begin
          SB.Add(Format('  inbox %-21s PULL     tiza -       teams: %s',
            [C.Teams[i].Name, C.Teams[i].Name]));
          AddFleetRow(FR, 'inbox', C.Teams[i].Name, 'PULL', '-',
            C.Teams[i].Name);
        end
        else
        begin
          if SessionExists(C.Teams[i].TmuxSession) then
            StateS := 'ONLINE '
          else
            StateS := 'OFFLINE';
          SB.Add(Format('  local %-21s %s  tiza %-7s teams: %s',
            [C.Teams[i].TmuxSession, StateS, PizarraVersion,
             TeamsWithActivity(C.Teams[i].Name)]));
          AddFleetRow(FR, 'local', C.Teams[i].TmuxSession, Trim(StateS),
            PizarraVersion, TeamsWithActivity(C.Teams[i].Name));
        end;
    O.Add('ok', True);
    O.Add('tree', TrimRight(SB.Text));
    O.Add('rows', FR);
    WriteLine(Data, O.AsJSON);
  finally
    O.Free;
    SB.Free;
  end;
end;

{ The release actually PUBLISHED in the artifact dir, per releases/VERSION
  (written by `make publish`). '' = nothing publishable. The hub must never
  advertise a release it cannot serve: a daemon that chases a phantom
  version burns its one automatic attempt and reports a failure. }
function TPizarra.PublishedVer(const C: TPizarraConfig): string;
var
  F: TStringList;
begin
  Result := '';
  if C.Releases = '' then
    Exit;
  if not FileExists(IncludeTrailingPathDelimiter(C.Releases) + 'VERSION') then
    Exit;
  F := TStringList.Create;
  try
    try
      F.LoadFromFile(IncludeTrailingPathDelimiter(C.Releases) + 'VERSION');
      if F.Count > 0 then
        Result := Trim(F[0]);
    except
      Result := '';
    end;
  finally
    F.Free;
  end;
end;

{ one hub-release ping per unique push host:port; 600 ms, results ignored -
  this is a broadcast beacon, not a health check (fleet does that on demand).
  The advertised version is the PUBLISHED one, never a phantom. }
procedure TPizarra.PingPushHosts(const C: TPizarraConfig);
var
  Hosts, R, E, HostKey, PV: string;
  i: Integer;
begin
  PV := PublishedVer(C);
  if PV = '' then
    Exit;   { nothing to offer: stay quiet }
  Hosts := '';
  for i := 0 to High(C.Teams) do
    if (C.Teams[i].Host <> '') and (not C.Teams[i].Dial) then
    begin
      HostKey := Format('|%s:%d|', [C.Teams[i].Host, C.Teams[i].Port]);
      if Pos(HostKey, Hosts) > 0 then
        Continue;
      Hosts := Hosts + HostKey;
      RequestLine(C.Teams[i].Host, C.Teams[i].Port, 1000,
        BuildPing(C.Secret, PV), R, E);
    end;
end;

{ cmd=upget: serve one chunk of a release artifact to a self-updating daemon.
  kind='bin' -> <releases>/tiza-<os>-<cpu>; kind='src' -> <releases>/src.tar.gz
  (the build-from-source route for platforms without a prebuilt binary). The
  reply carries the WHOLE file's size + sha256 so the daemon can verify the
  reassembled download; ver pins the offer to this hub build. }
procedure TPizarra.HandleUpget(Obj: TJSONObject; Data: TSocketStream);
var
  C: TPizarraConfig;
  OsS, CpuS, Kind, FN, Hex, ChunkS, PV: string;
  Offset, Max, Size, Take: Int64;
  FS: TFileStream;
  O: TJSONObject;
  i: Integer;
begin
  C := Snap;
  if C.Releases = '' then
  begin
    WriteLine(Data, ReplyErr('updates disabled: no [server] releases dir'));
    Exit;
  end;
  OsS  := LowerCase(Trim(Obj.Get('os', '')));
  CpuS := LowerCase(Trim(Obj.Get('cpu', '')));
  Kind := LowerCase(Trim(Obj.Get('kind', 'bin')));
  for i := 1 to Length(OsS) do
    if not (OsS[i] in ['a'..'z', '0'..'9', '_']) then
    begin
      WriteLine(Data, ReplyErr('bad os'));
      Exit;
    end;
  for i := 1 to Length(CpuS) do
    if not (CpuS[i] in ['a'..'z', '0'..'9', '_']) then
    begin
      WriteLine(Data, ReplyErr('bad cpu'));
      Exit;
    end;
  if (OsS = '') or (CpuS = '') then
  begin
    WriteLine(Data, ReplyErr('bad platform'));
    Exit;
  end;
  if Kind = 'src' then
    FN := IncludeTrailingPathDelimiter(C.Releases) + 'src.tar.gz'
  else if Kind = 'bin' then
    FN := IncludeTrailingPathDelimiter(C.Releases) +
      Format('tiza-%s-%s', [OsS, CpuS])
  else
  begin
    WriteLine(Data, ReplyErr('bad kind (bin|src)'));
    Exit;
  end;
  { serve ONLY what `make publish` actually stamped: releases/VERSION is the
    authority on which release these bytes are. Without it (or when it does
    not match this hub binary) the dir holds a stale/unknown build. }
  PV := PublishedVer(C);
  if PV = '' then
  begin
    WriteLine(Data, ReplyErr('no artifact published (run make publish)'));
    Exit;
  end;
  if PV <> PizarraVersion then
  begin
    WriteLine(Data, ReplyErr(Format(
      'no artifact for this release: published %s, hub runs %s (re-publish)',
      [PV, PizarraVersion])));
    Exit;
  end;
  if not FileExists(FN) then
  begin
    WriteLine(Data, ReplyErr(Format('no artifact for %s-%s (%s)',
      [OsS, CpuS, Kind])));
    Exit;
  end;
  Offset := Obj.Get('offset', Int64(0));
  Max := Obj.Get('max', Int64(262144));
  if Max < 1 then
    Max := 1;
  if Max > 262144 then
    Max := 262144;
  if Offset < 0 then
    Offset := 0;
  if not Sha256OfFile(FN, Hex) then
  begin
    WriteLine(Data, ReplyErr('cannot read artifact'));
    Exit;
  end;
  try
    { Shared access is required because concurrent downloads of the same fleet
      artifact are normal; LOCK_EX would reject the second reader. }
    FS := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
    try
      Size := FS.Size;
      if Offset > Size then
        Offset := Size;
      Take := Size - Offset;
      if Take > Max then
        Take := Max;
      SetLength(ChunkS, Take);
      if Take > 0 then
      begin
        FS.Position := Offset;
        FS.ReadBuffer(ChunkS[1], Take);
      end;
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLine(Data, ReplyErr('artifact read error: ' + E.Message));
      Exit;
    end;
  end;
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('ver', PV);            { the PUBLISHED release, not merely ours }
    O.Add('size', Size);
    O.Add('sha256', Hex);
    O.Add('data', EncodeStringBase64(ChunkS));
    WriteLine(Data, O.AsJSON);
  finally
    O.Free;
  end;
end;

{ cmd=update from the console: forward a self-update trigger to the selected
  daemons. Push hosts get a direct cmd=update (deduped per host:port); dial
  teams get the trigger queued on their HELD channel (an offline dial host
  cannot be triggered - it will catch up via autoupdate=on keepalives or a
  re-trigger once it dials in). Local/inbox teams run THIS host's binary:
  nothing to trigger - make install covers them. }

{ ---------- application registry ----------
  An app names the ONE team responsible for a real program: its repo, where it
  lives on disk, what it is for and what it does. Two questions must both be
  cheap: "who owns this app?" (app show) and "what does this team own?"
  (app list <team>, the team card, and the delivery header). }


{ a plain text blob reply; both clients already print the 'tree' field }
function ReplyTree(const Text: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('tree', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;


{ Legacy application manuals predate app_doc. They are read exactly once during
  cutover; current manuals and archived divergent versions both live in
  org.sqlite afterwards. }
function AppDocPath(const C: TPizarraConfig; const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(C.StoreDir) + 'appdocs' +
    PathDelim + LowerCase(Name) + '.md';
end;

function ReadLegacyAppDoc(const C: TPizarraConfig; const Name: string;
  out Present: Boolean; out Body, Err: string): Boolean;
var
  F: TFileStream;
  Path: string;
  Size: Int64;
  St: TStat;
begin
  Result := False;
  Present := False;
  Body := '';
  Err := '';
  Path := AppDocPath(C, Name);
  St := Default(TStat);
  if FpLStat(Path, St) <> 0 then
  begin
    if fpgeterrno = ESysENOENT then
      Exit(True);
    Err := 'cannot inspect ' + Path + ': ' + SysErrorMessage(fpgeterrno);
    Exit;
  end;
  Present := True;
  if fpS_ISLNK(St.st_mode) or (not fpS_ISREG(St.st_mode)) then
  begin
    Err := Path + ' is not a regular non-symlink file';
    Exit;
  end;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Size := F.Size;
      if Size > High(LongInt) then
      begin
        Err := Path + ' is too large to migrate safely';
        Exit;
      end;
      SetLength(Body, Size);
      if Size > 0 then
        F.ReadBuffer(Body[1], LongInt(Size));
      Result := True;
    finally
      F.Free;
    end;
    except
      on E: Exception do
      begin
        Body := '';
        Err := E.Message;
      end;
    end;
end;

{ Serialize one team row in pzdb's #1-delimited compatibility format. Every
  text field uses reversible framing; prompts and launch commands keep control
  bytes and newlines exactly. }
function RowFld(const S: string): string;
begin
  Result := RowFieldEncode(S);
end;

{ The single team-row serializer. Keeping one constructor prevents schema
  additions from producing differently shaped startup and runtime rows. }
function TeamRowDb(const T: TTeam): string;
begin
  Result := IntToStr(T.Id) + #1 + RowFld(T.Name) + #1 +
    RowFld(T.Speciality) + #1 + RowFld(T.Prompt) + #1 + RowFld(T.Parent) + #1 +
    RowFld(T.Project) + #1 + RowFld(T.Secret) + #1 + RowFld(T.Host) + #1 +
    IntToStr(T.Port) + #1 + IntToStr(Ord(T.Dial)) + #1 +
    RowFld(T.TmuxSession) + #1 + RowFld(T.Launch) + #1 + RowFld(T.User) + #1 +
    IntToStr(Ord(T.Slave)) + #1 + RowFld(T.Workdir) + #1 +
    RowFld(T.Delegate) + #1 + IntToStr(Ord(T.HoldBlocked));
end;

{ Serialize group members as a comma-separated list. }
function GroupMembersCsv(const G: TGroup): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(G.Members) do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + G.Members[i];
  end;
end;

function GroupExcludedCsv(const G: TGroup): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(G.Excluded) do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + G.Excluded[i];
  end;
end;

{ Serialize the full application row as JSON so deletion can be undone. }
function AppRowJson(const A: TApp): string;
begin
  Result := Format('{"name":"%s","team":"%s","repo":"%s","path":"%s",' +
    '"purpose":"%s","detail":"%s"}',
    [JsonEsc(A.Name), JsonEsc(A.Team), JsonEsc(A.Repo), JsonEsc(A.Path),
     JsonEsc(A.Purpose), JsonEsc(A.Detail)]);
end;

function AppsOf(const C: TPizarraConfig; const Team: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(C.Apps) do
    if SameText(C.Apps[i].Team, Team) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + C.Apps[i].Name;
    end;
end;

function FindApp(const C: TPizarraConfig; const Name: string;
  out A: TApp): Boolean;
var
  i: Integer;
begin
  Result := False;
  A := Default(TApp);
  for i := 0 to High(C.Apps) do
    if SameText(C.Apps[i].Name, Name) then
    begin
      A := C.Apps[i];
      Exit(True);
    end;
end;

{ Projects: rows of 'project'#9'role' exactly as ProjectsOfApp returns them.
  It comes in as a parameter instead of being queried here because AppCard is a
  free function with no database access; its callers do have it. nil means it
  was never asked, and then the field comes out empty rather than lying with a
  list. }
function AppCard(const A: TApp; HasDoc: Boolean = False;
  Projects: TStringList = nil): string;
var
  O, J, PO: TJSONObject;
  Arr: TJSONArray;
  i, t: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    J := TJSONObject.Create;
    J.Add('name', A.Name);
    J.Add('team', A.Team);
    J.Add('repo', A.Repo);
    J.Add('path', A.Path);
    J.Add('purpose', A.Purpose);
    J.Add('detail', A.Detail);
    J.Add('hasdoc', HasDoc);
    { WHICH PROJECTS this app takes part in, and what it does in each. The
      functionality belongs to the PAIR: the same app can hold up different
      things in two projects, which is why it does not fit in 'purpose'. }
    Arr := TJSONArray.Create;
    if Projects <> nil then
      for i := 0 to Projects.Count - 1 do
      begin
        t := Pos(#9, Projects[i]);
        PO := TJSONObject.Create;
        if t > 0 then
        begin
          PO.Add('name', Copy(Projects[i], 1, t - 1));
          PO.Add('role', Copy(Projects[i], t + 1, Length(Projects[i]) - t));
        end
        else
        begin
          PO.Add('name', Projects[i]);
          PO.Add('role', '');
        end;
        Arr.Add(PO);
      end;
    J.Add('projects', Arr);
    O.Add('app', J);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;


{ Number of file descriptors currently open by this process (diagnostic). }
function CountOpenFds: Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst('/proc/self/fd/*', faAnyFile, SR) = 0 then
  begin
    repeat
      Inc(Result);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ File size by path; the RTL FileSize overload expects an open File. }
function FileBytes(const P: string): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(P, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

{ cmd=backup - restore-oriented snapshot of the hub's core operational state.

  Included: the three SQLite databases, messages.jsonl, state.json,
  tareas.json, workflows.json, and pizarra.conf. The databases are copied live
  through SQLite's online-backup API; ordinary files are copied as-is.

  Deliberately NOT included: workflow history snapshots under wfhistory/ and
  legacy cold appdocs files. The result restores live registries, manuals stored
  in SQLite, messages, delivery cursors, tasks, and workflows, but it is not a
  complete archival copy of every historical artifact.

  The snapshot CONTAINS secrets, so it is created under a mode-0700 directory,
  clearly marked, and refused inside a Git tree unless --force is explicit. It
  is assembled under a temporary name and renamed only when complete. }
procedure TPizarra.HandleBackup(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  Base, Dir, Tmp, Err, Manifest, Stamp, SrcDir: string;
  SB: TStringList;
  Total, i: Integer;

  function InGitTree(const P: string): Boolean;
  var
    D: string;
    n: Integer;
  begin
    Result := False;
    D := ExpandFileName(P);
    for n := 1 to 12 do
    begin
      if DirectoryExists(IncludeTrailingPathDelimiter(D) + '.git') then
        Exit(True);
      if (D = '/') or (D = '') then
        Exit;
      D := ExtractFileDir(D);
    end;
  end;

  function SyncPath(const P: string; IsDir: Boolean; out Why: string): Boolean;
  var
    H: Integer;
  begin
    Result := False;
    if IsDir then
      H := PzOpenDirFd(P)
    else
      H := FpOpen(P, O_RDONLY);
    if H < 0 then
    begin
      Why := 'cannot open ' + P + ' for fsync: ' +
        SysErrorMessage(fpgeterrno);
      Exit;
    end;
    try
      if PzFsync(H) <> 0 then
      begin
        Why := 'cannot fsync ' + P + ': ' + SysErrorMessage(fpgeterrno);
        Exit;
      end;
    finally
      FpClose(H);
    end;
    Result := True;
  end;

  { Copy one included store file and record its size and SHA-256. }
  procedure Take(const RelPath: string);
  var
    Src, Dst, Hex: string;
  begin
    Src := IncludeTrailingPathDelimiter(SrcDir) + RelPath;
    if not FileExists(Src) then
      Exit;
    Dst := IncludeTrailingPathDelimiter(Tmp) + 'store' + PathDelim + RelPath;
    if not ForceDirectories(ExtractFileDir(Dst)) then
      raise EInOutError.Create('cannot create backup subdirectory for ' + Dst);
    if not CopyFileTo(Src, Dst, Err) then
      raise EInOutError.Create('cannot copy ' + RelPath + ': ' + Err);
    if not Sha256OfFile(Dst, Hex) then
      raise EInOutError.Create('cannot hash copied file ' + Dst);
    SB.Add(Format('store/%s  %d  %s',
      [RelPath, FileBytes(Dst), Hex]));
    Inc(Total);
  end;

begin
  { The snapshot carries SECRETS, so access requires explicit backup delegation
    rather than ordinary team authority. }
  if not ConsoleFor(From, 'backup') then
  begin
    WriteLine(Data, ReplyErr('only the console -or a team with delegate=backup- ' +
      'may take backups'));
    Exit;
  end;
  if (FDb = nil) or (not FDb.Available) then
  begin
    WriteLine(Data, ReplyErr('sqlite unavailable: cannot copy the databases'));
    Exit;
  end;
  C := Snap;
  SrcDir := IncludeTrailingPathDelimiter(C.StoreDir);
  Base := Trim(Obj.Get('out', ''));
  { The default destination lives beside the copied data inside the store,
    which already holds the same secrets and is ignored by Git. Apply the Git
    guard to operator-supplied destinations where accidental publication is
    possible. }
  if Base = '' then
    Base := SrcDir + 'backups'
  else if (not Obj.Get('force', False)) and InGitTree(Base) then
  begin
    WriteLine(Data, ReplyErr('that destination is inside a Git repository ' +
      'and the backup CONTAINS SECRETS; use another path (or --force if you ' +
      'accept the risk)'));
    Exit;
  end;
  Stamp := FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + IntToStr(FpGetpid);
  Dir := IncludeTrailingPathDelimiter(Base) + 'pizarra-' + Stamp;
  Tmp := Dir + '.partial';
  if not EnsurePrivateRuntimeDir(Tmp, Err) then
  begin
    WriteLine(Data, ReplyErr('cannot create private backup directory ' + Tmp +
      ': ' + Err));
    Exit;
  end;
  SB := TStringList.Create;
  try
    try
      Total := 0;
      SB.Add('# pizarra backup ' + PizarraVersion + '  ' +
        FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
      SB.Add('# SCOPE: core operational state; excludes wfhistory/, legacy appdocs, releases, and shared/NFS content');
      SB.Add('# CONTAINS SECRETS: protect it as a credential');
      SB.Add('# file  bytes  sha256');
      { One linearization barrier for every piece that participates in restore.
        Lock order is the program's established order:
          config -> workflow -> tasks -> message store -> SQLite.
        Workflow already nests tasks; tasks already nests SQLite; there is no
        reverse path. Without this barrier the manifest could certify a task
        JSON newer than work.sqlite or state.json newer than messages.jsonl. }
      FCfgLock.Enter;
      try
        FWf.LockForSnapshot;
        try
          FTasks.LockForSnapshot;
          try
            FStore.LockForSnapshot;
            try
              if not FDb.BackupTo(Tmp, Err) then
                raise EInOutError.Create('database copy failed: ' + Err);
              for i := 0 to 2 do
              begin
                case i of
                  0: Err := 'apps.sqlite';
                  1: Err := 'org.sqlite';
                else
                  Err := 'work.sqlite';
                end;
                if not Sha256OfFile(IncludeTrailingPathDelimiter(Tmp) + Err,
                  Manifest) then
                  raise EInOutError.Create('cannot hash mandatory database ' + Err);
                SB.Add(Format('%s  %d  %s', [Err,
                  FileBytes(IncludeTrailingPathDelimiter(Tmp) + Err), Manifest]));
                Inc(Total);
              end;
              Take('messages.jsonl');
              Take('state.json');
              Take('tareas.json');
              Take('workflows.json');
              { Configuration is mandatory and carries the bus secret. }
              Err := IncludeTrailingPathDelimiter(Tmp) + 'pizarra.conf';
              if not CopyFileTo(FCfgPath, Err, Manifest) then
                raise EInOutError.Create('configuration copy failed: ' + Manifest);
              if not Sha256OfFile(Err, Manifest) then
                raise EInOutError.Create('cannot hash mandatory pizarra.conf');
              SB.Add(Format('pizarra.conf  %d  %s', [FileBytes(Err), Manifest]));
              Inc(Total);
            finally
              FStore.UnlockForSnapshot;
            end;
          finally
            FTasks.UnlockForSnapshot;
          end;
        finally
          FWf.UnlockForSnapshot;
        end;
      finally
        FCfgLock.Leave;
      end;
      Err := IncludeTrailingPathDelimiter(Tmp) + 'MANIFEST';
      SB.SaveToFile(Err);
      if FpChmod(Err, &600) <> 0 then
        raise EInOutError.Create('cannot protect backup MANIFEST');
      if not SyncPath(Err, False, Manifest) then
        raise EInOutError.Create(Manifest);
      if FpChmod(Tmp, &700) <> 0 then
        raise EInOutError.Create('cannot protect partial backup directory');
      { Every file is durable now; persist the directory entries that name
        store/* and the top-level config/MANIFEST before publishing Tmp. }
      Err := IncludeTrailingPathDelimiter(Tmp) + 'store';
      if DirectoryExists(Err) and (not SyncPath(Err, True, Manifest)) then
        raise EInOutError.Create(Manifest);
      if not SyncPath(Tmp, True, Manifest) then
        raise EInOutError.Create(Manifest);
      if not RenameFile(Tmp, Dir) then
        raise EInOutError.Create('could not finish the backup in ' + Dir);
      if FpChmod(Dir, &700) <> 0 then
        raise EInOutError.Create('could not protect completed backup ' + Dir);
      if not SyncPath(Base, True, Manifest) then
        raise EInOutError.Create(Manifest);
      FLog.Info(Format('core-state backup complete in %s (%d pieces)', [Dir, Total]));
      WriteLine(Data, ReplyTree(Format('core-state backup complete: %s'#10 +
        '  %d pieces, SHA-256 manifest in MANIFEST'#10 +
        '  excludes wfhistory/, legacy appdocs, releases, and shared/NFS content'#10 +
        '  CONTAINS SECRETS: protect it as a credential (mode 0700)'#10 +
        '  verify: tiza backup verify %s', [Dir, Total, Dir])));
    except
      on E: Exception do
        WriteLine(Data, ReplyErr('backup incomplete: ' + E.Message));
    end;
  finally
    SB.Free;
  end;
end;

procedure TPizarra.MirrorAppProjects(const AppName: string);
var
  Rows_: TStringList;
  NewApps: TAppArray;
  ProjectList: string;
  i, t: Integer;
  idx: Integer;
begin
  Rows_ := nil;
  FCfgLock.Enter;
  try
    { Keep the documented lock order FCfgLock -> SQLite. The projection is
      published in memory only; pizarra.conf is no longer a registry mirror. }
    Rows_ := FDb.ProjectsOfApp(AppName);
    ProjectList := '';
    if Rows_ <> nil then
      for i := 0 to Rows_.Count - 1 do
      begin
        t := Pos(#9, Rows_[i]);
        if ProjectList <> '' then
          ProjectList := ProjectList + ', ';
        if t > 0 then
          ProjectList := ProjectList + Copy(Rows_[i], 1, t - 1)
        else
          ProjectList := ProjectList + Rows_[i];
      end;
    idx := -1;
    for i := 0 to High(FCfg.Apps) do
      if SameText(FCfg.Apps[i].Name, AppName) then
        idx := i;
    if idx < 0 then
      Exit;
    NewApps := Copy(FCfg.Apps);
    NewApps[idx].Projects := ProjectList;
    FCfg.Apps := NewApps;
  finally
    Rows_.Free;
    FCfgLock.Leave;
  end;
end;

procedure TPizarra.HandleApp(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C, NewCfg: TPizarraConfig;
  Op, Name, Field, Value, Txt, DbErr, OldRow, ChOld, Prj: string;
  Prj_: TProject;
  R, Fl, Prjs: TStringList;
  Und: TJSONObject;
  F: TPzDbFile;
  Arr: TJSONArray;
  AO, O: TJSONObject;
  A, Old: TApp;
  T: TTeam;
  i, idx: Integer;
  Found: Boolean;
begin
  Op := LowerCase(Trim(Obj.Get('op', '')));
  Name := Trim(Obj.Get('name', ''));
  C := Snap;

  if (Op = 'list') or (Op = '') then
  begin
    Txt := '';
    Arr := TJSONArray.Create;
    for i := 0 to High(C.Apps) do
      if (Name = '') or SameText(C.Apps[i].Team, Name) then
      begin
        Txt := Txt + Format('%-16s %-14s %s'#10,
          [C.Apps[i].Name,
           BoolToStr(C.Apps[i].Team = '', '(unassigned)', C.Apps[i].Team),
           C.Apps[i].Purpose]);
        { structured rows too: the client draws the table, old clients keep
          printing the 'tree' text below }
        AO := TJSONObject.Create;
        AO.Add('name', C.Apps[i].Name);
        AO.Add('team', BoolToStr(C.Apps[i].Team = '', '(unassigned)',
          C.Apps[i].Team));
        AO.Add('purpose', C.Apps[i].Purpose);
        AO.Add('hasdoc', C.Apps[i].HasDoc);
        Arr.Add(AO);
      end;
    if Txt = '' then
      if Name = '' then
        Txt := '(no applications registered - tiza app add <name> --team <t>)'
      else
        Txt := Format('(no applications owned by %s)', [Name]);
    O := TJSONObject.Create;
    try
      O.Add('ok', True);
      O.Add('tree', TrimRight(Txt));
      O.Add('rows', Arr);
      WriteLine(Data, O.AsJSON);
    finally
      O.Free;
    end;
    Exit;
  end;

  if Name = '' then
  begin
    WriteLine(Data, ReplyErr('app: missing name'));
    Exit;
  end;

  if Op = 'show' then
  begin
    if not FindApp(C, Name, A) then
      WriteLine(Data, ReplyErr('unknown app: ' + Name))
    else
    begin
      Prjs := FDb.ProjectsOfApp(A.Name);
      try
        WriteLine(Data, AppCard(A, A.HasDoc, Prjs));
      finally
        Prjs.Free;
      end;
    end;
    Exit;
  end;

  { History is readable by anyone, like the manual. }
  if (Op = 'history') or (Op = 'hist') then
  begin
    F := FDb.AppsDb;
    { Fetch only application events. Subject names may overlap across registry
      kinds; the relevant event types cover fields, manuals, and project links. }
    R := FDb.HistList(F, 'app,appdoc,appproject', Name, 40);
    Fl := TStringList.Create;
    try
      Fl.Delimiter := #1;
      Fl.StrictDelimiter := True;
      { StrictDelimiter does not disable quote parsing. QuoteChar=#0 prevents a
        leading double quote from shifting all subsequent #1-delimited fields. }
      Fl.QuoteChar := #0;
      Txt := '';
      for i := 0 to R.Count - 1 do
      begin
        Fl.DelimitedText := R[i];
        while Fl.Count < 7 do
          Fl.Add('');
        DecodeRowFields(Fl, [0, 1, 2, 3, 4, 5, 6]);
        if Fl[4] = '' then
          Txt := Txt + Format('snap %-4s %s  %-10s %s'#10,
            [Fl[0], Fl[1], Fl[2], Fl[3]])
        else
          Txt := Txt + Format('snap %-4s %s  %-10s %-7s %s: %s -> %s'#10,
            [Fl[0], Fl[1], Fl[2], Fl[3], Fl[4], Copy(Fl[5], 1, 40),
             Copy(Fl[6], 1, 40)]);
      end;
      if Txt = '' then
        Txt := '(no history for ' + Name + ')';
      WriteLine(Data, ReplyTree(TrimRight(Txt)));
    finally
      Fl.Free;
      R.Free;
    end;
    Exit;
  end;

  { Undo re-enters the normal operation instead of editing the database
    directly, so permissions and invariants are revalidated and the jump is
    recorded as another change. }
  if Op = 'undo' then
  begin
    F := FDb.AppsDb;
    Txt := FDb.HistGet(F, Obj.Get('snap', 0));
    if Txt = '' then
    begin
      WriteLine(Data, ReplyErr('no such history point'));
      Exit;
    end;
    Fl := TStringList.Create;
    try
      Fl.Delimiter := #1;
      Fl.StrictDelimiter := True;
      { Disable quote parsing explicitly; StrictDelimiter alone does not do so,
        and a leading quote would shift subsequent #1-delimited fields. }
      Fl.QuoteChar := #0;
      Fl.DelimitedText := Txt;
      while Fl.Count < 8 do
        Fl.Add('');
      DecodeRowFields(Fl, [0, 1, 2, 3, 4, 5, 6, 7]);
      { A snapshot belongs to exactly one named application. Snapshot numbers
        come from a global sequence, so verify the stored subject before
        re-entering the undo operation. }
      if (Name <> '') and (not SameText(Name, Fl[1])) then
      begin
        WriteLine(Data, ReplyErr(Format('history point %d belongs to "%s", ' +
          'not to "%s" — look it up with: tiza app history %s',
          [Obj.Get('snap', 0), Fl[1], Name, Name])));
        Exit;
      end;
      Und := TJSONObject.Create;
      try
        Und.Add('from', From);
        Und.Add('name', Fl[1]);
        if (Fl[0] = 'app') and (Fl[2] = 'set') then
        begin
          Und.Add('op', 'set');
          Und.Add('field', Fl[3]);
          Und.Add('value', Fl[4]);
        end
        else if (Fl[0] = 'appdoc') and (Fl[2] = 'setdoc') then
        begin
          Und.Add('op', 'setdoc');
          Und.Add('text', Fl[6]);
        end
        else
        begin
          WriteLine(Data, ReplyErr('cannot undo yet: ' +
            Fl[2] + ' of ' + Fl[0]));
          Exit;
        end;
        HandleApp(Und, From, Data);   { re-entry writes the response }
      finally
        Und.Free;
      end;
    finally
      Fl.Free;
    end;
    Exit;
  end;

  { the manual: ANY team may read it (knowledge is shared fleet-wide), only
    the responsible team or the console may write it }
  if Op = 'doc' then
  begin
    if not FindApp(C, Name, A) then
    begin
      WriteLine(Data, ReplyErr('unknown app: ' + Name));
      Exit;
    end;
    if Obj.Get('at', 0) > 0 then
    begin
      F := FDb.AppsDb;
      Txt := FDb.HistGet(F, Obj.Get('at', 0));
      Fl := TStringList.Create;
      try
        Fl.Delimiter := #1;
        Fl.StrictDelimiter := True;
        { Disable quote parsing explicitly so #1-delimited columns cannot shift
          when a field begins with a double quote. }
        Fl.QuoteChar := #0;
        Fl.DelimitedText := Txt;
        DecodeRowFields(Fl, [0, 1, 2, 3, 4, 5, 6, 7]);
        if (Fl.Count >= 8) and (Fl[0] = 'appdoc') then
          Txt := Fl[7]
        else
          Txt := '';
      finally
        Fl.Free;
      end;
      if Txt = '' then
        Txt := '(that history point does not contain a manual for ' + Name + ')';
      WriteLine(Data, ReplyTree(TrimRight(Txt)));
      Exit;
    end;
    Txt := FDb.AppDoc(Name);
    if Txt = '' then
      Txt := Format('(%s has no manual yet — its team %s can write one with:'#10 +
        '   tiza app doc %s --file <file>   |   tiza app doc %s "text")',
        [Name, BoolToStr(A.Team = '', '(unassigned)', A.Team), Name, Name]);
    WriteLine(Data, ReplyTree(TrimRight(Txt)));
    Exit;
  end;
  if Op = 'setdoc' then
  begin
    if not FindApp(C, Name, A) then
    begin
      WriteLine(Data, ReplyErr('unknown app: ' + Name));
      Exit;
    end;
    if (not ConsoleFor(From, 'app')) and (not SameText(A.Team, From)) then
    begin
      WriteLine(Data, ReplyErr(
        'only the console or the responsible team (' + A.Team +
        ') may write this manual'));
      Exit;
    end;
    FCfgLock.Enter;
    try
      { Recheck ownership under the same outer lock that serializes the SQLite
        transaction; a concurrent reassignment cannot authorize a stale owner. }
      if not FindApp(FCfg, Name, A) then
      begin
        WriteLine(Data, ReplyErr('unknown app: ' + Name));
        Exit;
      end;
      if (not SameText(From, 'console')) and
         (not TeamDelegated(FCfg, From, 'app')) and
         (not SameText(A.Team, From)) then
      begin
        WriteLine(Data, ReplyErr('application ownership changed; manual not saved'));
        Exit;
      end;
      if not FDb.AppSetDoc(Name, Obj.Get('text', ''), From,
        FDb.AppDoc(Name), Txt) then
      begin
        WriteLine(Data, ReplyErr('manual not saved: ' + Txt));
        Exit;
      end;
      NewCfg := FCfg;
      NewCfg.Apps := Copy(FCfg.Apps, 0, Length(FCfg.Apps));
      for i := 0 to High(NewCfg.Apps) do
        if SameText(NewCfg.Apps[i].Name, Name) then
          NewCfg.Apps[i].HasDoc := Trim(Obj.Get('text', '')) <> '';
      FCfg := NewCfg;
    finally
      FCfgLock.Leave;
    end;
    FLog.Info(Format('app %s manual written by %s (%d bytes)',
      [Name, From, Length(Obj.Get('text', ''))]));
    Broadcast(EvSys(Format('app %s: manual updated by %s', [Name, From])), 0);
    WriteLine(Data, ReplyOk);
    Exit;
  end;

  { mutations: console or the responsible team (a team may document its own) }
  Found := FindApp(C, Name, Old);
  { This guard precedes the operation-specific branches; delegated callers must
    be admitted here before their finer permissions can be evaluated. }
  if not ConsoleFor(From, 'app') then
    if Op = 'add' then
    begin
      { a team may only register an app it will own itself }
      if not SameText(Trim(Obj.Get('team', '')), From) then
      begin
        WriteLine(Data, ReplyErr(
          'only the console may register an app for another team'));
        Exit;
      end;
    end
    else if (not Found) or (not SameText(Old.Team, From)) then
    begin
      WriteLine(Data, ReplyErr(
        'only the console or the responsible team may change this app'));
      Exit;
    end;

  { Assign or remove an application/project link. Authorization matches `set`:
    the console, a caller delegated for `app`, or the owning team. Project
    leadership grants no extra permission here; cascades belong to the schema. }
  if (Op = 'project') or (Op = 'unproject') then
  begin
    if not Found then
    begin
      WriteLine(Data, ReplyErr('unknown app: ' + Name));
      Exit;
    end;
    if (not ConsoleFor(From, 'app')) and (not SameText(Old.Team, From)) then
    begin
      WriteLine(Data, ReplyErr('only the console or the responsible team (' +
        Old.Team + ') may change where this app is used'));
      Exit;
    end;
    Prj := Trim(Obj.Get('project', ''));
    if Prj = '' then
    begin
      WriteLine(Data, ReplyErr('which project? usage: ' +
        'tiza app project <app> <project> [--role "what it does there"]'));
      Exit;
    end;
    { Assignment requires an existing project and reports a clear error before
      the foreign-key check. Removal instead validates the relationship itself,
      allowing stale database links left by declarative INI edits to be cleaned. }
    if not FindProject(C, Prj, Prj_) then
    begin
      if Op = 'project' then
      begin
        WriteLine(Data, ReplyErr('unknown project: ' + Prj));
        Exit;
      end;
      Prj_.Name := Prj;   { remove using the supplied relationship name }
    end;
    if Op = 'project' then
    begin
      FCfgLock.Enter;
      try
        if (not FindApp(FCfg, Old.Name, A)) or
           ((not SameText(From, 'console')) and
            (not TeamDelegated(FCfg, From, 'app')) and
            (not SameText(A.Team, From))) then
        begin
          WriteLine(Data, ReplyErr('application ownership changed; nothing assigned'));
          Exit;
        end;
        if not FindProject(FCfg, Prj_.Name, Prj_) then
        begin
          WriteLine(Data, ReplyErr('project was removed; nothing assigned'));
          Exit;
        end;
        if not FDb.AppProjectSet(Old.Name, Prj_.Name,
          Trim(Obj.Get('role', '')), From, DbErr) then
        begin
          WriteLine(Data, ReplyErr('could not assign: ' + DbErr));
          Exit;
        end;
      finally
        FCfgLock.Leave;
      end;
      MirrorAppProjects(Old.Name);
      WriteLine(Data, ReplyOkNote(Format('app %s assigned to project %s (by %s)',
        [Old.Name, Prj_.Name, From])));
    end
    else
    begin
      FCfgLock.Enter;
      try
        if (not FindApp(FCfg, Old.Name, A)) or
           ((not SameText(From, 'console')) and
            (not TeamDelegated(FCfg, From, 'app')) and
            (not SameText(A.Team, From))) then
        begin
          WriteLine(Data, ReplyErr('application ownership changed; nothing unassigned'));
          Exit;
        end;
        if not FDb.AppProjectClear(Old.Name, Prj_.Name, From, DbErr) then
        begin
          WriteLine(Data, ReplyErr('could not unassign: ' + DbErr));
          Exit;
        end;
      finally
        FCfgLock.Leave;
      end;
      MirrorAppProjects(Old.Name);
      WriteLine(Data, ReplyOkNote(Format('app %s no longer in project %s (by %s)',
        [Old.Name, Prj_.Name, From])));
    end;
    Exit;
  end;

  if Op = 'add' then
  begin
    if Found then
    begin
      WriteLine(Data, ReplyErr('app already exists: ' + Name));
      Exit;
    end;
    { An app name is NOT a message destination, so the team/command reserved
      list does not apply (the hub's own app is legitimately called
      "pizarra"). Only the app subverbs would be ambiguous, because
      `tiza app <name>` is shorthand for `app show <name>`. }
    if (not SafeName(Name)) or SameText(Name, 'add') or
       SameText(Name, 'set') or SameText(Name, 'remove') or
       SameText(Name, 'list') or SameText(Name, 'show') or
       SameText(Name, 'doc') or SameText(Name, 'setdoc') or
       SameText(Name, 'project') or SameText(Name, 'unproject') then
      begin
        WriteLine(Data, ReplyErr(
          'invalid app name (unsafe, or clashes with an app subcommand): ' + Name));
        Exit;
      end;
    A := Default(TApp);
    A.Name    := Name;
    A.Team    := Trim(Obj.Get('team', ''));
    A.Repo    := Trim(Obj.Get('repo', ''));
    A.Path    := Trim(Obj.Get('path', ''));
    A.Purpose := Trim(Obj.Get('purpose', ''));
    A.Detail  := Trim(Obj.Get('detail', ''));
    if (A.Team <> '') and (not FindTeam(C, A.Team, T)) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + A.Team));
      Exit;
    end;
    if A.Team <> '' then
      A.Team := T.Name;   { canonical case/id -> name }
  end
  else if Op = 'set' then
  begin
    if not Found then
    begin
      WriteLine(Data, ReplyErr('unknown app: ' + Name));
      Exit;
    end;
    A := Old;
    Field := LowerCase(Trim(Obj.Get('field', '')));
    Value := Trim(Obj.Get('value', ''));
    ChOld := A.Team;
    if Field = 'team' then
    begin
      if (Value <> '') and (Value <> '-') then
      begin
        if not FindTeam(C, Value, T) then
        begin
          WriteLine(Data, ReplyErr('unknown team: ' + Value));
          Exit;
        end;
        A.Team := T.Name;
      end
      else
        A.Team := '';
    end
    else if Field = 'repo' then begin ChOld := A.Repo; A.Repo := Value; end
    else if Field = 'path' then begin ChOld := A.Path; A.Path := Value; end
    else if Field = 'purpose' then begin ChOld := A.Purpose; A.Purpose := Value; end
    else if Field = 'detail' then begin ChOld := A.Detail; A.Detail := Value; end
    else
    begin
      WriteLine(Data, ReplyErr('unknown field: ' + Field +
        ' (team|repo|path|purpose|detail)'));
      Exit;
    end;
  end
  else if Op <> 'remove' then
  begin
    WriteLine(Data, ReplyErr(
      'app: unknown op (add|set|remove|list|show|project|unproject)'));
    Exit;
  end;

  FCfgLock.Enter;
  try
    NewCfg := FCfg;
    NewCfg.Apps := Copy(FCfg.Apps, 0, Length(FCfg.Apps));
    idx := -1;
    for i := 0 to High(NewCfg.Apps) do
      if SameText(NewCfg.Apps[i].Name, Name) then
        idx := i;
    { The checks above ran against a pre-lock snapshot. Re-decide here, where
      the write actually happens: two teams racing `app add <same name>` would
      otherwise both pass and the loser would silently take ownership away
      from the winner, and `set` racing `remove` would resurrect the app. }
    if (Op = 'add') and (idx >= 0) then
    begin
      WriteLine(Data, ReplyErr('app already exists: ' + Name));
      Exit;
    end;
    if (Op = 'set') and (idx < 0) then
    begin
      WriteLine(Data, ReplyErr('unknown app: ' + Name));
      Exit;
    end;
    if (Op = 'set') and (not ConsoleFor(From, 'app')) and
       (not SameText(NewCfg.Apps[idx].Team, From)) then
    begin
      WriteLine(Data, ReplyErr(
        'only the console or the responsible team may change this app'));
      Exit;
    end;
    if Op = 'remove' then
    begin
      if idx < 0 then
      begin
        WriteLine(Data, ReplyErr('unknown app: ' + Name));
        Exit;
      end;
      if (not ConsoleFor(From, 'app')) and
         (not SameText(NewCfg.Apps[idx].Team, From)) then
      begin
        WriteLine(Data, ReplyErr(
          'only the console or the responsible team may remove this app'));
        Exit;
      end;
      { SQLite is authoritative. The manual and project links follow the app
        through foreign-key cascades; publish memory only after COMMIT. }
      if not FDb.AppRemove(Name, From, AppRowJson(NewCfg.Apps[idx]), DbErr) then
      begin
        WriteLine(Data, ReplyErr('app not removed: ' + DbErr));
        Exit;
      end;
      for i := idx to High(NewCfg.Apps) - 1 do
        NewCfg.Apps[i] := NewCfg.Apps[i + 1];
      SetLength(NewCfg.Apps, Length(NewCfg.Apps) - 1);
    end
    else
    begin
      if idx < 0 then
      begin
        SetLength(NewCfg.Apps, Length(NewCfg.Apps) + 1);
        idx := High(NewCfg.Apps);
        OldRow := '';
      end
      else
      begin
        OldRow := AppRowJson(NewCfg.Apps[idx]);
        A.HasDoc := NewCfg.Apps[idx].HasDoc;   { leave the manual unchanged }
      end;
      if not FDb.AppUpsert(A.Name, A.Team, A.Repo, A.Path, A.Purpose,
        A.Detail, From, OldRow = '', OldRow, Field, ChOld, Value, DbErr) then
      begin
        WriteLine(Data, ReplyErr('app not saved: ' + DbErr));
        Exit;
      end;
      NewCfg.Apps[idx] := A;
    end;
    FCfg := NewCfg;
  finally
    FCfgLock.Leave;
  end;

  if Op = 'remove' then
  begin
    FLog.Info(Format('app %s removed by %s', [Name, From]));
    Broadcast(EvSys(Format('app %s removed', [Name])), 0);
    WriteLine(Data, ReplyOk);
  end
  else
  begin
    FLog.Info(Format('app %s %s by %s (team %s)', [Name, Op, From, A.Team]));
    Broadcast(EvSys(Format('app %s -> %s', [Name,
      BoolToStr(A.Team = '', '(unassigned)', A.Team)])), 0);
    { the reply to 'project'/'unproject' is this very card: without the
      projects, the command that JUST changed them would answer without them }
    Prjs := FDb.ProjectsOfApp(A.Name);
    try
      WriteLine(Data, AppCard(A, A.HasDoc, Prjs));
    finally
      Prjs.Free;
    end;
  end;
end;

procedure TPizarra.HandleUpdate(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  Name, R, E, Hosts, PV, DVer: string;
  Force, IsAll, Any, TooOld: Boolean;
  SB: TStringList;
  O, RObj: TJSONObject;
  L: TList;
  Ch: TDialChannel;
  i, k: Integer;
  HostKey: string;
  Served: Boolean;
begin
  { Fleet update restarts remote daemons. Delegation is explicit and the
    caller identity remains visible in the journal. }
  if not ConsoleFor(From, 'update') then
  begin
    WriteLine(Data, ReplyErr('only the console -or a team with delegate=update- ' +
      'may trigger updates'));
    Exit;
  end;
  C := Snap;
  PV := PublishedVer(C);
  if C.Releases = '' then
  begin
    WriteLine(Data, ReplyErr('updates disabled: no [server] releases dir'));
    Exit;
  end;
  if PV = '' then
  begin
    WriteLine(Data, ReplyErr('nothing published: run make publish on the hub'));
    Exit;
  end;
  if PV <> PizarraVersion then
  begin
    WriteLine(Data, ReplyErr(Format(
      'published release is %s but the hub runs %s - re-publish before updating',
      [PV, PizarraVersion])));
    Exit;
  end;
  Name := Trim(Obj.Get('name', ''));
  Force := Obj.Get('force', False);
  if Name = '' then
    Name := 'all';
  IsAll := SameText(Name, 'all');
  Any := False;
  if not IsAll then
  begin
    for i := 0 to High(C.Teams) do
      if SameText(C.Teams[i].Name, Name) then
        Any := True;
    if not Any then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + Name));
      Exit;
    end;
  end;
  SB := TStringList.Create;
  try
    SB.Add(Format('update -> release %s%s', [PizarraVersion,
      BoolToStr(Force, ' (forced)', '')]));
    Hosts := '';
    for i := 0 to High(C.Teams) do
    begin
      if (not IsAll) and (not SameText(C.Teams[i].Name, Name)) then
        Continue;
      if C.Teams[i].Dial then
      begin
        Served := False;
        TooOld := False;
        DVer := '';
        L := FDialChannels.LockList;
        try
          for k := 0 to L.Count - 1 do
          begin
            Ch := TDialChannel(L[k]);
            if not Ch.Serves(C.Teams[i].Name) then
              Continue;
            { A pre-1.0.3 daemon does not ACK a control line: the dial loop
              would block DIAL_ACK_MS and then tear the channel down, cutting
              the host off the bus. Only trigger daemons that can answer. }
            if not VerAtLeast(Ch.Ver, '1.0.3') then
            begin
              TooOld := True;
              DVer := Ch.Ver;
              Continue;
            end;
            { Dial traffic carries no secret. The authenticated hello already
              establishes the outbound connection; repeating a global secret
              in deliveries, updates, or pings would disclose it to a
              team-bound peer. Seq=-1 denotes a control line and marks nothing. }
            Ch.Push(BuildUpdate('', 'pizarra', '', PV, Force), '', -1);
            Served := True;
          end;
        finally
          FDialChannels.UnlockList;
        end;
        if Served then
          SB.Add(Format('  dial  %-16s TRIGGERED (queued on the held channel)',
            [C.Teams[i].Name]))
        else if TooOld then
        begin
          if DVer = '' then
            DVer := 'pre-1.0.2';
          SB.Add(Format('  dial  %-16s SKIPPED - daemon is %s, too old to' +
            ' self-update (install 1.0.3 there once, by hand)',
            [C.Teams[i].Name, DVer]));
        end
        else
          SB.Add(Format('  dial  %-16s OFFLINE - re-trigger when it dials in' +
            ' (autoupdate=on catches it alone)', [C.Teams[i].Name]));
      end
      else if C.Teams[i].Host <> '' then
      begin
        HostKey := Format('|%s:%d|', [C.Teams[i].Host, C.Teams[i].Port]);
        if Pos(HostKey, Hosts) > 0 then
          Continue;   { one trigger per daemon host }
        Hosts := Hosts + HostKey;
        { 1000 ms per host — the smallest value the RTL can express (see
          pznet.RequestLine). The reply only goes out after this loop, so the
          console budget below must cover one second per unreachable host. }
        if RequestLine(C.Teams[i].Host, C.Teams[i].Port, 1000,
          BuildUpdate(C.Secret, 'pizarra', '', PV, Force),
          R, E) then
        begin
          RObj := ParseObj(R);
          Served := (RObj <> nil) and RObj.Get('ok', False);
          if RObj <> nil then
            RObj.Free;
          if Served then
            SB.Add(Format('  push  %s:%d TRIGGERED',
              [C.Teams[i].Host, C.Teams[i].Port]))
          else
            SB.Add(Format('  push  %s:%d refused (old daemon? update by hand)',
              [C.Teams[i].Host, C.Teams[i].Port]));
        end
        else
          SB.Add(Format('  push  %s:%d UNREACHABLE (%s)',
            [C.Teams[i].Host, C.Teams[i].Port, E]));
      end
      else if not IsAll then
      begin
        if C.Teams[i].TmuxSession = '' then
          SB.Add(Format('  inbox %-16s pull member - runs the hub host binary',
            [C.Teams[i].Name]))
        else
          SB.Add(Format('  local %-16s hub-host binary - update via make install',
            [C.Teams[i].Name]));
      end;
    end;
    if IsAll then
      SB.Add('  local/inbox teams: hub-host binary - updated by make install');
    FLog.Info('self-update trigger by console: ' + Name);
    O := TJSONObject.Create;
    try
      O.Add('ok', True);
      O.Add('tree', TrimRight(SB.Text));
      WriteLine(Data, O.AsJSON);
    finally
      O.Free;
    end;
  finally
    SB.Free;
  end;
end;

{ THE HUB decides which channel serves a team, never the caller. Accepting the
  served-team list from the client and validating acknowledgements against that
  same list would be circular: any valid credential could claim another team,
  read its pending mail, and acknowledge its queue arbitrarily far ahead.

  Return True when this channel may claim Team. Return False when another
  channel already serves it. If the existing channel has the SAME identity,
  drop the team from that older connection so a half-open link cannot prevent
  recovery. The caller holds the channel-list lock. }
function ClaimLocked(L: TList; const Team, From: string;
  out Holder: string): Boolean;
var
  i: Integer;
  Ch: TDialChannel;
begin
  Holder := '';
  for i := 0 to L.Count - 1 do
  begin
    Ch := TDialChannel(L[i]);
    if not Ch.Serves(Team) then
      Continue;
    if (From <> '') and SameText(Ch.From, From) then
    begin
      Ch.Drop(Team);   { Its own stale claim is removed before continuing. }
      Continue;
    end;
    Holder := Ch.From;
    if Holder = '' then
      Holder := '(no identity)';
    Exit(False);
  end;
  Result := True;
end;

procedure TPizarra.DoDial(Data: TSocketStream; const From, BoundTeam,
  TeamsCsv: string; KeepAlive: Integer; const DaemonVer: string);
var
  Ch: TDialChannel;
  Claimed, Served: TStringArray;
  C: TPizarraConfig;
  T: TTeam;
  Msgs: TPzMsgArray;
  HdrWfs: TWorkflowArray;
  HdrClean: TWfStrings;
  HdrBlock, Refused, ServedCsv, Holder, WantTeam: string;
  HdrN: Integer;
  Line, Ack, Full: string;
  WantSeq: Int64;
  IdleMs, i, j: Integer;
  AckObj, OkObj: TJSONObject;
  L: TList;

  procedure RejectTeam(const TeamName, Reason: string);
  begin
    if Refused <> '' then
      Refused := Refused + '; ';
    Refused := Refused + TeamName + ': ' + Reason;
  end;

  procedure AcceptTeam(const TeamName: string);
  begin
    SetLength(Served, Length(Served) + 1);
    Served[High(Served)] := TeamName;
  end;

  procedure InspectClaim(const Requested: string);
  begin
    if not FindTeam(C, Requested, T) then
      RejectTeam(Requested, 'not a hub team')
    else if not T.Dial then
      RejectTeam(T.Name, 'not dial=on in the SQLite registry (from the real ' +
        'console run: tiza team set ' + T.Name + ' dial on)')
    else if not ClaimLocked(L, T.Name, From, Holder) then
      RejectTeam(T.Name, 'already served by a dial channel from=' + Holder)
    else
      AcceptTeam(T.Name);   { canonical name, never the raw client value }
  end;

begin
  Claimed := SplitList(TeamsCsv);
  if Length(Claimed) = 0 then
  begin
    WriteLine(Data, ReplyErr('dial: no teams'));
    Exit;
  end;
  if KeepAlive < 5 then
    KeepAlive := 5;
  C := Snap;
  Served := nil;
  Refused := '';
  { Claiming and registering are one operation so concurrent channels cannot
    both acquire the same team. }
  L := FDialChannels.LockList;
  try
    if BoundTeam <> '' then
    begin
      { A bound credential determines scope, as with watch. The requested team
        list is used only to report mismatches. }
      for i := 0 to High(Claimed) do
        if not SameText(Claimed[i], BoundTeam) then
          RejectTeam(Claimed[i], 'this credential is bound to ' + BoundTeam);
      InspectClaim(BoundTeam);
    end
    else
      for i := 0 to High(Claimed) do
        InspectClaim(Claimed[i]);
    if Length(Served) > 0 then
    begin
      { register BEFORE the backlog snapshot so a message sent in between is
        not lost (the daemon dedupes by seq, so an overlap is harmless) }
      Ch := TDialChannel.Create(Served, From, BoundTeam);
      Ch.Ver := DaemonVer;
      L.Add(Ch);
    end;
  finally
    FDialChannels.UnlockList;
  end;
  ServedCsv := '';
  for i := 0 to High(Served) do
  begin
    if ServedCsv <> '' then ServedCsv := ServedCsv + ',';
    ServedCsv := ServedCsv + Served[i];
  end;
  { Log rejected dial claims at the hub so an excluded host is visible from
    both ends. }
  if Length(Served) = 0 then
  begin
    FLog.Info(Format('dial REFUSED from=%s bound=%s claimed=[%s]: %s',
      [From, BoundTeam, TeamsCsv, Refused]));
    WriteLine(Data, ReplyErr('dial: no serviceable team - ' + Refused));
    Exit;
  end;
  FLog.Info(Format('dial accepted from=%s bound=%s serving=[%s] ver=%s%s',
    [From, BoundTeam, ServedCsv, DaemonVer,
     BoolToStr(Refused <> '', '; refused: ' + Refused, '')]));
  if From = '' then
    FLog.Info('dial: hello with an empty from= - set [pizarra] self in ' +
      'tiza.conf, or the hub cannot tell two dial hosts apart');
  try
    try
      Data.IOTimeout := DIAL_ACK_MS;
      { The hello reports the teams the hub accepted and each rejection reason,
        rather than echoing the request. Existing daemons only consume `ok`, so
        the added fields remain backward compatible. }
      OkObj := TJSONObject.Create;
      try
        OkObj.Add('ok', True);
        OkObj.Add('teams', ServedCsv);
        if Refused <> '' then
          OkObj.Add('refused', Refused);
        WriteLine(Data, OkObj.AsJSON);
      finally
        OkObj.Free;
      end;
      { ADVERTISE THE PUBLISHED RELEASE IMMEDIATELY ON DIAL SETUP, not only after
        the first keepalive idle interval (see the ping at the bottom of this
        loop). A dial host on an unstable link can drop before KeepAlive seconds
        elapse, so a keepalive-only advertisement may never reach it and leave
        it silently stale. Sending the version at connection time makes even a
        brief window sufficient; stable hosts only receive an extra no-op check. }
      WriteLine(Data, BuildPing('', PublishedVer(C)));
      { Catch up pending deliveries for every team accepted by the hub. }
      for i := 0 to High(Served) do
        if FindTeam(C, Served[i], T) then
        begin
          Msgs := FStore.Since(FStore.DeliveredMark(T.Name), 0);
          for j := 0 to High(Msgs) do
            if SameText(Msgs[j].Dest, T.Name) then
            begin
              HdrWfs := FWf.CaptureHeader(T.Name, 5, HdrBlock, HdrN,
                HdrClean);
              Full := BuildDelivery(C, T, Msgs[j].From, Msgs[j].Text,
                HdrBlock, FStore.DeliveredMark(T.Name) = 0, HdrN,
                WfHeaderBlock(C, T.Name, HdrWfs, HdrClean), Msgs[j].Ident);
              { No secret; see the BuildUpdate security invariant above. }
              Ch.Push(BuildDeliver('', Msgs[j].Seq, Msgs[j].From, T.Name,
                Full), T.Name, Msgs[j].Seq);
            end;
        end;
      { deliver loop: drain -> write -> read ack; ping when idle }
      IdleMs := 0;
      while not ShutdownRequested do
      begin
        if Ch.Pop(Line, WantTeam, WantSeq) then
        begin
          WriteLine(Data, Line);
          Ack := ReadLine(Data);
          if Ack = '' then
            raise Exception.Create('dial: no ack (peer gone/slow)');
          AckObj := ParseObj(Ack);
          if AckObj = nil then
            raise Exception.Create('dial: unparseable ack');
          try
            { Validate the acknowledgement against the exact line just written,
              not a client-selected team list. Because the durable delivered
              mark only advances, accepting an invented sequence could suppress
              future traffic permanently. Empty WantTeam is a control line. }
            if AckObj.Get('ok', False) and (WantTeam <> '') then
            begin
              if (not SameText(AckObj.Get('team', ''), WantTeam)) or
                 (AckObj.Get('seq', Int64(0)) <> WantSeq) then
                raise Exception.CreateFmt(
                  'dial: ack mismatch (wrote %s/%d, got %s/%d)',
                  [WantTeam, WantSeq, AckObj.Get('team', ''),
                   AckObj.Get('seq', Int64(0))]);
              FStore.MarkDelivered(WantTeam, WantSeq);
            end;
          finally
            AckObj.Free;
          end;
          IdleMs := 0;
        end
        else
        begin
          Sleep(200);
          Inc(IdleMs, 200);
          if IdleMs >= KeepAlive * 1000 then
          begin
            { keep NAT alive; no ack — and advertise the PUBLISHED release so
              an autoupdate daemon notices new builds within one keepalive }
            WriteLine(Data, BuildPing('', PublishedVer(C)));
            IdleMs := 0;
          end;
        end;
      end;
    except
      { dead/slow daemon or shutdown: unsubscribe quietly, backlog replays next }
    end;
  finally
    FDialChannels.Remove(Ch);
    Ch.Free;
  end;
end;

{ Create one directory per team plus console/ with mode 1777: world-writable,
  sticky bit — a team can delete only its own uploads. The configured root is
  an operator-owned mount: NEVER create or chmod it. If it is absent (for
  example, NFS is not mounted), leave it untouched and retry on the next
  watchdog tick. Called at startup, on each tick, and after /team add. Never
  fatal. }
procedure TPizarra.EnsureSharedDirs;
var
  C: TPizarraConfig;
  i, RootFd: Integer;
  DescriptorRoot: string;

  procedure MkDir1777(const P: string);
  var
    St: TStat;
    DirFd, OpenFlags: Integer;
  begin
    { One level only. ForceDirectories could recreate a missing mount root
      locally after an NFS outage or a check/create race. EEXIST is resolved by
      the descriptor open below, which rejects links and non-directories. }
    if FpMkDir(P, &1777) <> 0 then
      if fpgeterrno <> ESysEEXIST then
        Exit;
    OpenFlags := O_NOFOLLOW;
    {$IFDEF LINUX}OpenFlags := OpenFlags or O_CLOEXEC;{$ENDIF}
    repeat
      DirFd := PzOpenDirFd(P, OpenFlags);
    until (DirFd >= 0) or (fpgeterrno <> ESysEINTR);
    if DirFd < 0 then
      Exit;
    try
      St := Default(TStat);
      if (FpFStat(DirFd, St) <> 0) or (not fpS_ISDIR(St.st_mode)) then
        Exit;
      { fchmod the pinned inode: lstat(P) followed by chmod(P) could be
        redirected to a symlink inserted between those two calls. }
      C_FChmod(DirFd, &1777);
    finally
      FpClose(DirFd);
    end;
  end;

  function WriteAll(Fd: Integer; const S: string): Boolean;
  var
    Done: SizeInt;
    N: TSSize;
  begin
    Result := False;
    Done := 0;
    while Done < Length(S) do
    begin
      repeat
        N := FpWrite(Fd, S[Done + 1], Length(S) - Done);
      until (N >= 0) or (fpgeterrno <> ESysEINTR);
      if N <= 0 then
        Exit;
      Inc(Done, N);
    end;
    Result := True;
  end;

var
  Txt, ManualPath: string;
  RootStat: TStat;
  ManualFd, ManualFlags: Integer;
  ManualOk: Boolean;
begin
  C := Snap;
  if C.SharedDir = '' then
    Exit;
  { Defense in depth: the loader rejects root. More importantly, opening the
    operator-created mount directory pins it without following a final symlink.
    We never ForceDirectories or chmod this configured root. }
  if C.SharedDir = PathDelim then
    Exit;
  ManualFlags := O_NOFOLLOW;
  {$IFDEF LINUX}ManualFlags := ManualFlags or O_CLOEXEC;{$ENDIF}
  repeat
    RootFd := PzOpenDirFd(C.SharedDir, ManualFlags);
  until (RootFd >= 0) or (fpgeterrno <> ESysEINTR);
  if RootFd < 0 then
    Exit;
  try
    try
    RootStat := Default(TStat);
    if (FpFStat(RootFd, RootStat) <> 0) or
       (not fpS_ISDIR(RootStat.st_mode)) then
      Exit;
    DescriptorRoot := '/proc/self/fd/' + IntToStr(RootFd);
    MkDir1777(DescriptorRoot + '/console');
    for i := 0 to High(C.Teams) do
      MkDir1777(DescriptorRoot + '/' + LowerCase(C.Teams[i].Name));
    { the onboarding manual a cold-start agent reads first (header points
      at it); rewritten whenever missing, so it survives NFS wipes and
      updates on hub restarts (startup deletes it first) }
    ManualPath := DescriptorRoot + '/' + SHARED_MANUAL;
    ManualFlags := O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW;
    {$IFDEF LINUX}ManualFlags := ManualFlags or O_CLOEXEC;{$ENDIF}
    repeat
      ManualFd := FpOpen(ManualPath, ManualFlags, &600);
    until (ManualFd >= 0) or (fpgeterrno <> ESysEINTR);
    if ManualFd >= 0 then
    begin
      ManualOk := False;
      try
        Txt := AgentsManualText;
        ManualOk := WriteAll(ManualFd, Txt) and
          (C_FChmod(ManualFd, &644) = 0) and (PzFsync(ManualFd) = 0);
      finally
        FpClose(ManualFd);
      end;
      if not ManualOk then
        FpUnlink(ManualPath);
    end;
    except
      { NFS down: retried on the next watchdog tick }
    end;
  finally
    FpClose(RootFd);
  end;
end;

{ Copy-on-read config snapshot. Mutators build a NEW Teams array and swap it
  under FCfgLock; taking the record copy under the same lock bumps the array
  refcount safely, so readers keep a consistent view while /team commands
  replace the live config (FPC SetLength may reallocate — never mutate the
  shared array in place). }
function TPizarra.Snap: TPizarraConfig;
begin
  FCfgLock.Enter;
  try
    Result := FCfg;
  finally
    FCfgLock.Leave;
  end;
end;

{ A read-only subordinate is omitted from the general team index because it is
  part of its leader and should not be discovered as a direct collaborator. Its
  leader, the console, and the team itself still see it. This is discovery
  filtering, not an authorization boundary: group membership and inbox routing
  continue to work normally. }
function TPizarra.ReplyTeams(const Asker: string): string;
var
  O, T: TJSONObject;
  A: TJSONArray;
  i: Integer;
  C: TPizarraConfig;

  function Visible(const Tm: TTeam): Boolean;
  begin
    { Do not add "Asker = ''". Older clients may omit their identity; treating
      them as privileged would expose every read-only subordinate. Anonymous
      callers may still see ordinary teams, but no subordinates. }
    Result := (not Tm.Slave) or SameText(Asker, 'console') or
              SameText(Asker, Tm.Name) or SameText(Asker, Tm.Parent);
  end;

begin
  C := Snap;
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('shared_dir', C.SharedDir);
    A := TJSONArray.Create;
    for i := 0 to High(C.Teams) do
    begin
      if not Visible(C.Teams[i]) then
        Continue;
      T := TJSONObject.Create;
      T.Add('id', C.Teams[i].Id);
      T.Add('name', C.Teams[i].Name);
      T.Add('speciality', C.Teams[i].Speciality);
      T.Add('parent', C.Teams[i].Parent);
      T.Add('open_tasks', FTasks.OpenCount(C.Teams[i].Name));
      T.Add('slave', C.Teams[i].Slave);
      T.Add('workdir', C.Teams[i].Workdir);
      if C.Teams[i].Host <> '' then
        T.Add('host', Format('%s:%d', [C.Teams[i].Host, C.Teams[i].Port]));
      { live pane-activity, if a daemon reports it for this team (opt-in) }
      if ActivityLabel(C.Teams[i].Name) <> '' then
        T.Add('activity', ActivityLabel(C.Teams[i].Name));
      A.Add(T);
    end;
    O.Add('teams', A);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ Deep-copy groups before candidate mutations. A record assignment shares both
  the group array and each member list, which would otherwise publish changes
  to live memory even when persistence failed. }
function DeepCopyGroups(const G: TGroupArray): TGroupArray;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(G));
  for i := 0 to High(G) do
  begin
    Result[i] := G[i];
    Result[i].Members := Copy(G[i].Members);
  end;
end;

function ReplyTask(const T: TTask): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('task', TaskToJson(T));
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ true if V already appears in A. Small linear scan: dependency lists are a
  handful of step numbers, never long enough to warrant a set. }
function IntInList(const A: array of Integer; V: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(A) do
    if A[i] = V then
      Exit(True);
end;

{ '' = FIELD is a whole-number id the engine can act on, or is absent (its own
  default then applies); a non-empty result is the reason to refuse. This is
  pzweb.StepOf's four-part guard brought to the WIRE — the browser helper has
  validated all along while the bus Get-default did none of it, so a message
  built by hand (or by a buggy client) reached the engine with a wrong-target id:
    - a string/bool id is refused: the wire carries ids as JSON numbers; a
      quoted "2" is NOT read as the number it looks like, so Get's default fires
      and the op silently acts on target 0 (the active step / no parent);
    - a FRACTIONAL number is refused: 2.9 would Round to 3 and close/edit a
      DIFFERENT id than the caller named, with ok:true;
    - when GUARD32, a value above MaxInt is refused: 2147483648 wraps to a
      non-positive Integer, the step/task constructor OMITS it, and the 0-default
      then closes the CALLER'S OWN ACTIVE step. This upper bound is the fourth
      part StepOf carries and a three-part guard would miss it.
  MinVal is the lowest legal value: 0 where 0 is a documented 'active/none'
  sentinel (step, parent), 1 where only a real id is meaningful. }
function BadIdField(Obj: TJSONObject; const Field: string; MinVal: Int64;
  Guard32: Boolean): string;
var
  D: TJSONData;
begin
  Result := '';
  D := Obj.Find(Field);
  if D = nil then
    Exit;                          { absent: the caller's default applies }
  if D.JSONType <> jtNumber then
    Exit(Field + ' must be a whole number, not text: a quoted id is read as ' +
      '"absent" and the op would silently act on the default target instead ' +
      'of the one you named');
  if Frac(D.AsFloat) <> 0 then
    Exit(Field + ' must be a whole number: a fractional value rounds to a ' +
      'DIFFERENT id and the op would act on the wrong target');
  if D.AsFloat < MinVal then
    Exit(Format('%s must be at least %d', [Field, MinVal]));
  if Guard32 and (D.AsFloat > 2147483647) then
    Exit(Field + ' is too large: it would overflow a 32-bit id and wrap to a ' +
      'non-positive value, closing/editing the wrong (often the ACTIVE) target');
end;

procedure TPizarra.HandleTask(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  Op, Title, TeamName, Milestone, State, Text, Filter, GName: string;
  TaskWhy, DelTitle: string;
  C: TPizarraConfig;
  Team, FromTeam: TTeam;
  Grp: TGroup;
  T, PT: TTask;
  Id, ParentId: Integer;
  Arr: TTaskArray;
  Kids: TIntArray;
  O: TJSONObject;
  A, KA: TJSONArray;
  i, n: Integer;
  Disp: string;
  FromIsTeam, IsGroup: Boolean;
  Gate: TWfGate;
  WfRes: TWfResult;

  { Task creation/(re)assignment is OPEN: any team may create or assign a task
    for ANY other team — same group or a different one — so teams coordinate
    freely (operator policy; a subordinate can hand work to its boss or a peer).
    The target team's existence is still validated below; the human console is
    likewise unrestricted. A team must name a target team (no anonymous backlog
    adds from a team). }

begin
  C := Snap;
  Op := LowerCase(Obj.Get('op', ''));
  { The id names the task to act on. A fractional or oversized id would round or
    wrap to a DIFFERENT task (state/note/done/delete are all destructive), so it
    is refused before use; 0 stays legal (the 'no id' sentinel, e.g. for add). }
  Disp := BadIdField(Obj, 'id', 0, True);
  if Disp <> '' then
  begin
    WriteLine(Data, ReplyErr(Disp));
    Exit;
  end;
  Id := Obj.Get('id', 0);
  FromIsTeam := FindTeam(C, From, FromTeam);
  { Delegation for the `task` family grants console authority within this
    handler while preserving the real sender in the journal. }
  if FromIsTeam and TeamDelegated(C, From, 'task') then
    FromIsTeam := False;

  if Op = 'add' then
  begin
    Title := Trim(Obj.Get('title', ''));
    TeamName := Trim(Obj.Get('team', ''));
    Milestone := Trim(Obj.Get('hito', ''));
    if Title = '' then
    begin
      WriteLine(Data, ReplyErr('empty title'));
      Exit;
    end;
    if TeamName = '-' then
      TeamName := '';
    if (TeamName <> '') and (not FindTeam(C, TeamName, Team)) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + TeamName));
      Exit;
    end;
    if TeamName <> '' then
      TeamName := Team.Name;   { canonical name even if addressed by id }
    if FromIsTeam and (TeamName = '') then
    begin
      WriteLine(Data, ReplyErr(Format(
        'team %s must create the task for a target team (its name or id)',
        [FromTeam.Name])));
      Exit;
    end;
    { A present field of the wrong JSON type is not an absent field. The typed
      Get overload returns its default when `parent` exists but is not numeric,
      silently moving a task to the root. Validate this command locally because
      the same field names deliberately have different types in other commands. }
    { parent names the task this subtask hangs under. A string was already
      refused (a quoted id reads as "no parent" -> a ROOT task, not a subtask);
      the guard now also refuses a FRACTIONAL parent (0.9 -> Round 1 -> attaches
      to the WRONG task) and an overflowing one. 0 stays legal: it is the
      documented "no parent" sentinel. }
    Disp := BadIdField(Obj, 'parent', 0, True);
    if Disp <> '' then
    begin
      WriteLine(Data, ReplyErr(Disp));
      Exit;
    end;
    ParentId := Obj.Get('parent', 0);
    if (ParentId > 0) and (not FTasks.Get(ParentId, PT)) then
    begin
      WriteLine(Data, ReplyErr(Format('parent task #%d does not exist', [ParentId])));
      Exit;
    end;
    T := FTasks.Add(Title, TeamName, Milestone, [], ParentId, TaskWhy);
    if T.Id = 0 then
    begin
      { Creation was fully rolled back; do not announce or journal a task that
        does not exist. }
      WriteLine(Data, ReplyErr('task not created: ' + TaskWhy));
      Exit;
    end;
    if TeamName = '' then
      Disp := 'backlog'
    else
      Disp := TeamName;
    if ParentId > 0 then
      Disp := Disp + Format(' (subtask of #%d)', [ParentId]);
    Broadcast(EvTask(Format('task #%d created -> %s (%s): %s',
      [T.Id, Disp, From, T.Title])), 0);
    FLog.Info(Format('task #%d add -> %s by %s', [T.Id, Disp, From]));
    WriteLine(Data, ReplyTask(T));
  end
  else if Op = 'state' then
  begin
    State := Trim(Obj.Get('state', ''));
    if State = '' then
    begin
      WriteLine(Data, ReplyErr('empty state'));
      Exit;
    end;
    { workflow gate BEFORE SetState: a task linked to a live workflow step
      only moves as the workflow allows, and closing it IS the milestone's
      done transition - tareas.json and workflows.json cannot desync }
    Gate := FWf.GateTask(Id, State, From, not FromIsTeam);
    if Gate.WfDone then
    begin
      WfRes := FWf.DoneStep(Gate.WfName, Gate.StepN, From,
        SameText(From, WfBossOf(C, Gate.WfName)), not FromIsTeam);
      if not WfRes.Ok then
      begin
        WriteLine(Data, ReplyErr(WfRes.Err));
        Exit;
      end;
      WfFeed(WfRes);
      DrainWfOutbox(C, Gate.WfName);
      if FTasks.Get(Id, T) then
        WriteLine(Data, ReplyTask(T))
      else
        WriteLine(Data, ReplyOk);
      Exit;
    end;
    if not Gate.Allow then
    begin
      WriteLine(Data, ReplyErr(Gate.Why));
      Exit;
    end;
    if not FTasks.SetState(Id, State, From, T, TaskWhy) then
      { False may mean a found change was rolled back after a storage failure.
        Preserve the store's specific reason instead of reporting not found. }
      if TaskWhy <> '' then
        WriteLine(Data, ReplyErr(Format('task #%d: %s',
          [Id, TaskWhy])))
      else
        WriteLine(Data, ReplyErr(Format('task #%d does not exist', [Id])))
    else
    begin
      Broadcast(EvTask(Format('task #%d state %s (%s)', [T.Id, T.StateS, From])), 0);
      FLog.Info(Format('task #%d state=%s by %s', [T.Id, T.StateS, From]));
      WriteLine(Data, ReplyTask(T));
    end;
  end
  else if Op = 'delete' then
  begin
    { Deletion is destructive and requires the task owner or console authority
      for this family. Unowned backlog tasks belong to the console, not every
      authenticated team. The store also protects workflow-bound tasks and
      parents with children, returning actionable reasons. }
    if FromIsTeam and FTasks.Get(Id, T) and
       ((T.Team = '') or (not SameText(T.Team, From))) then
    begin
      if T.Team = '' then
        WriteLine(Data, ReplyErr(Format('task #%d has no owner: it is backlog, ' +
          'and only the console may delete it. Assign it to yourself first if ' +
          'it is yours', [Id])))
      else
        WriteLine(Data, ReplyErr(Format('only %s (the owner) or the console may ' +
          'delete task #%d', [T.Team, Id])));
      Exit;
    end;
    { Capture the title before deletion so the notification remains useful. }
    if FTasks.Get(Id, T) then
      DelTitle := T.Title
    else
      DelTitle := '';
    if FTasks.Delete(Id, From, TaskWhy) then
    begin
      FLog.Info(Format('task #%d deleted by %s', [Id, From]));
      { Broadcast deletion just like creation, status, assignment, and notes so
        live clients do not silently retain a vanished task. }
      Broadcast(EvTask(Format('task #%d deleted (%s): %s',
        [Id, From, DelTitle])), 0);
      WriteLine(Data, ReplyOkNote(Format('task #%d deleted', [Id])));
    end
    else
      WriteLine(Data, ReplyErr(Format('task #%d: %s', [Id, TaskWhy])));
    Exit;
  end
  else if Op = 'assign' then
  begin
    { linked tasks may not be reassigned: milestone ownership lives in the
      workflow (refusal names the workflow + step) }
    if not FWf.GateAssign(Id, GName) then
    begin
      WriteLine(Data, ReplyErr(GName));
      Exit;
    end;
    TeamName := Trim(Obj.Get('team', ''));
    if TeamName = '-' then
      TeamName := ''
    else if not FindTeam(C, TeamName, Team) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + TeamName));
      Exit;
    end
    else
      TeamName := Team.Name;
    if FromIsTeam and (TeamName = '') then
    begin
      WriteLine(Data, ReplyErr(Format(
        'team %s must name a target team to assign the task to', [FromTeam.Name])));
      Exit;
    end;
    { reassignment moves OWNERSHIP: only the task's current owner (or the
      console) may hand it to another team — a team cannot yank another team's
      task. An unassigned task (no owner) may be claimed by anyone. }
    if FromIsTeam and FTasks.Get(Id, T) and (T.Team <> '')
       and (not SameText(From, T.Team)) then
    begin
      WriteLine(Data, ReplyErr(Format(
        'only %s (the current owner) or the console may reassign task #%d',
        [T.Team, Id])));
      Exit;
    end;
    if not FTasks.AssignTo(Id, TeamName, T, TaskWhy) then
      { False may also represent a rolled-back storage failure; return the
        store's reason rather than incorrectly saying the task was absent. }
      if TaskWhy <> '' then
        WriteLine(Data, ReplyErr(Format('task #%d: %s',
          [Id, TaskWhy])))
      else
        WriteLine(Data, ReplyErr(Format('task #%d does not exist', [Id])))
    else
    begin
      if TeamName = '' then
        Disp := 'backlog'
      else
        Disp := TeamName;
      Broadcast(EvTask(Format('task #%d assigned -> %s (%s)', [T.Id, Disp, From])), 0);
      WriteLine(Data, ReplyTask(T));
    end;
  end
  else if Op = 'note' then
  begin
    Text := Trim(Obj.Get('text', ''));
    if not FTasks.AddNote(Id, From, Text, T, TaskWhy) then
      { False may also represent a rolled-back storage failure; preserve the
        store's detailed reason. }
      if TaskWhy <> '' then
        WriteLine(Data, ReplyErr(Format('task #%d: %s',
          [Id, TaskWhy])))
      else
        WriteLine(Data, ReplyErr(Format('task #%d does not exist', [Id])))
    else
    begin
      Broadcast(EvTask(Format('note on task #%d (%s)', [T.Id, From])), 0);
      WriteLine(Data, ReplyTask(T));
    end;
  end
  else if Op = 'list' then
  begin
    Filter := LowerCase(Trim(Obj.Get('filter', 'open')));
    TeamName := Trim(Obj.Get('team', ''));
    { The team slot also accepts a group — same resolution as message
      destinations: '@name' forces the named group; a bare name that is NOT
      a team but IS a group resolves to that group (a team wins the name
      clash). A group filter lists its MEMBERS' tasks (members only, like
      group fan-out; the boss's tasks live under the boss's own name). }
    IsGroup := False;
    if (TeamName <> '') and (TeamName[1] = '@') then
    begin
      GName := Trim(Copy(TeamName, 2, Length(TeamName)));
      if GName = '' then
      begin
        WriteLine(Data, ReplyErr('empty group name'));
        Exit;
      end;
      if not FindGroup(C, GName, Grp) then
      begin
        WriteLine(Data, ReplyErr('unknown group: ' + GName));
        Exit;
      end;
      IsGroup := True;
    end
    else if (TeamName <> '') and (not FindTeam(C, TeamName, Team))
            and FindGroup(C, TeamName, Grp) then
      IsGroup := True;
    if IsGroup then
    begin
      Arr := FTasks.List(Filter, '');
      n := 0;
      for i := 0 to High(Arr) do
        if TeamInList(Grp.Members, Arr[i].Team) then
        begin
          Arr[n] := Arr[i];
          Inc(n);
        end;
      SetLength(Arr, n);
    end
    else if (TeamName <> '') and (Filter = 'open') and
            (not FindTeam(C, TeamName, Team)) then
      { the word is neither a team nor a group: treat it as an exact-state
        filter ('tiza task list error') — same free-string doctrine as List }
      Arr := FTasks.List(TeamName, '')
    else
      Arr := FTasks.List(Filter, TeamName);
    O := TJSONObject.Create;
    try
      O.Add('ok', True);
      A := TJSONArray.Create;
      { Keep list responses lightweight: clients fetch notes with the task card.
        The note count remains useful in the list. }
      for i := 0 to High(Arr) do
        A.Add(TaskToJsonLight(Arr[i]));
      O.Add('tasks', A);
      WriteLine(Data, O.AsJSON);
    finally
      O.Free;
    end;
  end
  else if Op = 'show' then
  begin
    if not FTasks.Get(Id, T) then
      WriteLine(Data, ReplyErr(Format('task #%d does not exist', [Id])))
    else
    begin
      O := TJSONObject.Create;
      try
        O.Add('ok', True);
        O.Add('task', TaskToJson(T));
        Kids := FTasks.ChildrenOf(T.Id);
        KA := TJSONArray.Create;
        for i := 0 to High(Kids) do
          KA.Add(Kids[i]);
        O.Add('subtasks', KA);
        WriteLine(Data, O.AsJSON);
      finally
        O.Free;
      end;
    end;
  end
  else
    WriteLine(Data, ReplyErr('unknown task op'));
end;

function TeamCard(const T: TTeam; const Apps: string = '';
  const C: PPizarraConfig = nil): string;
var
  O, J: TJSONObject;
  Arr: TJSONArray;
  AO: TJSONObject;
  i: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    J := TJSONObject.Create;
    J.Add('id', T.Id);
    J.Add('name', T.Name);
    J.Add('speciality', T.Speciality);
    J.Add('prompt', T.Prompt);
    J.Add('parent', T.Parent);
    if T.Host <> '' then
      J.Add('host', Format('%s:%d', [T.Host, T.Port]));
    { how this team is actually reached — an absent/empty host is NOT proof of
      a local tmux team: dial-in and inbox-only teams have no host either }
    if T.Dial then
      J.Add('kind', 'dial')
    else if T.Host <> '' then
      J.Add('kind', 'push')
    else if T.TmuxSession = '' then
      J.Add('kind', 'inbox')
    else
      J.Add('kind', 'local');
    J.Add('session', T.TmuxSession);
    J.Add('launch', T.Launch);
    J.Add('user', T.User);
    J.Add('apps', Apps);   { applications this team is responsible for }
    J.Add('project', T.Project);
    J.Add('slave', T.Slave);   { read-only subordinate; answers only its leader }
    { Surface ambiguous matching sessions because delivery may be targeting an
      unattended pane. }
    if (T.Host = '') and (not T.Dial) and (T.TmuxSession <> '') then
      J.Add('other_sessions', OtherSessionsLike(T.Name, T.TmuxSession));
    J.Add('workdir', T.Workdir);   { source directory where the team operates }
    { the detailed view: each owned app with its purpose and whether it has a
      manual, plus the groups the team belongs to }
    if C <> nil then
    begin
      Arr := TJSONArray.Create;
      for i := 0 to High(C^.Apps) do
        if SameText(C^.Apps[i].Team, T.Name) then
        begin
          AO := TJSONObject.Create;
          AO.Add('name', C^.Apps[i].Name);
          AO.Add('purpose', C^.Apps[i].Purpose);
          AO.Add('repo', C^.Apps[i].Repo);
          AO.Add('path', C^.Apps[i].Path);
          AO.Add('hasdoc', C^.Apps[i].HasDoc);
          Arr.Add(AO);
        end;
      J.Add('appsdetail', Arr);
      J.Add('groups', GroupsOf(C^, T.Name));
    end;
    O.Add('team', J);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ Runtime team management (cmd=team). Mutations are copy-on-write: build a
  new Teams array, validate it, commit the authoritative SQLite transaction,
  then publish the new FCfg snapshot under FCfgLock.
  Enforcement mirrors tasks: the console is unrestricted, a TEAM may only act
  on itself/its subtree, and new teams must hang from the caller's subtree. }
procedure TPizarra.HandleTeam(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C, NewCfg: TPizarraConfig;
  FromTeam, Team, PT: TTeam;
  FromIsTeam: Boolean;
  Op, Name, Field, Value, HostV, DbErrT, OldVal, HistNew, GrpTouched: string;
  SessRaw: string;
  TouchedG: TGroupArray;
  i, j, n, MembN, ExclN, MaxId: Integer;
  SlaveV, StillThere, GroupChanged: Boolean;

  function InSubtree(const Target: string): Boolean;
  begin
    if not FromIsTeam then
      Exit(True);
    Result := SameText(Target, FromTeam.Name) or
      IsSubordinate(C, Target, FromTeam.Name);
  end;

  function ValidDelegation(const S: string; out Bad: string): Boolean;
  var
    Parts_: TStringArray;
    a, b: Integer;
    Found: Boolean;
  begin
    Result := False;
    Bad := '';
    Parts_ := SplitList(S);
    for a := 0 to High(Parts_) do
    begin
      Found := False;
      for b := Low(DELEGATE_FAMILIES) to High(DELEGATE_FAMILIES) do
        if SameText(Parts_[a], DELEGATE_FAMILIES[b]) then
          Found := True;
      if not Found then
      begin
        Bad := Parts_[a];
        Exit;
      end;
    end;
    Result := True;
  end;

begin
  C := Snap;
  Op := LowerCase(Obj.Get('op', ''));
  Name := Trim(Obj.Get('name', ''));
  FromIsTeam := FindTeam(C, From, FromTeam);
  { Delegation for the `team` family grants console authority within this
    handler without changing the sender identity recorded in history. }
  if FromIsTeam and TeamDelegated(C, From, 'team') then
    FromIsTeam := False;

  if Op = 'list' then
  begin
    WriteLine(Data, ReplyTeams(From));
    Exit;
  end;

  if Op = 'show' then
  begin
    if not FindTeam(C, Name, Team) then
      WriteLine(Data, ReplyErr('unknown team: ' + Name))
    else
      WriteLine(Data, TeamCard(Team, AppsOf(C, Team.Name), @C));
    Exit;
  end;

  if Op = 'add' then
  begin
    if (Name = '') or ReservedName(Name) or (not SafeName(Name)) then
    begin
      WriteLine(Data, ReplyErr(
        'invalid/reserved team name (allowed: letters, digits, . _ -, start alnum): '
        + Name));
      Exit;
    end;
    if FindTeam(C, Name, Team) then
    begin
      WriteLine(Data, ReplyErr('team already exists: ' + Name));
      Exit;
    end;
    { Clear the entire record before populating it. An `out` parameter clears
      managed strings but not scalar fields; partial initialization could give
      a new team arbitrary boolean flags. }
    Team := Default(TTeam);
    Team.Speciality := Trim(Obj.Get('speciality', ''));
    Team.Prompt := Obj.Get('prompt', '');
    Team.Parent := Trim(Obj.Get('parent', ''));
    if (Team.Parent <> '') and (not FindTeam(C, Team.Parent, PT)) then
    begin
      WriteLine(Data, ReplyErr('unknown parent: ' + Team.Parent));
      Exit;
    end;
    if Team.Parent <> '' then
      Team.Parent := PT.Name;
    if FromIsTeam and ((Team.Parent = '') or (not InSubtree(Team.Parent))) then
    begin
      WriteLine(Data, ReplyErr(Format(
        'hierarchy: %s may only add teams under its own subtree (use --parent)',
        [FromTeam.Name])));
      Exit;
    end;
    HostV := Trim(Obj.Get('host', ''));
    { a non-console caller must not create a LOCAL team: the watchdog would run
      its 'launch' as a process on the hub host. A team may only add remote
      subordinates that run on their own tiza host (host=ip[:port]). }
    if FromIsTeam and (HostV = '') then
    begin
      WriteLine(Data, ReplyErr(
        'only the console may add a local team; a team must add remote '
        + 'subordinates with host=ip[:port]'));
      Exit;
    end;
    if HostV <> '' then
    begin
      SplitHostPort(HostV, Team.Host, Team.Port);
      Team.TmuxSession := '';
      Team.Launch := '';
    end
    else
    begin
      Team.Host := '';
      Team.Port := 0;
      { Empty and `-` are distinct: absent means use the default session, while
        `-` explicitly creates an inbox-only team with no tmux or push target. }
      SessRaw := Trim(Obj.Get('session', ''));
      if SessRaw = '' then
        Team.TmuxSession := 'team-' + LowerCase(Name)
      else
        Team.TmuxSession := NormSession(SessRaw);
      Team.Launch := Obj.Get('launch', '');
    end;
    Team.Name := Name;
    { FindTeam returned Team via an out param: managed fields (strings) are
      auto-cleared, but Dial (Boolean) is not — initialize it so a CLI-added
      team is never accidentally a dial-in team (those are config-file only). }
    Team.Dial := False;

    FCfgLock.Enter;
    try
      { recheck under the lock: another connection may have added this name
        between our snapshot and here (TOCTOU) }
      MaxId := 0;
      for i := 0 to High(FCfg.Teams) do
      begin
        if SameText(FCfg.Teams[i].Name, Name) then
        begin
          { Exit runs the finally (single Leave) — do NOT Leave here }
          WriteLine(Data, ReplyErr('team already exists: ' + Name));
          Exit;
        end;
        if FCfg.Teams[i].Id > MaxId then
          MaxId := FCfg.Teams[i].Id;
      end;
      Team.Id := MaxId + 1;
      NewCfg := FCfg;
      NewCfg.Teams := Copy(FCfg.Teams);
      n := Length(NewCfg.Teams);
      SetLength(NewCfg.Teams, n + 1);
      NewCfg.Teams[n] := Team;
      ValidateParents(NewCfg);
      if not FDb.TeamUpsert(TeamRowDb(Team), From, True, '', '', '', '',
        DbErrT) then
      begin
        WriteLine(Data, ReplyErr('team not added: ' + DbErrT));
        Exit;
      end;
      FCfg := NewCfg;
    finally
      FCfgLock.Leave;
    end;
    FStore.EnsureDest(Team.Name);
    EnsureSharedDirs;
    FLog.Info(Format('team %s added (id=%d) by %s', [Team.Name, Team.Id, From]));
    Broadcast(EvSys(Format('team %s added (id=%d) by %s',
      [Team.Name, Team.Id, From])), 0);
    WriteLine(Data, TeamCard(Team, AppsOf(Snap, Team.Name)));
    Exit;
  end;

  if Op = 'remove' then
  begin
    if not FindTeam(C, Name, Team) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + Name));
      Exit;
    end;
    if FromIsTeam and ((SameText(Team.Name, FromTeam.Name)) or
       (not InSubtree(Team.Name))) then
    begin
      WriteLine(Data, ReplyErr(Format(
        'hierarchy: %s may only remove its own subordinates', [FromTeam.Name])));
      Exit;
    end;
    if SubordinatesOf(C, Team.Name) <> '' then
    begin
      WriteLine(Data, ReplyErr('team has subordinates - remove or reassign them first'));
      Exit;
    end;
    { the workflow guard runs before the open-tasks one: a live workflow's
      linked task IS an open task, and the workflow is the real blocker }
    HostV := FWf.TeamBusy(Team.Name);
    if HostV <> '' then
    begin
      WriteLine(Data, ReplyErr(Format('team owns a step in workflow %s - ' +
        'finish or abort it first', [HostV])));
      Exit;
    end;
    if FTasks.OpenCount(Team.Name) > 0 then
    begin
      WriteLine(Data, ReplyErr('team has open tasks - close or reassign them first'));
      Exit;
    end;
    { applications must never be orphaned: a team removed while owning apps
      would leave records pointing at a name that no longer exists — and a
      later team reusing that name would inherit them, manuals included }
    HostV := AppsOf(C, Team.Name);
    if HostV <> '' then
    begin
      WriteLine(Data, ReplyErr(Format('team is responsible for applications ' +
        '(%s) - reassign them first: tiza app set <app> team <other|->',
        [HostV])));
      Exit;
    end;
    if Length(FStore.PendingFor(Team.Name)) > 0 then
    begin
      WriteLine(Data, ReplyErr('team has pending deliveries - wait or check the host'));
      Exit;
    end;
    FCfgLock.Enter;
    try
      NewCfg := FCfg;
      { Deep-copy groups before changing member lists so failed persistence
        cannot leak a side effect into FCfg. }
      NewCfg.Groups := DeepCopyGroups(FCfg.Groups);
      NewCfg.Teams := nil;
      SetLength(NewCfg.Teams, Length(FCfg.Teams));
      n := 0;
      for i := 0 to High(FCfg.Teams) do
        if FCfg.Teams[i].Id <> Team.Id then
        begin
          NewCfg.Teams[n] := FCfg.Teams[i];
          Inc(n);
        end;
      SetLength(NewCfg.Teams, n);
      ValidateParents(NewCfg);   { children of a removed team become roots }
      { Group membership is derived state and must be cleaned with team removal.
        Leaving a missing recipient could make a later workflow halt at its
        synthetic root step with no command path to recover. }
      GrpTouched := '';
      SetLength(TouchedG, 0);
      for i := 0 to High(NewCfg.Groups) do
      begin
        GroupChanged := False;
        MembN := 0;
        for j := 0 to High(NewCfg.Groups[i].Members) do
          if not SameText(NewCfg.Groups[i].Members[j], Team.Name) then
          begin
            NewCfg.Groups[i].Members[MembN] := NewCfg.Groups[i].Members[j];
            Inc(MembN);
          end;
        if MembN <> Length(NewCfg.Groups[i].Members) then
        begin
          SetLength(NewCfg.Groups[i].Members, MembN);
          GroupChanged := True;
        end;
        ExclN := 0;
        for j := 0 to High(NewCfg.Groups[i].Excluded) do
          if not SameText(NewCfg.Groups[i].Excluded[j], Team.Name) then
          begin
            NewCfg.Groups[i].Excluded[ExclN] := NewCfg.Groups[i].Excluded[j];
            Inc(ExclN);
          end;
        if ExclN <> Length(NewCfg.Groups[i].Excluded) then
        begin
          SetLength(NewCfg.Groups[i].Excluded, ExclN);
          GroupChanged := True;
        end;
        if SameText(NewCfg.Groups[i].Boss, Team.Name) then
        begin
          NewCfg.Groups[i].Boss := '';
          GroupChanged := True;
        end;
        if GroupChanged then
        begin
          if GrpTouched <> '' then
            GrpTouched := GrpTouched + ', ';
          GrpTouched := GrpTouched + NewCfg.Groups[i].Name;
          { Record the exact changed group here. Reconstructing it later with a
            substring search would create false history for similarly named
            groups. }
          SetLength(TouchedG, Length(TouchedG) + 1);
          TouchedG[High(TouchedG)] := NewCfg.Groups[i];
        end;
      end;
      { Membership cleanup and team deletion are one SQLite transaction. }
      if not FDb.TeamRemoveWithGroups(Team.Id, Team.Name, From,
        '{"id":' + IntToStr(Team.Id) + ',"name":"' + Team.Name + '"}',
        TouchedG, DbErrT) then
      begin
        WriteLine(Data, ReplyErr('team not removed: ' + DbErrT));
        Exit;
      end;
      FCfg := NewCfg;
    finally
      FCfgLock.Leave;
    end;
    { config-only removal: the tmux session is NEVER killed (Golden Rule 1) —
      the watchdog just stops respawning it }
    FLog.Info(Format('team %s removed (id=%d) by %s', [Team.Name, Team.Id, From]));
    if GrpTouched <> '' then
      FLog.Info(Format('team %s also removed from group(s): %s',
        [Team.Name, GrpTouched]));
    Broadcast(EvSys(Format('team %s removed by %s (session left running)',
      [Team.Name, From])), 0);
    if GrpTouched <> '' then
      WriteLine(Data, ReplyOkNote(Format(
        'team %s removed; also taken out of group(s): %s',
        [Team.Name, GrpTouched])))
    else
      WriteLine(Data, ReplyOk);
    Exit;
  end;

  if Op = 'set' then
  begin
    Field := LowerCase(Trim(Obj.Get('field', '')));
    Value := Obj.Get('value', '');
    if not FindTeam(C, Name, Team) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + Name));
      Exit;
    end;
    if FromIsTeam and (not InSubtree(Team.Name)) then
    begin
      WriteLine(Data, ReplyErr(Format(
        'hierarchy: %s may only modify itself or its subordinates',
        [FromTeam.Name])));
      Exit;
    end;
    if Field = 'name' then
    begin
      WriteLine(Data, ReplyErr('field ' + Field +
        ' cannot be changed at runtime because other registry rows reference it'));
      Exit;
    end;
    { Credentials, delegation and delivery topology change authority or where
      commands execute. A team delegated the general `team` family may not
      grant itself those powers; only the actual console identity may. }
    if ((Field = 'secret') or (Field = 'delegate') or (Field = 'host') or
        (Field = 'dial')) and (not SameText(From, 'console')) then
    begin
      WriteLine(Data, ReplyErr('only the real console may change ' + Field));
      Exit;
    end;
    if Field = 'delegate' then
    begin
      Value := LowerCase(Trim(Value));
      if not ValidDelegation(Value, DbErrT) then
      begin
        WriteLine(Data, ReplyErr('unknown delegation family: ' + DbErrT));
        Exit;
      end;
    end;
    if Field = 'parent' then
    begin
      Value := Trim(Value);
      if Value <> '' then
      begin
        if not FindTeam(C, Value, PT) then
        begin
          WriteLine(Data, ReplyErr('unknown parent: ' + Value));
          Exit;
        end;
        Value := PT.Name;
      end;
      if FromIsTeam then
      begin
        if SameText(Team.Name, FromTeam.Name) then
        begin
          WriteLine(Data, ReplyErr(
            'hierarchy: a team cannot change its own boss (console only)'));
          Exit;
        end;
        if (Value = '') or (not InSubtree(Value)) then
        begin
          WriteLine(Data, ReplyErr(Format(
            'hierarchy: new parent must be inside %s''s subtree',
            [FromTeam.Name])));
          Exit;
        end;
      end;
    end;

    if TEAMSET_TEST_DELAY > 0 then
      Sleep(TEAMSET_TEST_DELAY);
    FCfgLock.Enter;
    try
      NewCfg := FCfg;
      NewCfg.Teams := Copy(FCfg.Teams);
      { Resolve the team again while holding the lock. A pre-lock snapshot may
        race with removal; persisting that stale record could resurrect its
        credentials on restart. Compare both name and index so slot reuse is
        rejected as well. }
      StillThere := False;
      for i := 0 to High(NewCfg.Teams) do
        if (NewCfg.Teams[i].Id = Team.Id) and
           SameText(NewCfg.Teams[i].Name, Team.Name) then
          StillThere := True;
      if not StillThere then
      begin
        WriteLine(Data, ReplyErr(Format('team %s was removed while this change ' +
          'was in flight: nothing was written', [Team.Name])));
        Exit;
      end;
      for i := 0 to High(NewCfg.Teams) do
        if NewCfg.Teams[i].Id = Team.Id then
        begin
          { Preserve the old value so history can undo it. }
          if Field = 'prompt' then OldVal := NewCfg.Teams[i].Prompt
          else if Field = 'speciality' then OldVal := NewCfg.Teams[i].Speciality
          else if Field = 'parent' then OldVal := NewCfg.Teams[i].Parent
          else if Field = 'launch' then OldVal := NewCfg.Teams[i].Launch
          else if Field = 'session' then OldVal := NewCfg.Teams[i].TmuxSession
          else if Field = 'user' then OldVal := NewCfg.Teams[i].User
          else if Field = 'project' then OldVal := NewCfg.Teams[i].Project
          else if Field = 'slave' then
          begin
            if NewCfg.Teams[i].Slave then OldVal := 'on' else OldVal := 'off';
          end
          else if Field = 'workdir' then OldVal := NewCfg.Teams[i].Workdir
          else if Field = 'secret' then OldVal := '(redacted)'
          else if Field = 'delegate' then OldVal := NewCfg.Teams[i].Delegate
          else if Field = 'host' then
          begin
            OldVal := NewCfg.Teams[i].Host;
            if OldVal <> '' then
              OldVal := OldVal + ':' + IntToStr(NewCfg.Teams[i].Port);
          end
          else if Field = 'dial' then
          begin
            if NewCfg.Teams[i].Dial then OldVal := 'on' else OldVal := 'off';
          end
          else if Field = 'hold_when_blocked' then
          begin
            if NewCfg.Teams[i].HoldBlocked then OldVal := 'on' else OldVal := 'off';
          end
          else OldVal := '';
          if Field = 'prompt' then
            NewCfg.Teams[i].Prompt := Value
          else if Field = 'speciality' then
            NewCfg.Teams[i].Speciality := Value
          else if Field = 'parent' then
            NewCfg.Teams[i].Parent := Value
          else if Field = 'launch' then
            NewCfg.Teams[i].Launch := Value
          else if Field = 'session' then
          begin
            { '-' = make it inbox-only (pull via inbox) }
            NewCfg.Teams[i].TmuxSession := NormSession(Value);
          end
          else if Field = 'user' then
          begin
            { A session user is embedded in a `su` command and must be treated
              as command syntax, not arbitrary data. Accept empty (run as the
              daemon user) or a safe Unix-style name using the common name
              alphabet; reject option or shell injection. }
            if (Value <> '') and (not SafeName(Value)) then
            begin
              WriteLine(Data, ReplyErr('invalid user: only a unix account name ' +
                '(letters, digits, . _ -, starting alphanumeric) or empty. This ' +
                'value is spliced into a "su - <user> -c ..." command, so a name ' +
                'with spaces or shell metacharacters would be code execution.'));
              Exit;
            end;
            NewCfg.Teams[i].User := Value;
          end
          else if Field = 'project' then
            { Trim project labels consistently. Forward references to projects
              remain allowed, but surrounding whitespace must not create
              duplicate logical names in delivery headers. }
            NewCfg.Teams[i].Project := Trim(Value)
          else if Field = 'workdir' then
            NewCfg.Teams[i].Workdir := Trim(Value)
          else if Field = 'secret' then
          begin
            Value := Trim(Value);
            if Value = '-' then Value := '';
            NewCfg.Teams[i].Secret := Value;
          end
          else if Field = 'delegate' then
            NewCfg.Teams[i].Delegate := Value
          else if Field = 'host' then
          begin
            Value := Trim(Value);
            if Value = '-' then Value := '';
            if Value = '' then
            begin
              NewCfg.Teams[i].Host := '';
              NewCfg.Teams[i].Port := 0;
            end
            else
              SplitHostPort(Value, NewCfg.Teams[i].Host,
                NewCfg.Teams[i].Port);
          end
          else if Field = 'dial' then
          begin
            if not ParseOnOff(Value, SlaveV) then
            begin
              WriteLine(Data, ReplyErr('dial must be on or off (got: ' +
                Trim(Value) + ')'));
              Exit;
            end;
            NewCfg.Teams[i].Dial := SlaveV;
          end
          else if Field = 'slave' then
          begin
            { `slave` explicitly marks a read-only subordinate that answers only
              its leader. Use the same strict boolean parser as the INI and
              reject unknown spellings instead of silently enabling writes. }
            if not ParseOnOff(Value, SlaveV) then
            begin
              WriteLine(Data, ReplyErr('slave must be on or off (got: ' +
                Trim(Value) + ')'));
              Exit;
            end;
            NewCfg.Teams[i].Slave := SlaveV;
          end
          else if Field = 'hold_when_blocked' then
          begin
            { opt-in: hold delivery + tell the sender while this team is detected
              blocked on a permission prompt }
            if not ParseOnOff(Value, SlaveV) then
            begin
              WriteLine(Data, ReplyErr('hold_when_blocked must be on or off (got: ' +
                Trim(Value) + ')'));
              Exit;
            end;
            NewCfg.Teams[i].HoldBlocked := SlaveV;
          end
          else
          begin
            { Exit runs the finally (single Leave) — do NOT Leave here too }
            WriteLine(Data, ReplyErr('unknown field: ' + Field +
              ' (prompt|speciality|parent|launch|session|user|project|slave|' +
              'hold_when_blocked|workdir|secret|delegate|host|dial)'));
            Exit;
          end;
          Team := NewCfg.Teams[i];
        end;
      ValidateParents(NewCfg);
      if not SecretsCoherent(NewCfg, DbErrT) then
      begin
        WriteLine(Data, ReplyErr('credential change rejected: ' + DbErrT));
        Exit;
      end;
      if Field = 'parent' then
        { did the new parent survive validation? (cycle protection) }
        for i := 0 to High(NewCfg.Teams) do
          if (NewCfg.Teams[i].Id = Team.Id) and
             (not SameText(NewCfg.Teams[i].Parent, Value)) then
          begin
            WriteLine(Data, ReplyErr('rejected: that parent would create a cycle'));
            Exit;
          end;
      HistNew := Value;
      if Field = 'secret' then
        HistNew := '(redacted)';
      if not FDb.TeamUpsert(TeamRowDb(Team), From, False,
        '{"' + JsonEsc(Field) + '":"' + JsonEsc(OldVal) + '"}',
        Field, OldVal, HistNew,
        DbErrT) then
      begin
        WriteLine(Data, ReplyErr('team not changed: ' + DbErrT));
        Exit;
      end;
      FCfg := NewCfg;
    finally
      FCfgLock.Leave;
    end;
    FLog.Info(Format('team %s: %s changed by %s', [Team.Name, Field, From]));
    Broadcast(EvSys(Format('team %s: %s changed by %s',
      [Team.Name, Field, From])), 0);
    WriteLine(Data, TeamCard(Team, AppsOf(Snap, Team.Name)));
    Exit;
  end;

  WriteLine(Data, ReplyErr('unknown team op (add|remove|set|list|show)'));
end;

function TPizarra.ReplyGroups: string;
var
  C: TPizarraConfig;
  O, G: TJSONObject;
  A, MA, IA: TJSONArray;
  i, j, age, nMem: Integer;
  MT: TTeam;
  st, nt: string;
  allIdle, anyBlocked: Boolean;
begin
  C := Snap;
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    A := TJSONArray.Create;
    for i := 0 to High(C.Groups) do
    begin
      G := TJSONObject.Create;
      G.Add('name', C.Groups[i].Name);
      G.Add('project', C.Groups[i].Project);
      G.Add('boss', C.Groups[i].Boss);
      MA := TJSONArray.Create;
      { member_ids runs parallel to members: the [team:N] id, or 0 when the
        member is not a known team, so a viewer can print "#N name" }
      IA := TJSONArray.Create;
      for j := 0 to High(C.Groups[i].Members) do
      begin
        MA.Add(C.Groups[i].Members[j]);
        if FindTeam(C, C.Groups[i].Members[j], MT) then
          IA.Add(MT.Id)
        else
          IA.Add(0);
      end;
      G.Add('members', MA);
      G.Add('member_ids', IA);
      { the muted list, projected the same way so every reader (CLI, pzweb) sees
        who is excluded from this group's broadcasts }
      MA := TJSONArray.Create;
      IA := TJSONArray.Create;
      for j := 0 to High(C.Groups[i].Excluded) do
      begin
        MA.Add(C.Groups[i].Excluded[j]);
        if FindTeam(C, C.Groups[i].Excluded[j], MT) then
          IA.Add(MT.Id)
        else
          IA.Add(0);
      end;
      G.Add('excluded', MA);
      G.Add('excluded_ids', IA);
      { on_idle policy (what happens when the group goes fully idle) + the LIVE
        quiescence: all_idle = every non-excluded member reports 'idle' right now
        (the "all teams stopped" indicator); any_blocked = a member is stuck at a
        permission prompt (so the group is NOT cleanly idle). }
      G.Add('on_idle', C.Groups[i].OnIdle);
      G.Add('on_idle_msg', C.Groups[i].OnIdleMsg);
      G.Add('on_idle_from', C.Groups[i].OnIdleFrom);
      G.Add('on_idle_reply', C.Groups[i].OnIdleReply);
      G.Add('header', C.Groups[i].HdrNote);
      G.Add('on_block', C.Groups[i].OnBlock);
      allIdle := True;
      anyBlocked := False;
      nMem := 0;
      for j := 0 to High(C.Groups[i].Members) do
      begin
        if TeamInList(C.Groups[i].Excluded, C.Groups[i].Members[j]) then
          Continue;
        Inc(nMem);
        st := ActivityOf(C.Groups[i].Members[j], age, nt);
        if st = 'blocked' then
          anyBlocked := True;
        if st <> 'idle' then
          allIdle := False;
      end;
      G.Add('all_idle', allIdle and (nMem > 0));
      G.Add('any_blocked', anyBlocked);
      A.Add(G);
    end;
    O.Add('groups', A);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ Runtime group management. Groups are flat named team lists with an optional
  project; a member's effective project falls back to its group's. Mutations use
  copy-on-write under FCfgLock, commit org.sqlite first, and then publish FCfg.
  Build replies after releasing the lock because they perform I/O and reacquire
  a snapshot. }
{ Console authority is granted per command family, either to the real console
  or a team explicitly delegated that family. }
function TPizarra.ConsoleFor(const From, Family: string): Boolean;
var
  C: TPizarraConfig;
begin
  Result := SameText(From, 'console');
  if Result then
    Exit;
  FCfgLock.Enter;
  try
    C := FCfg;
  finally
    FCfgLock.Leave;
  end;
  Result := TeamDelegated(C, From, Family);
end;

procedure TPizarra.HandleGroup(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  Op, Name, Note, ErrMsg, Pol: string;
  DbErrT: string;
  Members: TStringArray;
  NewGroups: TGroupArray;
  T: TTeam;
  i, j, gi, n: Integer;
  Ok: Boolean;

  function CommitGroup: Boolean;
  begin
    Result := FDb.GroupUpsert(NewGroups[gi], From, '', DbErrT);
    if Result then
      FCfg.Groups := NewGroups
    else
      ErrMsg := 'group not saved: ' + DbErrT;
  end;
begin
  Op := LowerCase(Obj.Get('op', ''));
  Name := Trim(Obj.Get('name', ''));
  if Op = 'list' then
  begin
    WriteLine(Data, ReplyGroups);
    Exit;
  end;
  { Validate the name below while holding the lock and using the locked index.
    A pre-lock existence check races with group removal and can recreate a
    reserved name; reading the group array without its lock is unsafe as well. }

  ErrMsg := '';
  Note := '';
  Ok := False;
  FCfgLock.Enter;
  try
    gi := -1;
    for i := 0 to High(FCfg.Groups) do
      if SameText(FCfg.Groups[i].Name, Name) then
        gi := i;
    { Decide existence and creation together under one lock. A missing group is
      being created, so reserved-name validation applies atomically. }
    if (gi < 0) and BadRegistryName('group', Name, ErrMsg) then
    begin
      WriteLine(Data, ReplyErr(ErrMsg));
      Exit;
    end;
    { Every op except 'add' acts on a group that ALREADY exists. If it does not,
      the failure is that the group IS UNKNOWN -not a permissions problem-: saying
      so keeps 'exclude @typo' or 'boss @typo' from answering 'only the console
      may create or delete a group', which sends the reader to debug AUTHORITY
      when the real fault is the name. 'add' is let through: it is the only op
      that may create one. This runs before the authority guard so the message is
      the right one, and a group's existence is not secret: 'group list' shows
      them all. }
    if (gi < 0) and (Op <> 'add') then
    begin
      WriteLine(Data, ReplyErr('unknown group: ' + Name));
      Exit;
    end;
    { Authentication binds identity but does not grant group administration.
      Creation, deletion, leader, and project changes require console authority;
      the current group leader may also manage membership. }
    if (not SameText(From, 'console')) and
       (not TeamDelegated(FCfg, From, 'group')) then
    begin
      { gi<0 only reaches here with Op='add' (the rest exited above with
        'unknown group'): that is CREATING a group, which is the console's, like
        boss and project. 'add' on a group that already exists (gi>=0) does not
        come through here and falls to the boss check: membership may also be run
        by the group's boss. }
      if (gi < 0) or (Op = 'boss') or (Op = 'project') or
         ((Op = 'remove') and (Trim(Obj.Get('members', '')) = '')) then
      begin
        WriteLine(Data, ReplyErr('only the console may create or delete a ' +
          'group, or change its boss or project (a group''s boss may manage ' +
          'its membership)'));
        Exit;
      end;
      if not SameText(FCfg.Groups[gi].Boss, From) then
      begin
        WriteLine(Data, ReplyErr(Format('only the console or @%s''s boss ' +
          '(%s) may change its membership or policy', [Name,
          BoolToStr(FCfg.Groups[gi].Boss <> '', FCfg.Groups[gi].Boss,
          'nobody - ask the console')])));
        Exit;
      end;
    end;
    NewGroups := Copy(FCfg.Groups);

    if Op = 'add' then
    begin
      Members := SplitList(Obj.Get('members', ''));
      for j := 0 to High(Members) do
        if not FindTeam(FCfg, Members[j], T) then
        begin
          ErrMsg := 'unknown team: ' + Members[j];
          Break;
        end;
      if ErrMsg = '' then
      begin
        if gi < 0 then
        begin
          SetLength(NewGroups, Length(NewGroups) + 1);
          gi := High(NewGroups);
          NewGroups[gi].Name := Name;
          NewGroups[gi].Project := '';
          NewGroups[gi].Members := nil;
        end
        else
          NewGroups[gi].Members := Copy(NewGroups[gi].Members);
        for j := 0 to High(Members) do
          if not TeamInList(NewGroups[gi].Members, Members[j]) then
          begin
            FindTeam(FCfg, Members[j], T);   { canonical name }
            n := Length(NewGroups[gi].Members);
            SetLength(NewGroups[gi].Members, n + 1);
            NewGroups[gi].Members[n] := T.Name;
          end;
        if CommitGroup then
        begin
          Note := Format('group %s: members updated by %s', [Name, From]);
          Ok := True;
        end;
      end;
    end
    else if Op = 'boss' then
    begin
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        NewGroups[gi].Boss := Trim(Obj.Get('boss', ''));
        if (NewGroups[gi].Boss <> '') and (not FindTeam(FCfg, NewGroups[gi].Boss, T)) then
          ErrMsg := 'unknown team: ' + NewGroups[gi].Boss
        else
        begin
          if NewGroups[gi].Boss <> '' then
          begin
            FindTeam(FCfg, NewGroups[gi].Boss, T);
            NewGroups[gi].Boss := T.Name;
          end;
          if CommitGroup then
          begin
            Note := Format('group %s: admin = %s (by %s)',
              [Name, NewGroups[gi].Boss, From]);
            Ok := True;
          end;
        end;
      end;
    end
    else if Op = 'project' then
    begin
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        NewGroups[gi].Project := Trim(Obj.Get('project', ''));
        if CommitGroup then
        begin
          Note := Format('group %s: project = %s (by %s)',
            [Name, NewGroups[gi].Project, From]);
          Ok := True;
        end;
      end;
    end
    else if Op = 'exclude' then
    begin
      { MUTE a set of members from this group's broadcasts. Replace semantics,
        like project/boss: the value IS the whole excluded list, and naming none
        clears it. Each named team must be a real team (FindTeam, as boss does);
        it need NOT be a member - a non-member exclusion is inert, because the
        fan-out skips non-members before it reaches the mute check. Not requiring
        membership keeps this from having to re-validate every time membership
        changes. Auth is boss+console: 'exclude' is deliberately absent from the
        console-only guard above, so it falls to the group-boss check. }
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Members := SplitList(Obj.Get('excluded', ''));
        for j := 0 to High(Members) do
          if not FindTeam(FCfg, Members[j], T) then
          begin
            ErrMsg := 'unknown team: ' + Members[j];
            Break;
          end;
        if ErrMsg = '' then
        begin
          NewGroups[gi].Excluded := nil;
          for j := 0 to High(Members) do
            if not TeamInList(NewGroups[gi].Excluded, Members[j]) then
            begin
              FindTeam(FCfg, Members[j], T);   { canonical name }
              n := Length(NewGroups[gi].Excluded);
              SetLength(NewGroups[gi].Excluded, n + 1);
              NewGroups[gi].Excluded[n] := T.Name;
            end;
          if CommitGroup then
          begin
            if Length(NewGroups[gi].Excluded) = 0 then
              Note := Format('group %s: broadcast mute cleared (by %s)', [Name, From])
            else
              Note := Format('group %s: muted from broadcasts = %s (by %s)',
                [Name, GroupExcludedCsv(NewGroups[gi]), From]);
            Ok := True;
          end;
        end;
      end;
    end
    else if Op = 'onidle' then
    begin
      { on-idle policy: off | boss | all | team[,team...]. The complete policy
        is stored in the authoritative group row. }
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Pol := LowerCase(Trim(Obj.Get('onidle', '')));
        if Pol = 'off' then
          Pol := '';
        if (Pol <> '') and (Pol <> 'boss') and (Pol <> 'all') then
        begin
          Members := SplitList(Pol);
          for j := 0 to High(Members) do
            if not FindTeam(FCfg, Members[j], T) then
            begin
              ErrMsg := 'unknown team: ' + Members[j];
              Break;
            end;
        end;
        if ErrMsg = '' then
        begin
          NewGroups[gi].OnIdle := Pol;
          if CommitGroup then
          begin
            if Pol = '' then
              Note := Format('group %s: on-idle signal OFF (by %s)', [Name, From])
            else
              Note := Format('group %s: on-idle -> %s (by %s)', [Name, Pol, From]);
            Ok := True;
          end;
        end;
      end;
    end
    else if Op = 'onidlemsg' then
    begin
      { the text sent when the group quiesces; empty clears it (back to the
        generic default). Auth boss+console, like onidle. }
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Pol := Trim(Obj.Get('onidlemsg', ''));
        NewGroups[gi].OnIdleMsg := Pol;
        if CommitGroup then
        begin
          if Pol = '' then
            Note := Format('group %s: on-idle message reset to default (by %s)',
              [Name, From])
          else
            Note := Format('group %s: on-idle message set (by %s)', [Name, From]);
          Ok := True;
        end;
      end;
    end
    else if (Op = 'onidlefrom') or (Op = 'onidlereply') then
    begin
      { who the on-idle nudge reads as (from) / who to answer (reply). Each is
        'console', a real team, or empty (clear). Auth boss+console. }
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Pol := Trim(Obj.Get(Op, ''));
        if (Pol <> '') and (not SameText(Pol, 'console')) and
           (not FindTeam(FCfg, Pol, T)) then
          ErrMsg := 'unknown team (use a team name or ''console''): ' + Pol
        else
        begin
          if Op = 'onidlefrom' then
            NewGroups[gi].OnIdleFrom := Pol
          else
            NewGroups[gi].OnIdleReply := Pol;
          if CommitGroup then
          begin
            if Pol = '' then
              Note := Format('group %s: %s reset to default (by %s)', [Name, Op, From])
            else
              Note := Format('group %s: %s -> %s (by %s)', [Name, Op, Pol, From]);
            Ok := True;
          end;
        end;
      end;
    end
    else if Op = 'header' then
    begin
      { the standing instruction shown in EVERY member's delivery header; empty
        clears it. Auth boss+console, like the on-idle ops. }
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Pol := Trim(Obj.Get('header', ''));
        NewGroups[gi].HdrNote := Pol;
        if CommitGroup then
        begin
          if Pol = '' then
            Note := Format('group %s: header rule cleared (by %s)', [Name, From])
          else
            Note := Format('group %s: header rule set (by %s)', [Name, From]);
          Ok := True;
        end;
      end;
    end
    else if Op = 'onblock' then
    begin
      { Permission-block handling is a persisted group policy. Empty/default
        restores the normal loud alarm; `log` deliberately suppresses that
        alarm for non-excluded members while retaining detection and holds. }
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Pol := LowerCase(Trim(Obj.Get('onblock', '')));
        if Pol = 'default' then
          Pol := '';
        if (Pol <> '') and (Pol <> 'alarm') and (Pol <> 'log') then
          ErrMsg := 'onblock must be alarm, log, or default'
        else
        begin
          NewGroups[gi].OnBlock := Pol;
          if CommitGroup then
          begin
            if (Pol = '') or (Pol = 'alarm') then
              Note := Format('group %s: blocked members alarm normally (by %s)',
                [Name, From])
            else
              Note := Format('group %s: blocked members log only (by %s)',
                [Name, From]);
            Ok := True;
          end;
        end;
      end;
    end
    else if Op = 'remove' then
    begin
      if gi < 0 then
        ErrMsg := 'unknown group: ' + Name
      else
      begin
        Members := SplitList(Obj.Get('members', ''));
        if (Length(Members) = 0) and (FWf.GroupBusy(Name) <> '') then
          ErrMsg := Format('group is bound to workflow %s - finish or ' +
            'abort it first', [FWf.GroupBusy(Name)])
        else if Length(Members) = 0 then
        begin
          n := 0;
          for i := 0 to High(NewGroups) do
            if i <> gi then
            begin
              NewGroups[n] := NewGroups[i];
              Inc(n);
            end;
          SetLength(NewGroups, n);
          if not FDb.GroupRemove(Name, From, '{"group":"' + Name + '"}', DbErrT) then
            ErrMsg := 'group not removed: ' + DbErrT
          else
          begin
            FCfg.Groups := NewGroups;
            Note := Format('group %s removed by %s', [Name, From]);
          end;
        end
        else
        begin
          NewGroups[gi].Members := Copy(NewGroups[gi].Members);
          n := 0;
          for i := 0 to High(NewGroups[gi].Members) do
            if not TeamInList(Members, NewGroups[gi].Members[i]) then
            begin
              NewGroups[gi].Members[n] := NewGroups[gi].Members[i];
              Inc(n);
            end;
          SetLength(NewGroups[gi].Members, n);
          if CommitGroup then
            Note := Format('group %s: members removed by %s', [Name, From]);
        end;
        Ok := ErrMsg = '';
      end;
    end
    else
      ErrMsg := 'unknown group op (add|remove|boss|project|exclude|onidle|' +
        'onidlemsg|onidlefrom|onidlereply|onblock|header|list)';
  finally
    FCfgLock.Leave;
  end;

  if ErrMsg <> '' then
    WriteLine(Data, ReplyErr(ErrMsg))
  else if Ok then
  begin
    FLog.Info(Note);
    Broadcast(EvSys(Note), 0);
    WriteLine(Data, ReplyGroups);
  end;
end;

function TPizarra.ReplyProjects: string;
var
  C: TPizarraConfig;
  O, P: TJSONObject;
  A: TJSONArray;
  i: Integer;
begin
  C := Snap;
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    A := TJSONArray.Create;
    for i := 0 to High(C.Projects) do
    begin
      P := TJSONObject.Create;
      P.Add('name', C.Projects[i].Name);
      P.Add('boss', C.Projects[i].Boss);
      A.Add(P);
    end;
    O.Add('projects', A);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function TPizarra.ReplyProjectCard(const Name: string;
  out Found: Boolean): string;
var
  C: TPizarraConfig;
  Prj: TProject;
  O, J, AO: TJSONObject;
  Teams, Groups, Apps: TJSONArray;
  L: TStringList;
  i, t: Integer;
begin
  Result := '';
  C := Snap;
  Found := FindProject(C, Name, Prj);
  if not Found then
    Exit;
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    J := TJSONObject.Create;
    J.Add('name', Prj.Name);
    J.Add('boss', Prj.Boss);
    { who has it assigned: these are loose LABELS - a team's project field and
      a group's - not a relation with a table of its own, which is why they are
      walked here instead of being asked of the database }
    Teams := TJSONArray.Create;
    for i := 0 to High(C.Teams) do
      if SameText(C.Teams[i].Project, Prj.Name) then
        Teams.Add(C.Teams[i].Name);
    J.Add('teams', Teams);
    Groups := TJSONArray.Create;
    for i := 0 to High(C.Groups) do
      if SameText(C.Groups[i].Project, Prj.Name) then
        Groups.Add(C.Groups[i].Name);
    J.Add('groups', Groups);
    { apps ARE a relation, with per-pair functionality that can be detailed }
    Apps := TJSONArray.Create;
    L := FDb.AppsOfProject(Prj.Name);
    try
      if L <> nil then
        for i := 0 to L.Count - 1 do
        begin
          t := Pos(#9, L[i]);
          AO := TJSONObject.Create;
          if t > 0 then
          begin
            AO.Add('name', Copy(L[i], 1, t - 1));
            AO.Add('role', Copy(L[i], t + 1, Length(L[i]) - t));
          end
          else
          begin
            AO.Add('name', L[i]);
            AO.Add('role', '');
          end;
          Apps.Add(AO);
        end;
    finally
      L.Free;
    end;
    J.Add('apps', Apps);
    O.Add('project', J);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ Project registry (cmd=project): op boss sets [project:NAME] boss; op list
  returns the registry; op show returns ONE project's card. Copy-on-write
  under FCfgLock; reply after unlock. }
procedure TPizarra.HandleProject(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  Op, Name, Boss, Note, ErrMsg: string;
  DbErrT: string;
  NewProjects: TProjectArray;
  T: TTeam;
  i, pi: Integer;
  Ok: Boolean;
  OrphanedApps: TStringList;   { applications detached by project removal }
begin
  OrphanedApps := nil;
  Op := LowerCase(Obj.Get('op', ''));
  Name := Trim(Obj.Get('name', ''));
  if Op = 'list' then
  begin
    WriteLine(Data, ReplyProjects);
    Exit;
  end;
  if BadRegistryName('project', Name, ErrMsg) then
  begin
    WriteLine(Data, ReplyErr(ErrMsg));
    Exit;
  end;
  { READING comes before the gate: the card is a read, same as 'list', and
    whoever builds an app needs to know which project it belongs to without
    asking permission to change anything. The gate below guards MUTATIONS. }
  if Op = 'show' then
  begin
    Note := ReplyProjectCard(Name, Ok);
    if Ok then
      WriteLine(Data, Note)
    else
      WriteLine(Data, ReplyErr('unknown project: ' + Name));
    Exit;
  end;
  { A project leader governs every assigned team, so only console authority may
    change that role. }
  if not ConsoleFor(From, 'project') then
  begin
    WriteLine(Data, ReplyErr('only the console (or a team with project ' +
      'delegation) may change a project''s boss'));
    Exit;
  end;
  ErrMsg := '';
  Note := '';
  Ok := False;
  FCfgLock.Enter;
  try
    pi := -1;
    for i := 0 to High(FCfg.Projects) do
      if SameText(FCfg.Projects[i].Name, Name) then
        pi := i;
    NewProjects := Copy(FCfg.Projects);
    if Op = 'boss' then
    begin
      Boss := Trim(Obj.Get('boss', ''));
      if (Boss <> '') and (not FindTeam(FCfg, Boss, T)) then
        ErrMsg := 'unknown team: ' + Boss
      else
      begin
        if Boss <> '' then
        begin
          FindTeam(FCfg, Boss, T);
          Boss := T.Name;
        end;
        if pi < 0 then
        begin
          SetLength(NewProjects, Length(NewProjects) + 1);
          pi := High(NewProjects);
          NewProjects[pi].Name := Name;
        end;
        NewProjects[pi].Boss := Boss;
        if not FDb.ProjectUpsert(NewProjects[pi].Name, NewProjects[pi].Boss, From,
          '', DbErrT) then
          ErrMsg := 'project not saved: ' + DbErrT
        else
        begin
          FCfg.Projects := NewProjects;
          Note := Format('project %s: admin = %s (by %s)', [Name, Boss, From]);
          Ok := True;
        end;
      end;
    end
    else if Op = 'remove' then
    begin
      { Refuse removal while teams or groups still reference the project.
        Reassignment is an operator decision, not an implicit hub cleanup. }
      pi := -1;
      for i := 0 to High(FCfg.Projects) do
        if SameText(FCfg.Projects[i].Name, Name) then
          pi := i;
      if pi < 0 then
        ErrMsg := 'unknown project: ' + Name
      else
      begin
        Note := '';
        for i := 0 to High(FCfg.Teams) do
          if SameText(FCfg.Teams[i].Project, Name) then
            Note := Note + ' ' + FCfg.Teams[i].Name;
        for i := 0 to High(FCfg.Groups) do
          if SameText(FCfg.Groups[i].Project, Name) then
            Note := Note + ' @' + FCfg.Groups[i].Name;
        if Note <> '' then
          ErrMsg := Format('project %s is still assigned to:%s — reassign ' +
            'them first', [Name, Note])
        else
        begin
          { WHICH APPS WERE PAIRED WITH IT, read BEFORE the delete - afterwards
            the foreign key has cascaded the pairs away and there is nothing
            left to ask. The refusal above only guards teams and groups, whose
            project is a label; the app pairs are meant to cascade, so the
            deletion goes ahead and the affected applications' in-memory
            project projection must be rebuilt for delivery headers. }
          OrphanedApps := FDb.AppsOfProject(Name);
          NewProjects := Copy(FCfg.Projects, 0, Length(FCfg.Projects));
          for i := pi to High(NewProjects) - 1 do
            NewProjects[i] := NewProjects[i + 1];
          SetLength(NewProjects, Length(NewProjects) - 1);
          if not FDb.ProjectDelete(Name, From, DbErrT) then
          begin
            OrphanedApps.Free;
            OrphanedApps := nil;
            ErrMsg := 'project not removed: ' + DbErrT;
          end
          else
          begin
            FCfg.Projects := NewProjects;
            Note := Format('project %s removed (by %s)', [Name, From]);
            Ok := True;
          end;
        end;
      end;
    end
    else
      ErrMsg := 'unknown project op (boss|remove|list|show)';
  finally
    FCfgLock.Leave;
  end;
  { OUTSIDE the lock on purpose: MirrorAppProjects takes FCfgLock itself, so
    calling it above would be asking the same thread for a lock it already
    holds. It rebuilds each app's `projects=` and role map from a FRESH read of
    the database, which by now no longer has the cascaded pairs - so the file
    stops naming the dead project and the header goes back to telling the
    truth, this restart and every one after it. }
  if OrphanedApps <> nil then
  try
    for i := 0 to OrphanedApps.Count - 1 do
    begin
      { each row is app<TAB>role, not a bare name - read from the SELECT in
        TPzDb.AppsOfProject, not assumed }
      pi := Pos(#9, OrphanedApps[i]);
      if pi > 0 then
        MirrorAppProjects(Copy(OrphanedApps[i], 1, pi - 1))
      else
        MirrorAppProjects(OrphanedApps[i]);
    end;
  finally
    OrphanedApps.Free;
  end;
  if ErrMsg <> '' then
    WriteLine(Data, ReplyErr(ErrMsg))
  else if Ok then
  begin
    FLog.Info(Note);
    Broadcast(EvSys(Note), 0);
    WriteLine(Data, ReplyProjects);
  end;
end;

{ Current delivery-header config as a JSON object (for show + set replies). }
function TPizarra.ReplyHeader: string;
var
  C: TPizarraConfig;
  O, H: TJSONObject;
begin
  C := Snap;
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    H := TJSONObject.Create;
    H.Add('mode', C.HeaderMode);
    H.Add('style', C.HdrStyle);
    H.Add('orders', C.HdrOrders);
    H.Add('tasks', C.HdrTasks);
    H.Add('teams', C.HdrTeams);
    if C.HdrGroupOwn then H.Add('group', 'own') else H.Add('group', 'off');
    H.Add('project', C.HdrProject);
    H.Add('subs', C.HdrSubs);
    H.Add('shared', C.HdrShared);
    H.Add('workflow', C.HdrWorkflow);
    H.Add('manual', C.HdrManual);
    O.Add('header', H);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ Runtime delivery-header config (cmd=header). op=list shows it; op=set changes
  one key, applies it live (copy-on-write scalar under FCfgLock) and persists it
  to [server]/[header]. Only the console may change it (global display config). }
procedure TPizarra.HandleHeader(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  Op, Key, Val, ErrMsg, Note: string;
  NewCfg: TPizarraConfig;
  Ok: Boolean;

  { on/off/1/0/true/false/yes/no -> tri-state: 1 true, 0 false, -1 invalid }
  function ParseBool(const S: string): Integer;
  begin
    if (S = 'on') or (S = '1') or (S = 'true') or (S = 'yes') then Result := 1
    else if (S = 'off') or (S = '0') or (S = 'false') or (S = 'no') then Result := 0
    else Result := -1;
  end;

  { set a boolean toggle from Val; sets ErrMsg on a bad value }
  procedure SetFlag(var B: Boolean);
  var t: Integer;
  begin
    t := ParseBool(Val);
    if t < 0 then ErrMsg := 'value must be on|off (got: ' + Val + ')'
    else begin B := (t = 1); Ok := True; end;
  end;

begin
  Op := LowerCase(Obj.Get('op', ''));
  if Op = 'list' then
  begin
    WriteLine(Data, ReplyHeader);
    Exit;
  end;
  if (Op <> 'set') and (Op <> 'note') then
  begin
    WriteLine(Data, ReplyErr('unknown header op (set|note|list)'));
    Exit;
  end;
  if not ConsoleFor(From, 'header') then
  begin
    WriteLine(Data, ReplyErr('only the console -or a team with delegate=header- ' +
      'may change the header config'));
    Exit;
  end;
  Key := LowerCase(Trim(Obj.Get('key', '')));
  Val := LowerCase(Trim(Obj.Get('value', '')));
  ErrMsg := '';
  Ok := False;
  FCfgLock.Enter;
  try
    { Mutate a candidate copy, persist it, then publish it. FCfg must never serve
      a value from a command whose disk write failed. }
    NewCfg := FCfg;
    if Op = 'note' then
    begin
      { the GLOBAL header rule; the raw 'note' field is NOT lowercased. Empty
        clears it. }
      NewCfg.GlobalRule := Trim(Obj.Get('note', ''));
      Ok := True;
      if NewCfg.GlobalRule = '' then
        Note := Format('header note cleared (by %s)', [From])
      else
        Note := Format('header note set (by %s)', [From]);
    end
    else if (Key = 'mode') or (Key = 'header') then
    begin
      if (Val = 'short') or (Val = 'full') then
      begin NewCfg.HeaderMode := Val; Ok := True; end
      else ErrMsg := 'mode must be short|full';
    end
    else if Key = 'style'   then SetFlag(NewCfg.HdrStyle)
    else if Key = 'orders'  then SetFlag(NewCfg.HdrOrders)
    else if Key = 'tasks'   then SetFlag(NewCfg.HdrTasks)
    else if Key = 'teams'   then SetFlag(NewCfg.HdrTeams)
    else if Key = 'project' then SetFlag(NewCfg.HdrProject)
    else if Key = 'subs'    then SetFlag(NewCfg.HdrSubs)
    else if Key = 'shared'  then SetFlag(NewCfg.HdrShared)
    else if Key = 'workflow' then SetFlag(NewCfg.HdrWorkflow)
    else if Key = 'group'   then
    begin
      if Val = 'own' then begin NewCfg.HdrGroupOwn := True; Ok := True; end
      else if Val = 'off' then begin NewCfg.HdrGroupOwn := False; Ok := True; end
      else ErrMsg := 'group must be own|off';
    end
    else if Key = 'manual'  then
    begin
      if (Val = 'first') or (Val = 'off') or (Val = 'always') then
      begin NewCfg.HdrManual := Val; Ok := True; end
      else ErrMsg := 'manual must be first|off|always';
    end
    else
      ErrMsg := 'unknown header key: ' + Key +
        ' (mode|style|orders|tasks|teams|group|project|subs|shared|workflow|manual)';
    if Ok then
    begin
      try
        SaveHeaderIni(FCfgPath, NewCfg);
      except
        on E: Exception do
        begin
          { Diagnostic includes the open-descriptor count and errno. }
          FLog.Info(Format('DIAG header save failure: %s | errno=%d | fds=%d',
            [E.Message, fpgeterrno, CountOpenFds]));
          raise;
        end;
      end;
      { Publish only after SaveHeaderIni reaches disk; on failure the hub keeps
        serving the file-backed value. }
      FCfg := NewCfg;
      if Op <> 'note' then
        Note := Format('header %s = %s (by %s)', [Key, Val, From]);
    end;
  finally
    FCfgLock.Leave;
  end;
  if ErrMsg <> '' then
    WriteLine(Data, ReplyErr(ErrMsg))
  else if Ok then
  begin
    FLog.Info(Note);
    Broadcast(EvSys(Note), 0);
    WriteLine(Data, ReplyHeader);
  end;
end;

{ Upload a file's bytes over the bus and write them into the shared dir of team
  'to' (base64 in 'data', basename in 'name'). For hosts that cannot mount the
  shared NFS, where 'share' (a local cp) is unavailable. Same validation as
  share: basename whitelist, size cap, collision auto-rename. }
procedure TPizarra.HandlePut(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  Dest, Name, DestDir, FinalPath, Tmp, Bytes, NameErr, Why_: string;
  UpId, Part, GotSha, WantSha, Stale: string;
  Off, Have: Int64;
  i, Live: Integer;
  H2: LongInt;
  SR: TSearchRec;
  Team: TTeam;
  FS: TFileStream;
  Reply: TJSONObject;
begin
  C := Snap;
  if C.SharedDir = '' then
  begin
    WriteLine(Data, ReplyErr('shared exchange not configured on the hub ([shared] dir)'));
    Exit;
  end;
  Dest := Trim(Obj.Get('to', ''));
  Name := Trim(Obj.Get('name', ''));
  if not (SameText(Dest, 'console') or FindTeam(C, Dest, Team)) then
  begin
    WriteLine(Data, ReplyErr('unknown destination: ' + Dest));
    Exit;
  end;
  if not SameText(Dest, 'console') then
    Dest := Team.Name;   { canonical name even if addressed by id }
  NameErr := ShareNameError(Name);
  if NameErr <> '' then
  begin
    WriteLine(Data, ReplyErr(NameErr));
    Exit;
  end;
  try
    Bytes := DecodeStringBase64(Obj.Get('data', ''));
  except
    on E: Exception do
    begin
      WriteLine(Data, ReplyErr('bad base64 payload'));
      Exit;
    end;
  end;
  { The `id` field selects chunked upload. Without it, retain the legacy path so
    an older tiza can finish an in-progress fleet update. }
  UpId := Trim(Obj.Get('id', ''));
  if Bytes = '' then
  begin
    { An empty chunk may finalize an already complete upload. }
    if (UpId = '') or (not Obj.Get('last', False)) then
    begin
      WriteLine(Data, ReplyErr('empty file'));
      Exit;
    end;
  end;
  { The chunk limit applies only to chunked uploads. The legacy one-shot path
    remains governed by the protocol line limit for backward compatibility. }
  if (UpId <> '') and (Length(Bytes) > SHARE_CHUNK_MAX) then
  begin
    WriteLine(Data, ReplyErr(Format('chunk too large (max %d KB per line)',
      [SHARE_CHUNK_MAX div 1024])));
    Exit;
  end;
  if (UpId = '') and (Length(Bytes) > SHARE_MAX_BYTES) then
  begin
    WriteLine(Data, ReplyErr(Format('file too large (max %d MB)',
      [SHARE_MAX_BYTES div 1048576])));
    Exit;
  end;
  DestDir := IncludeTrailingPathDelimiter(C.SharedDir) + LowerCase(Dest);
  { Validate before creating anything: ForceDirectories would follow an
    existing destination symlink outside the shared directory. }
  if not InsideShared(C.SharedDir, ExcludeTrailingPathDelimiter(DestDir), Why_) then
  begin
    WriteLine(Data, ReplyErr(Why_));
    Exit;
  end;
  ForceDirectories(DestDir);

  { ---------------- chunked upload ---------------- }
  if UpId <> '' then
  begin
    { Measuring, validating order and size, writing, and publishing form one
      operation. The intentionally coarse process lock prevents concurrent
      chunks from both passing checks against the same old size. }
    FPutLock.Enter;
    try
    for i := 1 to Length(UpId) do
      if not (UpId[i] in ['0'..'9', 'a'..'z', 'A'..'Z', '-']) then
      begin
        WriteLine(Data, ReplyErr('bad upload id'));
        Exit;
      end;
    if Length(UpId) > 64 then
    begin
      WriteLine(Data, ReplyErr('bad upload id'));
      Exit;
    end;
    Part := IncludeTrailingPathDelimiter(DestDir) + '.pzput-' + UpId;
    { Revalidate on every chunk because a path may be replaced by a symlink
      between requests. }
    if not InsideShared(C.SharedDir, Part, Why_) then
    begin
      WriteLine(Data, ReplyErr(Why_));
      Exit;
    end;
    { Partial uploads are persistent disk state across independent connections.
      At upload start, remove stale entries and cap concurrent temporaries per
      destination to prevent unbounded disk consumption across restarts. }
    Off := Obj.Get('offset', Int64(0));
    if Off = 0 then
    begin
      { 1. Remove entries untouched for more than an hour. }
      if FindFirst(IncludeTrailingPathDelimiter(DestDir) + '.pzput-*',
           faAnyFile, SR) = 0 then
      begin
        repeat
          if (SR.Attr and faDirectory) <> 0 then
            Continue;
          Stale := IncludeTrailingPathDelimiter(DestDir) + SR.Name;
          if (Now - FileDateToDateTime(FileAge(Stale))) > (1 / 24) then
            DeleteFile(Stale);
        until FindNext(SR) <> 0;
        FindClose(SR);
      end;
      { 2) Reserve it exclusively; O_EXCL fails if it already exists. }
      H2 := FpOpen(Part, O_WRONLY or O_CREAT or O_EXCL, &600);
      if H2 < 0 then
      begin
        WriteLine(Data, ReplyErr('that upload id is already in flight'));
        Exit;
      end;
      FpClose(H2);
      { 3. Recount the directory only after reservation. The count then includes
           all concurrent arrivals; excess reservations withdraw safely. }
      Live := 0;
      if FindFirst(IncludeTrailingPathDelimiter(DestDir) + '.pzput-*',
           faAnyFile, SR) = 0 then
      begin
        repeat
          if (SR.Attr and faDirectory) = 0 then
            Inc(Live);
        until FindNext(SR) <> 0;
        FindClose(SR);
      end;
      if Live > MAX_PARTIAL_UPLOADS then
      begin
        DeleteFile(Part);
        WriteLine(Data, ReplyErr(Format(
          'too many unfinished uploads for %s (max %d): finish or abandon ' +
          'them; they are reaped an hour after their last chunk',
          [Dest, MAX_PARTIAL_UPLOADS])));
        Exit;
      end;
    end;
    { FPutLock serializes size checks and appends within this process. Do not
      rely on flock because the shared tree may be on NFS without effective
      file locks; open the temporary file for shared access deliberately. }
    { Distinguish a missing upload from a busy one. An offset above zero requires
      a previously reserved upload that began at offset zero. }
    if not FileExists(Part) then
    begin
      WriteLine(Data, ReplyErr(
        'no such upload in flight: send offset 0 first to start it'));
      Exit;
    end;
    try
      FS := TFileStream.Create(Part, fmOpenWrite or fmShareDenyNone);
    except
      on E: Exception do
      begin
        WriteLine(Data, ReplyErr('cannot open this upload: ' + E.Message));
        Exit;
      end;
    end;
    try
      Have := FS.Size;
      if Off <> Have then
      begin
        { Require the exact current end offset so missing chunks cannot create
          an unnoticed hole. }
        WriteLine(Data, ReplyErr(Format(
          'chunk out of order: this upload has %d bytes, you sent offset %d',
          [Have, Off])));
        Exit;
      end;
      if Have + Length(Bytes) > SHARE_MAX_BYTES then
      begin
        WriteLine(Data, ReplyErr(Format('file too large (max %d MB)',
          [SHARE_MAX_BYTES div 1048576])));
        Exit;
      end;
      try
        FS.Seek(0, soEnd);
        if Bytes <> '' then
          FS.WriteBuffer(Bytes[1], Length(Bytes));
      except
        on E: Exception do
        begin
          WriteLine(Data, ReplyErr('write failed: ' + E.Message));
          Exit;
        end;
      end;
    finally
      FS.Free;
    end;
    if not Obj.Get('last', False) then
    begin
      Reply := TJSONObject.Create;
      try
        Reply.Add('ok', True);
        Reply.Add('received', Int64(Have + Length(Bytes)));
        WriteLine(Data, Reply.AsJSON);
      finally
        Reply.Free;
      end;
      Exit;
    end;
    { At finalization, verify that assembled content matches the sender's stated
      size and digest before publishing it. }
    if not Sha256OfFile(Part, GotSha) then
    begin
      DeleteFile(Part);
      WriteLine(Data, ReplyErr('cannot read the assembled upload'));
      Exit;
    end;
    WantSha := LowerCase(Trim(Obj.Get('sha256', '')));
    if (WantSha = '') or (LowerCase(GotSha) <> WantSha) then
    begin
      DeleteFile(Part);
      WriteLine(Data, ReplyErr(Format(
        'upload does not match its declared sha256 (assembled %s): discarded',
        [Copy(GotSha, 1, 16)])));
      Exit;
    end;
    { Reserve the final name with link(), not rename(). Unix rename silently
      overwrites a concurrent winner, while link fails atomically with EEXIST. }
    FinalPath := '';
    for i := 1 to 64 do
    begin
      FinalPath := PickFreeName(DestDir, Name);
      if not InsideShared(C.SharedDir, FinalPath, Why_) then
      begin
        DeleteFile(Part);
        WriteLine(Data, ReplyErr(Why_));
        Exit;
      end;
      if FpLink(Part, FinalPath) = 0 then
        Break;
      FinalPath := '';
      if fpgeterrno <> ESysEEXIST then
        Break;   { not a collision; do not retry 64 times }
    end;
    DeleteFile(Part);
    if FinalPath = '' then
    begin
      WriteLine(Data, ReplyErr('could not place the upload in ' + DestDir));
      Exit;
    end;
    FpChmod(FinalPath, &644);
    FLog.Info(Format('put %d bytes (chunked) -> %s (from %s)',
      [FileBytes(FinalPath), FinalPath, From]));
    Reply := TJSONObject.Create;
    try
      Reply.Add('ok', True);
      Reply.Add('path', FinalPath);
      Reply.Add('sha256', LowerCase(GotSha));
      WriteLine(Data, Reply.AsJSON);
    finally
      Reply.Free;
    end;
    finally
      FPutLock.Leave;
    end;
    Exit;
  end;

  { The legacy path also uses a private temporary name and atomically reserves
    the final name with link(). This keeps backward compatibility without
    allowing concurrent uploads to share or overwrite a temporary file. }
  { Combine process counter, clock, and content-derived data for a genuinely
    unique temporary name; O_EXCL remains the final safety check. }
  Tmp := IncludeTrailingPathDelimiter(DestDir) + '.pzput-legacy-' +
         IntToStr(FpGetpid) + '-' + IntToStr(InterLockedIncrement(GScratchSeq));
  if not InsideShared(C.SharedDir, Tmp, Why_) then
  begin
    WriteLine(Data, ReplyErr(Why_));
    Exit;
  end;
  H2 := FpOpen(Tmp, O_WRONLY or O_CREAT or O_EXCL, &600);
  if H2 < 0 then
  begin
    WriteLine(Data, ReplyErr('could not reserve a scratch file in ' + DestDir));
    Exit;
  end;
  FpClose(H2);
  FinalPath := '';
  try
    FS := TFileStream.Create(Tmp, fmOpenWrite or fmShareDenyNone);
    try
      if Bytes <> '' then     { likewise, never index an empty string }
        FS.WriteBuffer(Bytes[1], Length(Bytes));
    finally
      FS.Free;
    end;
    for i := 1 to 64 do
    begin
      FinalPath := PickFreeName(DestDir, Name);
      if not InsideShared(C.SharedDir, FinalPath, Why_) then
      begin
        DeleteFile(Tmp);
        WriteLine(Data, ReplyErr(Why_));
        Exit;
      end;
      if FpLink(Tmp, FinalPath) = 0 then
        Break;
      FinalPath := '';
      if fpgeterrno <> ESysEEXIST then
        Break;
    end;
    DeleteFile(Tmp);
    if FinalPath = '' then
      raise Exception.Create('could not place the file in ' + DestDir);
    FpChmod(FinalPath, &644);   { world-readable over the shared NFS }
  except
    on E: Exception do
    begin
      DeleteFile(Tmp);
      WriteLine(Data, ReplyErr('write failed: ' + E.Message));
      Exit;
    end;
  end;
  FLog.Info(Format('put %d bytes -> %s (from %s)', [Length(Bytes), FinalPath, From]));
  Reply := TJSONObject.Create;
  try
    Reply.Add('ok', True);
    Reply.Add('path', FinalPath);
    WriteLine(Data, Reply.AsJSON);
  finally
    Reply.Free;
  end;
end;

{ Download a file FROM the shared dir over the bus: read Path (which must live
  under [shared] dir — traversal guard) and return its bytes (base64). The
  inverse of put, so NFS-less hosts can read what teammates deposited. }
procedure TPizarra.HandleGet(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  Path, Root, Bytes, Why_, ShaS: string;
  FS: THandleStream;
  Reply: TJSONObject;
  FdG, FdR: LongInt;
  RealRoot, RealF: string;
  Sz, Off, Want, Take: Int64;
  StG: Stat;
  Chunked, Eof_, ShaOk: Boolean;
begin
  C := Snap;
  if C.SharedDir = '' then
  begin
    WriteLine(Data, ReplyErr('shared exchange not configured on the hub ([shared] dir)'));
    Exit;
  end;
  Path := ExpandFileName(Trim(Obj.Get('path', '')));
  Root := IncludeTrailingPathDelimiter(ExpandFileName(C.SharedDir));
  if not InsideShared(C.SharedDir, Path, Why_) then
  begin
    WriteLine(Data, ReplyErr(Why_));
    Exit;
  end;
  { Serve regular files only. FileExists checks existence, not file type; a FIFO
    in a writable shared tree could otherwise block a hub connection forever. }
  { Open first with O_NOFOLLOW, then inspect the accepted descriptor. A separate
    lstat followed by a name-based open would leave a replacement race. }
  { O_NONBLOCK is required because type validation occurs after open and opening
    a FIFO for reading would otherwise block before it can be rejected. }
  FdG := FpOpen(Path, O_RDONLY or O_NOFOLLOW or O_NONBLOCK);
  if FdG < 0 then
  begin
    WriteLine(Data, ReplyErr('file not found: ' + Path));
    Exit;
  end;
  StG := Default(Stat);
  if (fpFStat(FdG, StG) <> 0) or (not fpS_ISREG(StG.st_mode)) then
  begin
    FpClose(FdG);
    WriteLine(Data, ReplyErr('not a regular file: ' + Path));
    Exit;
  end;
  { With the file open, verify its resolved descriptor path is still within the
    resolved shared root. This closes the race between the earlier component
    walk and open in writable team directories. }
  FdR := PzOpenDirFd(ExcludeTrailingPathDelimiter(C.SharedDir));
  if FdR < 0 then
  begin
    FpClose(FdG);
    WriteLine(Data, ReplyErr('the shared directory is not readable'));
    Exit;
  end;
  RealRoot := FdRealPath(FdR);
  FpClose(FdR);
  RealF := FdRealPath(FdG);
  if (RealRoot = '') or (RealF = '') or
     (Copy(RealF, 1, Length(RealRoot) + 1) <> RealRoot + PathDelim) then
  begin
    FpClose(FdG);
    WriteLine(Data, ReplyErr('that file is not inside the shared dir'));
    Exit;
  end;
  { A present `max` selects chunked download; absence preserves the bounded
    legacy path for older clients. }
  Chunked := Obj.Find('max') <> nil;
  Off := Obj.Get('offset', Int64(0));
  Want := Obj.Get('max', Int64(0));
  if Off < 0 then
    Off := 0;
  if Want > SHARE_CHUNK_MAX then
    Want := SHARE_CHUNK_MAX;
  if (Want <= 0) and Chunked then
    Want := SHARE_CHUNK_MAX;
  Bytes := '';
  { Read from the accepted DESCRIPTOR, not by name. }
  FS := THandleStream.Create(FdG);
  try
    Sz := FS.Size;
    if not Chunked then
    begin
      if Sz > 750000 then
      begin
        WriteLine(Data, ReplyErr(Format(
          'file too large for a whole-file get (%d bytes): ask for it in ' +
          'chunks with offset+max, or use the NFS', [Sz])));
        Exit;
      end;
      SetLength(Bytes, Sz);
      if Sz > 0 then
        FS.ReadBuffer(Bytes[1], Sz);
    end
    else
    begin
      if Off > Sz then
        Off := Sz;
      Take := Sz - Off;
      if Take > Want then
        Take := Want;
      SetLength(Bytes, Take);
      if Take > 0 then
      begin
        FS.Seek(Off, soBeginning);
        FS.ReadBuffer(Bytes[1], Take);
      end;
    end;
    { Compute the digest while the accepted descriptor is still open. }
    Eof_ := Chunked and ((Off + Length(Bytes)) >= Sz);
    ShaOk := False;
    if Eof_ then
      ShaOk := Sha256OfHandle(FdG, ShaS);
  finally
    FS.Free;
    FpClose(FdG);
  end;
  FLog.Info(Format('get %s -> %s (%d bytes)', [From, Path, Length(Bytes)]));
  Reply := TJSONObject.Create;
  try
    Reply.Add('ok', True);
    Reply.Add('name', ExtractFileName(Path));
    Reply.Add('data', EncodeStringBase64(Bytes));
    if Chunked then
    begin
      Reply.Add('size', Sz);
      Reply.Add('offset', Off);
      Reply.Add('len', Int64(Length(Bytes)));
      Reply.Add('eof', Eof_);
      { Hash the entire file only at finalization. If it changed during the
        download, the digest must differ from the assembled content. }
      { Do not report a successful final chunk without a verification digest. }
      { The accepted descriptor is already hashed; reopening by name would
        reintroduce the replacement race. }
      if Eof_ then
      begin
        if not ShaOk then
        begin
          Reply.Free;
          WriteLine(Data, ReplyErr('cannot sign the end of this download: ' +
            'refusing to close it as good'));
          Exit;
        end;
        Reply.Add('sha256', LowerCase(ShaS));
      end;
    end;
    WriteLine(Data, Reply.AsJSON);
  finally
    Reply.Free;
  end;
end;

{ Runs on the connection's own thread until the client goes away. Fully
  self-contained: it must swallow its own errors — an exception escaping to
  HandleConnect would append an error reply to a half-written event line and
  corrupt the stream's framing. }
procedure TPizarra.DoWatch(Data: TSocketStream; Since: Int64; const Scope: string);
var
  W: TWatcher;
  Msgs, Vis: TPzMsgArray;
  i, NVis, Keep, First: Integer;
  Line: string;
  IdleMs: Integer;
  CursorAhead, DropUnseq: Boolean;
  OrigSince: Int64;
  { Always initialize LastWritten; an exception may report a gap before any
    item has been written. }
  Seq, ReplayMax, LastWritten, Dropped, Base: Int64;
begin
  { A cursor ahead of the store signals a structural gap and terminates the
    stream. Silently clamping it would falsely claim a successful resume. }
  OrigSince := Since;   { original client cursor before normalization }
  { FPC does not initialize ordinal locals, so initialize this gap cursor even
    on paths that write no message. }
  LastWritten := OrigSince;
  CursorAhead := (Since >= 0) and (Since > FStore.LastSeq);
  if (Since < 0) or CursorAhead then
    Since := -1;   { -1 = no cursor; replay the 30 newest visible items }

  { register BEFORE the snapshot so nothing is lost in between; the queue and
    the replay may overlap, so the drain loop dedupes by seq below }
  W := TWatcher.Create(Scope);
  FWatchers.Add(W);
  try
    try
      WriteLine(Data, ReplyOk);
      { A structural gap terminates watching so replay cannot race the required
        reload. Report the original cursor as `after`, since it is the last
        position the client can claim to have received. }
      if CursorAhead then
      begin
        WriteLine(Data, EvGap(OrigSince, 'cursor_ahead'));
        Exit;
      end;

      { If the cursor predates the completeness floor, at least one record is
        missing and scoped history cannot be certified. Conservatively require
        reload even if the missing record might have been outside this scope. }
      { An ambiguous partially written store cannot certify any view; report a
        structural gap rather than closing without an explanation. }
      if FStore.Ambiguous then
      begin
        WriteLine(Data, EvGap(OrigSince, 'history_unavailable'));
        Exit;
      end;
      if (Since >= 0) and (Since < FStore.GreatestMissingSeq) then
      begin
        WriteLine(Data, EvGap(OrigSince, 'history_unavailable'));
        Exit;
      end;

      { Filter replay before counting and limiting. A global limit applied first
        could let unrelated records displace every visible item. }
      if Since < 0 then Base := 0 else Base := Since;
      Msgs := FStore.Since(Base, 0);
      Vis := nil;
      SetLength(Vis, Length(Msgs));
      NVis := 0;
      for i := 0 to High(Msgs) do
        if W.Sees(Msgs[i]) and ((Since < 0) or (Msgs[i].Seq > Since)) then
        begin
          Vis[NVis] := Msgs[i];
          Inc(NVis);
        end;
      SetLength(Vis, NVis);

      if Since < 0 then
        Keep := 30                  { no cursor: 30 visible items }
      else
        Keep := WATCH_REPLAY_MAX;   { cursor: cap visible items }
      First := NVis - Keep;
      if First < 0 then
        First := 0;
      { Report overflow only when records visible to this team were trimmed. }
      if (Since >= 0) and (First > 0) then
      begin
        { `after` is the client's last successfully delivered cursor. }
        WriteLine(Data, EvGap(Since, 'replay_overflow'));
        Exit;
      end;

      ReplayMax := Base;
      for i := First to NVis - 1 do
      begin
        WriteLine(Data, EvMsg(Vis[i]));
        if Vis[i].Seq > ReplayMax then
          ReplayMax := Vis[i].Seq;
      end;
      LastWritten := ReplayMax;
      { live }
      IdleMs := 0;
      while not ShutdownRequested do
      begin
        { Overflow is loss only if the discarded item was not already in replay;
          watcher registration intentionally overlaps the replay snapshot. }
        { If storage becomes ambiguous while watching, report it and close. }
        if FStore.Ambiguous then
        begin
          WriteLine(Data, EvGap(LastWritten, 'history_unavailable'));
          Exit;
        end;
        Dropped := W.TakeDropped(DropUnseq);
        { An unsequenced discarded sys/task event is always real loss because it
          is never replayed; do not compare its zero sequence to ReplayMax. }
        if (Dropped > ReplayMax) or DropUnseq then
        begin
          WriteLine(Data, EvGap(LastWritten, 'queue_overflow'));
          Exit;
        end;
        if W.Pop(Line, Seq) then
        begin
          { skip msg events already sent during the replay }
          if (Seq = 0) or (Seq > ReplayMax) then
          begin
            WriteLine(Data, Line);
            if Seq > LastWritten then
              LastWritten := Seq;   { only after a successful write }
            IdleMs := 0;
          end;
        end
        else
        begin
          Sleep(200);
          Inc(IdleMs, 200);
          if IdleMs >= WATCH_PING_MS then
          begin
            WriteLine(Data, EvPing);   { write failure = dead client }
            IdleMs := 0;
          end;
        end;
      end;
    except
      { Distinguish a dead client from history that became uncertifiable during
        streaming. Best-effort a structural-gap notice in its own try; if the
        socket is actually dead, silently terminate the subscription. }
      on E: EPzStoreAmbiguous do
        try
          WriteLine(Data, EvGap(LastWritten, 'history_unavailable'));
        except
        end;
      on E: EPzSyncUnknown do
        try
          WriteLine(Data, EvGap(LastWritten, 'history_unavailable'));
        except
        end;
      on E: Exception do
        { dead or slow client: cancel the subscription quietly };
    end;
  finally
    FWatchers.Remove(W);
    W.Free;
  end;
end;

{ Wrap + deliver one message to a team; confirms it in the store on success.
  Remote teams: one deliver line pushed to their tiza daemon (2 s timeout) —
  the daemon's reply IS the delivery ack. Local teams: tmux injection.

  The WHOLE check-deliver-mark runs under FLock with a recheck of the
  delivered high-water mark: a connection thread and the watchdog's retry
  tick can both pick the same seq, and without the recheck the second one
  would paste the identical message into the model again. }
function TPizarra.TryDeliver(const C: TPizarraConfig; const Team: TTeam;
  const FromName, Text: string; Seq: Int64; const Ident: string;
  MinimalHdr: Boolean; const ReplyTo: string): Boolean;
var
  Full, Reply, Err, Other, HeldWhy, StartWhy: string;
  HdrWfs: TWorkflowArray;
  HdrClean: TWfStrings;
  HdrBlock: string;
  HdrN: Integer;
  Obj: TJSONObject;
begin
  if FStore.DeliveredMark(Team.Name) >= Seq then
    Exit(True);   { someone else already delivered it }
  { HOLD: this team is at a permission prompt (auto from a hook, or the
    operator's manual hold). Do NOT deliver — pasting would answer the prompt.
    Return False = still pending: `delivered` is not advanced, so the message
    stays queued and the next RetryPending tick flushes it once the hold clears. }
  if HeldForTeam(Team, HeldWhy) then
    Exit(False);
  { MINIMAL header: a plain system nudge (e.g. the group-idle signal) is
    delivered as just the frame + text, with none of the recipient's workflow
    role block / tasks / apps / style context. }
  if MinimalHdr then
    Full := BuildDeliveryMinimal(Team, FromName, ReplyTo, Text)
  else
  begin
    { first delivery ever to this team -> embed the full quick guide }
    { Capture workflow, tasks, and their relationship once under both locks. }
    HdrWfs := FWf.CaptureHeader(Team.Name, 5, HdrBlock, HdrN, HdrClean);
    Full := BuildDelivery(C, Team, FromName, Text,
      HdrBlock, FStore.DeliveredMark(Team.Name) = 0, HdrN,
      WfHeaderBlock(C, Team.Name, HdrWfs, HdrClean), Ident);
  end;
  { SESSION AMBIGUITY. If more than one tmux session could belong to this team,
    usually because a process restarted in a new session while the old one
    remained alive, the hub still delivers to the configured session. That may
    be a pane nobody reads even though the log says "delivered". Put a warning
    at the very top so whoever receives it can correct the configured target. }
  if (Team.Host = '') and (not Team.Dial) and (Team.TmuxSession <> '') then
  begin
    Other := AmbiguousSessions(Team.Name, Team.TmuxSession);
    if Other <> '' then
      Full := Format('WARNING: %d tmux sessions could be you (%s, %s). ' +
        'pizarra delivers to "%s". If another one is the live agent, it is ' +
        'NOT receiving anything: tell the operator, or fix it with ' +
        'tiza team set %s session <the-right-one>.'#10#10,
        [2 + CountCommas(Other), Team.TmuxSession, Other, Team.TmuxSession,
         Team.Name]) + Full;
  end;
  if Team.Dial then
  begin
    { reverse channel: hand the full delivery to the dialed-in daemon (if any).
      MarkDelivered happens in DoDial on the daemon's ack; if none is connected
      the message stays pending and is replayed when the daemon reconnects. So
      TryDeliver reports "not delivered yet" (queued) either way. }
    { No secret travels over the dial channel; see DoDial. }
    DialEnqueue(Team.Name, BuildDeliver('', Seq, FromName, Team.Name, Full),
      Seq);
    Exit(False);
  end;
  if Team.Host <> '' then
  begin
    { remote push is a network call — must NOT hold the global delivery lock,
      or one slow/dead host stalls every other team. The remote tiza daemon
      dedupes by seq, so concurrent pushes are safe. }
    Result := RequestLine(Team.Host, Team.Port, 2000,
      BuildDeliver(C.Secret, Seq, FromName, Team.Name, Full), Reply, Err);
    if Result then
    begin
      Obj := ParseObj(Reply);
      if Obj = nil then
        Result := False
      else
        try
          Result := Obj.Get('ok', False);
        finally
          Obj.Free;
        end;
    end
    else
      FLog.Info(Format('push %s:%d failed: %s', [Team.Host, Team.Port, Err]));
  end
  else if Team.TmuxSession = '' then
    { inbox-only member (session '-'): no push channel exists. The message is
      already journaled by the caller; mark it delivered so nothing queues or
      retries — the member reads it with 'tiza --from <name> inbox'. }
    Result := True
  else
  begin
    { local tmux injection serialized under FLock (one paste at a time);
      recheck the mark under the lock to close the double-inject race }
    FLock.Enter;
    try
      if FStore.DeliveredMark(Team.Name) >= Seq then
        Exit(True);
      if not EnsureSessionDetailed(Team.TmuxSession, Team.Launch,
        Team.Workdir, Team.User, StartWhy) then
      begin
        FLog.Info('delivery queued for ' + Team.Name + ': session ' +
          Team.TmuxSession + ' unavailable: ' + StartWhy);
        Result := False;
      end
      else
        Result := DeliverTmux(Team.TmuxSession, Full);
    finally
      FLock.Leave;
    end;
  end;
  if Result then
    FStore.MarkDelivered(Team.Name, Seq);
end;

{ Fan one message out to a member team; returns True if queued (not delivered
  immediately). Shared by the 'all' broadcast and '@group' sends. }
{ Return three distinct facts: whether the message was stored, whether delivery
  is queued, and why storage failed. A single Boolean cannot distinguish an
  immediate delivery from a failed durable write. }
function TPizarra.FanOne(const C: TPizarraConfig; const Team: TTeam;
  const From, Text: string; out Stored, Queued: Boolean;
  out Why: string; const Ident: string = ''): Boolean;
var
  M: TPzMsg;
begin
  Stored := False;
  Queued := False;
  Why := '';
  Result := False;
  try
    M := FStore.Append(From, Team.Name, Text, ViaOf(Team), Ident);
    Stored := True;
  except
    on E: EPzSyncUnknown do
    begin
      { Written but not synchronized: outcome is unknown, so count it as neither
        sent nor rejected. }
      Why := Team.Name + ': ' + E.Message;
      FLog.Info(Format('store append UNKNOWN for %s: %s', [Team.Name, E.Message]));
      Exit;
    end;
    on E: Exception do
    begin
      Why := Team.Name + ': ' + E.Message;
      FLog.Info(Format('store append failed for %s: %s', [Team.Name, E.Message]));
      Exit;
    end;
  end;
  FLog.Store(From, Team.Name, Text, ViaOf(Team));
  if FStore.PendingCountBefore(Team.Name, M.Seq) > 0 then
    Queued := True
  else
    { Preserve the identity marker for group fan-out as well as direct delivery,
      so credential warnings do not depend on destination syntax. }
    Queued := not TryDeliver(C, Team, From, Text, M.Seq, Ident);
  Result := True;   { durable storage is what counts as sent }
  if Queued then
    FLog.Info(Format('queued seq=%d for %s', [M.Seq, Team.Name]));
end;

{ MULTI-DESTINATION SEND (1.1.35).

  `tiza a,b "text"` used to resolve as ONE destination literally named "a,b".
  Because a non-team destination is legitimate - it is how the operator console
  receives mail - that string was accepted, stored against a phantom name and
  delivered to nobody, while the sender was told "sent". Reported from the
  Telegram bridge, where /msg inherits the same command surface.

  Every element is resolved first and the whole send is refused if any one of
  them is unknown, so a typo cannot deliver a partial broadcast that looks
  complete. Resolution accepts the same spellings a single destination does:
  a team, a group, @group, and all. Group expansion honours that group's
  excluded members; a team named EXPLICITLY is not subject to any group's mute,
  which matches the documented rule that a muted member stays a member
  everywhere else. }
procedure TPizarra.SendMulti(const C: TPizarraConfig; const From, Dest, Text: string;
  Data: TSocketStream; const Ident: string);
var
  Parts: TStringArray;
  Names: array of string;
  Unknown: string;
  Grp: TGroup;
  Team: TTeam;
  One: string;
  i, j, k, nSent, nQueued, nFailed: Integer;
  Dup: Boolean;
  FanStored, FanQueued: Boolean;
  FanWhy, FanErr: string;

  { Add a team name once. The sender is skipped, as in a group fan-out, so
    naming yourself in a list cannot echo the message back at you. }
  procedure AddTeam(const N: string);
  var
    m: Integer;
  begin
    if SameText(N, From) then
      Exit;
    Dup := False;
    for m := 0 to High(Names) do
      if SameText(Names[m], N) then
      begin
        Dup := True;
        Break;
      end;
    if Dup then
      Exit;
    SetLength(Names, Length(Names) + 1);
    Names[High(Names)] := N;
  end;

begin
  Parts := SplitList(Dest);
  SetLength(Names, 0);
  Unknown := '';
  nSent := 0;
  nQueued := 0;
  nFailed := 0;
  FanErr := '';

  for i := 0 to High(Parts) do
  begin
    One := Trim(Parts[i]);
    if One = '' then
      Continue;
    if SameText(One, 'all') then
    begin
      for j := 0 to High(C.Teams) do
        AddTeam(C.Teams[j].Name);
      Continue;
    end;
    if One[1] = '@' then
    begin
      One := Trim(Copy(One, 2, Length(One)));
      if (One = '') or (not FindGroup(C, One, Grp)) then
      begin
        if Unknown <> '' then
          Unknown := Unknown + ', ';
        Unknown := Unknown + Parts[i];
        Continue;
      end;
    end
    else if FindTeam(C, One, Team) then
    begin
      { a team wins a name clash, exactly as for a single destination }
      AddTeam(Team.Name);
      Continue;
    end
    else if not FindGroup(C, One, Grp) then
    begin
      if Unknown <> '' then
        Unknown := Unknown + ', ';
      Unknown := Unknown + Parts[i];
      Continue;
    end;
    { a group: expand to its members, honouring its own mute list }
    for j := 0 to High(C.Teams) do
      if TeamInList(Grp.Members, C.Teams[j].Name)
         and (not TeamInList(Grp.Excluded, C.Teams[j].Name)) then
        AddTeam(C.Teams[j].Name);
  end;

  if Unknown <> '' then
  begin
    WriteLine(Data, ReplyErr('unknown destination(s): ' + Unknown +
      ' - nothing was sent'));
    Exit;
  end;
  if Length(Names) = 0 then
  begin
    WriteLine(Data, ReplyErr('no destination left after resolving "' + Dest +
      '" - nothing was sent'));
    Exit;
  end;

  for k := 0 to High(Names) do
  begin
    if not FindTeam(C, Names[k], Team) then
      Continue;
    if FanOne(C, Team, From, Text, FanStored, FanQueued, FanWhy, Ident) then
    begin
      Inc(nSent);
      if FanQueued then
        Inc(nQueued);
    end
    else
    begin
      Inc(nFailed);
      if FanErr = '' then
        FanErr := FanWhy;
    end;
  end;

  if nFailed > 0 then
    WriteLine(Data, ReplyErr(Format(
      'partial fan-out: %d stored, %d NOT stored (first: %s)',
      [nSent, nFailed, FanErr])))
  else
    WriteLine(Data, ReplyBroadcast(nSent, nQueued));
end;

procedure TPizarra.DoSend(const From, Dest, Text: string; Data: TSocketStream;
  const Ident: string);
var
  C: TPizarraConfig;
  Team: TTeam;
  Grp: TGroup;
  M: TPzMsg;
  Queued, IsGroupDest, FanStored, FanQueued, HeldNow: Boolean;
  i, nSent, nQueued, nFailed: Integer;
  GName, FanWhy, FanErr, HoldWhy: string;
begin
  C := Snap;
  { Initialize counters explicitly: FPC initializes managed locals but not
    ordinal values. }
  nSent := 0;
  nQueued := 0;
  nFailed := 0;
  FanErr := '';
  { Group destinations fan a copy out to each member (own seq/delivery/retry,
    so ordering and durability are unchanged). Three spellings resolve here:
      - 'all'            -> every team except the sender;
      - '@name'          -> the named group (explicit);
      - a bare group name that is NOT also a team -> the named group. A team
        wins a name clash, so 'alpha' still reaches team alpha even if a group
        is also called alpha; write '@alpha' to force the group in that rare
        case. }
  { A comma-separated list is the only case handled elsewhere. The guard is
    deliberately narrow - a comma AND more than one non-empty element - so every
    existing spelling, including a trailing comma, resolves exactly as before. }
  if (Pos(',', Dest) > 0) and (Length(SplitList(Dest)) > 1) then
  begin
    SendMulti(C, From, Dest, Text, Data, Ident);
    Exit;
  end;

  IsGroupDest := False;
  GName := '';
  if SameText(Trim(Dest), 'all') then
    IsGroupDest := True   { GName '' -> every team below }
  else if (Dest <> '') and (Dest[1] = '@') then
  begin
    GName := Trim(Copy(Trim(Dest), 2, Length(Dest)));
    if GName = '' then
    begin
      { a bare '@' must not silently fall through to broadcast-all }
      WriteLine(Data, ReplyErr('empty group name'));
      Exit;
    end;
    IsGroupDest := True;
  end
  else if (Trim(Dest) <> '') and (not FindTeam(C, Dest, Team))
          and FindGroup(C, Trim(Dest), Grp) then
  begin
    IsGroupDest := True;
    GName := Trim(Dest);
  end;

  if IsGroupDest then
  begin
    nSent := 0;
    nQueued := 0;
    if GName <> '' then
    begin
      if not FindGroup(C, GName, Grp) then
      begin
        WriteLine(Data, ReplyErr('unknown group: ' + GName));
        Exit;
      end;
    end
    else
      Grp.Members := nil;   { 'all' path uses every team below }

    for i := 0 to High(C.Teams) do
    begin
      if SameText(C.Teams[i].Name, From) then
        Continue;
      { for a specific group, restrict to its members }
      if (GName <> '') and (not TeamInList(Grp.Members, C.Teams[i].Name)) then
        Continue;
      { a MUTED member stays a member everywhere else, but does not receive the
        group's broadcasts. Group-scoped on purpose: GName='' is the fleet 'all',
        which has no group and is never muted. The check sits AFTER the member
        filter, so a team named in Excluded that is not a member never reaches
        here anyway - a stale exclusion is inert, not a bug. }
      if (GName <> '') and TeamInList(Grp.Excluded, C.Teams[i].Name) then
        Continue;
      { Count only durable writes as sent and surface unknown outcomes instead
        of claiming unqualified success. }
      if FanOne(C, C.Teams[i], From, Text, FanStored, FanQueued, FanWhy, Ident) then
      begin
        Inc(nSent);
        if FanQueued then
          Inc(nQueued);
      end
      else
      begin
        Inc(nFailed);
        if FanErr = '' then
          FanErr := FanWhy;
      end;
    end;
    if nFailed > 0 then
      WriteLine(Data, ReplyErr(Format(
        'partial fan-out: %d stored, %d NOT stored (first: %s)',
        [nSent, nFailed, FanErr])))
    else
      WriteLine(Data, ReplyBroadcast(nSent, nQueued));
    Exit;
  end;

  if FindTeam(C, Dest, Team) then
  begin
    { Append fires OnStoreAppend -> watch broadcast, inside the store lock }
    try
      M := FStore.Append(From, Team.Name, Text, ViaOf(Team), Ident);
    except
      on E: EPzSyncUnknown do
      begin
        { A write with unknown synchronization may have applied. Warn against a
          blind retry because it can duplicate the message. }
        WriteLine(Data, ReplyUnknown('store: message may or may not be on ' +
          'disk: ' + E.Message));
        Exit;
      end;
      on E: Exception do
      begin
        WriteLine(Data, ReplyErr('store: could not persist message: ' + E.Message));
        Exit;
      end;
    end;
    FLog.Store(From, Team.Name, Text, ViaOf(Team));
    { head-of-line: never overtake older pending messages for this team }
    HeldNow := HeldForTeam(Team, HoldWhy);
    if FStore.PendingCountBefore(Team.Name, M.Seq) > 0 then
      Queued := True
    else if HeldNow then
      Queued := True   { held (blocked/operator): do NOT attempt delivery now }
    else
      Queued := not TryDeliver(C, Team, From, Text, M.Seq, Ident);
    if Queued then
      FLog.Info(Format('queued seq=%d for %s', [M.Seq, Team.Name]));
    { tell the SENDER why it queued when the target is held - so they know it is
      not lost and will land when the team unblocks }
    if Queued and HeldNow then
      WriteLine(Data, ReplySent(M.Seq, True, Format('%s %s; your message is ' +
        'queued and delivers when it clears', [Team.Name, HoldWhy])))
    else
      WriteLine(Data, ReplySent(M.Seq, Queued));
  end
  else
  begin
    { destination is not a team (e.g. the user/console): record for inbox }
    try
      M := FStore.Append(From, Dest, Text, 'log', Ident);
    except
      on E: Exception do
      begin
        WriteLine(Data, ReplyErr('store: could not persist message: ' + E.Message));
        Exit;
      end;
    end;
    FLog.Store(From, Dest, Text, 'log');
    WriteLine(Data, ReplySent(M.Seq, False));
  end;
end;

{ Watchdog duty: oldest-first redelivery per team; stop a team's drain on the
  first failure (order preserved), never stall other teams. }
procedure TPizarra.RetryPending;
var
  i, j: Integer;
  P: TPzMsgArray;
  C: TPizarraConfig;
begin
  C := Snap;
  for i := 0 to High(C.Teams) do
  begin
    P := FStore.PendingFor(C.Teams[i].Name);
    for j := 0 to High(P) do
    begin
      { P[j].Minimal / P[j].ReplyTo carry the group-idle nudge's delivery shape
        across a retry: without them a nudge that missed its first send would be
        rebuilt with the full header and reply-to-sender. }
      if not TryDeliver(C, C.Teams[i], P[j].From, P[j].Text, P[j].Seq,
        P[j].Ident, P[j].Minimal, P[j].ReplyTo) then
        Break;
      FLog.Info(Format('redelivered seq=%d to %s', [P[j].Seq, C.Teams[i].Name]));
    end;
  end;
end;

{ ---------- workflow plumbing ---------- }

{ Boss (admin) of the group a workflow is bound to; '' when none. }
function TPizarra.WfBossOf(const C: TPizarraConfig; const WfName: string): string;
var
  W: TWorkflow;
  Grp: TGroup;
begin
  Result := '';
  W := Default(TWorkflow);
  if FWf.Get(WfName, W) and FindGroup(C, W.Group, Grp) then
    Result := Grp.Boss;
end;

procedure TPizarra.WfFeed(const R: TWfResult);
var
  i: Integer;
begin
  for i := 0 to High(R.Feed) do
  begin
    FLog.Info(R.Feed[i]);
    Broadcast(EvTask(R.Feed[i]), 0);
  end;
end;

{ The recipient's live workflow role, pre-rendered for the delivery header:
  ACTIVE-for-you with the exact finish command / HALTED-yours-to-fix /
  HALTED-stop / a pointer for an uninvolved member. Capped at 3 role lines
  (overflow points at 'tiza wf list'); header=full also embeds the tree of
  each workflow the team belongs to (max 2). }
{ Consume the snapshot captured under both locks, including cleanup notices.
  Reading the stores again here would allow a full command between workflow and
  task reads. }
function TPizarra.WfHeaderBlock(const C: TPizarraConfig;
  const TeamName: string; const Wfs: TWorkflowArray;
  const Cleanup: TWfStrings): string;
var
  i, Running, Halted, Total: Integer;
  IsMember: Boolean;
begin
  Result := '';
  { The delivery header carries NO detailed workflow lines any more — in ANY
    message, whatever the sender (pizarra, console or a team). Operator request,
    stated repeatedly: no per-step HALTED / ACTIVE-for-you enumeration, no
    PROJECTION CLEANUP, no tree. Just ONE pointer with the count; the detail
    (which step is yours, the finish command, why a plan is halted) lives one
    command away in `tiza wf list` / `tiza wf show`. Cleanup stays a parameter
    (callers still compute it) but the header never prints it. }
  if not C.HdrWorkflow then
    Exit;
  Running := 0;
  Halted := 0;
  for i := 0 to High(Wfs) do
  begin
    if (not SameText(Wfs[i].StateS, 'running')) and
       (not SameText(Wfs[i].StateS, 'halted')) then
      Continue;
    IsMember := TeamInList(Wfs[i].Members, TeamName);
    if not IsMember then
      Continue;
    if SameText(Wfs[i].StateS, 'halted') then
      Inc(Halted)
    else
      Inc(Running);
  end;
  Total := Running + Halted;
  if Total = 0 then
    Exit;
  { a halted plan still matters (STOP working it), so the count is surfaced —
    but never which one or which step; that is `tiza wf list`'s job }
  if Halted > 0 then
    Result := Format('(in %d workflow(s), %d HALTED -> tiza wf list)'#10,
      [Total, Halted])
  else
    Result := Format('(in %d workflow(s) -> tiza wf list)'#10, [Total]);
end;

{ Author one workflow notice on the bus as 'pizarra'. True once the message
  is durably journaled (delivery/queueing is then the store's business, same
  as any send); False only when the append itself failed - keep the outbox
  entry and let the watchdog retry. }
function TPizarra.WfNotify(const C: TPizarraConfig; const Team: TTeam;
  const Text: string): Boolean;
var
  M: TPzMsg;
  Queued: Boolean;
begin
  try
    M := FStore.Append('pizarra', Team.Name, Text, ViaOf(Team), 'hub');
  except
    on E: Exception do
    begin
      FLog.Info(Format('workflow notice append failed for %s: %s',
        [Team.Name, E.Message]));
      Exit(False);
    end;
  end;
  FLog.Store('pizarra', Team.Name, Text, ViaOf(Team));
  if FStore.PendingCountBefore(Team.Name, M.Seq) > 0 then
    Queued := True
  else
    Queued := not TryDeliver(C, Team, 'pizarra', Text, M.Seq);
  if Queued then
    FLog.Info(Format('queued seq=%d for %s', [M.Seq, Team.Name]));
  Result := True;
end;

function TPizarra.SendGroupNudge(const C: TPizarraConfig; const Team: TTeam;
  const FromName, ReplyTo, Text: string): Boolean;
var
  M: TPzMsg;
begin
  try
    { Store the minimal-header and reply-to metadata with the message so a later
      RetryPending rebuilds the exact same delivery. }
    M := FStore.Append(FromName, Team.Name, Text, ViaOf(Team), 'hub',
      True, ReplyTo);
  except
    on E: Exception do
    begin
      FLog.Info(Format('group nudge append failed for %s: %s',
        [Team.Name, E.Message]));
      Exit(False);
    end;
  end;
  FLog.Store(FromName, Team.Name, Text, ViaOf(Team));
  { deliver with a MINIMAL header + the configured reply-to; if it can't go now
    it stays pending and RetryPending flushes it with the SAME minimal header
    and reply-to (both are persisted on the message above). }
  if FStore.PendingCountBefore(Team.Name, M.Seq) = 0 then
    TryDeliver(C, Team, FromName, Text, M.Seq, '', True, ReplyTo);
  Result := True;
end;

{ Send everything a workflow's persisted outbox owes and clear each entry as
  its append lands. A notice for an unknown team can never deliver: drop it
  and halt the workflow visibly instead of retrying forever. }
procedure TPizarra.DrainWfOutbox(const C: TPizarraConfig; const WfName: string);
var
  Outs: TWfOutArray;
  i: Integer;
  Team: TTeam;
  R: TWfResult;
begin
  Outs := FWf.TakeOutbox(WfName);
  for i := 0 to High(Outs) do
  begin
    if SameText(Outs[i].Team, 'console') then
    begin
      { human notices (approval gates, gate nudges): land durably in the
        console inbox - OnStoreAppend also broadcasts to the live feed and
        an external notifier, exactly like a team->console message }
      try
        FStore.Append('pizarra', 'console', Outs[i].Text, 'log', 'hub');
        FLog.Store('pizarra', 'console', Outs[i].Text, 'log');
        FWf.OutboxDone(WfName, Outs[i].OutId);
      except
        on E: Exception do
          FLog.Info('workflow console notice append failed: ' + E.Message);
      end;
      Continue;
    end;
    if not FindTeam(C, Outs[i].Team, Team) then
    begin
      FLog.Info(Format('workflow %s: unknown team %s for %s notice',
        [WfName, Outs[i].Team, Outs[i].Kind]));
      FWf.OutboxDone(WfName, Outs[i].OutId);
      R := FWf.AutoHalt(WfName, Format('unknown team %s (step #%d %s notice)',
        [Outs[i].Team, Outs[i].StepN, Outs[i].Kind]));
      if R.Ok then
        WfFeed(R);
      Continue;
    end;
    if WfNotify(C, Team, Outs[i].Text) then
      FWf.OutboxDone(WfName, Outs[i].OutId);
  end;
end;

{ Workflow upkeep (startup + every watchdog tick): heal task/workflow drift
  left by a crash and re-offer any notices whose append never happened. }
procedure TPizarra.WfMaintain;
var
  C: TPizarraConfig;
  Feeds: TWfStrings;
  Wfs: TWorkflowArray;
  Admins: TWfAdminMap;
  i: Integer;
begin
  C := Snap;
  { Retry acknowledgements that did not reach disk. A memory-only delivered mark
    would disappear on restart and cause duplicate delivery. }
  FStore.RetryReceipt;
  Feeds := FWf.Reconcile;
  for i := 0 to High(Feeds) do
  begin
    FLog.Info(Feeds[i]);
    Broadcast(EvTask(Feeds[i]), 0);
  end;
  { stall detection: group->admin pairs come from live config at call time }
  SetLength(Admins, Length(C.Groups));
  for i := 0 to High(C.Groups) do
  begin
    Admins[i].Group := C.Groups[i].Name;
    Admins[i].Admin := C.Groups[i].Boss;
  end;
  Feeds := FWf.NudgeStale(Admins);
  for i := 0 to High(Feeds) do
  begin
    FLog.Info(Feeds[i]);
    Broadcast(EvTask(Feeds[i]), 0);
  end;
  Wfs := FWf.ListAll;
  for i := 0 to High(Wfs) do
    if Length(Wfs[i].Outbox) > 0 then
      DrainWfOutbox(C, Wfs[i].Name);
end;

function ReplyWfText(const S: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('text', S);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyWfCard(const W: TWorkflow; FromN: Integer = 0;
  Depth: Integer = 0; Detail: Boolean = False): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('workflow', WfToJson(W));
    O.Add('tree', RenderWfTree(W, FromN, Depth, Detail));
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyWfList(const Wfs: TWorkflowArray): string;
var
  O, E: TJSONObject;
  A: TJSONArray;
  i: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    A := TJSONArray.Create;
    for i := 0 to High(Wfs) do
    begin
      E := TJSONObject.Create;
      E.Add('name', Wfs[i].Name);
      E.Add('line', WfSummaryLine(Wfs[i]));
      { Include structured fields beside the formatted line so clients can
        render tables without parsing presentation text. }
      E.Add('group', Wfs[i].Group);
      E.Add('state', Wfs[i].StateS);
      E.Add('done', DoneCountOf(Wfs[i]));
      E.Add('steps', Length(Wfs[i].Steps));
      E.Add('note', WfActiveSummary(Wfs[i]));
      A.Add(E);
    end;
    O.Add('workflows', A);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ cmd=workflow: dependency-tree milestone plans. create/step/start/abort are
  console + group-admin only; done is owner/boss/console (also reachable via
  'task done' on the linked task); error is any group member; fixed is the
  error-step owner; verify is reporter/boss/console and NEVER the fixer.
  Every mutating op broadcasts its feed line(s) and drains the outbox. }
procedure TPizarra.HandleWorkflow(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  Op, Name, TeamName, Milestone, TargetGroup, AfterS, Text, ResS, FeedAll,
    Bad: string;
  FromTeam, Team: TTeam;
  Grp: TGroup;
  W: TWorkflow;
  R: TWfResult;
  FromIsTeam: Boolean;
  i, n2, n3: Integer;
  After: array of Integer;
  Parts: TStringArray;
  O: TJSONObject;
  A: TJSONArray;
  Feeds: TWfStrings;
  Wfs: TWorkflowArray;
  Grp2: TGroup;
  XAfter: array of TWfXDep;

  { console (any non-team identity) or the admin of the workflow's group }
  function BossOnly(const GroupBoss, Verb: string): Boolean;
  begin
    Result := (not FromIsTeam) or SameText(From, GroupBoss);
    if not Result then
      WriteLine(Data, ReplyErr(Format('only the console or the group admin ' +
        '(%s) may %s this workflow', [GroupBoss, Verb])));
  end;

  { the group a live workflow is bound to; refuses when the wf is unknown }
  function WfGroup(out G: TGroup): Boolean;
  begin
    Result := False;
    if not FWf.Get(Name, W) then
    begin
      WriteLine(Data, ReplyErr('unknown workflow: ' + Name));
      Exit;
    end;
    if not FindGroup(C, W.Group, G) then
    begin
      WriteLine(Data, ReplyErr(Format('workflow %s: its group @%s no ' +
        'longer exists', [Name, W.Group])));
      Exit;
    end;
    Result := True;
  end;

begin
  C := Snap;
  Op := LowerCase(Obj.Get('op', ''));
  Name := Trim(Obj.Get('name', ''));
  FromIsTeam := FindTeam(C, From, FromTeam);
  { Delegation for the `workflow` family grants console authority within this
    handler, including plans for any group. It remains independent from registry
    family permissions. }
  if FromIsTeam and TeamDelegated(C, From, 'workflow') then
    FromIsTeam := False;

  { step names the milestone to remove/set/done/error. On the wire it is always
    a JSON number (clients resolve the '-' convenience to 0 before sending), so a
    string, a fractional 2.9 (would edit step 3), or an overflowing value (wraps
    non-positive, the 0-default then closes the caller's ACTIVE step) is refused
    once here for every op that reads it. 0 is legal: the 'active/wf-level'
    sentinel that remove/set/done/error already honour. Ops without step (add,
    insert, list, ...) send none, so the guard is a no-op for them. }
  Bad := BadIdField(Obj, 'step', 0, True);
  if Bad <> '' then
  begin
    WriteLine(Data, ReplyErr(Bad));
    Exit;
  end;

  if Op = 'list' then
  begin
    Wfs := FWf.ListAll;
    TeamName := Trim(Obj.Get('team', ''));
    if Obj.Get('mine', False) then
      TeamName := From;
    if TeamName <> '' then
    begin
      i := 0;
      for n2 := 0 to High(Wfs) do
      begin
        FromIsTeam := False;
        for n3 := 0 to High(Wfs[n2].Steps) do
          if SameText(Wfs[n2].Steps[n3].Team, TeamName) then
            FromIsTeam := True;
        if FromIsTeam then
        begin
          Wfs[i] := Wfs[n2];
          Inc(i);
        end;
      end;
      SetLength(Wfs, i);
      FromIsTeam := FindTeam(C, From, FromTeam);   { restore }
    end;
    WriteLine(Data, ReplyWfList(Wfs));
    Exit;
  end;
  if Name = '' then
  begin
    WriteLine(Data, ReplyErr('workflow name required'));
    Exit;
  end;

  if Op = 'show' then
  begin
    if not FWf.Get(Name, W) then
      WriteLine(Data, ReplyErr('unknown workflow: ' + Name))
    else
      WriteLine(Data, ReplyWfCard(W, Obj.Get('subtree', 0),
        Obj.Get('depth', 0), Obj.Get('detail', False)));
    Exit;
  end;

  if Op = 'tasks' then
  begin
    if not FWf.TasksView(Name, Text) then
      WriteLine(Data, ReplyErr('unknown workflow: ' + Name))
    else
    begin
      O := TJSONObject.Create;
      try
        O.Add('ok', True);
        O.Add('tree', Text);
        WriteLine(Data, O.AsJSON);
      finally
        O.Free;
      end;
    end;
    Exit;
  end;

  if Op = 'create' then
  begin
    if (not SafeName(Name)) or ReservedName(Name) then
    begin
      WriteLine(Data, ReplyErr('invalid/reserved workflow name (allowed: ' +
        'letters, digits, . _ -, start alnum): ' + Name));
      Exit;
    end;
    if FindTeam(C, Name, Team) or FindGroup(C, Name, Grp) then
    begin
      WriteLine(Data, ReplyErr(Format('name %s already belongs to a team ' +
        'or group - pick another', [Name])));
      Exit;
    end;
    TeamName := Trim(Obj.Get('group', ''));
    if not FindGroup(C, TeamName, Grp) then
    begin
      WriteLine(Data, ReplyErr('unknown group: ' + TeamName));
      Exit;
    end;
    if not BossOnly(Grp.Boss, 'create') then
      Exit;
    R := FWf.CreateWf(Name, Grp.Name, From);
    { Warn at plan creation when a group has no leader. Fix verification needs a
      second party, so a self-reported failure would otherwise wait for the
      console without an obvious reason. }
    if R.Ok and (Trim(Grp.Boss) = '') then
    begin
      SetLength(R.Feed, Length(R.Feed) + 1);
      R.Feed[High(R.Feed)] := Format('NOTE: group @%s has no boss. If ' +
        'a team reports an error on its own step, only the console will be able ' +
        'to verify the fix (verification is always done by a second ' +
        'party). To make the group self-sufficient: tiza group boss %s <team>',
        [Grp.Name, Grp.Name]);
    end;
  end
  else if Op = 'step' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'edit') then
      Exit;
    TeamName := Trim(Obj.Get('team', ''));
    if SameText(TeamName, 'console') then
      Team.Name := 'console'            { human APPROVAL GATE owner }
    else if not FindTeam(C, TeamName, Team) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + TeamName +
        ' (or ''console'' for a human approval gate)'));
      Exit;
    end;
    Milestone := Trim(Obj.Get('hito', ''));
    if Milestone = '' then
    begin
      WriteLine(Data, ReplyErr('empty milestone title'));
      Exit;
    end;
    After := nil;
    XAfter := nil;
    AfterS := Trim(Obj.Get('after', ''));
    if AfterS <> '' then
    begin
      Parts := SplitList(AfterS);
      for i := 0 to High(Parts) do
      begin
        n2 := Pos('#', Parts[i]);
        if n2 > 1 then
        begin
          { cross-workflow dependency: otherwf#3 }
          SetLength(XAfter, Length(XAfter) + 1);
          XAfter[High(XAfter)].Wf := Copy(Parts[i], 1, n2 - 1);
          XAfter[High(XAfter)].N :=
            StrToIntDef(Copy(Parts[i], n2 + 1, Length(Parts[i])), 0);
        end
        else
        begin
          n3 := StrToIntDef(Parts[i], -1);
          if n3 < 0 then
          begin
            WriteLine(Data, ReplyErr('bad --after value: ' + Parts[i] +
              ' (step numbers, 0 = root, or cross-plan otherwf#3)'));
            Exit;
          end;
          { dedup: '--after 2,2' is ONE dependency on step 2, not two edges to
            the same step. group exclude already dedupes its list; this closes
            the same asymmetry in the plan's dependency graph. }
          if not IntInList(After, n3) then
          begin
            SetLength(After, Length(After) + 1);
            After[High(After)] := n3;
          end;
        end;
      end;
    end;
    R := FWf.AddStep(Name, Team.Name, Milestone, After, XAfter, From, Grp.Members,
      Trim(Obj.Get('eta', '')));
  end
  else if Op = 'insert' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'edit') then
      Exit;
    TeamName := Trim(Obj.Get('team', ''));
    if SameText(TeamName, 'console') then
      Team.Name := 'console'
    else if not FindTeam(C, TeamName, Team) then
    begin
      WriteLine(Data, ReplyErr('unknown team: ' + TeamName +
        ' (or ''console'' for a human approval gate)'));
      Exit;
    end;
    Milestone := Trim(Obj.Get('hito', ''));
    if Milestone = '' then
    begin
      WriteLine(Data, ReplyErr('empty milestone title'));
      Exit;
    end;
    if (Trim(Obj.Get('after', '')) = '') or
       (StrToIntDef(Trim(Obj.Get('after', '')), -1) < 0) then
    begin
      WriteLine(Data, ReplyErr(
        'insert needs --after <step> (0 = before everything)'));
      Exit;
    end;
    R := FWf.InsertStep(Name, Team.Name, Milestone,
      StrToIntDef(Trim(Obj.Get('after', '')), 0), From, Grp.Members,
      Trim(Obj.Get('eta', '')));
  end
  else if Op = 'remove' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'edit') then
      Exit;
    R := FWf.RemoveStep(Name, Obj.Get('step', 0), From);
  end
  else if Op = 'set' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'edit') then
      Exit;
    if Obj.Get('step', 0) = 0 then
      { workflow-level options: eta default, strict mode }
      R := FWf.SetWfOption(Name, Trim(Obj.Get('field', '')),
        Trim(Obj.Get('value', '')), From)
    else
      R := FWf.SetStep(Name, Obj.Get('step', 0),
        Trim(Obj.Get('field', '')), Trim(Obj.Get('value', '')), From,
        Grp.Members);
  end
  else if Op = 'start' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'start') then
      Exit;
    R := FWf.StartWf(Name, From, Grp.Members);
  end
  else if Op = 'done' then
    R := FWf.DoneStep(Name, Obj.Get('step', 0), From,
      SameText(From, WfBossOf(C, Name)), not FromIsTeam,
      Trim(Obj.Get('text', '')))
  else if Op = 'error' then
    R := FWf.FlagError(Name, Obj.Get('step', 0), Trim(Obj.Get('text', '')),
      From, not FromIsTeam)
  else if Op = 'fixed' then
    R := FWf.MarkFixed(Name, Trim(Obj.Get('text', '')), From,
      WfBossOf(C, Name), not FromIsTeam)
  else if Op = 'verify' then
  begin
    ResS := LowerCase(Trim(Obj.Get('result', '')));
    if (ResS <> 'ok') and (ResS <> 'fail') then
    begin
      WriteLine(Data, ReplyErr('verify result must be ok or fail'));
      Exit;
    end;
    R := FWf.Verify(Name, ResS = 'ok', Trim(Obj.Get('text', '')), From,
      SameText(From, WfBossOf(C, Name)), not FromIsTeam);
  end
  else if Op = 'abort' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'abort') then
      Exit;
    Text := Trim(Obj.Get('text', ''));
    if Text = '' then
      Text := 'no reason given';
    R := FWf.AbortWf(Name, Text, From);
  end
  else if Op = 'clone' then
  begin
    { permission: console or the SOURCE group's admin }
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'clone') then
      Exit;
    TeamName := Trim(Obj.Get('newname', ''));
    if (not SafeName(TeamName)) or ReservedName(TeamName) then
    begin
      WriteLine(Data, ReplyErr('invalid/reserved workflow name: ' + TeamName));
      Exit;
    end;
    if FindTeam(C, TeamName, Team) or FindGroup(C, TeamName, Grp2) then
    begin
      WriteLine(Data, ReplyErr(Format('name %s already belongs to a team ' +
        'or group - pick another', [TeamName])));
      Exit;
    end;
    TargetGroup := Trim(Obj.Get('group', ''));   { optional target group }
    if TargetGroup = '' then
      Grp2 := Grp
    else if not FindGroup(C, TargetGroup, Grp2) then
    begin
      WriteLine(Data, ReplyErr('unknown group: ' + TargetGroup));
      Exit;
    end;
    R := FWf.CloneWf(Name, TeamName, Grp2.Name, From, Grp2.Members);
  end
  else if Op = 'history' then
  begin
    O := TJSONObject.Create;
    try
      O.Add('ok', True);
      A := TJSONArray.Create;
      Feeds := FWf.HistoryOf(Name);
      for i := 0 to High(Feeds) do
        A.Add(Feeds[i]);
      O.Add('history', A);
      WriteLine(Data, O.AsJSON);
    finally
      O.Free;
    end;
    Exit;
  end
  else if Op = 'undo' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'undo') then
      Exit;
    R := FWf.UndoWf(Name, From, Obj.Get('snap', 0));
  end
  else if Op = 'delete' then
  begin
    if not WfGroup(Grp) then
      Exit;
    if not BossOnly(Grp.Boss, 'delete') then
      Exit;
    R := FWf.DeleteWf(Name, From, Trim(Obj.Get('text', '')));
  end
  else if Op = 'restore' then
  begin
    { restore may recreate a deleted... unknown workflow: permission falls
      back to the console when the workflow does not exist }
    if FWf.Get(Name, W) then
    begin
      if not WfGroup(Grp) then
        Exit;
      if not BossOnly(Grp.Boss, 'restore') then
        Exit;
    end
    else if FromIsTeam then
    begin
      WriteLine(Data, ReplyErr(
        'only the console may restore an unknown workflow'));
      Exit;
    end;
    R := FWf.RestoreWf(Name, Obj.Get('data', ''), From);
  end
  else
  begin
    WriteLine(Data, ReplyErr('unknown workflow op ' +
      '(create|step|insert|remove|set|start|done|error|fixed|verify|abort|' +
      'clone|tasks|list|show|history|undo|restore)'));
    Exit;
  end;

  if not R.Ok then
  begin
    WriteLine(Data, ReplyErr(R.Err));
    Exit;
  end;
  WfFeed(R);
  DrainWfOutbox(C, Name);
  { cross-workflow activations land in SIBLING outboxes - drain those too
    (same loop the watchdog runs; idempotent) }
  Wfs := FWf.ListAll;
  for i := 0 to High(Wfs) do
    if (not SameText(Wfs[i].Name, Name)) and (Length(Wfs[i].Outbox) > 0) then
      DrainWfOutbox(C, Wfs[i].Name);
  if Length(R.Feed) > 0 then
  begin
    { Return every result line, not only the first; subsequent lines may contain
      warnings relevant to the command issuer. }
    FeedAll := '';
    for i := 0 to High(R.Feed) do
    begin
      if FeedAll <> '' then
        FeedAll := FeedAll + #10;
      FeedAll := FeedAll + R.Feed[i];
    end;
    WriteLine(Data, ReplyWfText(FeedAll));
  end
  else
    WriteLine(Data, ReplyOk);
end;

{ Greatest sequence in a served page, or its requested starting point when the
  page is empty. Used to count messages remaining after this page. }
{ One-line conditional helper used to keep call sites compact. }
{ `proven`: the sender supplied its team-bound credential.
  `claimed`: a global credential named a team that has its own credential.
  `master`: the global console or a non-team operational label. }
function MarcaIdentidad(const BoundTeam, From: string;
  const C: TPizarraConfig): string;
var
  T: TTeam;
begin
  if BoundTeam <> '' then
    Exit('proven');
  if (From <> '') and (not SameText(From, 'console')) and FindTeam(C, From, T) then
    Exit('claimed');
  Result := 'master';
end;

function Choose(Cond: Boolean; const IfTrue, IfFalse: string): string;
begin
  if Cond then
    Result := IfTrue
  else
    Result := IfFalse;
end;

function GreatestSeq(const Msgs: TPzMsgArray; StartSeq: Int64): Int64;
var
  i: Integer;
begin
  Result := StartSeq;
  for i := 0 to High(Msgs) do
    if Msgs[i].Seq > Result then
      Result := Msgs[i].Seq;
end;

{ ---------------------------------------------------------------------------
  tiza attach (1.2.0): a raw terminal into a team's tmux session.

  The hub is a relay and a gate, never an interpreter: after the JSON
  handshake it moves bytes between the viewer and a tmux client and looks at
  none of them. What it does decide: who may look, who may type (console only),
  which route reaches the team, and how many of these may be open at once.

  This release serves LOCAL teams (the hub host's own sessions). Push and
  dial-in endpoints answer with a clear refusal until their routes land.
  --------------------------------------------------------------------------- }
const
  ATTACH_MAX_TOTAL    = 8;     { per hub }
  ATTACH_MAX_PER_TEAM = 2;     { per team }
  ATTACH_GRACE_MS     = 2000;  { HUP -> KILL grace for the tmux client }
  ATTACH_DIAL_MS      = 8000;  { a dial daemon must dial back within this }
  ATTACH_JOIN_TICK_MS = 1000;  { relay-park wait granularity (shutdown-aware) }

{ ---- dial attach rendezvous (TAttachWait) ---- }

constructor TAttachWait.Create(const AToken, AExpectFrom, ACaller, ATerm: string;
  AWrite: Boolean; AClient: TSocketStream);
begin
  inherited Create;
  Token := AToken;
  ExpectFrom := AExpectFrom;
  Caller := ACaller;
  Term := ATerm;
  Write := AWrite;
  ClientData := AClient;
  JoinData := nil;
  { manual-reset off (auto): each is waited exactly once }
  Arrived := TEvent.Create(nil, False, False, '');
  Finished := TEvent.Create(nil, False, False, '');
end;

destructor TAttachWait.Destroy;
begin
  Arrived.Free;
  Finished.Free;
  inherited Destroy;
end;

function TPizarra.PushToDial(const Team, Line: string): Boolean;
var
  L: TList;
  i: Integer;
  Ch: TDialChannel;
begin
  Result := False;
  L := FDialChannels.LockList;
  try
    for i := 0 to L.Count - 1 do
    begin
      Ch := TDialChannel(L[i]);
      if Ch.Serves(Team) then
      begin
        Ch.Push(Line, '', -1);   { control line: empty team, negative seq }
        Exit(True);
      end;
    end;
  finally
    FDialChannels.UnlockList;
  end;
end;

{ True when From is named in the attach_trust list (comma/space/;-separated,
  case-insensitive) or the list is the keyword 'all'. An empty From or empty
  list is never trusted. A trusted identity may attach AND write any team, with
  its OWN credential - no shared console secret. }
function AttachTrusted(const TrustList, From: string): Boolean;
var
  s, tok, f: string;
  i: Integer;
begin
  Result := False;
  f := LowerCase(Trim(From));
  if (f = '') or (Trim(TrustList) = '') then
    Exit;
  s := LowerCase(TrustList);
  for i := 1 to Length(s) do
    if (s[i] = ',') or (s[i] = ';') or (s[i] = #9) then
      s[i] := ' ';
  s := s + ' ';
  tok := '';
  for i := 1 to Length(s) do
    if s[i] = ' ' then
    begin
      tok := Trim(tok);
      if (tok = 'all') or (tok = f) then
        Exit(True);
      tok := '';
    end
    else
      tok := tok + s[i];
end;

function TPizarra.AttachAcquire(const Team: string; out Why: string): Boolean;
var
  n: Integer;
begin
  Result := False;
  Why := '';
  FAttachLock.Enter;
  try
    if FAttachTotal >= ATTACH_MAX_TOTAL then
    begin
      Why := Format('attach: too many attaches open on this hub (%d)',
        [ATTACH_MAX_TOTAL]);
      Exit;
    end;
    n := StrToIntDef(FAttachPer.Values[LowerCase(Team)], 0);
    if n >= ATTACH_MAX_PER_TEAM then
    begin
      Why := Format('attach: per-team limit reached for %s (%d)',
        [Team, ATTACH_MAX_PER_TEAM]);
      Exit;
    end;
    Inc(FAttachTotal);
    FAttachPer.Values[LowerCase(Team)] := IntToStr(n + 1);
    Result := True;
  finally
    FAttachLock.Leave;
  end;
end;

procedure TPizarra.AttachRelease(const Team: string);
var
  n: Integer;
begin
  FAttachLock.Enter;
  try
    if FAttachTotal > 0 then
      Dec(FAttachTotal);
    n := StrToIntDef(FAttachPer.Values[LowerCase(Team)], 0) - 1;
    if n <= 0 then
      FAttachPer.Values[LowerCase(Team)] := ''   { removes the pair }
    else
      FAttachPer.Values[LowerCase(Team)] := IntToStr(n);
  finally
    FAttachLock.Leave;
  end;
end;

procedure TPizarra.HandleAttach(Obj: TJSONObject; const From, BoundTeam: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  T: TTeam;
  TeamKey, Term, Mode, Why, Exe, Sess, PathV, HomeV, TmpV: string;
  WantWrite, Write, Held: Boolean;
  Cols, Rows: Integer;
  Child: TPtyChild;
  Err: string;
  Argv, Env: array of string;
  FromClient, FromPty: Int64;
begin
  C := Snap;
  Held := False;
  Child.Pid := 0;
  Child.Master := -1;

  { WHO. Console, a team delegated the attach family, or - when the operator
    trusts the whole fleet with [server] attach_trust - any authenticated team.
    The binding guard in HandleConnect has already made From trustworthy. }
  if not (ConsoleFor(From, 'attach') or AttachTrusted(C.AttachTrust, From)) then
  begin
    WriteLine(Data, ReplyErr('attach: only the console, a team delegated the ' +
      'attach family, or a team named in [server] attach_trust may open a ' +
      'terminal into another team''s session'));
    Exit;
  end;
  TeamKey := Trim(Obj.Get('team', ''));
  if not FindTeam(C, TeamKey, T) then
  begin
    WriteLine(Data, ReplyErr('unknown team: ' + TeamKey));
    Exit;
  end;
  { WRITE is for console and for identities the operator named in attach_trust.
    A writable tmux client is full control of that host's tmux server - prefix-s,
    choose-tree and kill-session included - so a merely delegated team is
    downgraded silently to read-only and the reply says so; attach_trust is the
    operator's explicit statement that those identities may drive it. }
  WantWrite := Obj.Get('write', False);
  Write := WantWrite and (SameText(From, 'console') or
                          AttachTrusted(C.AttachTrust, From));
  Term := SafeTerm(Obj.Get('term', ''));

  { WHERE. Same order as TryDeliver: dial, then push, then local. Push and dial
    targets are relayed to the daemon on that host, which owns the tmux client;
    only a LOCAL team is served here. Each route accounts and replies itself. }
  if T.Dial then
  begin
    RelayDialAttach(Data, From, T, Write, Term);
    Exit;
  end;
  if T.Host <> '' then
  begin
    RelayPushAttach(Data, From, T, Write, Term);
    Exit;
  end;
  if T.TmuxSession = '' then
  begin
    WriteLine(Data, ReplyErr(Format('attach: %s has no terminal session ' +
      '(inbox-only member)', [T.Name])));
    Exit;
  end;
  if not C.AttachLocal then
  begin
    WriteLine(Data, ReplyErr('attach not enabled for local teams on this ' +
      'hub: set [server] attach_local = on in pizarra.conf'));
    Exit;
  end;
  Sess := T.TmuxSession;
  if (Sess = '-') or (not SessionExists(Sess)) then
  begin
    WriteLine(Data, ReplyErr(Format('attach: session %s of %s is not running',
      [Sess, T.Name])));
    Exit;
  end;

  { HOW MANY. }
  if not AttachAcquire(T.Name, Why) then
  begin
    WriteLine(Data, ReplyErr(Why));
    Exit;
  end;
  Held := True;
  try
    Exe := TmuxPath;
    if Exe = '' then
    begin
      WriteLine(Data, ReplyErr('attach: tmux binary not found on the hub host'));
      Exit;
    end;
    { The PTY is sized to the SESSION, never to the viewer: with the client
      the same size as the window, tmux's window-size policy - whatever it is
      on this host - has nothing to resize. ignore-size on the client is the
      second guard. }
    if not SessionSize(Sess, Cols, Rows) then
    begin
      Cols := 80;
      Rows := 24;
    end;
    if Write then
    begin
      SetLength(Argv, 7);
      Argv[0] := 'tmux'; Argv[1] := '-u'; Argv[2] := 'attach-session';
      Argv[3] := '-f'; Argv[4] := 'ignore-size'; Argv[5] := '-t'; Argv[6] := Sess;
      Mode := 'write';
    end
    else
    begin
      { -r is read-only,ignore-size: only detach/switch keys have any effect }
      SetLength(Argv, 6);
      Argv[0] := 'tmux'; Argv[1] := '-u'; Argv[2] := 'attach-session';
      Argv[3] := '-r'; Argv[4] := '-t'; Argv[5] := Sess;
      Mode := 'read-only';
    end;
    { The child's environment is built here and contains no TMUX: the hub
      itself runs inside tmux under --host-session, and a tmux client started
      with TMUX set does not attach, it switches the hub's own client. }
    PathV := GetEnvironmentVariable('PATH');
    if PathV = '' then
      PathV := '/usr/local/bin:/usr/bin:/bin';
    HomeV := GetEnvironmentVariable('HOME');
    if HomeV = '' then
      HomeV := '/root';
    TmpV := GetEnvironmentVariable('TMUX_TMPDIR');
    SetLength(Env, 4);
    Env[0] := 'PATH=' + PathV;
    Env[1] := 'HOME=' + HomeV;
    Env[2] := 'TERM=' + Term;
    Env[3] := 'LANG=C.UTF-8';
    if TmpV <> '' then
    begin
      SetLength(Env, 5);
      Env[4] := 'TMUX_TMPDIR=' + TmpV;
    end;
    if not PtySpawn(Exe, Argv, Env, Cols, Rows, Child, Err) then
    begin
      WriteLine(Data, ReplyErr('attach: ' + Err));
      Exit;
    end;

    { UPGRADE. This is the last JSON line on the connection. }
    WriteLine(Data, ReplyAttachOk(T.Name, Write, Cols, Rows));
    FLog.Info(Format('attach opened: %s -> %s (%s, %dx%d, tmux pid %d)',
      [From, T.Name, Mode, Cols, Rows, Child.Pid]));
    Broadcast(EvSys(Format('attach: %s -> %s (%s) opened',
      [From, T.Name, Mode])), 0);

    FromClient := 0;
    FromPty := 0;
    try
      { Read-only: the viewer's bytes are dropped HERE, before any of them
        can reach the tmux client. tmux -r would ignore them too, but with
        input flowing its switch-client keys let a viewer browse other
        sessions on the server; the hub is the authoritative gate. }
      PtyPump(Data.Handle, Child.Master, not Write, @ShutdownRequested,
        FromClient, FromPty);
    except
      { Nothing may be written to the socket as JSON after the upgrade; an
        exception here is logged and the relay simply ends. }
      on E: Exception do
        FLog.Info('attach relay error for ' + T.Name + ': ' + E.Message);
    end;
    PtyClose(Child, ATTACH_GRACE_MS);
    FLog.Info(Format('attach closed: %s -> %s (%s, %d bytes from viewer, ' +
      '%d bytes from terminal)', [From, T.Name, Mode, FromClient, FromPty]));
    Broadcast(EvSys(Format('attach: %s -> %s (%s) closed',
      [From, T.Name, Mode])), 0);
  finally
    if Child.Pid > 0 then
      PtyClose(Child, ATTACH_GRACE_MS);
    if Held then
      AttachRelease(T.Name);
  end;
end;

procedure TPizarra.RelayPushAttach(Data: TSocketStream; const From: string;
  const T: TTeam; Write: Boolean; const Term: string);
var
  C: TPizarraConfig;
  Sock: TInetSocket;
  Why, Mode: string;
  Held: Boolean;
  a, b: Int64;
begin
  C := Snap;
  if not AttachAcquire(T.Name, Why) then
  begin
    WriteLine(Data, ReplyErr(Why));
    Exit;
  end;
  Held := True;
  Sock := nil;
  if Write then Mode := 'write' else Mode := 'read-only';
  try
    try
      Sock := TInetSocket.Create(T.Host, T.Port, 5000);
    except
      on E: Exception do
      begin
        WriteLine(Data, ReplyErr(Format('attach: cannot reach %s at %s:%d: %s',
          [T.Name, T.Host, T.Port, E.Message])));
        Exit;
      end;
    end;
    { The daemon opens the terminal and writes ReplyAttachOk (or ReplyErr) then
      raw bytes; all of it flows back through here to the viewer unread. The hub
      is a pipe from this point - it looks at none of it. }
    WriteLine(Sock, BuildAttach(C.Secret, From, T.Name, Write, Term));
    FLog.Info(Format('attach opened: %s -> %s (%s, push %s:%d)',
      [From, T.Name, Mode, T.Host, T.Port]));
    Broadcast(EvSys(Format('attach: %s -> %s (%s) opened',
      [From, T.Name, Mode])), 0);
    a := 0;
    b := 0;
    try
      { Read-only drops the viewer's keystrokes at the hub - the authoritative
        gate; the daemon also spawns -r, but the hub is the one that decides. }
      PtyPump(Data.Handle, Sock.Handle, not Write, @ShutdownRequested, a, b);
    except
      on E: Exception do
        FLog.Info('attach relay error for ' + T.Name + ': ' + E.Message);
    end;
    FLog.Info(Format('attach closed: %s -> %s (%s, %d bytes from viewer, ' +
      '%d bytes from terminal)', [From, T.Name, Mode, a, b]));
    Broadcast(EvSys(Format('attach: %s -> %s (%s) closed',
      [From, T.Name, Mode])), 0);
  finally
    if Sock <> nil then
      Sock.Free;
    if Held then
      AttachRelease(T.Name);
  end;
end;

procedure TPizarra.RelayDialAttach(Data: TSocketStream; const From: string;
  const T: TTeam; Write: Boolean; const Term: string);
var
  W: TAttachWait;
  Why, Mode, Token: string;
  Held, Claimed: Boolean;
  L: TList;
begin
  if not AttachAcquire(T.Name, Why) then
  begin
    WriteLine(Data, ReplyErr(Why));
    Exit;
  end;
  Held := True;
  if Write then Mode := 'write' else Mode := 'read-only';
  { Unique, unguessable-enough rendezvous token; the ExpectFrom check on the
    join is the real authority, so this only needs to be unique. }
  Token := IntToHex(GetTickCount64, 16) + IntToHex(Random($7FFFFFFF), 8) +
           IntToHex(Random($7FFFFFFF), 8);
  W := TAttachWait.Create(Token, T.Name, From, Term, Write, Data);
  FAttachWaits.Add(W);
  try
    if not PushToDial(T.Name, BuildAttachOpen(Token, From, T.Name, Write, Term)) then
    begin
      FAttachWaits.Remove(W);
      WriteLine(Data, ReplyErr(Format('attach: %s is not currently dialed in',
        [T.Name])));
      W.Free;
      Exit;
    end;
    { Wait for the daemon to dial the hub back; HandleAttachJoin claims W (sets
      JoinData and removes it from the list under the list lock) and does the
      relay. Then it signals Finished and we free W. }
    if W.Arrived.WaitFor(ATTACH_DIAL_MS) <> wrSignaled then
    begin
      Claimed := True;
      L := FAttachWaits.LockList;
      try
        if L.IndexOf(W) >= 0 then
        begin
          L.Remove(W);
          Claimed := False;   { it was never claimed; safe to refuse and free }
        end;
      finally
        FAttachWaits.UnlockList;
      end;
      if not Claimed then
      begin
        WriteLine(Data, ReplyErr(Format('attach: %s did not dial back in time',
          [T.Name])));
        W.Free;
        Exit;
      end;
    end;
    { Claimed: the join thread is relaying viewer <-> its dial-back connection
      and holds that connection open until we release it. Park until it finishes
      (it always signals Finished, including when the pump ends on shutdown). }
    while (W.Finished.WaitFor(ATTACH_JOIN_TICK_MS) <> wrSignaled) and
          (not ShutdownRequested) do
      ;
    if not ShutdownRequested then
      W.Free;   { on shutdown leave W to the exiting process; avoids a UAF race }
  finally
    if Held then
      AttachRelease(T.Name);
  end;
end;

procedure TPizarra.HandleAttachJoin(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  Token, Mode: string;
  W: TAttachWait;
  L: TList;
  i: Integer;
  a, b: Int64;
begin
  Token := Trim(Obj.Get('token', ''));
  W := nil;
  L := FAttachWaits.LockList;
  try
    for i := 0 to L.Count - 1 do
      if TAttachWait(L[i]).Token = Token then
      begin
        W := TAttachWait(L[i]);
        Break;
      end;
    { The token must be redeemed by the very team it targeted: a bound dial
      credential proves From, so a different host cannot hijack the viewer. }
    if (W <> nil) and (not SameText(From, W.ExpectFrom)) then
      W := nil
    else if W <> nil then
    begin
      W.JoinData := Data;   { set under the lock, atomically with the claim }
      L.Remove(W);
    end;
  finally
    FAttachWaits.UnlockList;
  end;
  if W = nil then
  begin
    WriteLine(Data, ReplyErr('attach_join: no waiting viewer for this token'));
    Exit;
  end;
  W.Arrived.SetEvent;
  if W.Write then Mode := 'write' else Mode := 'read-only';
  FLog.Info(Format('attach opened: %s -> %s (%s, dial)',
    [W.Caller, W.ExpectFrom, Mode]));
  Broadcast(EvSys(Format('attach: %s -> %s (%s) opened',
    [W.Caller, W.ExpectFrom, Mode])), 0);
  a := 0;
  b := 0;
  try
    { Relay viewer <-> this dial-back connection. The daemon's ReplyAttachOk and
      then raw terminal bytes flow to the viewer unread. }
    PtyPump(W.ClientData.Handle, Data.Handle, not W.Write, @ShutdownRequested,
      a, b);
  except
    on E: Exception do
      FLog.Info('attach relay error for ' + W.ExpectFrom + ': ' + E.Message);
  end;
  FLog.Info(Format('attach closed: %s -> %s (%s, dial, %d bytes from viewer, ' +
    '%d bytes from terminal)', [W.Caller, W.ExpectFrom, Mode, a, b]));
  Broadcast(EvSys(Format('attach: %s -> %s (%s) closed',
    [W.Caller, W.ExpectFrom, Mode])), 0);
  { Last touch of W: hand it back to the viewer thread to free. After this the
    viewer wakes, frees W, and closes its own connection; we return and close
    this one. }
  W.Finished.SetEvent;
end;

{ ---------------------------------------------------------------------------
  tiza shell (1.1.33) - a login shell on a team's HOST.

  Attach lets a caller watch and drive an agent's tmux pane. This opens a
  shell on the machine underneath it, which is the only way to administer the
  dial-in endpoints: they have no inbound route at all, so the shell rides the
  reverse channel they already hold open to the hub.

  The hub's job is unchanged doctrine: authorise, route, account, relay. It
  never interprets a byte of the session, and it deliberately does not record
  one - the operator types a sudo password in there, and the hub's store is
  replicated and fleet-readable. Who, where, as whom, how big and how many
  bytes is what gets logged; the content belongs to the host's own sudo and
  audit trail.

  Every gate and counter here is separate from attach's. Enabling one must
  never enable the other, and eight open attaches must never be able to make
  the fleet unadministrable.
  --------------------------------------------------------------------------- }
const
  SHELL_MAX_TOTAL    = 4;     { per hub - a shell is heavier than a viewer }
  SHELL_MAX_PER_HOST = 2;     { per target HOST, not per team }
  SHELL_GRACE_MS     = 3000;  { HUP -> KILL; a login shell runs its logout }
  SHELL_DIAL_MS      = 8000;  { a dial daemon must dial back within this }
  SHELL_JOIN_TICK_MS = 1000;  { relay-park wait granularity (shutdown-aware) }

{ ---- dial shell rendezvous (TShellWait) ---- }

constructor TShellWait.Create(const AToken, AExpectFrom, ACaller, ATerm: string;
  ACols, ARows: Integer; AClient: TSocketStream);
begin
  inherited Create;
  Token := AToken;
  ExpectFrom := AExpectFrom;
  Caller := ACaller;
  Term := ATerm;
  Cols := ACols;
  Rows := ARows;
  ClientData := AClient;
  JoinData := nil;
  { manual-reset off (auto): each is waited exactly once }
  Arrived := TEvent.Create(nil, False, False, '');
  Finished := TEvent.Create(nil, False, False, '');
end;

destructor TShellWait.Destroy;
begin
  Arrived.Free;
  Finished.Free;
  inherited Destroy;
end;

{ Same list grammar as AttachTrusted, but its OWN key. Deliberately a separate
  function rather than a shared one: two lists that happen to parse alike must
  not quietly become one key under a later refactor. }
function ShellTrusted(const TrustList, From: string): Boolean;
var
  s, tok, want: string;
  i: Integer;
begin
  Result := False;
  want := LowerCase(Trim(From));
  if want = '' then
    Exit;
  s := LowerCase(Trim(TrustList));
  if s = '' then
    Exit;
  tok := '';
  for i := 1 to Length(s) + 1 do
    if (i > Length(s)) or (s[i] = ',') or (s[i] = ';') or (s[i] = #9) or
       (s[i] = ' ') then
    begin
      tok := Trim(tok);
      if (tok = 'all') or ((tok <> '') and (tok = want)) then
        Exit(True);
      tok := '';
    end
    else
      tok := tok + s[i];
end;

{ The accounting key. A shell is per HOST: two teams on one push box share one
  budget there, which is what the operator actually means by "two shells on
  that machine". }
function ShellHostKey(const T: TTeam): string;
begin
  if T.Dial then
    Result := 'dial:' + LowerCase(T.Name)
  else if T.Host <> '' then
    Result := 'push:' + LowerCase(T.Host) + ':' + IntToStr(T.Port)
  else
    Result := 'local';
end;

function TPizarra.ShellAcquire(const HostKey: string; out Why: string): Boolean;
var
  n: Integer;
begin
  Result := False;
  Why := '';
  FShellLock.Enter;
  try
    if FShellTotal >= SHELL_MAX_TOTAL then
    begin
      Why := Format('shell: too many shells open on this hub (%d)',
        [SHELL_MAX_TOTAL]);
      Exit;
    end;
    n := StrToIntDef(FShellPer.Values[HostKey], 0);
    if n >= SHELL_MAX_PER_HOST then
    begin
      Why := Format('shell: shell limit reached for %s (%d)',
        [HostKey, SHELL_MAX_PER_HOST]);
      Exit;
    end;
    Inc(FShellTotal);
    FShellPer.Values[HostKey] := IntToStr(n + 1);
    Result := True;
  finally
    FShellLock.Leave;
  end;
end;

procedure TPizarra.ShellRelease(const HostKey: string);
var
  n: Integer;
begin
  FShellLock.Enter;
  try
    if FShellTotal > 0 then
      Dec(FShellTotal);
    n := StrToIntDef(FShellPer.Values[HostKey], 0) - 1;
    if n <= 0 then
      FShellPer.Values[HostKey] := ''   { removes the pair }
    else
      FShellPer.Values[HostKey] := IntToStr(n);
  finally
    FShellLock.Leave;
  end;
end;

procedure TPizarra.HandleShell(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  C: TPizarraConfig;
  T: TTeam;
  TeamKey, Term, Why, Exe, Err, HostKey: string;
  Held: Boolean;
  Cols, Rows: Word;
  Child: TPtyChild;
  Argv, Env: TStringArray;
  FromClient, FromPty: Int64;
begin
  C := Snap;
  Held := False;
  Child.Pid := 0;
  Child.Master := -1;

  { WHO. The console, or an identity the operator named in [server]
    shell_trust. Deliberately NOT ConsoleFor: the delegate families are
    administrative command families, and a root-capable shell sits above every
    one of them - a hand-edited delegate key must never grow into shell
    access. The binding guard in HandleConnect has already made From
    trustworthy. }
  if not (SameText(From, 'console') or ShellTrusted(C.ShellTrust, From)) then
  begin
    WriteLine(Data, ReplyErr('shell: only the console or a team named in ' +
      '[server] shell_trust may open a shell on a host'));
    Exit;
  end;
  TeamKey := Trim(Obj.Get('team', ''));
  if not FindTeam(C, TeamKey, T) then
  begin
    WriteLine(Data, ReplyErr('unknown team: ' + TeamKey));
    Exit;
  end;
  Term := SafeTerm(Obj.Get('term', ''));
  { Unlike attach, the pty is sized to the VIEWER: a shell has no session to
    inherit a size from and no other observer to disturb. }
  SafeWinSize(Obj.Get('cols', 0), Obj.Get('rows', 0), Cols, Rows);

  { WHERE. Same order as TryDeliver: dial, then push, then local. The shell
    opens on the MACHINE where the team runs, not inside the team's session,
    so two teams on one host are two names for the same shell. }
  if T.Dial then
  begin
    RelayDialShell(Data, From, T, Term, Cols, Rows);
    Exit;
  end;
  if T.Host <> '' then
  begin
    RelayPushShell(Data, From, T, Term, Cols, Rows);
    Exit;
  end;
  { LOCAL: the hub host's own machine. Its opt-in is a hub key because a local
    team lives in the registry and has no daemon config of its own. }
  if not C.ShellLocal then
  begin
    WriteLine(Data, ReplyErr('shell not enabled on this hub host: set ' +
      '[server] shell_local = on in pizarra.conf'));
    Exit;
  end;
  if C.ShellUser = '' then
  begin
    WriteLine(Data, ReplyErr('shell: no account configured on the hub host ' +
      '(set [server] shell_user = <account> in pizarra.conf)'));
    Exit;
  end;

  { HOW MANY. }
  HostKey := ShellHostKey(T);
  if not ShellAcquire(HostKey, Why) then
  begin
    WriteLine(Data, ReplyErr(Why));
    Exit;
  end;
  Held := True;
  try
    { One shared plan for every route, so the hub's local shell and a daemon's
      are the same thing spawned the same way and refused in the same words. }
    if not ShellSpawnPlan(C.ShellUser, Term, Exe, Argv, Env, Why) then
    begin
      WriteLine(Data, ReplyErr(Why));
      Exit;
    end;
    if not PtySpawn(Exe, Argv, Env, Cols, Rows, Child, Err) then
    begin
      WriteLine(Data, ReplyErr('shell: ' + Err));
      Exit;
    end;

    { UPGRADE. This is the last JSON line on the connection. }
    WriteLine(Data, ReplyShellOk(T.Name, C.ShellUser, GetHostName, Cols, Rows));
    FLog.Info(Format('shell opened: %s -> %s (local, %s@%s, %dx%d, pid %d)',
      [From, T.Name, C.ShellUser, GetHostName, Cols, Rows, Child.Pid]));
    Broadcast(EvSys(Format('shell: %s -> %s (local, %s) opened',
      [From, T.Name, C.ShellUser])), 0);

    FromClient := 0;
    FromPty := 0;
    try
      { False: never drop. A shell you cannot type into is not a lesser
        grant, it is a useless one - so there is no read-only mode at all. }
      PtyPump(Data.Handle, Child.Master, False, @ShutdownRequested,
        FromClient, FromPty);
    except
      { Nothing may be written to the socket as JSON after the upgrade. }
      on E: Exception do
        FLog.Info('shell relay error for ' + T.Name + ': ' + E.Message);
    end;
    PtyClose(Child, SHELL_GRACE_MS);
    FLog.Info(Format('shell closed: %s -> %s (local, %d bytes from client, ' +
      '%d bytes from shell)', [From, T.Name, FromClient, FromPty]));
    Broadcast(EvSys(Format('shell: %s -> %s (local) closed',
      [From, T.Name])), 0);
  finally
    if Child.Pid > 0 then
      PtyClose(Child, SHELL_GRACE_MS);
    if Held then
      ShellRelease(HostKey);
  end;
end;

procedure TPizarra.RelayPushShell(Data: TSocketStream; const From: string;
  const T: TTeam; const Term: string; Cols, Rows: Integer);
var
  C: TPizarraConfig;
  Sock: TInetSocket;
  Why, HostKey: string;
  Held: Boolean;
  a, b: Int64;
begin
  C := Snap;
  HostKey := ShellHostKey(T);
  if not ShellAcquire(HostKey, Why) then
  begin
    WriteLine(Data, ReplyErr(Why));
    Exit;
  end;
  Held := True;
  Sock := nil;
  try
    try
      Sock := TInetSocket.Create(T.Host, T.Port, 5000);
    except
      on E: Exception do
      begin
        WriteLine(Data, ReplyErr(Format('shell: cannot reach %s at %s:%d: %s',
          [T.Name, T.Host, T.Port, E.Message])));
        Exit;
      end;
    end;
    { The daemon opens the shell and writes ReplyShellOk (or ReplyErr) then raw
      bytes; all of it flows back through here unread. The hub does not learn
      which account that host uses - the daemon logs it at its own end, which
      is where the host's audit trail already lives. }
    WriteLine(Sock, BuildShell(C.Secret, From, T.Name, Term, Cols, Rows));
    FLog.Info(Format('shell opened: %s -> %s (push %s:%d, %dx%d)',
      [From, T.Name, T.Host, T.Port, Cols, Rows]));
    Broadcast(EvSys(Format('shell: %s -> %s (push) opened', [From, T.Name])), 0);
    a := 0;
    b := 0;
    try
      PtyPump(Data.Handle, Sock.Handle, False, @ShutdownRequested, a, b);
    except
      on E: Exception do
        FLog.Info('shell relay error for ' + T.Name + ': ' + E.Message);
    end;
    FLog.Info(Format('shell closed: %s -> %s (push, %d bytes from client, ' +
      '%d bytes from shell)', [From, T.Name, a, b]));
    Broadcast(EvSys(Format('shell: %s -> %s (push) closed', [From, T.Name])), 0);
  finally
    if Sock <> nil then
      Sock.Free;
    if Held then
      ShellRelease(HostKey);
  end;
end;

procedure TPizarra.RelayDialShell(Data: TSocketStream; const From: string;
  const T: TTeam; const Term: string; Cols, Rows: Integer);
var
  W: TShellWait;
  Why, Token, HostKey: string;
  Held, Claimed: Boolean;
  L: TList;
begin
  HostKey := ShellHostKey(T);
  if not ShellAcquire(HostKey, Why) then
  begin
    WriteLine(Data, ReplyErr(Why));
    Exit;
  end;
  Held := True;
  { Unique, unguessable-enough rendezvous token; the ExpectFrom check on the
    join is the real authority, so this only needs to be unique. }
  Token := IntToHex(GetTickCount64, 16) + IntToHex(Random($7FFFFFFF), 8) +
           IntToHex(Random($7FFFFFFF), 8);
  W := TShellWait.Create(Token, T.Name, From, Term, Cols, Rows, Data);
  FShellWaits.Add(W);
  try
    if not PushToDial(T.Name, BuildShellOpen(Token, From, T.Name, Term, Cols, Rows)) then
    begin
      FShellWaits.Remove(W);
      WriteLine(Data, ReplyErr(Format('shell: %s is not currently dialed in',
        [T.Name])));
      W.Free;
      Exit;
    end;
    { Wait for the daemon to dial the hub back; HandleShellJoin claims W (sets
      JoinData and removes it from the list under the list lock) and does the
      relay. Then it signals Finished and we free W. }
    if W.Arrived.WaitFor(SHELL_DIAL_MS) <> wrSignaled then
    begin
      Claimed := True;
      L := FShellWaits.LockList;
      try
        if L.IndexOf(W) >= 0 then
        begin
          L.Remove(W);
          Claimed := False;   { it was never claimed; safe to refuse and free }
        end;
      finally
        FShellWaits.UnlockList;
      end;
      if not Claimed then
      begin
        WriteLine(Data, ReplyErr(Format('shell: %s did not dial back in time',
          [T.Name])));
        W.Free;
        Exit;
      end;
    end;
    { Claimed: the join thread is relaying and holds its dial-back connection
      open until we release it. Park until it finishes (it always signals
      Finished, including when the pump ends on shutdown). }
    while (W.Finished.WaitFor(SHELL_JOIN_TICK_MS) <> wrSignaled) and
          (not ShutdownRequested) do
      ;
    if not ShutdownRequested then
      W.Free;   { on shutdown leave W to the exiting process; avoids a UAF race }
  finally
    if Held then
      ShellRelease(HostKey);
  end;
end;

procedure TPizarra.HandleShellJoin(Obj: TJSONObject; const From: string;
  Data: TSocketStream);
var
  Token: string;
  W: TShellWait;
  L: TList;
  i: Integer;
  a, b: Int64;
begin
  Token := Trim(Obj.Get('token', ''));
  W := nil;
  L := FShellWaits.LockList;
  try
    for i := 0 to L.Count - 1 do
      if TShellWait(L[i]).Token = Token then
      begin
        W := TShellWait(L[i]);
        Break;
      end;
    { The token must be redeemed by the very team it targeted: a bound dial
      credential proves From, so a different host cannot hijack the client. }
    if (W <> nil) and (not SameText(From, W.ExpectFrom)) then
      W := nil
    else if W <> nil then
    begin
      W.JoinData := Data;   { set under the lock, atomically with the claim }
      L.Remove(W);
    end;
  finally
    FShellWaits.UnlockList;
  end;
  if W = nil then
  begin
    WriteLine(Data, ReplyErr('shell_join: no waiting client for this token'));
    Exit;
  end;
  W.Arrived.SetEvent;
  { W.Caller, never From: From is the daemon that dialed back, so logging it
    would record the target as its own caller and lose the audit trail. }
  FLog.Info(Format('shell opened: %s -> %s (dial, %dx%d)',
    [W.Caller, W.ExpectFrom, W.Cols, W.Rows]));
  Broadcast(EvSys(Format('shell: %s -> %s (dial) opened',
    [W.Caller, W.ExpectFrom])), 0);
  a := 0;
  b := 0;
  try
    PtyPump(W.ClientData.Handle, Data.Handle, False, @ShutdownRequested, a, b);
  except
    on E: Exception do
      FLog.Info('shell relay error for ' + W.ExpectFrom + ': ' + E.Message);
  end;
  FLog.Info(Format('shell closed: %s -> %s (dial, %d bytes from client, ' +
    '%d bytes from shell)', [W.Caller, W.ExpectFrom, a, b]));
  Broadcast(EvSys(Format('shell: %s -> %s (dial) closed',
    [W.Caller, W.ExpectFrom])), 0);
  { Last touch of W: hand it back to the client thread to free. }
  W.Finished.SetEvent;
end;

procedure TPizarra.HandleConnect(Stream: TSocketStream);
var
  Data: TSocketStream;
  Line, Cmd, From, Presented, BoundTeam: string;
  FromTeamChk: TTeam;
  Fams: array of string;
  Vis: TPzMsgArray;
  NVis, NMax, InbLim: Integer;
  Base, InbAfter: Int64;
  Obj: TJSONObject;
  Msgs: TPzMsgArray;
  Seq: Int64;
  C: TPizarraConfig;
  i: Integer;
  HasAfter: Boolean;   { whether `after` was present, independent of its value }
begin
  Data := Stream;
  try
    Line := ReadLine(Data);
    Obj := ParseObj(Line);
    if Obj = nil then
    begin
      WriteLine(Data, ReplyErr('bad json'));
      Exit;
    end;
    try
      { Auth: the global secret is unrestricted (console/admin). A per-team
        secret ([team:N] secret=) binds the request to THAT team — it may only
        claim from=<that team>, so a compromised team host cannot impersonate
        the console or another team. Teams without a per-team secret fall back
        to the global secret (unchanged behavior). }
      Presented := Obj.Get('secret', '');
      From := Obj.Get('from', '');
      BoundTeam := '';
      { an empty global secret must never authorize (defense in depth — the hub
        also refuses to start with an empty [server] secret) }
      if (FCfg.Secret <> '') and (Presented = FCfg.Secret) then
      begin
        { The global credential belongs to the console. In strict mode it may
          identify the console or a non-team operational label, but it may not
          impersonate a team that has a verifiable bound credential. The option
          defaults off for staged migration and quick rollback. }
        if FCfg.MasterConsoleOnly and (From <> '') and
           (not SameText(From, 'console')) and FindTeam(Snap, From, FromTeamChk) then
        begin
          WriteLine(Data, ReplyErr(Format('identity: the master key may only ' +
            'speak as console; use %s''s own credential to say from=%s ' +
            '(/etc/pizarra/agents/%s.conf)', [From, From, From])));
          Exit;
        end;
      end
      else
      begin
        C := Snap;
        for i := 0 to High(C.Teams) do
          if (C.Teams[i].Secret <> '') and (C.Teams[i].Secret = Presented) then
          begin
            BoundTeam := C.Teams[i].Name;
            Break;
          end;
        if BoundTeam = '' then
        begin
          WriteLine(Data, ReplyErr('unauthorized'));
          Exit;
        end;
      end;
      { An empty `from` with a team-bound credential has one unambiguous identity.
        Complete it here so legacy commands that omit `from` remain compatible;
        requiring redundant identity text would add no security. }
      if (BoundTeam <> '') and (Trim(From) = '') then
        From := BoundTeam;
      Cmd  := Obj.Get('cmd', '');
      { A daemon reports activity for EVERY team it hosts, yet presents ONE team's
        per-team secret (its [pizarra] self). So an activity report for a
        CO-HOSTED team legitimately has from<>BoundTeam — exempt it here and let
        HandleActivity authorize it by same-host. Everything else stays strict. }
      if (BoundTeam <> '') and (not SameText(From, BoundTeam)) and
         (Cmd <> CMD_ACTIVITY) then
      begin
        WriteLine(Data, ReplyErr(Format(
          'identity: this secret is bound to team %s; from=%s not allowed',
          [BoundTeam, From])));
        Exit;
      end;
      if Cmd = CMD_INBOX then
      begin
        { Inbox pages use `after` without consuming messages. Only an explicit
          acknowledgement advances the durable cursor. }
        InbLim := Obj.Get('limit', 50);
        if InbLim <= 0 then
          InbLim := 50;
        if InbLim > 200 then
          InbLim := 200;
        { Presence of `after`, not a positive value, selects pagination. Zero is
          a valid cursor for the first non-consuming page. }
        HasAfter := Obj.Find('after') <> nil;
        InbAfter := Obj.Get('after', Int64(0));
        if InbAfter < 0 then
          InbAfter := 0;
        if HasAfter then
        begin
          { Requesting a page is always non-consuming. }
          Msgs := FStore.UnreadPage(From, InbAfter, InbLim,
            Obj.Get('all', False));
          WriteLine(Data, ReplyInbox(Msgs,
            FStore.UnreadAfter(From,
              GreatestSeq(Msgs, InbAfter), Obj.Get('all', False))));
          Exit;
        end;
        { peek first, advance the cursor only AFTER the reply is written —
          otherwise a broken connection silently marks unseen messages read }
        Msgs := FStore.Unread(From, InbLim, True, Obj.Get('all', False));
        { Report how many remain beyond the page so acknowledgements cannot
          silently skip unseen messages. }
        WriteLine(Data, ReplyInbox(Msgs,
          FStore.UnreadOutside(From, InbLim, Obj.Get('all', False))));
        if (not Obj.Get('peek', False)) and (not Obj.Get('all', False)) and
           (Length(Msgs) > 0) then
          FStore.Ack(From, Msgs[High(Msgs)].Seq);
      end
      else if Cmd = CMD_SEND then
        { BoundTeam exists only when the sender proved its own team credential;
          preserve that distinction with the durable message. }
        { Distinguish a proven team, a team identity claimed through the global
          credential, and the legitimate global console/non-team label. Only the
          second case warrants an identity warning. }
        DoSend(From, Obj.Get('to', ''), Obj.Get('text', ''), Data,
          MarcaIdentidad(BoundTeam, From, Snap))
      else if Cmd = CMD_ACK then
      begin
        { Reject an acknowledgement beyond the latest stored message instead of
          silently clamping it; otherwise the client would believe a different
          cursor was committed and future messages could become invisible. }
        if FStore.Ack(From, Obj.Get('upto', Int64(0))) then
          WriteLine(Data, ReplyOk)
        else
          WriteLine(Data, ReplyErr(Format(
            'cannot acknowledge #%d: the last message is #%d — an acknowledgement ' +
            'marks read EVERYTHING below it, so one above the end would hide every ' +
            'message that arrives afterwards',
            [Obj.Get('upto', Int64(0)), FStore.LastSeq])));
      end
      else if Cmd = CMD_TEAMS then
        WriteLine(Data, ReplyTeams(From))
      else if Cmd = CMD_VER then
        WriteLine(Data, ReplyVer(PizarraVersion))
      { Report capabilities derived from BoundTeam, never from the caller's
        `from` claim. This lets delegated consoles verify their permission set
        before exposing unavailable actions. }
      else if Cmd = CMD_CAPS then
      begin
        SetLength(Fams, 0);
        if BoundTeam = '' then
        begin
          { A global credential is unbound and has no family ceiling. }
          for i := 0 to High(DELEGATE_FAMILIES) do
          begin
            SetLength(Fams, Length(Fams) + 1);
            Fams[High(Fams)] := DELEGATE_FAMILIES[i];
          end;
          WriteLine(Data, ReplyCaps('', True, Fams));
        end
        else
        begin
          for i := 0 to High(DELEGATE_FAMILIES) do
            if TeamDelegated(Snap, BoundTeam, DELEGATE_FAMILIES[i]) then
            begin
              SetLength(Fams, Length(Fams) + 1);
              Fams[High(Fams)] := DELEGATE_FAMILIES[i];
            end;
          WriteLine(Data, ReplyCaps(BoundTeam, False, Fams));
        end;
      end
      else if Cmd = CMD_RECENT then
      begin
        { Apply the same credential-derived scope as watch. A team-bound caller
          may see only its own traffic; viewing all traffic requires explicit
          `watch` delegation or the global console credential. }
        Seq := Obj.Get('since', Int64(-1));
        NMax := Obj.Get('max', 30);
        if NMax < 1 then
          NMax := 1;
        if (BoundTeam <> '') and
           (not TeamDelegated(Snap, BoundTeam, 'watch')) then
        begin
          { Filter before counting and limiting, as in watch, so unrelated
            records cannot displace every visible entry under a global cap. }
          if Seq < 0 then
            Base := 0
          else
            Base := Seq;
          Msgs := FStore.Since(Base, 0);
          Vis := nil;
          SetLength(Vis, Length(Msgs));
          NVis := 0;
          for i := 0 to High(Msgs) do
            if (SameText(Msgs[i].Dest, BoundTeam) or
                SameText(Msgs[i].From, BoundTeam)) and
               ((Seq < 0) or (Msgs[i].Seq > Seq)) then
            begin
              Vis[NVis] := Msgs[i];
              Inc(NVis);
            end;
          { Return the newest visible records requested. }
          if NVis > NMax then
          begin
            for i := 0 to NMax - 1 do
              Vis[i] := Vis[NVis - NMax + i];
            NVis := NMax;
          end;
          SetLength(Vis, NVis);
          Msgs := Vis;
        end
        else
        begin
          if Seq < 0 then
          begin
            { no cursor: the NEWEST max messages }
            Seq := FStore.LastSeq - NMax;
            if Seq < 0 then
              Seq := 0;
          end;
          Msgs := FStore.Since(Seq, NMax);
        end;
        WriteLine(Data, ReplyInbox(Msgs));
      end
      else if Cmd = CMD_TASK then
        HandleTask(Obj, From, Data)
      else if Cmd = CMD_WORKFLOW then
        HandleWorkflow(Obj, From, Data)
      else if Cmd = CMD_TEAM then
        HandleTeam(Obj, From, Data)
      else if Cmd = CMD_GROUP then
        HandleGroup(Obj, From, Data)
      else if Cmd = CMD_PROJECT then
        HandleProject(Obj, From, Data)
      else if Cmd = CMD_HEADER then
        HandleHeader(Obj, From, Data)
      else if Cmd = CMD_PUT then
        HandlePut(Obj, From, Data)
      else if Cmd = CMD_GET then
        HandleGet(Obj, From, Data)
      else if Cmd = CMD_WATCH then
begin
          { `watch` delegation grants fleet-wide traffic visibility like the
            console. It is deliberately separate from administrative families. }
          if (BoundTeam <> '') and TeamDelegated(Snap, BoundTeam, 'watch') then
            DoWatch(Data, Obj.Get('since', Int64(-1)), '')
          else
            DoWatch(Data, Obj.Get('since', Int64(-1)), BoundTeam);
        end
      else if Cmd = CMD_DIAL then
        { Identity and scope come from the authenticated credential, never from
          client-supplied watch fields. }
        DoDial(Data, From, BoundTeam, Obj.Get('teams', ''),
          Obj.Get('keepalive', 60), Obj.Get('ver', ''))
      else if Cmd = CMD_ATTACH then
        { The reply line is the last JSON on this connection: after it the
          stream is raw terminal bytes both ways until either side ends. }
        HandleAttach(Obj, From, BoundTeam, Data)
      else if Cmd = CMD_ATTACH_JOIN then
        { A dial daemon dialing the hub back for a pending attach. Pairs to the
          waiting viewer by token, then relays raw bytes both ways. }
        HandleAttachJoin(Obj, From, Data)
      else if Cmd = CMD_SHELL then
        { Same upgrade, but the far end is a login shell on the team's HOST.
          The reply line is the last JSON on this connection. }
        HandleShell(Obj, From, Data)
      else if Cmd = CMD_SHELL_JOIN then
        { A dial daemon dialing back for a pending shell. }
        HandleShellJoin(Obj, From, Data)
      else if Cmd = CMD_FLEET then
        HandleFleet(Data)
      else if Cmd = CMD_UPGET then
        HandleUpget(Obj, Data)
      else if Cmd = CMD_UPDATE then
        HandleUpdate(Obj, From, Data)
      else if Cmd = CMD_APP then
        HandleApp(Obj, From, Data)
      else if Cmd = CMD_BACKUP then
        HandleBackup(Obj, From, Data)
      else if Cmd = CMD_ACTIVITY then
        HandleActivity(Obj, From, BoundTeam, Data)
      else if Cmd = CMD_HOLD then
        HandleHold(Obj, From, Data)
      else
        WriteLine(Data, ReplyErr('unknown cmd'));
    finally
      Obj.Free;
    end;
  except
    on E: Exception do
      try
        WriteLine(Data, ReplyErr('server error: ' + E.Message));
      except
      end;
  end;
end;

procedure TPizarra.Run;
var
  wd: TWatchdog;
  i: Integer;
  Where: string;
  CfgWarns: TStringArray;
begin
  { Log unrecognized configuration values as well as printing them to stderr.
    TakeConfigWarnings drains its queue, so call it once before iterating. }
  CfgWarns := TakeConfigWarnings;
  for i := 0 to High(CfgWarns) do
    FLog.Info('config: ' + CfgWarns[i]);
  FLog.Info(Format('pizarra starting: listen=%s port=%d teams=%d',
    [FCfg.Listen, FCfg.Port, Length(FCfg.Teams)]));
  InstallShutdownHandler;
  FServer := TPzServer.Create(FCfg.Listen, FCfg.Port, @HandleConnect);
  try
    { Binding is the startup commit point. Nothing below may launch a managed
      session or claim that the hub is listening until both bind(2) and
      listen(2) have succeeded. }
    FServer.Prepare;
    Writeln(Format('pizarra: listening on %s:%d, %d team(s)',
      [FCfg.Listen, FCfg.Port, Length(FCfg.Teams)]));
    for i := 0 to High(FCfg.Teams) do
    begin
      if FCfg.Teams[i].Host <> '' then
        Where := Format('push %s:%d', [FCfg.Teams[i].Host, FCfg.Teams[i].Port])
      else
        Where := 'tmux ' + FCfg.Teams[i].TmuxSession;
      Writeln(Format('  [%d] %-12s %-24s %s',
        [FCfg.Teams[i].Id, FCfg.Teams[i].Name, Where, FCfg.Teams[i].Speciality]));
    end;
    Flush(Output);

    { Refresh the manual only after the listener is owned. A failed bind must
      be a read-only startup failure. }
    if FCfg.SharedDir <> '' then
      { unlink removes this exact directory entry and never follows a symlink;
        unlike FileExists it also catches a dangling link planted in the 1777
        exchange before the exclusive/no-follow recreation below. }
      FpUnlink(FCfg.SharedDir + '/' + SHARED_MANUAL);
    EnsureSharedDirs;
    { finish any workflow work the previous shutdown interrupted }
    try
      WfMaintain;
    except
      on E: Exception do
        FLog.Info('startup: workflow reconcile error: ' + E.Message);
    end;
    wd := TWatchdog.Create(Self);
    try
      FServer.Run;
    finally
      FLog.Info('pizarra: shutting down');
      Writeln('pizarra: shutting down');
      wd.Terminate;
      wd.WaitFor;
      wd.Free;
      { Detached connection threads (watch loops exit on ShutdownRequested within
        ~200 ms; a send handler is bounded by its I/O timeouts and the 2 s remote-
        push deadline) must finish before TPizarra state is freed. The listen
        socket is already closed, so no new connection can arrive. Give a generous
        window; if a handler is still running, exit the process rather than free
        state it is using (a shutdown use-after-free). }
      if not WaitConnectionsIdle(30000) then
      begin
        FLog.Info('pizarra: handlers still active at shutdown; exiting now');
        Writeln('pizarra: handlers still active; exiting now');
        Flush(Output);
        Halt(0);
      end;
    end;
  finally
    FreeAndNil(FServer);
  end;
end;

{ ---------- entry point ---------- }

function ShellQuote(const Value: string): string;
begin
  Result := '''' + StringReplace(Value, '''', '''\''''', [rfReplaceAll]) + '''';
end;

var
  ConfigArg, Path, SqlV, ConfigReason, HostSession, HostLaunch,
    HostStartWhy, SelfExe: string;
  i: Integer;
  App: TPizarra;
  MigrateOnly, HostCreated: Boolean;
begin
  { treat all AnsiStrings as UTF-8 regardless of the ambient locale — under a
    non-UTF-8 LANG (systemd/tmux default LANG=C) fpjson's parser would otherwise
    downgrade decoded text to the system codepage, turning accents/em-dashes
    into '?' on delivery and in the journal. }
  SetMultiByteConversionCodePage(CP_UTF8);
  { The hub always emits rendered color, even when its own output is a tmux pipe.
    The viewing client owns terminal capability detection and strips color when
    necessary. }
  AnsiInit(cmAlways);
  WATCHDOG_INTERVAL := StrToIntDef(GetEnvironmentVariable('PIZARRA_TICK'), 15);
  TEAMSET_TEST_DELAY := StrToIntDef(
    GetEnvironmentVariable('PIZARRA_TEST_SETDELAY'), 0);
  if WATCHDOG_INTERVAL < 1 then
    WATCHDOG_INTERVAL := 1;
  ConfigArg := '';
  HostSession := '';
  MigrateOnly := False;
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--config' then
    begin
      if i >= ParamCount then
      begin
        Writeln(StdErr, 'pizarra: --config requires a path');
        Halt(1);
      end;
      ConfigArg := ParamStr(i + 1);
      Inc(i);
    end
    else if (ParamStr(i) = '--version') or (ParamStr(i) = 'ver') then
    begin
      Writeln('pizarra ', PizarraVersion);
      { SQLite is loaded at runtime; report its availability prominently when
        diagnosing persistence. }
      if SqliteProbe(SqlV) then
        Writeln('sqlite: ', SqlV)
      else
        Writeln('sqlite: unavailable (the hub would refuse to start)');
      Halt(0);
    end
    else if ParamStr(i) = '--migrate-only' then
      MigrateOnly := True
    else if ParamStr(i) = '--host-session' then
    begin
      if i >= ParamCount then
      begin
        Writeln(StdErr, 'pizarra: --host-session requires a tmux session name');
        Halt(1);
      end;
      HostSession := Trim(ParamStr(i + 1));
      Inc(i);
    end
    else if ParamStr(i) = '--help' then
    begin
      Writeln('usage: pizarra [--config PATH] [--migrate-only] ' +
        '[--host-session NAME] [--version]');
      Halt(0);
    end;
    Inc(i);
  end;

  Path := ResolveConfigStrict(ConfigArg, 'PIZARRA_CONF', 'pizarra.conf', ConfigReason);
  { A missing canonical config is a genuine first installation only when no
    identity path was requested. Explicit and environment paths remain strict
    and are never replaced by a generated identity. }
  if (Path = '') and (ConfigReason = '') then
  begin
    if not BootstrapDefaultPizarraConfig(ConfigReason) then
    begin
      Writeln(StdErr, 'pizarra: first-run initialization failed: ', ConfigReason);
      Writeln(StdErr, 'pizarra: create /etc/pizarra/pizarra.conf (mode 0600) ',
        'and writable /var/lib/pizarra and /var/log/pizarra directories, or ',
        'start with --config PATH. No source-tree conf/ file is used.');
      Halt(1);
    end;
    Path := ResolveConfigStrict('', 'PIZARRA_CONF', 'pizarra.conf', ConfigReason);
    if Path <> '' then
      Writeln('pizarra: initialized /etc/pizarra and /var/lib/pizarra; ',
        'created matching pizarra.conf and tiza.conf credentials');
  end;
  if Path = '' then
  begin
    if ConfigReason <> '' then
      Writeln('pizarra: ', ConfigReason)
    else
      Writeln('pizarra: no config found (looked for pizarra.conf; use --config)');
    Halt(1);
  end;

  { Optional outer launcher for deployments that deliberately keep the hub in
    a visible tmux pane instead of systemd. Pizarra itself performs the single
    create-if-missing operation. An existing session always wins: it is never
    killed, replaced, renamed, or sent another launch command. The child omits
    --host-session, so it becomes the actual hub rather than recursing. }
  if HostSession <> '' then
  begin
    if MigrateOnly then
    begin
      Writeln(StdErr, 'pizarra: --host-session and --migrate-only are mutually exclusive');
      Halt(1);
    end;
    if HostSession = '-' then
    begin
      Writeln(StdErr, 'pizarra: refusing --host-session=-');
      Halt(1);
    end;
    SelfExe := ExpandFileName(ParamStr(0));
    HostLaunch := 'exec ' + ShellQuote(SelfExe) + ' --config ' + ShellQuote(Path);
    if not EnsureSessionReported(HostSession, HostLaunch,
      ExtractFileDir(SelfExe), '', HostCreated, HostStartWhy) then
    begin
      Writeln(StdErr, 'pizarra: host session was not started: ', HostStartWhy);
      Halt(1);
    end;
    { Say which of the two things actually happened. One message for both was
      a launcher that reported 'exists' about a session it had just created —
      it reads as 'someone else is already running the hub'. }
    if HostCreated then
      Writeln('pizarra: host session ', HostSession,
        ' created with the hub inside')
    else
      Writeln('pizarra: host session ', HostSession,
        ' already exists; existing sessions are always preserved');
    Halt(0);
  end;

  try
    App := TPizarra.Create(Path);
  except
    on E: Exception do
    begin
      Writeln('pizarra: ', E.Message);
      Halt(1);
    end;
  end;
  if MigrateOnly then
  begin
    Writeln('pizarra: configuration and SQLite registry verified; ' +
      'migration-only run complete (no listener or watchdog started)');
    App.Free;
    Halt(0);
  end;
  try
    App.Run;
  finally
    App.Free;
  end;
end.
