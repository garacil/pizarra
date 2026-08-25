{ pzconfig - INI configuration loader and delivery-message builder, shared by
  pizarra (daemon) and tiza (client/daemon/chat).

  pizarra.conf (bootstrap/static settings only):
    [server]  listen / port / secret / releases
    [log]     path
    [store]   dir
    [prompts] global | global_file   (short project prompt on every delivery)

  Teams, groups, projects, applications, manuals, and their relations live in
  SQLite. Legacy [team:*], [group:*], [project:*], and [app:*] sections are
  accepted only as one-time migration input and are then removed atomically.

  tiza.conf:
    [pizarra]      host / port / secret / self
    [daemon]       listen / port / secret     (only read by `tiza daemon`)
    [session:NAME] tmux_session / launch      (one per team hosted here)

  The *_file prompt variants read a UTF-8 text file (path relative to the
  config file's directory unless absolute) and win over the inline key.

  Config file resolution:
    1. explicit path argument (strict; no fallback)
    2. $PIZARRA_CONF / $TIZA_CONF / $PZWEB_CONF (strict; no fallback)
    3. /etc/pizarra/<name> (the only implicit runtime location)               }
unit pzconfig;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, IniFiles, pzmanual, pzlayout, Types, Unix, BaseUnix;

const
  DEFAULT_DAEMON_PORT = 7011;
  { Bootstrap manual stored at the exchange root. The hub recreates it when
    missing because cold-start agents read it first and delivery headers point
    to it. Keep its name centralized so the UI, header, and file stay aligned. }
  SHARED_MANUAL = 'AGENTS.md';

type
  TTeam = record
    Id:          Integer;
    Name:        string;
    Speciality:  string;
    Prompt:      string;   { per-team instructions added to every delivery }
    Parent:      string;   { boss team name; '' = root of the hierarchy }
    Project:     string;   { assigned project name; '' = inherit group/none }
    Secret:      string;   { per-team link secret; '' = use the global secret }
    Host:        string;   { '' = local team; else push to tiza daemon at Host:Port }
    Port:        Word;
    Dial:        Boolean;  { reverse channel: delivered over the daemon's inbound
                             dial connection (no host push) — for NAT/dynamic IP }
    TmuxSession: string;   { local teams only }
    Launch:      string;   { local teams only }
    User:        string;   { local teams only: OS user to run the session as }
    Workdir:     string;   { team's source/work directory. Local tmux sessions
                             start there and the delivery header names it. }
    Slave:       Boolean;  { read-only subordinate that answers only its owner.
                             This is an explicit team property, not something
                             inferred from having a parent: ordinary subordinate
                             teams may still write code. }
    Delegate:    string;   { explicit list of delegated console-command families:
                             team, group, project, app, task, workflow, and watch.
                             watch exposes traffic and is distinct from mutation
                             authority. Empty means no delegation.

                             Delegation is per FAMILY rather than a broad
                             "is-console" flag. The delegated team keeps its own
                             identity and every action remains attributable. }
    HoldBlocked: Boolean;  { opt-in: when the hub DETECTS this team blocked on a
                             permission prompt, queue deliveries instead of
                             pasting and warn senders. Delivery resumes on
                             unblock. Per-team and off by default because pane
                             classification is heuristic. }
  end;
  TTeamArray = array of TTeam;

  TGroup = record
    Name:     string;
    Project:  string;            { project assigned to the whole group }
    Boss:     string;            { team that administers this group; '' = none }
    Members:  array of string;   { team names }
    Excluded: array of string;   { members MUTED from @group broadcasts: still
                                   members in every other respect (roster, boss
                                   authority, project derivation), just skipped
                                   in the fan-out. Group-scoped; 'all' ignores it. }
    OnIdle:   string;            { what to do when ALL members go idle (the group
                                   quiesces): '' / 'off' = nothing; 'boss' = wake
                                   the group boss; 'all' = wake every member; or a
                                   comma list of specific teams. }
    OnIdleMsg: string;           { the text sent when the group quiesces; '' = a
                                   generic default. Configurable so it can change
                                   without a rebuild. }
    OnIdleFrom: string;          { sender identity of that message; '' = 'pizarra'.
                                   e.g. 'console' so it reads as the operator. }
    OnIdleReply: string;         { who the recipient is told to answer; '' = the
                                   sender. Can differ, e.g. from=console but the
                                   reply routes to a designated coordinator. }
    HdrNote:  string;            { a standing instruction shown in the delivery
                                   header of EVERY message to this group's
                                   members (operator rule for the group's work).
                                   '' = nothing. Uncapped: it is meant to be read
                                   in full each time. }
    OnBlock:  string;            { what the hub does when a member is DETECTED
                                   blocked on a permission prompt. '' or 'alarm'
                                   = the loud operator alarm (default);
                                   'log' = record a quiet log line only, no
                                   alarm — for groups the operator watches by
                                   hand. Detection/hold/auto_enter are unaffected. }
  end;
  TGroupArray = array of TGroup;

  { An application: a real program the fleet builds and runs. It names the
    ONE team responsible for it, so "who owns this?" and "what does this team
    own?" are both answerable, and the owner sees its apps in every header. }
  TApp = record
    Name:    string;
    Team:    string;   { responsible team; '' = unassigned }
    Repo:    string;   { repository (URL or path) }
    Path:    string;   { where it lives on disk }
    Purpose: string;   { one line: what it is for }
    Detail:  string;   { longer: what it actually does }
    HasDoc:  Boolean;  { has a manual; resolved at load time, not by file }
    { Comma-separated projection of the authoritative app_project rows loaded
      from SQLite. It exists because the delivery-header builder intentionally
      has no database dependency. Per-pair roles remain in app_project. }
    Projects: string;
  end;
  TAppArray = array of TApp;

  TProject = record
    Name: string;
    Boss: string;   { team that administers this project; '' = none }
  end;
  TProjectArray = array of TProject;

  PPizarraConfig = ^TPizarraConfig;
  TPizarraConfig = record
    Listen:       string;
    Port:         Integer;
    Secret:       string;
    LogPath:      string;
    StoreDir:     string;
    RegistryAuthority: string; { [registry] authority: sqlite }
    SharedDir:    string;   { NFS exchange root; '' = feature off }
    Releases:     string;   { release-artifact dir served to self-updating
                              daemons (cmd=upget); '' = feature off }
    GlobalPrompt: string;
    GlobalRule:   string;   { [header] note: a standing instruction shown in the
                              delivery header of EVERY message to EVERY team,
                              uncapped. '' = none. }
    HeaderMode:   string;   { 'short' (default) | 'full' — delivery header size }
    HdrStyle:     Boolean;  { [header] toggles, honored only when header=short }
    HdrOrders:    Boolean;
    { [server] master_console_only restricts the master key to from=console.
      It defaults off because enabling it before every team speaker has a
      per-team secret would silence those clients and fleet delivery daemons. }
    MasterConsoleOnly: Boolean;
    HdrTasks:     Boolean;
    HdrTeams:     Boolean;
    HdrGroupOwn:  Boolean;  { group=own -> True; group=off -> False }
    HdrProject:   Boolean;
    HdrSubs:      Boolean;
    HdrShared:    Boolean;
    HdrWorkflow:  Boolean;  { workflow role lines in delivery headers }
    HdrManual:    string;   { 'first' (default) | 'off' | 'always' }
    { permission-block alarm throttle: at most AlarmMax alarms per blocked
      episode (1..5, default 3), spaced AlarmEvery seconds — so a long block
      does not ring forever. }
    AlarmMax:     Integer;
    AlarmEvery:   Integer;
    { a group must stay fully idle this long before it counts as quiesced (the
      barrier), so a between-turns flicker never fires the continue-signal. }
    GroupIdleDwell: Integer;
    Teams:        TTeamArray;
    Groups:       TGroupArray;
    Projects:     TProjectArray;
    Apps:         TAppArray;
  end;

  TTizaConfig = record
    Host:   string;
    Port:   Integer;
    Secret: string;
    SelfId: string;
  end;

  { One tmux session hosted by this machine's tiza daemon. }
  TPzSession = record
    Team:        string;   { team name, as addressed on the bus }
    TmuxSession: string;
    Launch:      string;
    Workdir:     string;   { session start directory (tmux -c); '' = default }
    User:        string;   { OS user to run the session as; '' = the daemon user }
    Activity:    Boolean;  { opt-in: sample this pane and report moving/idle/blocked }
    IdleMatch:   string;   { extra '|'-separated substrings that mark the idle prompt }
    BlockMatch:  string;   { extra '|'-separated substrings that mark a permission prompt }
    AutoEnter:   Boolean;  { opt-in: when this pane is DETECTED blocked on a
                             permission prompt, the daemon presses Enter to clear
                             it (accepts the default). Off by default - it
                             auto-approves prompts, so only for a trusted session. }
    Hint:        string;   { path to a state hint file written by an optional
                             session hook: its content overrides the pane guess
                             and a 'blocked' hint is auto-hold-eligible }
  end;
  TPzSessionArray = array of TPzSession;

  TTizaDaemonConfig = record
    Listen:    string;
    Port:      Integer;
    Secret:    string;             { what pizarra must present (to us, if we listen) }
    Dial:      Boolean;            { reverse channel: dial the hub and hold it open }
    KeepAlive: Integer;            { dial-mode hub<->daemon keepalive seconds }
    HubHost:   string;             { [pizarra] host — where to dial }
    HubPort:   Word;               { [pizarra] port }
    HubSecret: string;             { [pizarra] secret — presented when dialing }
    { DELIVERY-RECEIPT LOCATION. It defaults to /var/lib/pizarra/tiza.state:
      configuration is root-owned under /etc while the daemon needs directory
      write access for its tmp+rename save. Without the receipt, a restart
      forgets the delivered position and can inject a message twice. }
    StatePath: string;             { [daemon] state; defaults under /var/lib }
    SelfId:    string;             { identity label for the dial connection }
    Sessions:  TPzSessionArray;
    { self-update (1.0.3) — all static, no operator on the box needed }
    AutoUpdate: Boolean;           { update alone when the hub is newer }
    UpdatePath: string;            { installed binary to replace }
    UpdateSudo: Boolean;           { prefix install with sudo (mac: daemon != root) }
    UpdateFpc:  string;            { compiler for the build-from-source recipe }
  end;

{ Strict resolution: an explicit --config or environment path that does not
  exist is an error, never a reason to select another identity. Why explains ''. }
function ResolveConfigStrict(const Explicit, EnvVar, BaseName: string;
  out Why: string): string;

function ResolveConfig(const Explicit, EnvVar, BaseName: string): string;

{ Secure first implicit hub start. Call only when neither --config nor
  PIZARRA_CONF was supplied. Existing files are never overwritten. }
function BootstrapDefaultPizarraConfig(out Why: string): Boolean;

function LoadPizarraConfig(const Path: string): TPizarraConfig;
function LoadTizaConfig(const Path: string): TTizaConfig;
function LoadTizaDaemonConfig(const Path: string): TTizaDaemonConfig;

{ Open an INI through the same descriptor-pinned, mode-0600 reader used by
  the typed loaders. This is reserved for migration-only keys that are not
  part of TPizarraConfig; callers own the returned instance. }
function OpenPrivateIniFile(const Path: string): TIniFile;

{ Delegable families in one authoritative list shared by cards, authorization,
  and documentation. }
const
  DELEGATE_FAMILIES: array[0..9] of string =
    ('team', 'group', 'project', 'app', 'task', 'workflow', 'watch',
    { These final families are high impact: backup exports SECRETS, update
      RESTARTS remote daemons, and header changes what the entire fleet sees.
      Keep names unquoted because external readers parse this list. }
     'backup', 'update', 'header');

{ Whether Who may execute Family commands with console authority. Only an
  explicit team delegation grants it. }
function TeamDelegated(const Cfg: TPizarraConfig; const Who, Family: string): Boolean;

{ Credential coherence. A per-team secret equal to the global secret binds no
  identity because authentication takes the unrestricted global branch. Shared
  secrets between teams also make identity depend on file order. Reject the
  complete configuration before opening stores or listeners. Err names affected
  teams and NEVER prints a secret. }
function SecretsCoherent(const Cfg: TPizarraConfig; out Err: string): Boolean;

{ Team lookup: Key may be a numeric id or a name (case-insensitive). Returns
  True and fills Team when found. }
function FindTeam(const Cfg: TPizarraConfig; const Key: string; out Team: TTeam): Boolean;

{ Split 'a, b c' into a trimmed name list (comma and/or space separated). }
function SplitList(const S: string): TStringArray;

{ Group lookup by name (case-insensitive). }
function FindGroup(const Cfg: TPizarraConfig; const Name: string; out Grp: TGroup): Boolean;

{ A team's PRIMARY project: its own, else the first group-with-a-project it
  belongs to, else '' (drives the primary admin / AWAIT chain). A team can take
  part in SEVERAL projects at once; for the full deduped union (own + every
  group's project), each with its admin, the header uses ProjectsLine. }
function EffectiveProject(const Cfg: TPizarraConfig; const TeamName: string): string;

{ Project registry lookup + boss of a team's effective project. }
function FindProject(const Cfg: TPizarraConfig; const Name: string; out Prj: TProject): Boolean;
function ProjectBossOf(const Cfg: TPizarraConfig; const TeamName: string): string;

{ Boss of the first group (with a boss) the team belongs to. }
function GroupBossOf(const Cfg: TPizarraConfig; const TeamName: string): string;

{ Persist the delivery-header config ([server] header + the [header] toggles). }
procedure SaveHeaderIni(const Path: string; const Cfg: TPizarraConfig);

{ Groups (comma list) a team belongs to, for the header/tree. }
function GroupsOf(const Cfg: TPizarraConfig; const TeamName: string): string;

{ Session lookup in a daemon config, by team name. }
function FindSession(const Cfg: TTizaDaemonConfig; const Team: string;
  out Sess: TPzSession): Boolean;

{ Hierarchy helpers (parent = key). }
{ Parse on/off/1/0/true/false/yes/no/si. Return False for unknown text so the
  caller can reject it rather than silently assume a default. }
function ParseOnOff(const S: string; out V: Boolean): Boolean;

{ Single lexical rule for names that become sections or paths. }
{ '-' in configuration means INBOX ONLY, while the rest of the hub represents
  "no session" as an empty string. If the dash survives loading, delivery tries
  to inject into a tmux target named "-", which may resolve to the ACTIVE session
  and therefore another team's terminal. Define "no session" in one place. }
function NormSession(const S: string): string;
function LooksSafeName(const N: string): Boolean;
{ A CLI verb cannot also name a destination. }
function IsCommandWord(const N: string): Boolean;

{ Warnings accumulated while loading unrecognized configuration values. The
  consumer drains and records them once. }
function TakeConfigWarnings: TStringArray;

function IsSubordinate(const Cfg: TPizarraConfig;
  const Child, Ancestor: string): Boolean;          { strict descendant }
function SubordinatesOf(const Cfg: TPizarraConfig;
  const Boss: string): string;                      { direct subs, comma-joined }

{ Drop unknown/cyclic parent links (warns on stderr). Also used after
  runtime /team set parent changes. }
procedure ValidateParents(var Cfg: TPizarraConfig);

{ One-time cutover helper. Preserve an owner-only timestamped copy, remove all
  legacy team/group/project/app sections atomically, and leave only the SQLite
  authority marker in the bootstrap INI. Existing data is never deleted from
  SQLite and the backup is never overwritten. }
function StripLegacyRegistryIni(const Path: string; out BackupPath,
  Err: string): Boolean;

{ 'ip' or 'ip:port' -> host + port (default DEFAULT_DAEMON_PORT). }
procedure SplitHostPort(const S: string; out Host: string; out Port: Word);

{ Build the self-describing delivery text (header + prompts + team index +
  open tasks + body) that pizarra injects into a team's session. OpenTasks is
  a pre-rendered block of '#id [milestone] title' lines (each ending in #10);
  empty until the task engine fills it. WfBlock is the hub-rendered workflow
  role block for this recipient (lines ending in #10; '' = none) - rendered
  hub-side so this unit stays free of a pzworkflow dependency. }
function BuildDelivery(const Cfg: TPizarraConfig; const Team: TTeam;
  const FromName, Body: string; const OpenTasks: string = '';
  IncludeManual: Boolean = False; OpenCount: Integer = 0;
  const WfBlock: string = ''; const Ident: string = ''): string;

{ A MINIMAL delivery: just the spine (To/From/reply) and the message frame — no
  workflow role block, style, MORE, apps, subs or files. For a plain system nudge
  that should read like a short note from the sender, not a full agent header.
  ReplyTo is who the recipient is told to answer ('' = the sender FromName); it
  can differ from FromName so a message can read "from console" yet route the
  answer to another team. }
function BuildDeliveryMinimal(const Team: TTeam; const FromName, ReplyTo,
  Body: string): string;

implementation

type
  { TIniFile's filename constructor opens by pathname and therefore follows
    links. This reader keeps the descriptor returned by PzOpenPrivateConfig
    alive for the complete parse and closes it only after TIniFile is done. }
  TSecureIniFile = class(TIniFile)
  private
    FInput: THandleStream;
    FInputHandle: Integer;
  public
    constructor CreatePrivate(const Path: string);
    destructor Destroy; override;
  end;

constructor TSecureIniFile.CreatePrivate(const Path: string);
var
  Full, Why: string;
begin
  FInput := nil;
  FInputHandle := -1;
  if not PzOpenPrivateConfig(Path, FInputHandle, Full, Why) then
    raise EInOutError.Create('unsafe credential configuration ' + Path + ': ' + Why);
  try
    FInput := THandleStream.Create(FInputHandle);
    { The filename constructor enables ifoStripQuotes automatically; the stream
      overload does not, so request the identical parsing behavior explicitly. }
    inherited Create(FInput, [ifoStripQuotes]);
  except
    FInput.Free;
    FInput := nil;
    FpClose(FInputHandle);
    FInputHandle := -1;
    raise;
  end;
end;

destructor TSecureIniFile.Destroy;
begin
  inherited Destroy;
  FreeAndNil(FInput);
  if FInputHandle >= 0 then
    FpClose(FInputHandle);
  FInputHandle := -1;
end;

function OpenPrivateIniFile(const Path: string): TIniFile;
begin
  Result := TSecureIniFile.CreatePrivate(Path);
end;

{ THE ONLY INI VALUE SANITIZER. Every static-configuration writer must use it:
  a newline in an unfiltered header note could inject new pizarra.conf
  sections, including altered server or store settings.

  Collapse line breaks because they split the file. Remove one surrounding
  quote pair because TIniFile.ReadString strips it on reload; otherwise a
  write/read cycle would change the value. }
function IniValorSeguro(const V: string): string;
begin
  Result := StringReplace(V, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  if (Length(Result) >= 2) and (Result[1] = Result[Length(Result)])
     and ((Result[1] = '"') or (Result[1] = '''')) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;


{ --- atomic INI writes ------------------------------------------------------

  TIniFile.UpdateFile reaches TStrings.SaveToFile, which truncates the target
  before writing and provides no temporary file, rename, or fsync. With default
  CacheUpdates, every WriteString/DeleteKey can rewrite the whole file.

  pizarra.conf carries the bus secret and bootstrap settings, so interruption
  inside that window could leave an empty or truncated identity file. Work on
  a COPY and rename it into place. Keep TIniFile rather than switching to
  TMemIniFile because their quote-stripping behavior differs.

  Resolve the REAL target through symlinks before committing. Renaming over a
  symlink would replace the link itself and silently split the configured path
  from its intended target. }
function RealTarget(const Path: string): string;
var
  R, Cur: string;
  Seen: TStringList;
  St: TStat;
  Depth, ErrNo: Integer;
begin
  Cur := ExpandFileName(Path);
  Seen := TStringList.Create;
  try
    Seen.CaseSensitive := True;
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    for Depth := 0 to 39 do
    begin
      if Seen.IndexOf(Cur) >= 0 then
        raise EInOutError.Create('symbolic-link cycle while resolving ' + Path);
      Seen.Add(Cur);
      St := Default(TStat);
      if FpLStat(Cur, St) <> 0 then
      begin
        ErrNo := fpgeterrno;
        if ErrNo = ESysENOENT then
          Exit(Cur);
        raise EInOutError.CreateFmt('cannot inspect %s: %s',
          [Cur, SysErrorMessage(ErrNo)]);
      end;
      if not fpS_ISLNK(St.st_mode) then
        Exit(Cur);
      R := fpReadLink(Cur);
      if R = '' then
        raise EInOutError.CreateFmt('cannot read symbolic link %s: %s',
          [Cur, SysErrorMessage(fpgeterrno)]);
      if R[1] <> PathDelim then
        Cur := ExpandFileName(IncludeTrailingPathDelimiter(
          ExtractFileDir(Cur)) + R)
      else
        Cur := ExpandFileName(R);
    end;
    raise EInOutError.Create('too many symbolic links while resolving ' + Path);
  finally
    Seen.Free;
  end;
end;

{ CREATE THE TEMPORARY FILE, WAITING IF ANOTHER WRITER HOLDS IT.

  'Unable to create file ...conf.tmp: Try again' comes from the RTL:
  TFileStream.Create(..., fmCreate) calls FileCreate(Name, Mode, Rights)
  (streams.inc:557-562). That mode contains no sharing bits, so the masked value
  is fmShareCompat, which selects LOCK_EX or LOCK_NB (sysutils.pp:404-407).
  When another writer holds the non-blocking exclusive flock, the call returns
  EAGAIN and the RTL raises that exception.

  Treating EAGAIN as fatal can leave the database and INI inconsistent when the
  database write has already completed. Retry for half a second, enough for the
  brief overlap that causes it, then return the original error. Waiting forever
  would turn lock contention into a hang.

  THE NAME REMAINS THE SAME ACROSS RETRIES intentionally. Different names would
  let two writers create separate temporary files and allow the writer that
  FINISHES last to win, rather than the one that started first. With one name,
  the lock holder writes while the other waits.

  KNOWN LIMITATION, not fixed here: the DeleteFile above ignores the lock because
  unlink does not consult flock. A second writer can therefore remove the first
  writer's partially written temporary file. Retrying cannot fix that; the
  writer needs a broader redesign. }
function CreateTempWithRetry(const Tmp: string): TFileStream;
var
  Attempts, ErrNo: Integer;
begin
  Result := nil;
  for Attempts := 1 to 20 do
  begin
    try
      { The three-argument constructor passes Rights to FileCreate. Creating
        the inode as 0600 closes the exposure window that a later chmod would
        leave when the process umask is 0022. }
      Result := TFileStream.Create(Tmp, fmCreate, &600);
      if FpChmod(Tmp, &600) <> 0 then
      begin
        ErrNo := fpgeterrno;
        FreeAndNil(Result);
        DeleteFile(Tmp);
        raise EInOutError.CreateFmt('could not protect %s as mode 0600: %s',
          [Tmp, SysErrorMessage(ErrNo)]);
      end;
      Exit;
    except
      on E: EFCreateError do
      begin
        if Attempts = 20 then
          raise;
        Sleep(25);
      end;
    end;
  end;
end;

function IniOpenForWrite(const Path: string): TIniFile;
var
  Tmp, Real_, Line: string;
  Src, Dst: TFileStream;
  Lines: TStringList;
  i, p: Integer;
begin
  Real_ := RealTarget(Path);
  Tmp := Real_ + '.tmp';
  if FileExists(Tmp) and (not DeleteFile(Tmp)) then
    raise EInOutError.CreateFmt('could not remove stale temporary file %s',
      [Tmp]);
  Dst := CreateTempWithRetry(Tmp);
  try
    if FileExists(Real_) then
    begin
      Src := TFileStream.Create(Real_, fmOpenRead or fmShareDenyNone);
      try
        if Src.Size > 0 then
          Dst.CopyFrom(Src, Src.Size);
      finally
        Src.Free;
      end;
    end;
  finally
    Dst.Free;
  end;
  { FPC 3.2.2 TIniFile recognizes only ';' as a comment marker. Existing
    examples historically used '#'; without normalization UpdateFile drops a
    leading hash comment or serializes it as an empty-key assignment. Convert
    only lines whose first non-space byte is '#', never hashes inside values. }
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Tmp);
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      p := 1;
      while (p <= Length(Line)) and (Line[p] in [' ', #9]) do
        Inc(p);
      if (p <= Length(Line)) and (Line[p] = '#') then
      begin
        Line[p] := ';';
        Lines[i] := Line;
      end;
    end;
    Lines.SaveToFile(Tmp);
    if FpChmod(Tmp, &600) <> 0 then
      raise EInOutError.CreateFmt('could not retain mode 0600 on %s', [Tmp]);
  finally
    Lines.Free;
  end;
  try
    Result := TIniFile.Create(Tmp);
  except
    DeleteFile(Tmp);
    raise;
  end;
  { Prevent each WriteString from rewriting the complete temporary file. }
  Result.CacheUpdates := True;
end;

function SyncParentDirectory(const Path: string; out Why: string): Boolean;
var
  Dir: string;
  H, ErrNo: Integer;
begin
  Result := False;
  Why := '';
  Dir := ExtractFileDir(ExpandFileName(Path));
  H := FpOpen(Dir, O_RDONLY or O_DIRECTORY);
  if H < 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot open parent directory ' + Dir + ' for fsync: ' +
      SysErrorMessage(ErrNo);
    Exit;
  end;
  try
    if PzFsync(H) <> 0 then
    begin
      ErrNo := fpgeterrno;
      Why := 'cannot fsync parent directory ' + Dir + ': ' +
        SysErrorMessage(ErrNo);
      Exit;
    end;
  finally
    FpClose(H);
  end;
  Result := True;
end;

{ Flush to the temporary file, sync it, and rename over the destination. Do not
  free Ini; the caller owns its try/finally. Clearing FDirty prevents another
  write from the destructor. }
procedure IniCommit(Ini: TIniFile);
var
  Tmp, Path: string;
  H: THandle;
  ErrNo: Integer;
  Why: string;
begin
  Tmp := Ini.FileName;
  if (Length(Tmp) < 4) or
     (Copy(Tmp, Length(Tmp) - 3, 4) <> '.tmp') then
    Exit;   { not opened by IniOpenForWrite; nothing to rename }
  Path := Copy(Tmp, 1, Length(Tmp) - 4);
  { TIniFile.UpdateFile reaches TStringList.SaveToFile, whose fmCreate would
    otherwise use 0666 subject to umask. The inode already exists as 0600, and
    chmod is repeated after the rewrite so neither implementation changes nor
    an unusual RTL can make the secret-bearing temporary file readable. }
  if FpChmod(Tmp, &600) <> 0 then
  begin
    ErrNo := fpgeterrno;
    raise EInOutError.CreateFmt('could not protect %s before update: %s',
      [Tmp, SysErrorMessage(ErrNo)]);
  end;
  Ini.UpdateFile;
  if FpChmod(Tmp, &600) <> 0 then
  begin
    ErrNo := fpgeterrno;
    raise EInOutError.CreateFmt('could not protect %s after update: %s',
      [Tmp, SysErrorMessage(ErrNo)]);
  end;
  { fsync before rename so power loss cannot preserve the rename without data. }
  { Explicit sharing avoids an FPC LOCK_EX request that can make FileOpen fail
    and silently skip fsync before the rename. }
  H := FileOpen(Tmp, fmOpenRead or fmShareDenyNone);
  if H = THandle(-1) then
    raise EInOutError.CreateFmt('could not reopen %s for fsync', [Tmp]);
  try
    if PzFsync(H) <> 0 then
    begin
      ErrNo := fpgeterrno;
      raise EInOutError.CreateFmt('could not fsync %s: %s',
        [Tmp, SysErrorMessage(ErrNo)]);
    end;
  finally
    FileClose(H);
  end;
  if not RenameFile(Tmp, Path) then
  begin
    DeleteFile(Tmp);
    raise EInOutError.CreateFmt('could not rename %s over %s', [Tmp, Path]);
  end;
  { The rename is already committed. A directory-fsync failure must be made
    visible, but reporting the whole mutation as failed would be false and
    could make a caller retry a change that is already on disk. }
  if not SyncParentDirectory(Path, Why) then
    Writeln(StdErr, 'pizarra: warning: configuration committed but ', Why);
end;

function FileHere(const P: string): Boolean;
begin
  Result := (P <> '') and FileExists(P);
end;

{ Read a prompt from Key or Key_file (file wins; relative to ConfDir). A
  configured-but-missing prompt file warns on stderr and falls back inline —
  never fatal. }
function ReadPrompt(Ini: TIniFile; const Sec, Key, ConfDir: string): string;
var
  PathV: string;
  SL: TStringList;
begin
  Result := Ini.ReadString(Sec, Key, '');
  PathV := Ini.ReadString(Sec, Key + '_file', '');
  if PathV = '' then
    Exit;
  if PathV[1] <> '/' then
    PathV := ConfDir + '/' + PathV;
  if not FileExists(PathV) then
  begin
    Writeln(StdErr, 'pizarra: warning: ', Key, '_file not found: ', PathV);
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(PathV);
    Result := TrimRight(SL.Text);
  finally
    SL.Free;
  end;
end;


{ AN EXPLICIT PATH IS NOT ANOTHER CANDIDATE. Falling back from a missing
  --config or environment path may silently change both identity and credential.
  Return no configuration so the caller reports the exact missing path. }
function ResolveConfigStrict(const Explicit, EnvVar, BaseName: string;
  out Why: string): string;
var
  Env: string;
begin
  Why := '';
  if Trim(Explicit) <> '' then
  begin
    if FileHere(Explicit) then
      Exit(Explicit);
    Why := 'config not found: ' + Explicit +
      ' (no fallback: selecting another file could silently change identity)';
    Exit('');
  end;
  Env := GetEnvironmentVariable(EnvVar);
  if Trim(Env) <> '' then
  begin
    if FileHere(Env) then
      Exit(Env);
    Why := EnvVar + ' points to missing file ' + Env +
      ' (no fallback: selecting another file could silently change identity)';
    Exit('');
  end;
  Result := ResolveConfig('', '', BaseName);
end;

function ResolveConfig(const Explicit, EnvVar, BaseName: string): string;
var
  Env, DefaultPath: string;
begin
  if Trim(Explicit) <> '' then
  begin
    if FileHere(Explicit) then
      Exit(Explicit);
    Exit('');
  end;
  Env := GetEnvironmentVariable(EnvVar);
  if Trim(Env) <> '' then
  begin
    if FileHere(Env) then
      Exit(Env);
    Exit('');
  end;
  DefaultPath := PzDefaultConfigPath(BaseName);
  if FileHere(DefaultPath) then
    Exit(DefaultPath);
  Result := '';
end;

function BootstrapDefaultPizarraConfig(out Why: string): Boolean;
begin
  Result := BootstrapDefaultHub(Why);
end;

{ 'ip' or 'ip:port' -> host + port (default DEFAULT_DAEMON_PORT). }
procedure SplitHostPort(const S: string; out Host: string; out Port: Word);
var
  T: string;
  p, cc, Parsed: Integer;

  procedure ReadPort(const V: string);
  begin
    if TryStrToInt(Trim(V), Parsed) and (Parsed >= 1) and
       (Parsed <= High(Word)) then
      Port := Word(Parsed)
    else
      Port := DEFAULT_DAEMON_PORT;
  end;
begin
  T := Trim(S);
  Port := DEFAULT_DAEMON_PORT;
  if (T <> '') and (T[1] = '[') then
  begin
    { bracketed IPv6:  [::1]  or  [::1]:7011 }
    p := Pos(']', T);
    if p > 0 then
    begin
      Host := Copy(T, 2, p - 2);
      if (p < Length(T)) and (T[p + 1] = ':') then
        ReadPort(Copy(T, p + 2, Length(T)));
      Exit;
    end;
  end;
  { count colons: >1 = bare IPv6 (no port), exactly 1 = host:port }
  cc := 0;
  for p := 1 to Length(T) do
    if T[p] = ':' then Inc(cc);
  if cc <> 1 then
    Host := T   { bare IPv4 (no colon) or bare IPv6 (many colons) }
  else
  begin
    p := Pos(':', T);
    Host := Copy(T, 1, p - 1);
    ReadPort(Copy(T, p + 1, Length(T)));
  end;
end;

procedure BackupOnce(const Path: string);
var
  Src, Dst: TFileStream;
  H: THandle;
  ErrNo: Integer;
  Why: string;
begin
  if (not FileExists(Path)) or FileExists(Path + '.bak') then
    Exit;
  try
    Src := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      { pizarra.conf contains the bus credential. Create the backup with its
        final mode rather than exposing it as 0644 until a later chmod. }
      Dst := TFileStream.Create(Path + '.bak', fmCreate, &600);
      try
        Dst.CopyFrom(Src, 0);
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
    if FpChmod(Path + '.bak', &600) <> 0 then
    begin
      ErrNo := fpgeterrno;
      DeleteFile(Path + '.bak');
      raise EInOutError.CreateFmt('could not protect config backup: %s',
        [SysErrorMessage(ErrNo)]);
    end;
    H := FileOpen(Path + '.bak', fmOpenRead or fmShareDenyNone);
    if H = THandle(-1) then
      raise EInOutError.Create('could not reopen config backup for fsync');
    try
      if PzFsync(H) <> 0 then
      begin
        ErrNo := fpgeterrno;
        raise EInOutError.CreateFmt('could not fsync config backup: %s',
          [SysErrorMessage(ErrNo)]);
      end;
    finally
      FileClose(H);
    end;
    if not SyncParentDirectory(Path + '.bak', Why) then
      Writeln(StdErr, 'pizarra: warning: config backup exists but ', Why);
  except
    on E: Exception do
    begin
      DeleteFile(Path + '.bak');
      Writeln(StdErr, 'pizarra: warning: cannot write config backup: ', E.Message);
    end;
  end;
end;

function StripLegacyRegistryIni(const Path: string; out BackupPath,
  Err: string): Boolean;
var
  Ini: TIniFile;
  Sections: TStringList;
  Src, Dst: TFileStream;
  RealPath, Sec: string;
  H: THandle;
  i: Integer;
  HasLegacy: Boolean;
begin
  Result := False;
  BackupPath := '';
  Err := '';
  Ini := nil;
  Sections := TStringList.Create;
  try
    try
      RealPath := RealTarget(Path);
    Ini := TIniFile.Create(RealPath);
    Ini.ReadSections(Sections);
    HasLegacy := False;
    for i := 0 to Sections.Count - 1 do
    begin
      Sec := LowerCase(Sections[i]);
      if (Copy(Sec, 1, 5) = 'team:') or
         (Copy(Sec, 1, 6) = 'group:') or
         (Copy(Sec, 1, 8) = 'project:') or
         (Copy(Sec, 1, 4) = 'app:') then
        HasLegacy := True;
    end;
    FreeAndNil(Ini);
    if not HasLegacy then
      Exit(True);

    BackupPath := RealPath + '.pre-registry-sqlite.' +
      FormatDateTime('yyyymmdd-hhnnss', Now) + '.' +
      IntToStr(FpGetpid) + '.bak';
    if FileExists(BackupPath) then
    begin
      Err := 'refusing to overwrite migration backup ' + BackupPath;
      Exit;
    end;
    Src := TFileStream.Create(RealPath, fmOpenRead or fmShareDenyNone);
    try
      { The three-argument constructor passes Rights to FileCreate directly
        (FPC rtl/objpas/classes/streams.inc), avoiding even a brief 0644
        credential backup before chmod. }
      Dst := TFileStream.Create(BackupPath, fmCreate, &600);
      try
        Dst.CopyFrom(Src, 0);
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
    if FpChmod(BackupPath, &600) <> 0 then
    begin
      Err := 'could not protect migration backup ' + BackupPath;
      DeleteFile(BackupPath);
      Exit;
    end;
    H := FileOpen(BackupPath, fmOpenRead or fmShareDenyNone);
    if H = THandle(-1) then
    begin
      Err := 'could not reopen migration backup for fsync: ' + BackupPath;
      Exit;
    end;
    try
      if PzFsync(H) <> 0 then
      begin
        Err := 'could not fsync migration backup ' + BackupPath;
        Exit;
      end;
    finally
      FileClose(H);
    end;
    if not SyncParentDirectory(BackupPath, Err) then
      Exit;

    Ini := IniOpenForWrite(RealPath);
    try
      Sections.Clear;
      Ini.ReadSections(Sections);
      for i := 0 to Sections.Count - 1 do
      begin
        Sec := LowerCase(Sections[i]);
        if (Copy(Sec, 1, 5) = 'team:') or
           (Copy(Sec, 1, 6) = 'group:') or
           (Copy(Sec, 1, 8) = 'project:') or
           (Copy(Sec, 1, 4) = 'app:') then
          Ini.EraseSection(Sections[i]);
      end;
      Ini.WriteString('registry', 'authority', 'sqlite');
      IniCommit(Ini);
    finally
      FreeAndNil(Ini);
    end;
      Result := True;
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    Ini.Free;
    Sections.Free;
  end;
end;

{ Drop parent links that point nowhere or loop; warn on stderr, never fatal. }
procedure ValidateParents(var Cfg: TPizarraConfig);
var
  i, Steps: Integer;
  Cur: string;
  T: TTeam;
begin
  for i := 0 to High(Cfg.Teams) do
  begin
    if Cfg.Teams[i].Parent = '' then
      Continue;
    if not FindTeam(Cfg, Cfg.Teams[i].Parent, T) then
    begin
      Writeln(StdErr, 'pizarra: warning: team ', Cfg.Teams[i].Name,
        ' has unknown parent "', Cfg.Teams[i].Parent, '" - ignored');
      Cfg.Teams[i].Parent := '';
      Continue;
    end;
    Cfg.Teams[i].Parent := T.Name;   { canonical name (id also accepted) }
    { cycle check: walk up at most Length(Teams) steps }
    Cur := Cfg.Teams[i].Parent;
    Steps := 0;
    while (Cur <> '') and (Steps <= Length(Cfg.Teams)) do
    begin
      if SameText(Cur, Cfg.Teams[i].Name) then
      begin
        Writeln(StdErr, 'pizarra: warning: hierarchy cycle at team ',
          Cfg.Teams[i].Name, ' - parent ignored');
        Cfg.Teams[i].Parent := '';
        Break;
      end;
      if FindTeam(Cfg, Cur, T) then
        Cur := T.Parent
      else
        Cur := '';
      Inc(Steps);
    end;
  end;
end;

{ Single boolean grammar for both INI and bus mutations. Return False for
  unknown text so callers reject it rather than silently applying a default. }
function ParseOnOff(const S: string; out V: Boolean): Boolean;
var v2: string;
begin
  v2 := LowerCase(Trim(S));
  Result := True;
  if (v2 = 'on') or (v2 = '1') or (v2 = 'true') or (v2 = 'yes') or
     (v2 = 'si') or (v2 = 'sí') then
    V := True
  else if (v2 = 'off') or (v2 = '0') or (v2 = 'false') or (v2 = 'no') then
    V := False
  else
  begin
    V := False;
    Result := False;
  end;
end;

{ INI boolean that accepts on/off/1/0/true/false/yes/no (TIniFile.ReadBool is
  picky); returns Def when the key is absent or unrecognized. }
var
  GCfgWarn: TStringList = nil;

{ An unrecognized configuration value must not pass silently. Loading remains
  tolerant so one typo does not stop the hub, but warn on stderr and retain the
  warning for the hub log. }
procedure CfgWarn(const S: string);
begin
  if GCfgWarn = nil then
    GCfgWarn := TStringList.Create;
  GCfgWarn.Add(S);
  Writeln(StdErr, 'config warning: ', S);
  Flush(StdErr);   { otherwise a piped warning may remain buffered }
end;

function TakeConfigWarnings: TStringArray;
var
  i: Integer;
begin
  Result := nil;
  if GCfgWarn = nil then
    Exit;
  SetLength(Result, GCfgWarn.Count);
  for i := 0 to GCfgWarn.Count - 1 do
    Result[i] := GCfgWarn[i];
  GCfgWarn.Clear;
end;

{ Apply the SAME lexical rules used when the hub creates a name that becomes an
  INI section or disk directory. Validate on LOAD as well as mutation because a
  hand-edited or legacy file may already contain an impossible name. Checking
  only at mutation boundaries leaves a back door. }
{ Every word the CLI interprets as a top-level VERB. A team or group with such
  a name is unreachable because the client consumes the token before deciding
  it was a destination. This list lives in the unit shared by hub and client,
  and the test suite keeps it aligned with the actual verbs. }
function IsCommandWord(const N: string): Boolean;
const
  W: array[0..48] of string = (
    'all', 'console', 'pizarra', 'inbox', 'buzon', 'tree', 'arbol',
    'task', 'tarea', 'tareas', 'team', 'teams', 'equipo', 'equipos',
    'group', 'groups', 'grupo', 'grupos', 'project', 'projects',
    'proyecto', 'proyectos', 'app', 'apps', 'aplicacion', 'aplicaciones',
    'workflow', 'workflows', 'wf', 'flujo', 'flujos', 'daemon', 'chat',
    'share', 'compartir', 'files', 'ficheros', 'manual', 'put', 'get',
    'cat', 'leer', 'ver', 'version', 'fleet', 'flota', 'update', 'actualizar',
    'hold');
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(W) do
    if SameText(N, W[i]) then
      Exit(True);
  { Additional command words kept outside the fixed array for clarity. }
  Result := SameText(N, 'help') or SameText(N, 'ayuda') or
    SameText(N, 'backup') or SameText(N, 'copia') or
    SameText(N, 'restore') or SameText(N, 'restaurar') or
    SameText(N, 'header') or SameText(N, 'headers') or
    SameText(N, 'cabecera') or SameText(N, 'log') or SameText(N, 'registro') or
    SameText(N, 'full') or SameText(N, 'completo') or SameText(N, 'info');
end;

function NormSession(const S: string): string;
begin
  Result := Trim(S);
  if Result = '-' then
    Result := '';
end;

function LooksSafeName(const N: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  if N = '' then
    Exit;
  c := N[1];
  if not (((c>='a')and(c<='z'))or((c>='A')and(c<='Z'))or((c>='0')and(c<='9'))) then
    Exit;
  for i := 1 to Length(N) do
  begin
    c := N[i];
    if not (((c>='a')and(c<='z'))or((c>='A')and(c<='Z'))or((c>='0')and(c<='9'))
       or (c='.')or(c='_')or(c='-')) then
      Exit;
  end;
  Result := True;
end;

{ TIniFile does not remove inline comments: `activity = on   # note` is read as
  the literal value 'on   # note' and would silently become off. A TYPED field,
  such as an on/off flag or number, is one token, so text after '#' or ';' is a
  comment and is removed. Do NOT use this for free text (prompt, secret,
  speciality, launch...), where those characters may be legitimate. }
function StripInlineComment(const S: string): string;
var i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if (Result[i] = '#') or (Result[i] = ';') then
    begin
      SetLength(Result, i - 1);
      Break;
    end;
  Result := Trim(Result);
end;

function IniFlag(Ini: TIniFile; const Sec, Key: string; Def: Boolean): Boolean;
var v: string; b: Boolean;
begin
  v := StripInlineComment(Ini.ReadString(Sec, Key, ''));
  if v = '' then Exit(Def);
  if ParseOnOff(v, b) then Exit(b);
  CfgWarn(Format('[%s] %s = "%s" is not on/off; assuming %s',
    [Sec, Key, v, BoolToStr(Def, 'on', 'off')]));
  Result := Def;
end;

function IniInt(Ini: TIniFile; const Sec, Key: string; Def, MinV,
  MaxV: Integer): Integer;
var
  Raw: string;
begin
  Raw := StripInlineComment(Ini.ReadString(Sec, Key, ''));
  if Raw = '' then
    Exit(Def);
  if (not TryStrToInt(Raw, Result)) or (Result < MinV) or (Result > MaxV) then
  begin
    CfgWarn(Format('[%s] %s = "%s" is not an integer in %d..%d; assuming %d',
      [Sec, Key, Raw, MinV, MaxV, Def]));
    Result := Def;
  end;
end;

function IniToken(Ini: TIniFile; const Sec, Key, Def: string): string;
begin
  Result := LowerCase(Trim(StripInlineComment(
    Ini.ReadString(Sec, Key, Def))));
end;

function LoadPizarraConfig(const Path: string): TPizarraConfig;
var
  Ini:      TIniFile;
  Sections: TStringList;
  i, n:     Integer;
  Sec, IdS, HostV: string;
  T:        TTeam;
  ConfDir:  string;
  np, na:   Integer;
begin
  Result.Teams := nil;
  Result.Apps := nil;
  ConfDir := ExtractFileDir(ExpandFileName(Path));
  Ini := OpenPrivateIniFile(Path);
  Sections := TStringList.Create;
  try
    Result.Listen  := Ini.ReadString('server', 'listen', '127.0.0.1');
    Result.Port    := IniInt(Ini, 'server', 'port', 7010, 1, High(Word));
    Result.Secret  := Ini.ReadString('server', 'secret', '');
    Result.Releases := Trim(Ini.ReadString('server', 'releases', ''));
    Result.LogPath := Ini.ReadString('log', 'path',
      PZ_LOG_DIR + '/pizarra.log');
    Result.RegistryAuthority := IniToken(Ini, 'registry', 'authority', 'sqlite');
    if Result.RegistryAuthority <> 'sqlite' then
      raise EInOutError.Create('[registry] authority must be sqlite (got "' +
        Result.RegistryAuthority + '"); legacy INI sections are migration ' +
        'input, not an alternate live authority');
    Result.GlobalPrompt := ReadPrompt(Ini, 'prompts', 'global', ConfDir);
    { delivery header: 'short' (compact, default) or 'full' (legacy long). The
      [header] toggles trim the short header further; on|off|1|0|true|false. }
    Result.HeaderMode  := IniToken(Ini, 'server', 'header', 'short');
    if (Result.HeaderMode <> 'short') and (Result.HeaderMode <> 'full') then
    begin
      CfgWarn('[server] header must be short or full; assuming short');
      Result.HeaderMode := 'short';
    end;
    Result.AlarmMax    := IniInt(Ini, 'server', 'alarm_max', 3,
      Low(Integer), High(Integer));
    if Result.AlarmMax < 1 then Result.AlarmMax := 1;
    if Result.AlarmMax > 5 then Result.AlarmMax := 5;
    Result.AlarmEvery  := IniInt(Ini, 'server', 'alarm_every', 180,
      Low(Integer), High(Integer));
    if Result.AlarmEvery < 15 then Result.AlarmEvery := 15;
    Result.GroupIdleDwell := IniInt(Ini, 'server', 'group_idle_dwell', 120,
      Low(Integer), High(Integer));
    if Result.GroupIdleDwell < 15 then Result.GroupIdleDwell := 15;
    Result.HdrStyle    := IniFlag(Ini, 'header', 'style',   True);
    Result.HdrOrders   := IniFlag(Ini, 'header', 'orders',  True);
    Result.MasterConsoleOnly := IniFlag(Ini, 'server', 'master_console_only', False);
    Result.HdrTasks    := IniFlag(Ini, 'header', 'tasks',   True);
    Result.HdrTeams    := IniFlag(Ini, 'header', 'teams',   True);
    HostV := IniToken(Ini, 'header', 'group', 'own');
    if (HostV <> 'own') and (HostV <> 'off') then
    begin
      CfgWarn('[header] group must be own or off; assuming own');
      HostV := 'own';
    end;
    Result.HdrGroupOwn := HostV = 'own';
    Result.HdrProject  := IniFlag(Ini, 'header', 'project', False);
    Result.HdrSubs     := IniFlag(Ini, 'header', 'subs',    False);
    Result.HdrShared   := IniFlag(Ini, 'header', 'shared',  True);
    Result.HdrWorkflow := IniFlag(Ini, 'header', 'workflow', True);
    Result.GlobalRule  := Trim(Ini.ReadString('header', 'note', ''));
    Result.HdrManual   := IniToken(Ini, 'header', 'manual', 'first');
    if (Result.HdrManual <> 'first') and (Result.HdrManual <> 'off') and
       (Result.HdrManual <> 'always') then
    begin
      CfgWarn('[header] manual must be first, off, or always; assuming first');
      Result.HdrManual := 'first';
    end;
    Result.StoreDir := Trim(Ini.ReadString('store', 'dir', PZ_STATE_DIR));
    if Result.StoreDir = '' then
      raise EInOutError.Create('[store] dir must not be empty; an empty path ' +
        'would resolve to the filesystem root in the FPC path helpers');
    Result.SharedDir := Trim(Ini.ReadString('shared', 'dir', ''));
    { FPC 3.2.2 ExcludeTrailingPathDelimiter removes only ONE separator.
      Normalize all of them before the root check: // would otherwise become /
      and EnsureSharedDirs could chmod the filesystem root mode 01777. }
    while (Length(Result.SharedDir) > 1) and
          CharInSet(Result.SharedDir[Length(Result.SharedDir)],
            AllowDirectorySeparators) do
      Delete(Result.SharedDir, Length(Result.SharedDir), 1);
    if (Result.SharedDir <> '') and (Result.SharedDir[1] <> PathDelim) then
      raise EInOutError.Create('[shared] dir must be an absolute path; a ' +
        'relative NFS mount would resolve against the hub process working ' +
        'directory');
    if Result.SharedDir = PathDelim then
      raise EInOutError.Create('[shared] dir may not be the filesystem root; ' +
        'the hub creates and chmods only team directories below a dedicated ' +
        'operator-owned mount');

    Ini.ReadSections(Sections);
    n := 0;
    for i := 0 to Sections.Count - 1 do
    begin
      Sec := Sections[i];
      if (Length(Sec) > 5) and (LowerCase(Copy(Sec, 1, 5)) = 'team:') then
      begin
        IdS := Copy(Sec, 6, Length(Sec));
        T.Id          := StrToIntDef(Trim(IdS), 0);
        T.Name        := Ini.ReadString(Sec, 'name', '');
        T.Speciality  := Ini.ReadString(Sec, 'speciality', '');
        T.Prompt      := ReadPrompt(Ini, Sec, 'prompt', ConfDir);
        T.Parent      := Trim(Ini.ReadString(Sec, 'parent', ''));
        T.Project     := Trim(Ini.ReadString(Sec, 'project', ''));
        T.Secret      := Trim(Ini.ReadString(Sec, 'secret', ''));
        T.Delegate    := IniToken(Ini, Sec, 'delegate', '');
        HostV         := StripInlineComment(Ini.ReadString(Sec, 'host', ''));
        if HostV <> '' then
          SplitHostPort(HostV, T.Host, T.Port)
        else
        begin
          T.Host := '';
          T.Port := 0;
        end;
        T.Dial        := IniFlag(Ini, Sec, 'dial', False);
        T.Workdir     := Trim(Ini.ReadString(Sec, 'workdir', ''));
        T.Slave       := IniFlag(Ini, Sec, 'slave', False);
        T.HoldBlocked := IniFlag(Ini, Sec, 'hold_when_blocked', False);
        T.TmuxSession := NormSession(Ini.ReadString(Sec, 'tmux_session', ''));
        T.Launch      := Ini.ReadString(Sec, 'launch', '');
        T.User        := Trim(Ini.ReadString(Sec, 'user', ''));
        { User enters `su - <user> -c ...`, so accept only a Unix account name
          or empty just like `team set`. Whitespace or shell metacharacters
          would turn a hand-written configuration into command injection.
          Warn and fall back to the daemon account instead of launching it. }
        if (T.User <> '') and (not LooksSafeName(T.User)) then
        begin
          CfgWarn('[' + Sec + ']: user "' + T.User + '" is not a valid account ' +
            'name and would be spliced into a shell command; IGNORED, this team ' +
            'runs as the daemon user.');
          T.User := '';
        end;
        if T.Name <> '' then
        begin
          SetLength(Result.Teams, n + 1);
          Result.Teams[n] := T;
          Inc(n);
        end;
      end;
    end;

    { Parse every legacy registry family from this same descriptor-pinned INI
      snapshot. Reopening by pathname here could combine teams from one file
      generation with groups/projects/apps from another. }
    n := 0;
    np := 0;
    na := 0;
    for i := 0 to Sections.Count - 1 do
    begin
      Sec := Sections[i];
      if (Length(Sec) > 6) and (LowerCase(Copy(Sec, 1, 6)) = 'group:') then
      begin
        SetLength(Result.Groups, n + 1);
        Result.Groups[n].Name := Copy(Sec, 7, Length(Sec));
        { REFUSE TO START rather than ignore this section. Warning "it is
          IGNORED" while loading it anyway would lie. This file is declarative
          authority, so starting with one object missing makes an ABSENCE look
          authoritative. Exact reconciliation could then delete its replica row.
          Refusal is recoverable: fix the section and restart. }
        if not LooksSafeName(Result.Groups[n].Name) then
          raise EInOutError.Create('[' + Sec + ']: unsafe group name "' +
            Result.Groups[n].Name + '" (letters, digits, . _ - and must start ' +
            'alnum). Refusing to start: fix that section in the config.');
        Result.Groups[n].Project := Trim(Ini.ReadString(Sec, 'project', ''));
        Result.Groups[n].Boss := Trim(Ini.ReadString(Sec, 'boss', ''));
        Result.Groups[n].Members := SplitList(Ini.ReadString(Sec, 'members', ''));
        Result.Groups[n].Excluded := SplitList(Ini.ReadString(Sec, 'excluded', ''));
        Result.Groups[n].OnIdle := IniToken(Ini, Sec, 'on_idle', '');
        Result.Groups[n].OnIdleMsg := Trim(Ini.ReadString(Sec, 'on_idle_msg', ''));
        Result.Groups[n].OnIdleFrom := Trim(Ini.ReadString(Sec, 'on_idle_from', ''));
        Result.Groups[n].OnIdleReply := Trim(Ini.ReadString(Sec, 'on_idle_reply', ''));
        Result.Groups[n].HdrNote := Trim(Ini.ReadString(Sec, 'header', ''));
        Result.Groups[n].OnBlock := IniToken(Ini, Sec, 'on_block', '');
        if (Result.Groups[n].OnBlock <> '') and
           (Result.Groups[n].OnBlock <> 'alarm') and
           (Result.Groups[n].OnBlock <> 'log') then
        begin
          CfgWarn('[' + Sec + '] on_block must be alarm, log, or empty; ' +
            'assuming alarm');
          Result.Groups[n].OnBlock := '';
        end;
        Inc(n);
      end
      else if (Length(Sec) > 8) and (LowerCase(Copy(Sec, 1, 8)) = 'project:') then
      begin
        SetLength(Result.Projects, np + 1);
        Result.Projects[np].Name := Copy(Sec, 9, Length(Sec));
        if not LooksSafeName(Result.Projects[np].Name) then
          raise EInOutError.Create('[' + Sec + ']: unsafe project name "' +
            Result.Projects[np].Name + '" (letters, digits, . _ - and must ' +
            'start alnum). Refusing to start: fix that section in the config.');
        Result.Projects[np].Boss := Trim(Ini.ReadString(Sec, 'boss', ''));
        Inc(np);
      end
      else if (Length(Sec) > 4) and (LowerCase(Copy(Sec, 1, 4)) = 'app:') then
      begin
        SetLength(Result.Apps, na + 1);
        Result.Apps[na].Name    := Copy(Sec, 5, Length(Sec));
        { '-' means unassigned, matching runtime `app set X team -`. Keep INI
          and command semantics identical. }
        Result.Apps[na].Team    := NormSession(Ini.ReadString(Sec, 'team', ''));
        Result.Apps[na].Repo    := Trim(Ini.ReadString(Sec, 'repo', ''));
        Result.Apps[na].Path    := Trim(Ini.ReadString(Sec, 'path', ''));
        Result.Apps[na].Purpose := Trim(Ini.ReadString(Sec, 'purpose', ''));
        Result.Apps[na].Detail  := Trim(Ini.ReadString(Sec, 'detail', ''));
        Result.Apps[na].Projects := Trim(Ini.ReadString(Sec, 'projects', ''));
        Inc(na);
      end;
    end;
  finally
    Sections.Free;
    Ini.Free;
  end;

  { validate the hierarchy: a parent must exist and must not form a cycle }
  ValidateParents(Result);
end;

function LoadTizaConfig(const Path: string): TTizaConfig;
var
  Ini: TIniFile;
begin
  Ini := TSecureIniFile.CreatePrivate(Path);
  try
    Result.Host   := Ini.ReadString('pizarra', 'host', '127.0.0.1');
    Result.Port   := IniInt(Ini, 'pizarra', 'port', 7010, 1, High(Word));
    Result.Secret := Ini.ReadString('pizarra', 'secret', '');
    { WITHOUT self THERE IS NO IDENTITY, AND CONSOLE IS NOT A DEFAULT. Keep it
      empty so callers that require identity stop with an actionable error. }
    Result.SelfId := Trim(Ini.ReadString('pizarra', 'self', ''));
  finally
    Ini.Free;
  end;
end;

function LoadTizaDaemonConfig(const Path: string): TTizaDaemonConfig;
var
  Ini:      TIniFile;
  Sections: TStringList;
  i, n:     Integer;
  Sec:      string;
  S:        TPzSession;
begin
  Result.Sessions := nil;
  Ini := TSecureIniFile.CreatePrivate(Path);
  Sections := TStringList.Create;
  try
    Result.Listen := Ini.ReadString('daemon', 'listen', '127.0.0.1');
    Result.Port   := IniInt(Ini, 'daemon', 'port', DEFAULT_DAEMON_PORT,
      1, High(Word));
    { default: the same secret used to talk to pizarra }
    Result.Secret := Ini.ReadString('daemon', 'secret',
      Ini.ReadString('pizarra', 'secret', ''));
    { reverse delivery channel (dial-in): the daemon dials the hub instead of
      being pushed to — for hosts behind NAT or with a roaming (DHCP/VPN) IP }
    Result.Dial      := IniFlag(Ini, 'daemon', 'dial', False);
    Result.KeepAlive := IniInt(Ini, 'daemon', 'keepalive', 60,
      Low(Integer), High(Integer));
    if Result.KeepAlive < 5 then
      Result.KeepAlive := 5;   { sane floor }
    Result.HubHost   := Ini.ReadString('pizarra', 'host', '127.0.0.1');
    Result.HubPort   := Word(IniInt(Ini, 'pizarra', 'port', 7010,
      1, High(Word)));
    Result.HubSecret := Ini.ReadString('pizarra', 'secret', '');
    Result.StatePath := Trim(Ini.ReadString('daemon', 'state',
      PZ_TIZA_STATE_PATH));
    if Result.StatePath = '' then
      Result.StatePath := PZ_TIZA_STATE_PATH;
    Result.SelfId    := Ini.ReadString('pizarra', 'self', '');
    Result.AutoUpdate := IniFlag(Ini, 'daemon', 'autoupdate', False);
    Result.UpdatePath := Ini.ReadString('daemon', 'update_path',
      '/usr/local/bin/tiza');
    Result.UpdateSudo := IniFlag(Ini, 'daemon', 'update_sudo', False);
    Result.UpdateFpc  := Ini.ReadString('daemon', 'update_fpc', 'fpc');

    Ini.ReadSections(Sections);
    n := 0;
    for i := 0 to Sections.Count - 1 do
    begin
      Sec := Sections[i];
      if (Length(Sec) > 8) and (LowerCase(Copy(Sec, 1, 8)) = 'session:') then
      begin
        S.Team        := Trim(Copy(Sec, 9, Length(Sec)));
        { Here '-' cannot mean the hub's inbox-only mode. A remote daemon only
          delivers through tmux, and an unnamed target could resolve to the
          active session. Reject the entry rather than inventing a default. }
        S.TmuxSession := Trim(Ini.ReadString(Sec, 'tmux_session',
          'team-' + S.Team));
        if (S.TmuxSession = '') or (S.TmuxSession = '-') then
        begin
          CfgWarn('[' + Sec + ']: tmux_session "' + S.TmuxSession +
            '" is not a delivery target for a remote daemon (only the hub has ' +
            'inbox-only teams). Entry IGNORED: this team gets no local ' +
            'delivery here.');
          Continue;
        end;
        S.Launch      := Ini.ReadString(Sec, 'launch', '');
        S.Workdir     := Ini.ReadString(Sec, 'workdir', '');
        S.User        := Trim(Ini.ReadString(Sec, 'user', ''));
        { Same user-name boundary as above; this host daemon actually executes
          the session through `su - <user> -c ...`. }
        if (S.User <> '') and (not LooksSafeName(S.User)) then
        begin
          CfgWarn('[' + Sec + ']: user "' + S.User + '" is not a valid account ' +
            'name and would be spliced into a shell command; IGNORED, this ' +
            'session runs as the daemon user.');
          S.User := '';
        end;
        { opt-in activity sampling: default OFF, so nothing is watched unless
          the operator asks for it session by session (set unconditionally each
          iteration — S is reused, a stale True must not leak to the next). }
        S.Activity    := IniFlag(Ini, Sec, 'activity', False);
        S.AutoEnter   := IniFlag(Ini, Sec, 'auto_enter', False);
        S.IdleMatch   := Trim(Ini.ReadString(Sec, 'idle_match', ''));
        S.BlockMatch  := Trim(Ini.ReadString(Sec, 'block_match', ''));
        S.Hint        := Trim(Ini.ReadString(Sec, 'hint', ''));
        if S.Team <> '' then
        begin
          SetLength(Result.Sessions, n + 1);
          Result.Sessions[n] := S;
          Inc(n);
        end;
      end;
    end;
  finally
    Sections.Free;
    Ini.Free;
  end;
end;

function SplitList(const S: string): TStringArray;
var
  i, n: Integer;
  cur: string;

  procedure Flush;
  begin
    cur := Trim(cur);
    if cur <> '' then
    begin
      SetLength(Result, n + 1);
      Result[n] := cur;
      Inc(n);
    end;
    cur := '';
  end;

begin
  SetLength(Result, 0);
  n := 0;
  cur := '';
  for i := 1 to Length(S) do
    if (S[i] = ',') or (S[i] = ' ') then
      Flush
    else
      cur := cur + S[i];
  Flush;
end;

function TeamDelegated(const Cfg: TPizarraConfig; const Who, Family: string): Boolean;
var
  T: TTeam;
  Parts: TStringArray;
  i: Integer;
begin
  Result := False;
  if (Who = '') or (Family = '') then
    Exit;
  if not FindTeam(Cfg, Who, T) then
    Exit;
  if T.Delegate = '' then
    Exit;
  Parts := SplitList(T.Delegate);
  for i := 0 to High(Parts) do
    if SameText(Trim(Parts[i]), Family) then
      Exit(True);
end;

function SecretsCoherent(const Cfg: TPizarraConfig; out Err: string): Boolean;
var
  i, j: Integer;
begin
  Err := '';
  Result := False;
  { TPizarra.Create already rejects an empty global secret with recovery advice.
    Check again here so future callers do not depend on that outer guard. }
  if Cfg.Secret = '' then
  begin
    Err := '[server] secret is empty';
    Exit;
  end;
  for i := 0 to High(Cfg.Teams) do
  begin
    if Cfg.Teams[i].Secret = '' then
      Continue;   { no per-team secret means legacy fallback to global }
    if Cfg.Teams[i].Secret = Cfg.Secret then
    begin
      Err := Format('team %s has the same secret as [server]: it would ' +
        'authenticate as UNRESTRICTED (able to claim from=console) instead ' +
        'of being bound to itself', [Cfg.Teams[i].Name]);
      Exit;
    end;
    for j := 0 to i - 1 do
      if (Cfg.Teams[j].Secret <> '') and
         (Cfg.Teams[j].Secret = Cfg.Teams[i].Secret) then
      begin
        Err := Format('teams %s and %s share one secret: identity would ' +
          'depend on config order', [Cfg.Teams[j].Name, Cfg.Teams[i].Name]);
        Exit;
      end;
  end;
  Result := True;
end;

function FindTeam(const Cfg: TPizarraConfig; const Key: string; out Team: TTeam): Boolean;
var
  i, Id: Integer;
  K: string;
begin
  Result := False;
  K := Trim(Key);
  Id := StrToIntDef(K, -1);
  for i := 0 to High(Cfg.Teams) do
    if (SameText(Cfg.Teams[i].Name, K)) or
       ((Id >= 0) and (Cfg.Teams[i].Id = Id)) then
    begin
      Team := Cfg.Teams[i];
      Exit(True);
    end;
end;

function FindGroup(const Cfg: TPizarraConfig; const Name: string; out Grp: TGroup): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Cfg.Groups) do
    if SameText(Cfg.Groups[i].Name, Trim(Name)) then
    begin
      Grp := Cfg.Groups[i];
      Exit(True);
    end;
end;

function EffectiveProject(const Cfg: TPizarraConfig; const TeamName: string): string;
var
  T: TTeam;
  i, j: Integer;
begin
  Result := '';
  T := Default(TTeam);
  if FindTeam(Cfg, TeamName, T) and (T.Project <> '') then
    Exit(T.Project);
  for i := 0 to High(Cfg.Groups) do
    if Cfg.Groups[i].Project <> '' then
      for j := 0 to High(Cfg.Groups[i].Members) do
        if SameText(Cfg.Groups[i].Members[j], TeamName) then
          Exit(Cfg.Groups[i].Project);
end;

function GroupsOf(const Cfg: TPizarraConfig; const TeamName: string): string;
var
  i, j: Integer;
begin
  Result := '';
  for i := 0 to High(Cfg.Groups) do
    for j := 0 to High(Cfg.Groups[i].Members) do
      if SameText(Cfg.Groups[i].Members[j], TeamName) then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + Cfg.Groups[i].Name;
      end;
end;

function FindProject(const Cfg: TPizarraConfig; const Name: string; out Prj: TProject): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Cfg.Projects) do
    if SameText(Cfg.Projects[i].Name, Trim(Name)) then
    begin Prj := Cfg.Projects[i]; Exit(True); end;
end;

function ProjectBossOf(const Cfg: TPizarraConfig; const TeamName: string): string;
var P: TProject;
begin
  Result := '';
  P := Default(TProject);
  if FindProject(Cfg, EffectiveProject(Cfg, TeamName), P) then
    Result := P.Boss;
end;

{ Header render of ALL projects a team takes part in: the deduped union of its
  own project plus the project of every group it belongs to, each annotated
  with its admin. Returns '' when the team has no project at all. Groups are
  pure addressing lists (a team may be in many); a team may likewise carry many
  projects — this simply lists them instead of collapsing to one. }
function ProjectsLine(const Cfg: TPizarraConfig; const TeamName, Prefix: string): string;
var
  T: TTeam;
  P: TProject;
  i, j: Integer;
  seen, rendered: string;
  isMember: Boolean;

  procedure Consider(const ProjName: string);
  begin
    if ProjName = '' then Exit;
    if Pos('|' + LowerCase(ProjName) + '|', seen) > 0 then Exit;   { dedupe }
    seen := seen + '|' + LowerCase(ProjName) + '|';
    if rendered <> '' then rendered := rendered + ', ';
    rendered := rendered + ProjName;
    P := Default(TProject);
    if FindProject(Cfg, ProjName, P) and (P.Boss <> '') then
      rendered := rendered + ' (admin: ' + P.Boss + ')';
  end;

begin
  Result := '';
  seen := '';
  rendered := '';
  T := Default(TTeam);
  if FindTeam(Cfg, TeamName, T) then
    Consider(T.Project);
  for i := 0 to High(Cfg.Groups) do
  begin
    isMember := False;
    for j := 0 to High(Cfg.Groups[i].Members) do
      if SameText(Cfg.Groups[i].Members[j], TeamName) then
      begin
        isMember := True;
        Break;
      end;
    if isMember then
      Consider(Cfg.Groups[i].Project);
  end;
  if rendered <> '' then
    Result := Prefix + rendered;
end;

function GroupBossOf(const Cfg: TPizarraConfig; const TeamName: string): string;
var i, j: Integer;
begin
  Result := '';
  for i := 0 to High(Cfg.Groups) do
    if Cfg.Groups[i].Boss <> '' then
      for j := 0 to High(Cfg.Groups[i].Members) do
        if SameText(Cfg.Groups[i].Members[j], TeamName) then
          Exit(Cfg.Groups[i].Boss);
end;

procedure SaveHeaderIni(const Path: string; const Cfg: TPizarraConfig);
  function OnOff(B: Boolean): string;
  begin if B then Result := 'on' else Result := 'off'; end;
var
  Ini: TIniFile;
begin
  BackupOnce(Path);
  Ini := IniOpenForWrite(Path);
  try
    Ini.WriteString('server', 'header', Cfg.HeaderMode);
    Ini.WriteString('header', 'style',   OnOff(Cfg.HdrStyle));
    Ini.WriteString('header', 'orders',  OnOff(Cfg.HdrOrders));
    Ini.WriteString('header', 'tasks',   OnOff(Cfg.HdrTasks));
    Ini.WriteString('header', 'teams',   OnOff(Cfg.HdrTeams));
    if Cfg.HdrGroupOwn then
      Ini.WriteString('header', 'group', 'own')
    else
      Ini.WriteString('header', 'group', 'off');
    Ini.WriteString('header', 'project', OnOff(Cfg.HdrProject));
    Ini.WriteString('header', 'subs',    OnOff(Cfg.HdrSubs));
    Ini.WriteString('header', 'shared',  OnOff(Cfg.HdrShared));
    Ini.WriteString('header', 'workflow', OnOff(Cfg.HdrWorkflow));
    Ini.WriteString('header', 'manual',  Cfg.HdrManual);
    if Trim(Cfg.GlobalRule) <> '' then
      Ini.WriteString('header', 'note', IniValorSeguro(Cfg.GlobalRule))
    else
      Ini.DeleteKey('header', 'note');
    IniCommit(Ini);
  finally
    Ini.Free;
  end;
end;

function FindSession(const Cfg: TTizaDaemonConfig; const Team: string;
  out Sess: TPzSession): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Cfg.Sessions) do
    if SameText(Cfg.Sessions[i].Team, Trim(Team)) then
    begin
      Sess := Cfg.Sessions[i];
      Exit(True);
    end;
end;

function IsSubordinate(const Cfg: TPizarraConfig;
  const Child, Ancestor: string): Boolean;
var
  T: TTeam;
  Cur: string;
  Steps: Integer;
begin
  Result := False;
  if SameText(Child, Ancestor) then
    Exit;   { strict: a team is not its own subordinate }
  if not FindTeam(Cfg, Child, T) then
    Exit;
  Cur := T.Parent;
  Steps := 0;
  while (Cur <> '') and (Steps <= Length(Cfg.Teams)) do
  begin
    if SameText(Cur, Ancestor) then
      Exit(True);
    if FindTeam(Cfg, Cur, T) then
      Cur := T.Parent
    else
      Cur := '';
    Inc(Steps);
  end;
end;

function SubordinatesOf(const Cfg: TPizarraConfig; const Boss: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Cfg.Teams) do
    if SameText(Cfg.Teams[i].Parent, Boss) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + Cfg.Teams[i].Name;
    end;
end;

{ Compact delivery header (header=short, the default). Only per-message facts
  (who sent it + how to reply to THEM) and the recipient's own behavior-shaping
  lines are kept; lists become one-line pointers. Every extra line is behind a
  [header] toggle. }
function AppsOwnedBy(const Cfg: TPizarraConfig; const Team: string;
  WithProjects: Boolean = False): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Cfg.Apps) do
    if SameText(Cfg.Apps[i].Team, Team) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + Cfg.Apps[i].Name;
      { WHICH PROJECTS each app serves, projected into this snapshot by the
        SQLite loader because the header intentionally has no database
        dependency. It goes in brackets right after the app so both remain
        adjacent in the rendered text. }
      if WithProjects and (Cfg.Apps[i].Projects <> '') then
        Result := Result + ' [' + Cfg.Apps[i].Projects + ']';
    end;
end;

{ Owner/read-only-subordinate relationship lines emitted in BOTH directions.
  Remind the subordinate that it is read-only and who receives its reports;
  tell the owner when the sender is its subordinate. This is an explicit flag,
  not something inferred from ordinary hierarchy. }
function MasterSlaveLines(const Cfg: TPizarraConfig; const Team: TTeam;
  const FromName: string): string;
var
  FT: TTeam;
begin
  Result := '';
  FT := Default(TTeam);   { -Sew: FindTeam writes it only on success }
  if Team.Workdir <> '' then
    Result := Result + 'You work in: ' + Team.Workdir + #10;
  if Team.Slave and (Team.Parent <> '') then
    Result := Result +
      'READ-ONLY: you may only READ code and report what you find — never ' +
      'modify product code.'#10 +
      Format('Your master: %s — reply ONLY to %s:  tiza %s "..."'#10,
        [Team.Parent, Team.Parent, Team.Parent]);
  if FindTeam(Cfg, FromName, FT) and FT.Slave and
     SameText(FT.Parent, Team.Name) then
  begin
    Result := Result + Format(
      '%s is YOUR SLAVE (read-only): it reports to you and to nobody else.'#10,
      [FromName]);
    if FT.Workdir <> '' then
      Result := Result + Format('%s works in: %s'#10, [FromName, FT.Workdir]);
  end;
end;

{ First line capped at Max. If truncated, name where to find the remainder so
  readers do not mistake an excerpt for the complete value. }
function OneLine(const S: string; Max: Integer; const Context: string): string;
var
  i: Integer;
begin
  Result := S;
  { stop at the first line break, regardless of newline convention }
  i := Pos(#10, Result);
  if i > 0 then
    Result := Copy(Result, 1, i - 1);
  i := Pos(#13, Result);
  if i > 0 then
    Result := Copy(Result, 1, i - 1);
  Result := TrimRight(Result);
  if (Max > 0) and (Length(Result) > Max) then
  begin
    { cut at the last space rather than splitting a word }
    i := Max;
    while (i > 1) and (Result[i] <> ' ') do
      Dec(i);
    if i <= 1 then
      i := Max;
    Result := TrimRight(Copy(Result, 1, i)) + '... (' + Context + ')';
  end
  else if Length(S) > Length(Result) then
    Result := Result + ' (' + Context + ')';
end;

function BuildDeliveryMinimal(const Team: TTeam; const FromName, ReplyTo,
  Body: string): string;
var
  RT: string;
begin
  RT := Trim(ReplyTo);
  if RT = '' then
    RT := FromName;
  Result :=
    '======== PIZARRA ========'#10 +
    Format('To: %s (id=%d)  |  From: %s  |  %s'#10,
      [Team.Name, Team.Id, FromName, FormatDateTime('yyyy-mm-dd hh:nn', Now)]) +
    Format('>> REPLY TO:  tiza %s "your answer"   (long: tiza %s --file answer.txt)'#10,
      [RT, RT]) +
    Format('---- MESSAGE from %s ----'#10, [FromName]) +
    Body + #10 +
    '=========================';
end;

function BuildDeliveryShort(const Cfg: TPizarraConfig; const Team: TTeam;
  const FromName, Body: string; IncludeManual: Boolean; OpenCount: Integer;
  const WfBlock: string; const Ident: string = ''): string;
var
  S, Admin, More, Grp, Subs, Apps_: string;
  FT: TTeam;
  gi, gj: Integer;

  procedure AddTok(const T: string);
  begin
    if More <> '' then More := More + '  |  ';
    More := More + T;
  end;

begin
  { always-on spine: identity + reply-to-sender-only }
  S :=
    '======== PIZARRA ========'#10 +
    Format('To: %s (id=%d)  |  From: %s  |  %s'#10,
      [Team.Name, Team.Id, FromName, FormatDateTime('yyyy-mm-dd hh:nn', Now)]) +
    Format('>> REPLY TO SENDER ONLY:  tiza %s "your answer"   (long: tiza %s --file answer.txt)'#10,
      [FromName, FromName]);
  { CLAIMED, NOT PROVEN identity. The master key accepts any sender name. Warn
    HERE, where the recipient acts on it, and only for unbound senders so the
    exceptional warning remains visible. }
  if SameText(Ident, 'claimed') then
    S := S + '!! UNVERIFIED IDENTITY: the sender used the master key, which' +
      ' accepts any name. The sender is a CLAIM, not a verified fact.'#10;
  { AWAIT ORDERS — only for a non-boss recipient with an admin }
  Admin := ProjectBossOf(Cfg, Team.Name);
  if Admin = '' then
    Admin := GroupBossOf(Cfg, Team.Name);
  if Cfg.HdrOrders and (Admin <> '') and (not SameText(Admin, Team.Name)) then
    S := S + Format('AWAIT ORDERS from %s: don''t build/start on your own; report -> tiza %s "..."'#10,
      [Admin, Admin]);
  { the recipient's live workflow role (ACTIVE for you / HALTED / pointer) }
  S := S + WfBlock;
  { the GLOBAL standing rule: an operator instruction shown in EVERY delivery to
    EVERY team, uncapped (read in full each time). }
  if Trim(Cfg.GlobalRule) <> '' then
    S := S + 'RULE: ' + Trim(Cfg.GlobalRule) + #10;
  { per-group standing rule(s) for this recipient: an operator instruction shown
    on EVERY delivery to a group's members, UNCAPPED - it is not a hint, it is
    how the work in that group must be done, and it must be read in full each
    time. One line per group the recipient belongs to that carries a rule. }
  for gi := 0 to High(Cfg.Groups) do
    if Trim(Cfg.Groups[gi].HdrNote) <> '' then
      for gj := 0 to High(Cfg.Groups[gi].Members) do
        if SameText(Cfg.Groups[gi].Members[gj], Team.Name) then
        begin
          S := S + '@' + Cfg.Groups[gi].Name + ' RULE: ' +
            Trim(Cfg.Groups[gi].HdrNote) + #10;
          Break;
        end;
  { the team's own style prompt (one load-bearing behavioral line) }
  { ONE LINE MEANS ONE LINE. Repeating an uncapped team prompt on every delivery
    can bury the actual message. Send a bounded first line and point to
    `tiza team show` for the full text. }
  if Cfg.HdrStyle and (Team.Prompt <> '') then
    S := S + 'Style: ' + OneLine(Team.Prompt, 220,
      'full text: tiza team show ' + Team.Name) + #10;
  { optional (default off): the global project prompt }
  { Apply the same cap to the global prompt. }
  if Cfg.HdrProject and (Cfg.GlobalPrompt <> '') then
    S := S + 'Project: ' + OneLine(Cfg.GlobalPrompt, 220,
      'full text: tiza manual') + #10;
  { the MORE pointer line: tasks | teams | own-group | guide }
  More := '';
  if Cfg.HdrTasks and (OpenCount > 0) then
    AddTok(Format('%d pending -> tiza task list', [OpenCount]));
  if Cfg.HdrTeams then
    AddTok('teams -> tiza teams');
  if Cfg.HdrGroupOwn then
  begin
    Grp := GroupsOf(Cfg, Team.Name);   { recipient's OWN groups only }
    if Grp <> '' then
      AddTok('group @' + StringReplace(Grp, ', ', ', @', [rfReplaceAll]));
  end;
  { Explain how to look objects up, not merely that they exist. }
  AddTok('look up -> tiza team|app|group <name>');
  AddTok('guide -> tiza manual | tiza help');
  if More <> '' then
    S := S + 'MORE:  ' + More + #10;
  { the applications this team is responsible for: it must never have to guess
    which code is its own (tiza app show <name> has repo/path/detail) }
  { THE HEADER HAS A MEASURED BUDGET AND THIS LINE CAN NO LONGER BE BOUNDED BY
    the number of apps alone: each one now drags its projects behind it, so a
    team with a handful of apps across several plans would push the real message
    off the screen. Use the same cap and lookup pattern: omitted metadata is not
    lost; it remains one command away. }
  Apps_ := AppsOwnedBy(Cfg, Team.Name, True);
  if Apps_ <> '' then
    S := S + 'Your apps: ' + OneLine(Apps_, 200, 'more: tiza app list') +
      '  -> tiza app show <name>'#10;
  { optional (default off): subordinates + delegate cheatsheet }
  if Cfg.HdrSubs then
  begin
    Subs := SubordinatesOf(Cfg, Team.Name);
    if Subs <> '' then
      S := S + 'Subs: ' + Subs +
        ' — delegate: tiza task add <sub> "..." --parent <id>'#10;
  end;
  S := S + MasterSlaveLines(Cfg, Team, FromName);
  { file exchange (default ON): the full paths to READ (your own dir, where
    files sent to you land) and to WRITE to the other team (the sender's dir,
    plus the share command). }
  if Cfg.HdrShared and (Cfg.SharedDir <> '') then
  begin
    S := S + Format('Files:  read your dir: %s/%s/',
      [Cfg.SharedDir, LowerCase(Team.Name)]);
    if SameText(FromName, 'console') or FindTeam(Cfg, FromName, FT) then
      S := S + Format('  |  write to %s: %s/%s/  (or tiza share %s <file>)',
        [FromName, Cfg.SharedDir, LowerCase(FromName), FromName]);
    S := S + #10;
  end;
  { cold-start: embed the guide on the first-ever delivery (manual=first) or
    every time (manual=always) }
  if (Cfg.HdrManual = 'always') or ((Cfg.HdrManual = 'first') and IncludeManual) then
    S := S +
      '---- QUICK GUIDE (first message only; later: tiza manual) ----'#10 +
      AgentsManualText + #10;
  { body frame (anchors kept identical to full mode for grep back-compat) }
  S := S +
    Format('---- MESSAGE from %s ----'#10, [FromName]) +
    Body + #10 +
    '=========================';
  Result := S;
end;

function BuildDelivery(const Cfg: TPizarraConfig; const Team: TTeam;
  const FromName, Body: string; const OpenTasks: string;
  IncludeManual: Boolean; OpenCount: Integer; const WfBlock: string;
  const Ident: string): string;
var
  i, j: Integer;
  Idx, S, Subs, Admin, ProjLine: string;
  FT: TTeam;
begin
  { short header is the default; header=full selects the legacy long header }
  if not SameText(Cfg.HeaderMode, 'full') then
    Exit(BuildDeliveryShort(Cfg, Team, FromName, Body, IncludeManual,
      OpenCount, WfBlock, Ident));
  Idx := '';
  for i := 0 to High(Cfg.Teams) do
    Idx := Idx + Format('  %d %-8s - %s'#10,
      [Cfg.Teams[i].Id, Cfg.Teams[i].Name, Cfg.Teams[i].Speciality]);

  S :=
    '======== PIZARRA ========'#10 +
    Format('To: %s (id=%d)  |  From: %s  |  %s'#10,
      [Team.Name, Team.Id, FromName,
       FormatDateTime('yyyy-mm-dd hh:nn', Now)]);
  { CLAIMED, NOT PROVEN identity. The master key accepts any sender name. Warn
    at the recipient boundary only when the sender was not credential-bound. }
  if SameText(Ident, 'claimed') then
    S := S + '!! UNVERIFIED IDENTITY: the sender used the master key, which' +
      ' accepts any name. The sender is a CLAIM, not a verified fact.'#10;
  if Cfg.GlobalPrompt <> '' then
    S := S + 'Project: ' + OneLine(Cfg.GlobalPrompt, 220,
      'full text: tiza manual') + #10;
  { every project the team takes part in (own + its groups'), each with admin }
  ProjLine := ProjectsLine(Cfg, Team.Name, 'Your project: ');
  if ProjLine <> '' then
    S := S + ProjLine + #10;
  if GroupBossOf(Cfg, Team.Name) <> '' then
    S := S + 'Your group admin: ' + GroupBossOf(Cfg, Team.Name) + #10;
  { the effective admin (project admin preferred, else group admin) that this
    team must obey; a boss does not wait on itself }
  Admin := ProjectBossOf(Cfg, Team.Name);
  if Admin = '' then
    Admin := GroupBossOf(Cfg, Team.Name);
  if (Admin <> '') and (not SameText(Admin, Team.Name)) then
    S := S + 'AWAIT ORDERS: do NOT build, change or start anything on your own. '
      + 'Wait for instructions/tasks from your admin ' + Admin
      + ' and report progress to ' + Admin + '.'#10;
  if Team.Prompt <> '' then
    S := S + 'Your style: ' + Team.Prompt + #10;
  { the applications this team is responsible for — it must never guess which
    code is its own; the ficha and manual are one command away }
  if AppsOwnedBy(Cfg, Team.Name) <> '' then
    S := S + 'Your apps: ' + OneLine(AppsOwnedBy(Cfg, Team.Name, True), 200,
      'more: tiza app list') +
      '  (ficha: tiza app show <name>  |  manual: tiza app doc <name>)'#10;
  if Cfg.SharedDir <> '' then
  begin
    S := S + Format('Your shared dir: %s/%s/'#10,
      [Cfg.SharedDir, LowerCase(Team.Name)]);
    if SameText(FromName, 'console') or FindTeam(Cfg, FromName, FT) then
      S := S + Format('%s''s shared dir: %s/%s/  |  share a file: tiza share %s <file> [note]'#10,
        [FromName, Cfg.SharedDir, LowerCase(FromName), FromName]);
    S := S + Format('New here? Full manual: %s/%s'#10,
      [Cfg.SharedDir, SHARED_MANUAL]);
  end;
  if Team.Parent <> '' then
    S := S + Format('Your boss: %s  (report progress: tiza %s "...")'#10,
      [Team.Parent, Team.Parent]);
  S := S + MasterSlaveLines(Cfg, Team, FromName);
  Subs := SubordinatesOf(Cfg, Team.Name);
  if Subs <> '' then
    S := S +
      'Your subordinates: ' + Subs + #10 +
      'Delegate: tiza task add <sub> "subtask" --parent <id>  |  tiza task note <id> "..."  |  tiza task done <id>'#10;
  S := S +
    Format('Reply:       tiza %s "your answer"'#10, [FromName]) +
    Format('  long answer: write a file and run:  tiza %s --file answer.txt'#10,
      [FromName]) +
    'Other team:  tiza <id|name> "your question"'#10 +
    'Look things up: tiza team <name> (who they are, what they own, where they'#10 +
    '  work) | tiza app <name> (what a program is for) | tiza app doc <name>'#10 +
    '  (its full manual) | tiza group <name> (who is in it and who leads it)'#10 +
    'Full guide:  tiza manual   |   every command: tiza help'#10 +
    'Teams:'#10 +
    Idx;
  { groups block: each group, its project, and its member teams }
  if Length(Cfg.Groups) > 0 then
  begin
    S := S + 'Groups:'#10;
    for i := 0 to High(Cfg.Groups) do
    begin
      Subs := '';
      for j := 0 to High(Cfg.Groups[i].Members) do
      begin
        if Subs <> '' then Subs := Subs + ', ';
        Subs := Subs + Cfg.Groups[i].Members[j];
      end;
      S := S + Format('  @%s', [Cfg.Groups[i].Name]);
      if Cfg.Groups[i].Project <> '' then
        S := S + Format(' [%s]', [Cfg.Groups[i].Project]);
      if Cfg.Groups[i].Boss <> '' then
        S := S + Format(' admin=%s', [Cfg.Groups[i].Boss]);
      S := S + ': ' + Subs + #10;
    end;
  end;
  { workflow role lines + plan trees (hub-rendered) }
  S := S + WfBlock;
  if OpenTasks <> '' then
    S := S + 'Your open tasks:'#10 + OpenTasks;
  if IncludeManual then
    { a team's FIRST delivery embeds the whole guide: a cold-start agent
      learns the system from this single message, no files involved }
    S := S +
      '---- QUICK GUIDE (embedded in your first message; later: tiza manual) ----'#10 +
      AgentsManualText + #10;
  S := S +
    Format('---- MESSAGE from %s ----'#10, [FromName]) +
    Body + #10 +
    '=========================';
  Result := S;
end;

end.
