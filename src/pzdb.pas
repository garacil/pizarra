{ pzdb - SQLite access for the hub. Only pizarra uses this unit: tiza must not
  link it, and pzconfig must not depend on it, because the client is deployed
  across the fleet and should continue to depend only on libc.

  sqlite3dyn loads the library at RUNTIME with dlopen, so `ldd pizarra` is
  unchanged. If libsqlite3 is missing, the hub still starts with registries in
  read-only mode and continues delivering messages. The sqlite3, sqlite3ds, and
  sqlite3db units would create a hard link dependency and are not used.

  Concurrency: each open file has one FULLMUTEX handle, which is safe across
  threads, but prepared statements are not. One TCriticalSection therefore
  wraps each prepare/bind/step/reset sequence. Hub lock order is fixed:
  FCfgLock -> TPzDb.FLock, never the reverse.

  NON-LOCAL INVARIANT: FLock protects ONE STATEMENT, not a transaction. Each
  Exec/QueryStr/Rows call acquires and releases it, so BEGIN IMMEDIATE ...
  INSERT ... HistAdd ... COMMIT is not atomic by itself. Atomicity depends on
  the CALLER holding its outer lock throughout the mutation:

    teams, groups, projects, applications -> FCfgLock (pizarra.pas)
    tasks                                 -> TTaskStore.FLock (pztasks.pas)

  The three files use SEPARATE handles (FApps/FOrg/FWork), so task writers do
  not share a connection with organization writers. Calling an FOrg/FApps
  writer without FCfgLock, however, would let two mutations interleave on the
  SAME connection. The second BEGIN could fail, or its statements and COMMIT
  could enter and finish the first writer's transaction. Any new writer must
  run under its corresponding outer lock.

  Known READ limitation, deliberately unchanged: HistList, HistGet, and Rows
  query without an outer lock. A SELECT can therefore run inside an uncommitted
  write transaction on the same connection and expose rows later rolled back.
  This is a read inconsistency, not corruption. Fixing it requires a separate
  read handle or serving history under FCfgLock too. }
unit pzdb;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, BaseUnix, ctypes, sqlite3dyn;

type
  { An open handle to an .sqlite file. }
  TPzDbFile = record
    Handle: psqlite3;
    Path:   string;
  end;

  TPzDb = class
  private
    FLock: TCriticalSection;
    FApps, FOrg, FWork: TPzDbFile;
    { The PHYSICAL apps.sqlite file. After migration, FApps POINTS TO FOrg: apps
      live beside teams, groups, and projects so app<->project can use genuine
      foreign keys. A foreign key CANNOT cross databases; SQLite will not even
      compile the statement. This field retains the old handle for closing and
      leaves apps.sqlite in place so rollback means copying one file. }
    FAppsViejo: TPzDbFile;
    FMudado: Boolean;
    FAvail: Boolean;
    FWhy:   string;
    FVer:   string;
    FDir:   string;
    function OpenOne(var F: TPzDbFile; const FileName: string;
      out Err: string): Boolean;
    procedure CloseOne(var F: TPzDbFile);
  public
    constructor Create(const StoreDir: string);   { Never raises an exception. }
    destructor Destroy; override;

    { False when libsqlite3 is unavailable. The hub must still start and expose
      registries as read-only. }
    property Available: Boolean read FAvail;
    { Human-readable reason when Available is False. }
    property Unavailable: string read FWhy;
    { Loaded library version, or '' when unavailable. }
    property LibVersion: string read FVer;
    property Dir: string read FDir;

    { Execute SQL without results: DDL, PRAGMA, or BEGIN/COMMIT. }
    function Exec(var F: TPzDbFile; const SQL: string; out Err: string): Boolean;
    { Return one text value, or '' when no row exists. }
    function QueryStr(var F: TPzDbFile; const SQL: string): string;
    function QueryInt(var F: TPzDbFile; const SQL: string; Def: Int64 = 0): Int64;

    { Synchronize the database with INI declarations at every startup. The INI
      is the DECLARATIVE SOURCE (since 1.0.13), so manually editing pizarra.conf
      and restarting remains supported: unknown records are inserted and known
      records are UPDATED from the file, including renames detected by ID as
      described in that branch. Synchronization does NOT delete; removing an
      INI section does not remove its database record. Return the number of
      affected rows. }
    function ImportMissing(const Names, Teams, Repos, Paths, Purposes,
      Details: TStringList; const TeamRows, GroupRows,
      ProjectRows: TStringList; out N: Integer; out Err: string): Boolean;

    { --- Mutations: row and history in the SAME transaction. --- }
    function TaskUpsert(const Row, Who, Op, ChField, ChOld, ChNew: string;
      out Err: string): Boolean;
    function TaskNoteAdd(Id: Integer; const Ts, ByWho, Text: string;
      out Err: string): Boolean;
    function AppUpsert(const Name, Team, Repo, PathS, Purpose, Detail,
      Who: string; IsNew: Boolean; const OldRow: string;
      const ChField, ChOld, ChNew: string; out Err: string): Boolean;
    function AppRemove(const Name, Who, OldRow: string; out Err: string): Boolean;
    { --- App<->project relationship: assign, remove, and read from both ends.
      CASCADES live in the schema (SQL_APPPROJ), not here, so correctness does
      not depend on every caller remembering them. These methods only apply the
      operator's request and record it in history. --- }
    function AppProjectSet(const App_, Project_, Role, Who: string;
      out Err: string): Boolean;
    function AppProjectClear(const App_, Project_, Who: string;
      out Err: string): Boolean;
    { project<TAB>role, one line per assignment. }
    function ProjectsOfApp(const App_: string): TStringList;
    { app<TAB>role, one line per assignment. }
    function AppsOfProject(const Project_: string): TStringList;
    function AppSetDoc(const Name, Body, Who, OldBody: string;
      out Err: string): Boolean;
    function AppDoc(const Name: string): string;
    function TeamUpsert(const Row, Who: string; IsNew: Boolean;
      const OldRow, ChField, ChOld, ChNew: string; out Err: string): Boolean;
    function TeamRemove(Id: Integer; const Name, Who, OldRow: string;
      out Err: string): Boolean;
    function GroupUpsert(const Name, Project, Boss, Members, Excluded, Who: string;
      const OldRow: string; out Err: string): Boolean;
    function GroupRemove(const Name, Who, OldRow: string; out Err: string): Boolean;
    function ProjectUpsert(const Name, Boss, Who, OldRow: string;
      out Err: string): Boolean;
    function ProjectDelete(const Name, Who: string; out Err: string): Boolean;
    function TaskDelete(Id: Integer; const Title, Who: string;
      out Err: string): Boolean;

    { One-time migration from files. Idempotent through both the
      meta['ini_migrated'] sentinel and INSERT OR IGNORE. }
    function MigrateApps(const Names, Teams, Repos, Paths, Purposes,
      Details, Docs: TStringList; out N, NDocs: Integer;
      out Err: string): Boolean;
    function MigrateOrg(const TeamRows, GroupRows, ProjectRows: TStringList;
      out NT, NG, NP: Integer; out Err: string): Boolean;
    function MigrateTasks(const TaskRows, NoteRows: TStringList;
      out NT, NN: Integer; out Err: string): Boolean;
    { Add an audit row; the caller is already inside its transaction. }
    function HistAdd(var F: TPzDbFile; const Who, Kind, Subject, Op, Field,
      OldV, NewV, Before, After: string; Keep: Boolean; out Err: string): Boolean;

    { HOT backup of all three databases to the given directory through SQLite's
      online backup API, the only defined method while writes are in flight.
      VACUUM INTO would fail with SQLITE_BUSY. }
    function BackupTo(const OutDir: string; out Err: string): Boolean;

    { --- History. --- }
    { Lines shaped 'snap|ts|who|op|field|oldval|newval' for one object, or all
      objects when Subject is empty, newest first. }
    function HistList(var F: TPzDbFile; const Kind, Subject: string;
      Limit: Integer): TStringList;
    { One entry: kind|subject|op|field|oldval|newval|before|after. }
    function HistGet(var F: TPzDbFile; Snap: Integer): string;

    { Run a query and return rows with fields separated by #1, matching the
      migration format. }
    function Rows(var F: TPzDbFile; const SQL: string): TStringList;

    { Create the schema idempotently in all three databases. }
    function EnsureSchema(out Err: string): Boolean;
    { Per-database control key/value: 'ini_migrated', 'schema', and so on. }
    function MetaGet(var F: TPzDbFile; const K: string): string;
    function MetaSet(var F: TPzDbFile; const K, V: string; out Err: string): Boolean;

    { All three database files for modules that build statements. }
    function AppsDb: TPzDbFile;
    function OrgDb: TPzDbFile;
    function WorkDb: TPzDbFile;
    procedure Lock;
    procedure Unlock;
  end;

{ Escape a string for embedding between SQL single quotes. }
function SqlQuote(const S: string): string;
{ SQL-ready quoted and escaped value, avoiding repeated quote-doubling at every
  call site. }
function Q(const S: string): string;
{ A text value, or NULL when empty. }
function QN(const S: string): string;
{ Escape a string for placement INSIDE JSON text. Without this, a quoted name
  or path corrupts the history before/after JSON needed for rollback. }
function JsonEsc(const S: string): string;
{ A safe INTEGER literal for SQL. Current callers pass IntToStr, but that
  boundary is fragile: any future path placing text in a numeric position would
  permit injection. Convert nonintegers to -1, which matches no real ID. }
function QI(const S: string): string;

{ Probe whether libsqlite3 loads without opening a database, allowing
  `pizarra --version` to report it before reading configuration. }
function SqliteProbe(out Ver: string): Boolean;

implementation

const
  { Library names in probe order. Put the .so.0 soname FIRST: the unversioned
    libsqlite3.so link exists only with the development package and is FPC's
    default, so relying on it fails on stock Debian and Fedora installations. }
  LIBNAMES: array[0..3] of UnicodeString = (
    'libsqlite3.so.0', 'libsqlite3.so', 'libsqlite3.dylib', 'libsqlite3.so.3');

function SqlQuote(const S: string): string;
begin
  Result := StringReplace(S, '''', '''''', [rfReplaceAll]);
end;

function Q(const S: string): string;
begin
  Result := '''' + SqlQuote(S) + '''';
end;

function QN(const S: string): string;
begin
  if S = '' then
    Result := 'NULL'
  else
    Result := Q(S);
end;

function QI(const S: string): string;
begin
  Result := IntToStr(StrToIntDef(Trim(S), -1));
end;

function JsonEsc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
end;

function SqliteProbe(out Ver: string): Boolean;
var
  i: Integer;
begin
  Ver := '';
  Result := False;
  for i := 0 to High(LIBNAMES) do
    if TryInitializeSqlite(LIBNAMES[i]) > 0 then
    begin
      Ver := string(sqlite3_libversion());
      ReleaseSqlite;
      Exit(True);
    end;
end;

constructor TPzDb.Create(const StoreDir: string);
var
  i: Integer;
  Err: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDir := IncludeTrailingPathDelimiter(StoreDir);
  FAvail := False;
  FWhy := '';
  FVer := '';
  { TryInitializeSqlite returns -1 instead of raising an exception. The
    InitialiseSQLite variant is deprecated and breaks a -Sew build. It expects
    UnicodeString; passing AnsiString emits an implicit-conversion warning. }
  for i := 0 to High(LIBNAMES) do
    if TryInitializeSqlite(LIBNAMES[i]) > 0 then
    begin
      FAvail := True;
      Break;
    end;
  if not FAvail then
  begin
    FWhy := 'libsqlite3 not found (tried: libsqlite3.so.0, ' +
      'libsqlite3.so, libsqlite3.dylib)';
    Exit;
  end;
  FVer := string(sqlite3_libversion());
  if not ForceDirectories(FDir) then
  begin
    FAvail := False;
    FWhy := 'cannot create ' + FDir;
    Exit;
  end;
  if not OpenOne(FAppsViejo, 'apps.sqlite', Err) then
  begin
    FAvail := False;
    FWhy := Err;
    Exit;
  end;
  { Until EnsureSchema decides otherwise, read apps from their original file. }
  FApps := FAppsViejo;
  if not OpenOne(FOrg, 'org.sqlite', Err) then
  begin
    FAvail := False;
    FWhy := Err;
    Exit;
  end;
  if not OpenOne(FWork, 'work.sqlite', Err) then
  begin
    FAvail := False;
    FWhy := Err;
    Exit;
  end;
end;

destructor TPzDb.Destroy;
begin
  { Close the PHYSICAL handle. FApps becomes an ALIAS of FOrg after migration,
    so closing FApps here would close the same handle twice. }
  CloseOne(FAppsViejo);
  CloseOne(FOrg);
  CloseOne(FWork);
  if FAvail then
    ReleaseSqlite;
  FLock.Free;
  inherited Destroy;
end;

function TPzDb.OpenOne(var F: TPzDbFile; const FileName: string;
  out Err: string): Boolean;
var
  P: AnsiString;
  rc: cint;
begin
  Result := False;
  Err := '';
  F.Path := FDir + FileName;
  P := F.Path;
  rc := sqlite3_open_v2(PAnsiChar(P), @F.Handle,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_FULLMUTEX, nil);
  if rc <> SQLITE_OK then
  begin
    if F.Handle <> nil then
    begin
      Err := FileName + ': ' + string(sqlite3_errmsg(F.Handle));
      sqlite3_close(F.Handle);
      F.Handle := nil;
    end
    else
      Err := FileName + ': could not open it (code ' + IntToStr(rc) + ')';
    Exit;
  end;
  { Wait 5 s when another writer holds the file. WAL prevents readers such as
    online backup from blocking the writer, and FULL synchronizes every commit,
    as required for a configuration registry. }
  sqlite3_busy_timeout(F.Handle, 5000);
  if not Exec(F, 'PRAGMA journal_mode=WAL;', Err) then
    Exit;
  if not Exec(F, 'PRAGMA synchronous=FULL;', Err) then
    Exit;
  if not Exec(F, 'PRAGMA foreign_keys=ON;', Err) then
    Exit;
  { The organization database contains team secrets; only the hub owner reads it. }
  FpChmod(F.Path, &600);
  Result := True;
end;

procedure TPzDb.CloseOne(var F: TPzDbFile);
begin
  if F.Handle <> nil then
  begin
    sqlite3_close(F.Handle);
    F.Handle := nil;
  end;
end;

function TPzDb.Exec(var F: TPzDbFile; const SQL: string; out Err: string): Boolean;
var
  S: AnsiString;
  Msg: PAnsiChar;
  rc: cint;
begin
  Err := '';
  if (not FAvail) or (F.Handle = nil) then
  begin
    Err := 'SQLite unavailable';
    Exit(False);
  end;
  S := SQL;
  Msg := nil;
  FLock.Enter;
  try
    rc := sqlite3_exec(F.Handle, PAnsiChar(S), nil, nil, @Msg);
  finally
    FLock.Leave;
  end;
  Result := rc = SQLITE_OK;
  if not Result then
  begin
    if Msg <> nil then
    begin
      Err := string(Msg);
      sqlite3_free(Msg);
    end
    else
      Err := 'sqlite error ' + IntToStr(rc);
  end;
end;

function TPzDb.QueryStr(var F: TPzDbFile; const SQL: string): string;
var
  S: AnsiString;
  St: psqlite3_stmt;
  P: PAnsiChar;
begin
  Result := '';
  if (not FAvail) or (F.Handle = nil) then
    Exit;
  S := SQL;
  St := nil;
  FLock.Enter;
  try
    if sqlite3_prepare_v2(F.Handle, PAnsiChar(S), -1, @St, nil) <> SQLITE_OK then
      Exit;
    try
      if sqlite3_step(St) = SQLITE_ROW then
      begin
        P := sqlite3_column_text(St, 0);
        if P <> nil then
          Result := string(P);
      end;
    finally
      sqlite3_finalize(St);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzDb.QueryInt(var F: TPzDbFile; const SQL: string; Def: Int64): Int64;
var
  S: string;
begin
  S := QueryStr(F, SQL);
  if S = '' then
    Result := Def
  else
    Result := StrToInt64Def(S, Def);
end;


const
  { Apply the schema with CREATE ... IF NOT EXISTS at every startup, making it
    harmless and useful for forward migration. The history table is deliberately
    identical in all three databases so each file can be restored independently
    without losing its own audit trail. }
  SQL_HISTORY =
    'CREATE TABLE IF NOT EXISTS history (' +
    '  snap INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  ts TEXT NOT NULL, who TEXT NOT NULL,' +
    '  kind TEXT NOT NULL, subject TEXT NOT NULL COLLATE NOCASE,' +
    '  op TEXT NOT NULL, field TEXT NOT NULL DEFAULT '''',' +
    '  oldval TEXT, newval TEXT, before TEXT, after TEXT,' +
    '  keep INTEGER NOT NULL DEFAULT 0);' +
    'CREATE INDEX IF NOT EXISTS ix_hist_subj' +
    '  ON history(kind, subject COLLATE NOCASE, snap DESC);' +
    'CREATE INDEX IF NOT EXISTS ix_hist_ts ON history(ts);' +
    'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);';

  SQL_APPS =
    'CREATE TABLE IF NOT EXISTS app (' +
    '  name TEXT PRIMARY KEY COLLATE NOCASE,' +
    '  team TEXT NOT NULL DEFAULT '''' COLLATE NOCASE,' +
    '  repo TEXT NOT NULL DEFAULT '''',' +
    '  path TEXT NOT NULL DEFAULT '''',' +
    '  purpose TEXT NOT NULL DEFAULT '''',' +
    '  detail TEXT NOT NULL DEFAULT '''');' +
    'CREATE TABLE IF NOT EXISTS app_doc (' +
    '  app TEXT PRIMARY KEY COLLATE NOCASE' +
    '    REFERENCES app(name) ON DELETE CASCADE ON UPDATE CASCADE,' +
    '  body TEXT NOT NULL DEFAULT '''', bytes INTEGER NOT NULL DEFAULT 0,' +
    '  sha256 TEXT NOT NULL DEFAULT '''',' +
    '  updated_ts TEXT NOT NULL DEFAULT '''',' +
    '  updated_by TEXT NOT NULL DEFAULT '''');' +
    'CREATE INDEX IF NOT EXISTS ix_app_team ON app(team COLLATE NOCASE);';

  { THE app<->project RELATIONSHIP lives ONLY in org.sqlite, which now contains
    both referenced tables. Foreign keys cannot cross databases; SQLite will not
    compile 'REFERENCES other.table(col)'. Without both keys, cleanup would be
    caller convention rather than structure.
    Encode both operator rules HERE in the schema:
      delete an app     -> remove it from every project (cascade by app)
      delete a project -> preserve EVERY app            (the project cascade
                           removes assignments only)
    'role' describes what the app does IN THAT project. It belongs to the pair,
    not either object individually. This is a NEW table, so IF NOT EXISTS is
    sufficient. pragma_table_info is required only when adding a COLUMN to an
    existing table, which is a different migration. }
  SQL_APPPROJ =
    'CREATE TABLE IF NOT EXISTS app_project (' +
    '  app     TEXT NOT NULL COLLATE NOCASE' +
    '          REFERENCES app(name)     ON DELETE CASCADE ON UPDATE CASCADE,' +
    '  project TEXT NOT NULL COLLATE NOCASE' +
    '          REFERENCES project(name) ON DELETE CASCADE ON UPDATE CASCADE,' +
    '  role    TEXT NOT NULL DEFAULT '''',' +
    '  PRIMARY KEY (app, project));' +
    'CREATE INDEX IF NOT EXISTS ix_ap_project' +
    '  ON app_project(project COLLATE NOCASE);';

  SQL_ORG =
    'CREATE TABLE IF NOT EXISTS team (' +
    '  id INTEGER PRIMARY KEY,' +
    '  name TEXT NOT NULL UNIQUE COLLATE NOCASE,' +
    '  speciality TEXT NOT NULL DEFAULT '''',' +
    '  prompt TEXT NOT NULL DEFAULT '''',' +
    '  parent TEXT NOT NULL DEFAULT '''',' +
    '  project TEXT NOT NULL DEFAULT '''',' +
    '  secret TEXT NOT NULL DEFAULT '''',' +
    '  host TEXT NOT NULL DEFAULT '''', port INTEGER NOT NULL DEFAULT 0,' +
    '  dial INTEGER NOT NULL DEFAULT 0,' +
    '  tmux_session TEXT NOT NULL DEFAULT '''',' +
    '  launch TEXT NOT NULL DEFAULT '''',' +
    '  usr TEXT NOT NULL DEFAULT '''',' +
    '  slave INTEGER NOT NULL DEFAULT 0,' +
    '  workdir TEXT NOT NULL DEFAULT '''');' +
    'CREATE INDEX IF NOT EXISTS ix_team_parent ON team(parent COLLATE NOCASE);' +
    'CREATE TABLE IF NOT EXISTS grp (' +
    '  name TEXT PRIMARY KEY COLLATE NOCASE,' +
    '  project TEXT NOT NULL DEFAULT '''',' +
    '  boss TEXT NOT NULL DEFAULT '''',' +
    { the muted list (members excluded from @group broadcasts), CSV. The COLUMN
      is 'muted' and not 'excluded' on purpose: SQLite's UPSERT keyword for the
      would-be-inserted row is 'excluded', so a column of that name would read
      as 'excluded.excluded' in the ON CONFLICT clause below - valid but a trap.
      The INI key, the JSON field and the CLI verb are all 'excluded'; only this
      column is renamed to dodge the keyword. }
    '  muted TEXT NOT NULL DEFAULT '''');' +
    'CREATE TABLE IF NOT EXISTS grp_member (' +
    '  grp TEXT NOT NULL COLLATE NOCASE' +
    '    REFERENCES grp(name) ON DELETE CASCADE ON UPDATE CASCADE,' +
    '  team TEXT NOT NULL COLLATE NOCASE,' +
    '  ord INTEGER NOT NULL DEFAULT 0,' +
    '  PRIMARY KEY (grp, team));' +
    'CREATE INDEX IF NOT EXISTS ix_grpmem_team' +
    '  ON grp_member(team COLLATE NOCASE);' +
    'CREATE TABLE IF NOT EXISTS project (' +
    '  name TEXT PRIMARY KEY COLLATE NOCASE,' +
    '  boss TEXT NOT NULL DEFAULT '''');';

  SQL_WORK =
    'CREATE TABLE IF NOT EXISTS task (' +
    '  id INTEGER PRIMARY KEY,' +
    '  title TEXT NOT NULL DEFAULT '''',' +
    '  team TEXT NOT NULL DEFAULT '''' COLLATE NOCASE,' +
    '  state TEXT NOT NULL DEFAULT ''open'',' +
    '  hito TEXT NOT NULL DEFAULT '''',' +
    '  parent INTEGER NOT NULL DEFAULT 0,' +
    '  created TEXT NOT NULL DEFAULT '''',' +
    '  closed TEXT NOT NULL DEFAULT '''');' +
    'CREATE INDEX IF NOT EXISTS ix_task_team ON task(team COLLATE NOCASE, state);' +
    'CREATE INDEX IF NOT EXISTS ix_task_parent ON task(parent);' +
    'CREATE TABLE IF NOT EXISTS task_note (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  task_id INTEGER NOT NULL' +
    '    REFERENCES task(id) ON DELETE CASCADE,' +
    '  ts TEXT NOT NULL DEFAULT '''',' +
    '  by_who TEXT NOT NULL DEFAULT '''',' +
    '  text TEXT NOT NULL DEFAULT '''');' +
    'CREATE INDEX IF NOT EXISTS ix_note_task ON task_note(task_id, id);';


{ Every migration receives caller-extracted data, keeping pzdb independent from
  pzconfig and pztasks. TStringList fields use #1, which cannot appear in INI
  data or textual JSON. }

function TPzDb.HistAdd(var F: TPzDbFile; const Who, Kind, Subject, Op, Field,
  OldV, NewV, Before, After: string; Keep: Boolean; out Err: string): Boolean;
begin
  Result := Exec(F,
    'INSERT INTO history(ts,who,kind,subject,op,field,oldval,newval,' +
    'before,after,keep) VALUES(' +
    Q(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)) + ',' + Q(Who) + ',' +
    Q(Kind) + ',' + Q(Subject) + ',' + Q(Op) + ',' + Q(Field) + ',' +
    QN(OldV) + ',' + QN(NewV) + ',' + QN(Before) + ',' + QN(After) + ',' +
    IntToStr(Ord(Keep)) + ');', Err);
end;



{ --------- Mutations ---------
  Every mutation follows the same form: BEGIN IMMEDIATE, row update, history
  row, COMMIT. Any failure rolls back the complete transaction and returns False
  with a reason; the caller must NOT replace its in-memory configuration. }


function TPzDb.TaskUpsert(const Row, Who, Op, ChField, ChOld,
  ChNew: string; out Err: string): Boolean;
var
  F: TStringList;
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  F := TStringList.Create;
  try
    F.Delimiter := #1;
    F.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    F.QuoteChar := #0;
    F.DelimitedText := Row;
    while F.Count < 8 do
      F.Add('');
    if not Exec(FWork, 'BEGIN IMMEDIATE;', Err) then
      Exit;
    try
      if not Exec(FWork,
        'INSERT INTO task(id,title,team,state,hito,parent,created,closed)' +
        ' VALUES(' + QI(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) +
        ',' + Q(F[4]) + ',' + QI(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ')' +
        ' ON CONFLICT(id) DO UPDATE SET title=excluded.title,' +
        'team=excluded.team,state=excluded.state,hito=excluded.hito,' +
        'parent=excluded.parent,closed=excluded.closed;', Err) then
        Exit;
      if not HistAdd(FWork, Who, 'task', QI(F[0]), Op, ChField, ChOld, ChNew,
        '', '{"title":"' + JsonEsc(F[1]) + '","team":"' + JsonEsc(F[2]) +
        '","state":"' + JsonEsc(F[3]) + '"}', False, Err) then
        Exit;
      Result := Exec(FWork, 'COMMIT;', Err);
    finally
      if not Result then
        Exec(FWork, 'ROLLBACK;', Tmp);
    end;
  finally
    F.Free;
  end;
end;

{ A deletion is NOT an upsert. Calling TaskUpsert here reinserted the row just
  removed, making the mirror contradict the store, and then failed. Delete the
  row and its notes while preserving the audit record in history. }
function TPzDb.TaskDelete(Id: Integer; const Title, Who: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FWork, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FWork, 'DELETE FROM task_note WHERE task_id=' +
      IntToStr(Id) + ';', Err) then
      Exit;
    if not Exec(FWork, 'DELETE FROM task WHERE id=' + IntToStr(Id) + ';',
      Err) then
      Exit;
    if not HistAdd(FWork, Who, 'task', IntToStr(Id), 'delete', '', Title, '',
      '', '', False, Err) then
      Exit;
    Result := Exec(FWork, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FWork, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.TaskNoteAdd(Id: Integer; const Ts, ByWho, Text: string;
  out Err: string): Boolean;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  Result := Exec(FWork, 'INSERT INTO task_note(task_id,ts,by_who,text)' +
    ' VALUES(' + IntToStr(Id) + ',' + Q(Ts) + ',' + Q(ByWho) + ',' +
    Q(Text) + ');', Err);
end;

function TPzDb.AppUpsert(const Name, Team, Repo, PathS, Purpose, Detail,
  Who: string; IsNew: Boolean; const OldRow: string;
  const ChField, ChOld, ChNew: string; out Err: string): Boolean;
var
  Tmp, NewRow: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  NewRow := '{"team":"' + JsonEsc(Team) + '","repo":"' + JsonEsc(Repo) +
    '","path":"' + JsonEsc(PathS) + '","purpose":"' + JsonEsc(Purpose) + '"}';
  if not Exec(FApps, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FApps,
      'INSERT INTO app(name,team,repo,path,purpose,detail) VALUES(' +
      Q(Name) + ',' + Q(Team) + ',' + Q(Repo) + ',' + Q(PathS) + ',' +
      Q(Purpose) + ',' + Q(Detail) + ')' +
      ' ON CONFLICT(name) DO UPDATE SET team=excluded.team,repo=excluded.repo,' +
      'path=excluded.path,purpose=excluded.purpose,detail=excluded.detail;',
      Err) then
      Exit;
    if IsNew then
    begin
      if not HistAdd(FApps, Who, 'app', Name, 'add', '', '', '', '', NewRow,
        False, Err) then
        Exit;
    end
    else
      if not HistAdd(FApps, Who, 'app', Name, 'set', ChField, ChOld, ChNew,
        OldRow, NewRow, False, Err) then
        Exit;
    Result := Exec(FApps, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FApps, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.AppProjectSet(const App_, Project_, Role, Who: string;
  out Err: string): Boolean;
var
  Tmp, PreviousRole, EffectiveRole: string;
  PreviousRows: TStringList;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  { Read the PREVIOUS VALUE before changing anything. It prevents overwriting a
    role nobody asked to change and records the old value in history. }
  PreviousRole := '';
  PreviousRows := Rows(FOrg, 'SELECT role FROM app_project WHERE app=' + Q(App_) +
    ' AND project=' + Q(Project_) + ';');
  try
    if (PreviousRows <> nil) and (PreviousRows.Count > 0) then
      PreviousRole := PreviousRows[0];
  finally
    PreviousRows.Free;
  end;
  { DO NOT ERASE A HAND-WRITTEN ROLE BY OMISSION. Reassigning the same pair with
    an explicit role still changes it, but `tiza app project X Y` without
    --role arrives with an empty value because the client always sends the field;
    the hub cannot distinguish "not supplied" from "set empty". The former
    behavior silently erased carefully written text and did not retain OldV for
    recovery. An empty value on an existing pair now PRESERVES the current role.
    To clear it, remove and add the assignment again as two deliberate actions. }
  EffectiveRole := Role;
  if (EffectiveRole = '') and (PreviousRole <> '') then
    EffectiveRole := PreviousRole;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FOrg, 'INSERT OR REPLACE INTO app_project(app,project,role) ' +
      'VALUES(' + Q(App_) + ',' + Q(Project_) + ',' + Q(EffectiveRole) + ');', Err) then
      Exit;
    if not HistAdd(FOrg, Who, 'appproject', App_, 'assign', Project_,
      PreviousRole, EffectiveRole, '', '', False, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.AppProjectClear(const App_, Project_, Who: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FOrg, 'DELETE FROM app_project WHERE app=' + Q(App_) +
      ' AND project=' + Q(Project_) + ';', Err) then
      Exit;
    if not HistAdd(FOrg, Who, 'appproject', App_, 'unassign', Project_,
      '', '', '', '', False, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.ProjectsOfApp(const App_: string): TStringList;
begin
  Result := Rows(FOrg, 'SELECT project || char(9) || role FROM app_project ' +
    'WHERE app=' + Q(App_) + ' ORDER BY project COLLATE NOCASE;');
end;

function TPzDb.AppsOfProject(const Project_: string): TStringList;
begin
  Result := Rows(FOrg, 'SELECT app || char(9) || role FROM app_project ' +
    'WHERE project=' + Q(Project_) + ' ORDER BY app COLLATE NOCASE;');
end;

function TPzDb.AppRemove(const Name, Who, OldRow: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FApps, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    { The manual follows the app through the cascading foreign key. }
    if not Exec(FApps, 'DELETE FROM app WHERE name=' + Q(Name) + ';', Err) then
      Exit;
    { keep=1: never prune removals; they are the only record that it existed. }
    if not HistAdd(FApps, Who, 'app', Name, 'remove', '', '', '', OldRow, '',
      True, Err) then
      Exit;
    Result := Exec(FApps, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FApps, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.AppSetDoc(const Name, Body, Who, OldBody: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FApps, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FApps,
      'INSERT INTO app_doc(app,body,bytes,updated_ts,updated_by) VALUES(' +
      Q(Name) + ',' + Q(Body) + ',' + IntToStr(Length(Body)) + ',' +
      Q(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)) + ',' + Q(Who) + ')' +
      ' ON CONFLICT(app) DO UPDATE SET body=excluded.body,' +
      'bytes=excluded.bytes,updated_ts=excluded.updated_ts,' +
      'updated_by=excluded.updated_by;', Err) then
      Exit;
    { Preserve complete old and new bodies in history so an earlier manual
      version can be restored. }
    if not HistAdd(FApps, Who, 'appdoc', Name, 'setdoc', '',
      IntToStr(Length(OldBody)) + ' bytes', IntToStr(Length(Body)) + ' bytes',
      OldBody, Body, False, Err) then
      Exit;
    Result := Exec(FApps, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FApps, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.AppDoc(const Name: string): string;
begin
  Result := QueryStr(FApps, 'SELECT body FROM app_doc WHERE app=' + Q(Name));
end;

function TPzDb.TeamUpsert(const Row, Who: string; IsNew: Boolean;
  const OldRow, ChField, ChOld, ChNew: string; out Err: string): Boolean;
var
  F: TStringList;
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  F := TStringList.Create;
  try
    F.Delimiter := #1;
    F.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    F.QuoteChar := #0;
    F.DelimitedText := Row;
    while F.Count < 15 do
      F.Add('');
    if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
      Exit;
    try
      if not Exec(FOrg,
        'INSERT INTO team(id,name,speciality,prompt,parent,project,secret,' +
        'host,port,dial,tmux_session,launch,usr,slave,workdir) VALUES(' + QI(F[0]) + ',' +
        Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) + ',' + Q(F[4]) + ',' +
        Q(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ',' + QI(F[8]) + ',' + QI(F[9]) +
        ',' + Q(F[10]) + ',' + Q(F[11]) + ',' + Q(F[12]) + ',' + QI(F[13]) +
        ',' + Q(F[14]) + ')' +
        ' ON CONFLICT(id) DO UPDATE SET name=excluded.name,' +
        'speciality=excluded.speciality,prompt=excluded.prompt,' +
        'parent=excluded.parent,project=excluded.project,' +
        'secret=excluded.secret,host=excluded.host,port=excluded.port,' +
        'dial=excluded.dial,tmux_session=excluded.tmux_session,' +
        'launch=excluded.launch,usr=excluded.usr,slave=excluded.slave,' +
        'workdir=excluded.workdir;', Err) then
        Exit;
      if IsNew then
      begin
        if not HistAdd(FOrg, Who, 'team', F[1], 'add', '', '', '', '',
          '{"id":' + QI(F[0]) + ',"speciality":"' + JsonEsc(F[2]) + '"}', False,
          Err) then
          Exit;
      end
      else
        if not HistAdd(FOrg, Who, 'team', F[1], 'set', ChField, ChOld, ChNew,
          OldRow, '{"id":' + QI(F[0]) + '}', False, Err) then
          Exit;
      Result := Exec(FOrg, 'COMMIT;', Err);
    finally
      if not Result then
        Exec(FOrg, 'ROLLBACK;', Tmp);
    end;
  finally
    F.Free;
  end;
end;

function TPzDb.TeamRemove(Id: Integer; const Name, Who, OldRow: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FOrg, 'DELETE FROM team WHERE id=' + IntToStr(Id) + ';',
      Err) then
      Exit;
    if not HistAdd(FOrg, Who, 'team', Name, 'remove', '', '', '', OldRow, '',
      True, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.GroupUpsert(const Name, Project, Boss, Members, Excluded, Who: string;
  const OldRow: string; out Err: string): Boolean;
var
  Mem: TStringList;
  i: Integer;
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  Mem := TStringList.Create;
  try
    Mem.Delimiter := ',';
    Mem.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    Mem.QuoteChar := #0;
    Mem.DelimitedText := Members;
    if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
      Exit;
    try
      if not Exec(FOrg, 'INSERT INTO grp(name,project,boss,muted) VALUES(' +
        Q(Name) + ',' + Q(Project) + ',' + Q(Boss) + ',' + Q(Excluded) + ')' +
        ' ON CONFLICT(name) DO UPDATE SET project=excluded.project,' +
        'boss=excluded.boss,muted=excluded.muted;', Err) then
        Exit;
      if not Exec(FOrg, 'DELETE FROM grp_member WHERE grp=' + Q(Name) + ';',
        Err) then
        Exit;
      for i := 0 to Mem.Count - 1 do
        if Trim(Mem[i]) <> '' then
          if not Exec(FOrg,
            'INSERT OR IGNORE INTO grp_member(grp,team,ord) VALUES(' +
            Q(Name) + ',' + Q(Trim(Mem[i])) + ',' + IntToStr(i) + ');',
            Err) then
            Exit;
      if not HistAdd(FOrg, Who, 'group', Name, 'set', 'members', OldRow,
        Members, '', '{"members":"' + JsonEsc(Members) + '"}', False, Err) then
        Exit;
      Result := Exec(FOrg, 'COMMIT;', Err);
    finally
      if not Result then
        Exec(FOrg, 'ROLLBACK;', Tmp);
    end;
  finally
    Mem.Free;
  end;
end;

function TPzDb.ProjectDelete(const Name, Who: string; out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FOrg, 'DELETE FROM project WHERE name=' + Q(Name) + ';', Err) then
      Exit;
    if not HistAdd(FOrg, Who, 'project', Name, 'remove', '', '', '', '', '',
      True, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.GroupRemove(const Name, Who, OldRow: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FOrg, 'DELETE FROM grp WHERE name=' + Q(Name) + ';', Err) then
      Exit;
    if not HistAdd(FOrg, Who, 'group', Name, 'remove', '', '', '', OldRow, '',
      True, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.ProjectUpsert(const Name, Boss, Who, OldRow: string;
  out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    if not Exec(FOrg, 'INSERT INTO project(name,boss) VALUES(' + Q(Name) +
      ',' + Q(Boss) + ') ON CONFLICT(name) DO UPDATE SET boss=excluded.boss;',
      Err) then
      Exit;
    if not HistAdd(FOrg, Who, 'project', Name, 'set', 'boss', OldRow, Boss,
      '', '{"boss":"' + JsonEsc(Boss) + '"}', False, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.ImportMissing(const Names, Teams, Repos, Paths, Purposes,
  Details: TStringList; const TeamRows, GroupRows,
  ProjectRows: TStringList; out N: Integer; out Err: string): Boolean;
var
  i, j: Integer;
  F, Mem, INames: TStringList;
  Keep, Tmp, Old: string;
begin
  Result := False;
  N := 0;
  F := TStringList.Create;
  Mem := TStringList.Create;
  INames := TStringList.Create;
  try
    F.Delimiter := #1;
    F.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    F.QuoteChar := #0;
    Mem.Delimiter := ',';
    Mem.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    Mem.QuoteChar := #0;

    { --- apps --- }
    if not Exec(FApps, 'BEGIN IMMEDIATE;', Err) then
      Exit;
    Keep := '';
    for i := 0 to Names.Count - 1 do
    begin
      if Keep <> '' then
        Keep := Keep + ',';
      Keep := Keep + Q(Names[i]);
      if not Exec(FApps,
        'INSERT INTO app(name,team,repo,path,purpose,detail) VALUES(' +
        Q(Names[i]) + ',' + Q(Teams[i]) + ',' + Q(Repos[i]) + ',' +
        Q(Paths[i]) + ',' + Q(Purposes[i]) + ',' + Q(Details[i]) + ')' +
        ' ON CONFLICT(name) DO UPDATE SET team=excluded.team,' +
        'repo=excluded.repo,path=excluded.path,purpose=excluded.purpose,' +
        'detail=excluded.detail;', Err) then
      begin
        Exec(FApps, 'ROLLBACK;', Tmp);
        Exit;
      end;
      Inc(N);
    end;
    if not Exec(FApps, 'COMMIT;', Err) then
      Exit;

    { --- Teams, groups, and projects. --- }
    if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
      Exit;
    try
      { Names currently declared by the INI distinguish a RENAME, where no one
        claims the old row, from an ID collision between two configurations
        sharing one store. }
      INames.Clear;
      INames.CaseSensitive := False;
      for i := 0 to TeamRows.Count - 1 do
      begin
        F.DelimitedText := TeamRows[i];
        if F.Count > 1 then
          INames.Add(F[1]);
      end;
      Keep := '';
      for i := 0 to TeamRows.Count - 1 do
      begin
        F.DelimitedText := TeamRows[i];
        while F.Count < 15 do
          F.Add('');
        if Keep <> '' then
          Keep := Keep + ',';
        Keep := Keep + F[0];
        { NAME is the identity. If the database already knows it, update its
          fields so manual pizarra.conf edits followed by restart remain valid. }
        if QueryStr(FOrg, 'SELECT 1 FROM team WHERE name=' + Q(F[1])) <> '' then
        begin
          if not Exec(FOrg, 'UPDATE team SET speciality=' + Q(F[2]) +
            ',prompt=' + Q(F[3]) + ',parent=' + Q(F[4]) + ',project=' +
            Q(F[5]) + ',secret=' + Q(F[6]) + ',host=' + Q(F[7]) + ',port=' +
            QI(F[8]) + ',dial=' + QI(F[9]) + ',tmux_session=' + Q(F[10]) +
            ',launch=' + Q(F[11]) + ',usr=' + Q(F[12]) + ',slave=' +
            QI(F[13]) + ',workdir=' + Q(F[14]) + ' WHERE name=' + Q(F[1]) +
            ';', Err) then
            Exit;
          Continue;
        end;
        { The database does not contain this name. If a row DOES have this ID
          and no INI team claims its current name, the row is orphaned and this
          is a manual RENAME in pizarra.conf. UPDATE that row instead of adding
          another. Previously a new row received a free ID and BOTH survived:
          the old orphan and the new name. Every later mutation then failed on
          UNIQUE(name) even though it WAS applied in memory and the INI, creating
          silent divergence that appeared successful to the operator. }
        Old := QueryStr(FOrg, 'SELECT name FROM team WHERE id=' + QI(F[0]));
        if (Old <> '') and (INames.IndexOf(Old) < 0) then
        begin
          if not Exec(FOrg, 'UPDATE team SET name=' + Q(F[1]) +
            ',speciality=' + Q(F[2]) + ',prompt=' + Q(F[3]) + ',parent=' +
            Q(F[4]) + ',project=' + Q(F[5]) + ',secret=' + Q(F[6]) +
            ',host=' + Q(F[7]) + ',port=' + QI(F[8]) + ',dial=' + QI(F[9]) +
            ',tmux_session=' + Q(F[10]) + ',launch=' + Q(F[11]) + ',usr=' +
            Q(F[12]) + ',slave=' + QI(F[13]) + ',workdir=' + Q(F[14]) +
            ' WHERE id=' + QI(F[0]) + ';', Err) then
            Exit;
          Inc(N);
          Continue;
        end;
        { Another team may occupy this ID when separate configurations share one
          store. Assign a free ID instead of silently discarding the team. }
        Tmp := F[0];
        if QueryStr(FOrg, 'SELECT 1 FROM team WHERE id=' + Tmp) <> '' then
          Tmp := IntToStr(StrToIntDef(QueryStr(FOrg,
            'SELECT COALESCE(MAX(id),0) FROM team'), 0) + 1);
        if not Exec(FOrg,
          'INSERT INTO team(id,name,speciality,prompt,parent,project,secret,' +
          'host,port,dial,tmux_session,launch,usr,slave,workdir) VALUES(' + QI(Tmp) + ',' +
          Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) + ',' + Q(F[4]) + ',' +
          Q(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ',' + QI(F[8]) + ',' + QI(F[9]) +
          ',' + Q(F[10]) + ',' + Q(F[11]) + ',' + Q(F[12]) + ',' + QI(F[13]) +
          ',' + Q(F[14]) + ');', Err) then
          Exit;
        Inc(N);
      end;

      Keep := '';
      for i := 0 to GroupRows.Count - 1 do
      begin
        F.DelimitedText := GroupRows[i];
        while F.Count < 4 do
          F.Add('');
        if Keep <> '' then
          Keep := Keep + ',';
        Keep := Keep + Q(F[0]);
        if not Exec(FOrg, 'INSERT INTO grp(name,project,boss) VALUES(' +
          Q(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) + ')' +
          ' ON CONFLICT(name) DO UPDATE SET project=excluded.project,' +
          'boss=excluded.boss;', Err) then
          Exit;
        if not Exec(FOrg, 'DELETE FROM grp_member WHERE grp=' + Q(F[0]) + ';',
          Err) then
          Exit;
        Inc(N);
        Mem.DelimitedText := F[3];
        for j := 0 to Mem.Count - 1 do
          if Trim(Mem[j]) <> '' then
            if not Exec(FOrg,
              'INSERT OR IGNORE INTO grp_member(grp,team,ord) VALUES(' +
              Q(F[0]) + ',' + Q(Trim(Mem[j])) + ',' + IntToStr(j) + ');',
              Err) then
              Exit;
      end;

      Keep := '';
      for i := 0 to ProjectRows.Count - 1 do
      begin
        F.DelimitedText := ProjectRows[i];
        while F.Count < 2 do
          F.Add('');
        if Keep <> '' then
          Keep := Keep + ',';
        Keep := Keep + Q(F[0]);
        if not Exec(FOrg, 'INSERT INTO project(name,boss) VALUES(' +
          Q(F[0]) + ',' + Q(F[1]) + ')' +
          ' ON CONFLICT(name) DO UPDATE SET boss=excluded.boss;', Err) then
          Exit;
      end;
      Result := Exec(FOrg, 'COMMIT;', Err);
    finally
      if not Result then
        Exec(FOrg, 'ROLLBACK;', Tmp);
    end;
  finally
    F.Free;
    Mem.Free;
    INames.Free;
  end;
end;

function TPzDb.MigrateApps(const Names, Teams, Repos, Paths, Purposes,
  Details, Docs: TStringList; out N, NDocs: Integer; out Err: string): Boolean;
var
  i: Integer;
  Tmp: string;
begin
  Result := False;
  N := 0;
  NDocs := 0;
  if not Exec(FApps, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  try
    for i := 0 to Names.Count - 1 do
    begin
      if not Exec(FApps,
        'INSERT OR IGNORE INTO app(name,team,repo,path,purpose,detail) VALUES(' +
        Q(Names[i]) + ',' + Q(Teams[i]) + ',' + Q(Repos[i]) + ',' +
        Q(Paths[i]) + ',' + Q(Purposes[i]) + ',' + Q(Details[i]) + ');',
        Err) then
        Exit;
      Inc(N);
      if not HistAdd(FApps, '(migration)', 'app', Names[i], 'add', '', '', '',
        '', '{"team":"' + JsonEsc(Teams[i]) + '"}', False, Err) then
        Exit;
      if Docs[i] <> '' then
      begin
        if not Exec(FApps,
          'INSERT OR IGNORE INTO app_doc(app,body,bytes,updated_ts,updated_by)' +
          ' VALUES(' + Q(Names[i]) + ',' + Q(Docs[i]) + ',' +
          IntToStr(Length(Docs[i])) + ',' +
          Q(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)) + ',' +
          Q('(migration)') + ');', Err) then
          Exit;
        Inc(NDocs);
      end;
    end;
    Result := Exec(FApps, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FApps, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.MigrateOrg(const TeamRows, GroupRows, ProjectRows: TStringList;
  out NT, NG, NP: Integer; out Err: string): Boolean;
var
  i, j: Integer;
  F, Mem: TStringList;
  Tmp: string;
begin
  Result := False;
  NT := 0; NG := 0; NP := 0;
  if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  F := TStringList.Create;
  Mem := TStringList.Create;
  try
    F.Delimiter := #1;
    F.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    F.QuoteChar := #0;
    Mem.Delimiter := ',';
    Mem.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    Mem.QuoteChar := #0;
    for i := 0 to TeamRows.Count - 1 do
    begin
      F.DelimitedText := TeamRows[i];
      while F.Count < 15 do
        F.Add('');
      if not Exec(FOrg,
        'INSERT OR IGNORE INTO team(id,name,speciality,prompt,parent,project,' +
        'secret,host,port,dial,tmux_session,launch,usr,slave,workdir) VALUES(' +
        QI(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) + ',' +
        Q(F[4]) + ',' + Q(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ',' +
        QI(F[8]) + ',' + QI(F[9]) + ',' + Q(F[10]) + ',' + Q(F[11]) + ',' +
        Q(F[12]) + ',' + QI(F[13]) + ',' + Q(F[14]) + ');', Err) then
        Exit;
      Inc(NT);
      if not HistAdd(FOrg, '(migration)', 'team', F[1], 'add', '', '', '', '',
        '{"id":' + QI(F[0]) + '}', False, Err) then
        Exit;
    end;
    for i := 0 to GroupRows.Count - 1 do
    begin
      F.DelimitedText := GroupRows[i];
      while F.Count < 4 do
        F.Add('');
      if not Exec(FOrg,
        'INSERT OR IGNORE INTO grp(name,project,boss) VALUES(' +
        Q(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) + ');', Err) then
        Exit;
      Mem.DelimitedText := F[3];
      for j := 0 to Mem.Count - 1 do
        if Trim(Mem[j]) <> '' then
          if not Exec(FOrg,
            'INSERT OR IGNORE INTO grp_member(grp,team,ord) VALUES(' +
            Q(F[0]) + ',' + Q(Trim(Mem[j])) + ',' + IntToStr(j) + ');',
            Err) then
            Exit;
      Inc(NG);
      if not HistAdd(FOrg, '(migration)', 'group', F[0], 'add', '', '', '', '',
        '{"members":"' + JsonEsc(F[3]) + '"}', False, Err) then
        Exit;
    end;
    for i := 0 to ProjectRows.Count - 1 do
    begin
      F.DelimitedText := ProjectRows[i];
      while F.Count < 2 do
        F.Add('');
      if not Exec(FOrg, 'INSERT OR IGNORE INTO project(name,boss) VALUES(' +
        Q(F[0]) + ',' + Q(F[1]) + ');', Err) then
        Exit;
      Inc(NP);
      if not HistAdd(FOrg, '(migration)', 'project', F[0], 'add', '', '', '',
        '', '{}', False, Err) then
        Exit;
    end;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    F.Free;
    Mem.Free;
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.MigrateTasks(const TaskRows, NoteRows: TStringList;
  out NT, NN: Integer; out Err: string): Boolean;
var
  i: Integer;
  F: TStringList;
  Tmp: string;
begin
  Result := False;
  NT := 0; NN := 0;
  if not Exec(FWork, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  F := TStringList.Create;
  try
    F.Delimiter := #1;
    F.StrictDelimiter := True;
    { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
      never consults that property (rtl/objpas/classes/stringl.inc:549-573), and
      QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a double
      quote was split internally, silently shifting EVERY following column. With
      #0, CheckQuoted always returns False (stringl.inc:556, aQuoteChar<>#0). }
    F.QuoteChar := #0;
    for i := 0 to TaskRows.Count - 1 do
    begin
      F.DelimitedText := TaskRows[i];
      while F.Count < 8 do
        F.Add('');
      if not Exec(FWork,
        'INSERT OR IGNORE INTO task(id,title,team,state,hito,parent,' +
        'created,closed) VALUES(' + QI(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) +
        ',' + Q(F[3]) + ',' + Q(F[4]) + ',' + QI(F[5]) + ',' + Q(F[6]) + ',' +
        Q(F[7]) + ');', Err) then
        Exit;
      Inc(NT);
    end;
      { NOTE TEXT MUST BE LAST. It is free text and may contain newlines or even
        the delimiter; preserve it exactly because a note is someone's evidence.
        While it remains the LAST column, an embedded delimiter can only append
        ignored fields. Adding a later column would silently corrupt rows, as
        once happened with task titles. Any new fields must go BEFORE the note. }
    for i := 0 to NoteRows.Count - 1 do
    begin
      F.DelimitedText := NoteRows[i];
      while F.Count < 4 do
        F.Add('');
      if not Exec(FWork,
        'INSERT INTO task_note(task_id,ts,by_who,text) VALUES(' +
        QI(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) + ');',
        Err) then
        Exit;
      Inc(NN);
    end;
    Result := Exec(FWork, 'COMMIT;', Err);
  finally
    F.Free;
    if not Result then
      Exec(FWork, 'ROLLBACK;', Tmp);
  end;
end;




function TPzDb.BackupTo(const OutDir: string; out Err: string): Boolean;

  function One(var Src: TPzDbFile; const FileName: string): Boolean;
  var
    Dst: psqlite3;
    B: psqlite3backup;
    P: AnsiString;
    rc: cint;
  begin
    Result := False;
    Dst := nil;
    P := IncludeTrailingPathDelimiter(OutDir) + FileName;
    if sqlite3_open_v2(PAnsiChar(P), @Dst,
      SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil) <> SQLITE_OK then
    begin
      Err := 'cannot create ' + FileName;
      if Dst <> nil then
        sqlite3_close(Dst);
      Exit;
    end;
    try
      B := sqlite3_backup_init(Dst, 'main', Src.Handle, 'main');
      if B = nil then
      begin
        Err := FileName + ': ' + string(sqlite3_errmsg(Dst));
        Exit;
      end;
        { Copy 256 pages at a time. If another thread writes, SQLite restarts
          the copy itself without blocking message delivery. }
      repeat
        rc := sqlite3_backup_step(B, 256);
      until (rc <> SQLITE_OK) and (rc <> 5) and (rc <> 6);
      sqlite3_backup_finish(B);
      if rc <> SQLITE_DONE then
      begin
        Err := FileName + ': incomplete copy (code ' + IntToStr(rc) + ')';
        Exit;
      end;
      Result := True;
    finally
      sqlite3_close(Dst);
    end;
  end;

begin
  Result := False;
  Err := '';
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not ForceDirectories(OutDir) then
  begin
    Err := 'cannot create ' + OutDir;
    Exit;
  end;
  FLock.Enter;
  try
    { Use the PHYSICAL FILE, not its alias. After migration FApps POINTS TO FOrg,
      so copying FApps here saved org.sqlite TWICE, once under the apps.sqlite
      name, and never captured the real file. A backup that misstates its content
      is worse than no backup because the defect appears only during restore. }
    if not One(FAppsViejo, 'apps.sqlite') then
      Exit;
    if not One(FOrg, 'org.sqlite') then
      Exit;
    if not One(FWork, 'work.sqlite') then
      Exit;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

{ KIND MAY BE A LIST. Since applications moved to org.sqlite, teams, groups,
  projects, and applications share both a history table and a name namespace.
  Filtering `tiza app history pizarra` only by subject mixed an application's
  history with same-named groups or projects, for example showing the group
  event `set members: -> frontend,api` in an application card. This is not
  cosmetic because `app undo` consumes snapshot numbers from that list.
  Kind therefore accepts comma-separated values: application events may be
  `app`, `appdoc`, or `appproject`. }
function TPzDb.HistList(var F: TPzDbFile; const Kind, Subject: string;
  Limit: Integer): TStringList;
var
  W, OneKind, KindList: string;
  p_: Integer;
  RemainingKinds: string;
begin
  W := '';
  if Kind <> '' then
  begin
    if Pos(',', Kind) = 0 then
      W := ' WHERE kind=' + Q(Kind)
    else
    begin
      KindList := '';
      RemainingKinds := Kind;
      while RemainingKinds <> '' do
      begin
        p_ := Pos(',', RemainingKinds);
        if p_ > 0 then
        begin
          OneKind := Trim(Copy(RemainingKinds, 1, p_ - 1));
          RemainingKinds := Copy(RemainingKinds, p_ + 1, Length(RemainingKinds));
        end
        else
        begin
          OneKind := Trim(RemainingKinds);
          RemainingKinds := '';
        end;
        if OneKind <> '' then
        begin
          if KindList <> '' then
            KindList := KindList + ',';
          KindList := KindList + Q(OneKind);
        end;
      end;
      W := ' WHERE kind IN (' + KindList + ')';
    end;
  end;
  if Subject <> '' then
  begin
    if W = '' then
      W := ' WHERE '
    else
      W := W + ' AND ';
    W := W + 'subject=' + Q(Subject);
  end;
  Result := Rows(F, 'SELECT snap,ts,who,op,field,COALESCE(oldval,''''),' +
    'COALESCE(newval,'''') FROM history' + W +
    ' ORDER BY snap DESC LIMIT ' + IntToStr(Limit));
end;

function TPzDb.HistGet(var F: TPzDbFile; Snap: Integer): string;
var
  R: TStringList;
begin
  Result := '';
  R := Rows(F, 'SELECT kind,subject,op,field,COALESCE(oldval,''''),' +
    'COALESCE(newval,''''),COALESCE(before,''''),' +
    'COALESCE(after,'''') FROM history WHERE snap=' + IntToStr(Snap));
  try
    if R.Count > 0 then
      Result := R[0];
  finally
    R.Free;
  end;
end;

function TPzDb.Rows(var F: TPzDbFile; const SQL: string): TStringList;
var
  A: AnsiString;
  St: psqlite3_stmt;
  P: PAnsiChar;
  Line: string;
  i, n: Integer;
begin
  Result := TStringList.Create;
  if (not FAvail) or (F.Handle = nil) then
    Exit;
  A := SQL;
  St := nil;
  FLock.Enter;
  try
    if sqlite3_prepare_v2(F.Handle, PAnsiChar(A), -1, @St, nil) <> SQLITE_OK then
      Exit;
    try
      n := sqlite3_column_count(St);
      while sqlite3_step(St) = SQLITE_ROW do
      begin
        Line := '';
        for i := 0 to n - 1 do
        begin
          if i > 0 then
            Line := Line + #1;
          P := sqlite3_column_text(St, i);
          if P <> nil then
            Line := Line + string(P);
        end;
        Result.Add(Line);
      end;
    finally
      sqlite3_finalize(St);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzDb.EnsureSchema(out Err: string): Boolean;
var
  Tmp: string;
begin
  Result := False;
  Err := '';
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not Exec(FAppsViejo, SQL_APPS + SQL_HISTORY, Err) then Exit;
  if not Exec(FOrg,  SQL_ORG  + SQL_HISTORY, Err) then Exit;
  { MOVE APPS BESIDE TEAMS, GROUPS, AND PROJECTS. The reason is structural and
    verified: foreign keys CANNOT cross databases; SQLite will not compile
    'REFERENCES other.table(col)'. While app lived in apps.sqlite and project in
    org.sqlite, their relationship could not cascade automatically. Together,
    the operator's rules become schema rather than code callers must remember:
    deleting an app clears its assignments, while deleting a project preserves
    every app. Do NOT delete apps.sqlite; retain it so rollback is a file copy. }
  if not Exec(FOrg, SQL_APPS, Err) then Exit;
  { Create the relationship now that both referenced tables share a database. }
  if not Exec(FOrg, SQL_APPPROJ, Err) then Exit;
  if MetaGet(FOrg, 'apps_en_org') <> '1' then
  begin
      { ATTACH works across databases even though foreign keys do not, so copy in
        ONE transaction on the destination database. OR IGNORE makes migration
        repeatable without duplicates: after interruption, the next run completes
        missing rows. Apps go BEFORE manuals because app_doc has an active foreign
        key to app. }
    if not Exec(FOrg,
      'ATTACH DATABASE ' + Q(FAppsViejo.Path) + ' AS vieja;' +
      'BEGIN IMMEDIATE;' +
      'INSERT OR IGNORE INTO app(name,team,repo,path,purpose,detail) ' +
      '  SELECT name,team,repo,path,purpose,detail FROM vieja.app;' +
      'INSERT OR IGNORE INTO app_doc(app,body,bytes,sha256,updated_ts,updated_by) ' +
      '  SELECT app,body,bytes,sha256,updated_ts,updated_by FROM vieja.app_doc;' +
      'INSERT INTO history(ts,who,kind,subject,op,field,oldval,newval,before,after,keep) ' +
      '  SELECT ts,who,kind,subject,op,field,oldval,newval,before,after,keep ' +
      '  FROM vieja.history WHERE kind IN (''app'',''appdoc'');' +
      'COMMIT;' +
      'DETACH DATABASE vieja;', Err) then
    begin
      { Do NOT mark a failed migration. Keep FApps at its original location so
        the hub continues serving apps instead of losing them. }
      Exec(FOrg, 'ROLLBACK;', Tmp);
      Exec(FOrg, 'DETACH DATABASE vieja;', Tmp);
      Exit;
    end;
    if not MetaSet(FOrg, 'apps_en_org', '1', Err) then Exit;
  end;
  { FROM HERE ON, apps belong to org.sqlite. One assignment redirects every FApps
    write; changing each call manually is how the critical one gets missed. }
  FApps := FOrg;
  FMudado := True;
  if not Exec(FWork, SQL_WORK + SQL_HISTORY, Err) then Exit;
  { Column added in 1.0.18: CREATE TABLE IF NOT EXISTS does not modify an
    existing table, so upgrade older databases explicitly here. }
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''team'') ' +
     'WHERE name=''slave''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE team ADD COLUMN slave INTEGER NOT NULL DEFAULT 0;',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''team'') ' +
     'WHERE name=''workdir''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE team ADD COLUMN workdir TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  { grp.muted added later: bases created before the broadcast-mute feature get
    the column here, same pattern as slave/workdir above }
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''muted''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN muted TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  Result := True;
end;

function TPzDb.MetaGet(var F: TPzDbFile; const K: string): string;
begin
  Result := QueryStr(F, 'SELECT v FROM meta WHERE k=' + Q(K));
end;

function TPzDb.MetaSet(var F: TPzDbFile; const K, V: string;
  out Err: string): Boolean;
begin
  Result := Exec(F, 'INSERT INTO meta(k,v) VALUES(' + Q(K) + ',' + Q(V) +
    ') ON CONFLICT(k) DO UPDATE SET v=excluded.v;', Err);
end;

function TPzDb.AppsDb: TPzDbFile;
begin
  Result := FApps;
end;

function TPzDb.OrgDb: TPzDbFile;
begin
  Result := FOrg;
end;

function TPzDb.WorkDb: TPzDbFile;
begin
  Result := FWork;
end;

procedure TPzDb.Lock;
begin
  FLock.Enter;
end;

procedure TPzDb.Unlock;
begin
  FLock.Leave;
end;

end.
