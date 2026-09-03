{ pzdb - SQLite access for the hub. Only pizarra uses this unit: tiza must not
  link it, and pzconfig must not depend on it, because the client is deployed
  across the fleet and should continue to depend only on libc.

  sqlite3dyn loads the library at RUNTIME with dlopen, so `ldd pizarra` is
  unchanged. SQLite is the registry authority, so the hub refuses to start if
  the library or authoritative database cannot be opened. The sqlite3,
  sqlite3ds, and sqlite3db units would create a hard link dependency and are
  not used.

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
  SysUtils, Classes, SyncObjs, BaseUnix, Unix, ctypes, sqlite3dyn, Types, pzconfig,
  pzlayout;

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
    function CloseOne(var F: TPzDbFile): Boolean;
    { Write one complete group row plus its ordered membership. The caller has
      already opened the transaction. }
    function GroupWrite(const Grp: TGroup; const Who, OldRow: string;
      out Err: string): Boolean;
  public
    constructor Create(const StoreDir: string);   { Never raises an exception. }
    destructor Destroy; override;

    { False when libsqlite3 or the private store is unavailable. The hub treats
      this as fatal because no partial INI registry exists after cutover. }
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
    function QueryStrChecked(var F: TPzDbFile; const SQL: string;
      out Value, Err: string): Boolean;
    function QueryInt(var F: TPzDbFile; const SQL: string; Def: Int64 = 0): Int64;
    { Checked scalar count/value for migration preflights. Unlike QueryInt it
      distinguishes a real zero from prepare/step failure. }
    function QueryIntChecked(var F: TPzDbFile; const SQL: string;
      out Value: Int64; out Err: string): Boolean;

    { Import declarations during the initial INI-to-SQLite cutover. It upserts
      but never deletes, preserving records from either side while the stores
      are reconciled. Once the caller records the authority marker, startup
      uses LoadRegistry instead and SQLite is authoritative. }
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
    { Atomically update every group touched by a team removal and then remove
      the team. Callers pass only the groups whose membership/boss changed. }
    function TeamRemoveWithGroups(Id: Integer; const Name, Who, OldRow: string;
      const Groups: TGroupArray; out Err: string): Boolean;
    function GroupUpsert(const Grp: TGroup; const Who, OldRow: string;
      out Err: string): Boolean;
    function GroupRemove(const Name, Who, OldRow: string; out Err: string): Boolean;
    function ProjectUpsert(const Name, Boss, Who, OldRow: string;
      out Err: string): Boolean;
    function ProjectDelete(const Name, Who: string; out Err: string): Boolean;
    function TaskDelete(Id: Integer; const Title, Who: string;
      out Err: string): Boolean;

    { One-time migration from files. Idempotent through both the
      meta['ini_migrated'] sentinel and INSERT OR IGNORE. }
    function MigrateApps(const Names, Teams, Repos, Paths, Purposes,
      Details, Docs, DocPresent: TStringList; out N, NDocs: Integer;
      out Err: string): Boolean;
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

    { Run a query and return rows with fields separated by #1. Each field is
      RowFieldEncode-framed when needed so embedded separators/control bytes
      cannot shift columns; consumers decode after splitting. }
    function Rows(var F: TPzDbFile; const SQL: string): TStringList;

    { Replace the four organization registries in Cfg from org.sqlite. This is
      deliberately a typed reader: registry text is never serialized through
      Rows/#1, so every SQLite column retains its own boundary. The caller must
      hold FCfgLock, preserving the documented lock order. }
    function LoadRegistry(var Cfg: TPizarraConfig; out Err: string): Boolean;

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
{ Reversible framing for the few compatibility/migration APIs that carry
  several fields in one #1-delimited string. Fields needing it use a long
  version marker; '%' and all control bytes are hex-escaped. Ordinary unmarked
  fields decode unchanged for old callers and fixtures. }
function RowFieldEncode(const S: string): string;
function RowFieldDecode(const S: string): string;
procedure DecodeRowFields(Fields: TStrings; const Indices: array of Integer);

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
var
  StartAt, P: Integer;
  Part: string;
begin
  { sqlite3_exec receives a NUL-terminated SQL string. Represent embedded NUL
    bytes as SQL char(0) expressions so they never truncate the statement. }
  Result := '';
  StartAt := 1;
  repeat
    P := Pos(#0, Copy(S, StartAt, Length(S)));
    if P > 0 then
      P := P + StartAt - 1;
    if P = 0 then
      Part := Copy(S, StartAt, Length(S) - StartAt + 1)
    else
      Part := Copy(S, StartAt, P - StartAt);
    if Result <> '' then
      Result := Result + '||';
    Result := Result + '''' + SqlQuote(Part) + '''';
    if P > 0 then
    begin
      Result := Result + '||char(0)';
      StartAt := P + 1;
    end;
  until P = 0;
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

function HexNibble(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function RowFieldEncode(const S: string): string;
const
  Hex: array[0..15] of Char = '0123456789ABCDEF';
  Marker = '~pizarra-row-v1~';
var
  i: Integer;
  C: Byte;
  NeedsEncoding: Boolean;
begin
  NeedsEncoding := Copy(S, 1, Length(Marker)) = Marker;
  for i := 1 to Length(S) do
  begin
    C := Ord(S[i]);
    if (C < 32) or (C = Ord('%')) or (C = 127) then
      NeedsEncoding := True;
  end;
  if not NeedsEncoding then
    Exit(S);
  Result := Marker;
  for i := 1 to Length(S) do
  begin
    C := Ord(S[i]);
    if (C < 32) or (C = Ord('%')) or (C = 127) then
      Result := Result + '%' + Hex[C shr 4] + Hex[C and $0f]
    else
      Result := Result + Char(C);
  end;
end;

function RowFieldDecode(const S: string): string;
const
  Marker = '~pizarra-row-v1~';
var
  i, H, L, p: Integer;
  Framed: Boolean;
begin
  if Copy(S, 1, Length(Marker)) <> Marker then
    Exit(S);
  { Old unframed callers may legitimately pass text beginning with the marker.
    Treat it as encoded only when the payload contains a valid escape (the
    reason ordinary data gets framed) or starts with a second marker (how the
    encoder disambiguates a literal marker prefix). }
  Framed := Copy(S, Length(Marker) + 1, Length(Marker)) = Marker;
  p := Length(Marker) + 1;
  while (not Framed) and (p + 2 <= Length(S)) do
  begin
    if (S[p] = '%') and (HexNibble(S[p + 1]) >= 0) and
       (HexNibble(S[p + 2]) >= 0) then
      Framed := True;
    Inc(p);
  end;
  if not Framed then
    Exit(S);
  Result := '';
  i := Length(Marker) + 1;
  while i <= Length(S) do
  begin
    if (S[i] = '%') and (i + 2 <= Length(S)) then
    begin
      H := HexNibble(S[i + 1]);
      L := HexNibble(S[i + 2]);
      if (H >= 0) and (L >= 0) then
      begin
        Result := Result + Char((H shl 4) or L);
        Inc(i, 3);
        Continue;
      end;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

procedure DecodeRowFields(Fields: TStrings; const Indices: array of Integer);
var
  i, Idx: Integer;
begin
  for i := 0 to High(Indices) do
  begin
    Idx := Indices[i];
    if (Idx >= 0) and (Idx < Fields.Count) then
      Fields[Idx] := RowFieldDecode(Fields[Idx]);
  end;
end;

function JsonEsc(const S: string): string;
const
  Hex: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
  C: Byte;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    C := Ord(S[i]);
    case C of
      8:  Result := Result + '\b';
      9:  Result := Result + '\t';
      10: Result := Result + '\n';
      12: Result := Result + '\f';
      13: Result := Result + '\r';
      34: Result := Result + '\"';
      92: Result := Result + '\\';
      0..7, 11, 14..31:
        Result := Result + '\u00' + Hex[C shr 4] + Hex[C and $0f];
    else
      Result := Result + Char(C);
    end;
  end;
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
  Err, CleanDir: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAvail := False;
  FWhy := '';
  FVer := '';
  CleanDir := Trim(StoreDir);
  while (Length(CleanDir) > 1) and
        (CleanDir[Length(CleanDir)] = PathDelim) do
    Delete(CleanDir, Length(CleanDir), 1);
  if (CleanDir = '') or (CleanDir = PathDelim) then
  begin
    FDir := '';
    FWhy := 'unsafe empty/root SQLite store directory';
    Exit;
  end;
  FDir := IncludeTrailingPathDelimiter(CleanDir);
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
  if not EnsurePrivateRuntimeDir(CleanDir, Err) then
  begin
    FAvail := False;
    FWhy := Err;
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
var
  ClosedAll: Boolean;
begin
  { Close the PHYSICAL handle. FApps becomes an ALIAS of FOrg after migration,
    so closing FApps here would close the same handle twice. }
  ClosedAll := CloseOne(FAppsViejo);
  ClosedAll := CloseOne(FOrg) and ClosedAll;
  ClosedAll := CloseOne(FWork) and ClosedAll;
  { FVer is assigned immediately after the dynamic library loads, even when a
    later open fails and Available becomes false. Never unload sqlite while a
    SQLITE_BUSY close has left a connection alive. }
  if (FVer <> '') and ClosedAll then
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
  { sqlite3_open_v2 creates a missing database as 0666 subject to umask.
    Protect the main file before PRAGMA journal_mode can create sidecars. The
    containing directory has already been verified mode 0700. }
  if FpChmod(F.Path, &600) <> 0 then
  begin
    Err := FileName + ': cannot protect database as mode 0600: ' +
      SysErrorMessage(fpgeterrno);
    sqlite3_close(F.Handle);
    F.Handle := nil;
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
  { journal_mode may have created sidecars. They are also credential-bearing;
    chmod those that exist and fail rather than silently leave a weak mode. }
  if FileExists(F.Path + '-wal') and (FpChmod(F.Path + '-wal', &600) <> 0) then
  begin
    Err := FileName + ': cannot protect WAL as mode 0600: ' +
      SysErrorMessage(fpgeterrno);
    Exit;
  end;
  if FileExists(F.Path + '-shm') and (FpChmod(F.Path + '-shm', &600) <> 0) then
  begin
    Err := FileName + ': cannot protect SHM as mode 0600: ' +
      SysErrorMessage(fpgeterrno);
    Exit;
  end;
  Result := True;
end;

function TPzDb.CloseOne(var F: TPzDbFile): Boolean;
var
  rc: cint;
begin
  Result := True;
  if F.Handle <> nil then
  begin
    rc := sqlite3_close(F.Handle);
    if rc = SQLITE_OK then
      F.Handle := nil
    else
    begin
      Result := False;
      Writeln(StdErr, 'pizarra: warning: SQLite close failed for ', F.Path,
        ' (code ', rc, '); keeping the dynamic library loaded');
    end;
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
          SetString(Result, P, sqlite3_column_bytes(St, 0));
      end;
    finally
      sqlite3_finalize(St);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzDb.QueryStrChecked(var F: TPzDbFile; const SQL: string;
  out Value, Err: string): Boolean;
var
  S: AnsiString;
  St: psqlite3_stmt;
  P: PAnsiChar;
  rc: cint;
begin
  Result := False;
  Value := '';
  Err := '';
  if (not FAvail) or (F.Handle = nil) then
  begin
    Err := 'SQLite unavailable';
    Exit;
  end;
  S := SQL;
  St := nil;
  FLock.Enter;
  try
    rc := sqlite3_prepare_v2(F.Handle, PAnsiChar(S), -1, @St, nil);
    if rc <> SQLITE_OK then
    begin
      Err := string(sqlite3_errmsg(F.Handle));
      Exit;
    end;
    try
      rc := sqlite3_step(St);
      if rc <> SQLITE_ROW then
      begin
        if rc = SQLITE_DONE then
          Err := 'query returned no row'
        else
          Err := string(sqlite3_errmsg(F.Handle));
        Exit;
      end;
      P := sqlite3_column_text(St, 0);
      if P <> nil then
        SetString(Value, P, sqlite3_column_bytes(St, 0));
      Result := True;
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

function TPzDb.QueryIntChecked(var F: TPzDbFile; const SQL: string;
  out Value: Int64; out Err: string): Boolean;
var
  S: AnsiString;
  St: psqlite3_stmt;
  rc: cint;
begin
  Result := False;
  Value := 0;
  Err := '';
  if (not FAvail) or (F.Handle = nil) then
  begin
    Err := 'SQLite unavailable';
    Exit;
  end;
  S := SQL;
  St := nil;
  FLock.Enter;
  try
    rc := sqlite3_prepare_v2(F.Handle, PAnsiChar(S), -1, @St, nil);
    if rc <> SQLITE_OK then
    begin
      Err := string(sqlite3_errmsg(F.Handle));
      Exit;
    end;
    try
      rc := sqlite3_step(St);
      if rc <> SQLITE_ROW then
      begin
        if rc = SQLITE_DONE then
          Err := 'query returned no row'
        else
          Err := string(sqlite3_errmsg(F.Handle));
        Exit;
      end;
      Value := sqlite3_column_int64(St, 0);
      Result := True;
    finally
      sqlite3_finalize(St);
    end;
  finally
    FLock.Leave;
  end;
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
    '  workdir TEXT NOT NULL DEFAULT '''',' +
    '  delegate TEXT NOT NULL DEFAULT '''',' +
    '  hold_when_blocked INTEGER NOT NULL DEFAULT 0);' +
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
    '  muted TEXT NOT NULL DEFAULT '''',' +
    '  on_idle TEXT NOT NULL DEFAULT '''',' +
    '  on_idle_msg TEXT NOT NULL DEFAULT '''',' +
    '  on_idle_from TEXT NOT NULL DEFAULT '''',' +
    '  on_idle_reply TEXT NOT NULL DEFAULT '''',' +
    '  hdr_note TEXT NOT NULL DEFAULT '''',' +
    '  on_block TEXT NOT NULL DEFAULT '''');' +
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


{ Every migration receives caller-extracted data. Compatibility row APIs use
  #1 only between RowFieldEncode-framed values, so legal JSON control bytes do
  not flatten or shift columns. }

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
    DecodeRowFields(F, [1, 2, 3, 4, 6, 7]);
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
      PreviousRole := RowFieldDecode(PreviousRows[0]);
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
var
  i: Integer;
begin
  Result := Rows(FOrg, 'SELECT project || char(9) || role FROM app_project ' +
    'WHERE app=' + Q(App_) + ' ORDER BY project COLLATE NOCASE;');
  for i := 0 to Result.Count - 1 do
    Result[i] := RowFieldDecode(Result[i]);
end;

function TPzDb.AppsOfProject(const Project_: string): TStringList;
var
  i: Integer;
begin
  Result := Rows(FOrg, 'SELECT app || char(9) || role FROM app_project ' +
    'WHERE project=' + Q(Project_) + ' ORDER BY app COLLATE NOCASE;');
  for i := 0 to Result.Count - 1 do
    Result[i] := RowFieldDecode(Result[i]);
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
    { id,name,speciality,prompt,parent,project,secret,host,port,dial,
      tmux_session,launch,usr,slave,workdir,delegate,hold_when_blocked }
    while F.Count < 17 do
      F.Add('');
    DecodeRowFields(F, [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 15]);
    if not Exec(FOrg, 'BEGIN IMMEDIATE;', Err) then
      Exit;
    try
      if not Exec(FOrg,
        'INSERT INTO team(id,name,speciality,prompt,parent,project,secret,' +
        'host,port,dial,tmux_session,launch,usr,slave,workdir,delegate,' +
        'hold_when_blocked) VALUES(' + QI(F[0]) + ',' +
        Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) + ',' + Q(F[4]) + ',' +
        Q(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ',' + QI(F[8]) + ',' + QI(F[9]) +
        ',' + Q(F[10]) + ',' + Q(F[11]) + ',' + Q(F[12]) + ',' + QI(F[13]) +
        ',' + Q(F[14]) + ',' + Q(F[15]) + ',' +
        IntToStr(StrToIntDef(Trim(F[16]), 0)) + ')' +
        ' ON CONFLICT(id) DO UPDATE SET name=excluded.name,' +
        'speciality=excluded.speciality,prompt=excluded.prompt,' +
        'parent=excluded.parent,project=excluded.project,' +
        'secret=excluded.secret,host=excluded.host,port=excluded.port,' +
        'dial=excluded.dial,tmux_session=excluded.tmux_session,' +
        'launch=excluded.launch,usr=excluded.usr,slave=excluded.slave,' +
        'workdir=excluded.workdir,delegate=excluded.delegate,' +
        'hold_when_blocked=excluded.hold_when_blocked;', Err) then
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

function TPzDb.TeamRemoveWithGroups(Id: Integer;
  const Name, Who, OldRow: string; const Groups: TGroupArray;
  out Err: string): Boolean;
var
  i: Integer;
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
    { GroupWrite has no transaction of its own: every changed group, its
      ordered member rows, every audit record, and the team deletion therefore
      commit (or roll back) as one indivisible organization mutation. }
    for i := 0 to High(Groups) do
      if not GroupWrite(Groups[i], Who, '', Err) then
        Exit;
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

function TPzDb.GroupWrite(const Grp: TGroup; const Who, OldRow: string;
  out Err: string): Boolean;
var
  i: Integer;
  Members, Excluded, AfterRow: string;
begin
  Result := False;
  Members := '';
  for i := 0 to High(Grp.Members) do
  begin
    if Members <> '' then
      Members := Members + ',';
    Members := Members + Grp.Members[i];
  end;
  Excluded := '';
  for i := 0 to High(Grp.Excluded) do
  begin
    if Excluded <> '' then
      Excluded := Excluded + ',';
    Excluded := Excluded + Grp.Excluded[i];
  end;

  if not Exec(FOrg,
    'INSERT INTO grp(name,project,boss,muted,on_idle,on_idle_msg,' +
    'on_idle_from,on_idle_reply,hdr_note,on_block) VALUES(' +
    Q(Grp.Name) + ',' + Q(Grp.Project) + ',' + Q(Grp.Boss) + ',' +
    Q(Excluded) + ',' + Q(Grp.OnIdle) + ',' + Q(Grp.OnIdleMsg) + ',' +
    Q(Grp.OnIdleFrom) + ',' + Q(Grp.OnIdleReply) + ',' + Q(Grp.HdrNote) +
    ',' + Q(Grp.OnBlock) + ')' +
    ' ON CONFLICT(name) DO UPDATE SET project=excluded.project,' +
    'boss=excluded.boss,muted=excluded.muted,on_idle=excluded.on_idle,' +
    'on_idle_msg=excluded.on_idle_msg,on_idle_from=excluded.on_idle_from,' +
    'on_idle_reply=excluded.on_idle_reply,hdr_note=excluded.hdr_note,' +
    'on_block=excluded.on_block;', Err) then
    Exit;
  if not Exec(FOrg, 'DELETE FROM grp_member WHERE grp=' + Q(Grp.Name) + ';',
    Err) then
    Exit;
  for i := 0 to High(Grp.Members) do
    if Trim(Grp.Members[i]) <> '' then
      if not Exec(FOrg,
        'INSERT OR IGNORE INTO grp_member(grp,team,ord) VALUES(' +
        Q(Grp.Name) + ',' + Q(Trim(Grp.Members[i])) + ',' + IntToStr(i) + ');',
        Err) then
        Exit;

  AfterRow := '{"project":"' + JsonEsc(Grp.Project) + '","boss":"' +
    JsonEsc(Grp.Boss) + '","members":"' + JsonEsc(Members) +
    '","excluded":"' + JsonEsc(Excluded) + '","on_idle":"' +
    JsonEsc(Grp.OnIdle) + '","on_idle_msg":"' + JsonEsc(Grp.OnIdleMsg) +
    '","on_idle_from":"' + JsonEsc(Grp.OnIdleFrom) +
    '","on_idle_reply":"' + JsonEsc(Grp.OnIdleReply) +
    '","hdr_note":"' + JsonEsc(Grp.HdrNote) + '","on_block":"' +
    JsonEsc(Grp.OnBlock) + '"}';
  Result := HistAdd(FOrg, Who, 'group', Grp.Name, 'set', 'members', OldRow,
    Members, OldRow, AfterRow, False, Err);
end;

function TPzDb.GroupUpsert(const Grp: TGroup; const Who, OldRow: string;
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
    if not GroupWrite(Grp, Who, OldRow, Err) then
      Exit;
    Result := Exec(FOrg, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FOrg, 'ROLLBACK;', Tmp);
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
  F, Mem: TStringList;
  Keep, Tmp: string;
begin
  Result := False;
  N := 0;
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
      Keep := '';
      for i := 0 to TeamRows.Count - 1 do
      begin
        F.DelimitedText := TeamRows[i];
        while F.Count < 17 do
          F.Add('');
        DecodeRowFields(F, [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 15]);
        if Keep <> '' then
          Keep := Keep + ',';
        Keep := Keep + F[0];
        { OpenRegistryDb has already proved that every overlapping legacy row
          is byte-for-byte compatible. Existing rows may therefore be filled
          with the newly-added policy columns without overwriting a conflict. }
        if QueryStr(FOrg, 'SELECT 1 FROM team WHERE name=' + Q(F[1])) <> '' then
        begin
          if not Exec(FOrg, 'UPDATE team SET speciality=' + Q(F[2]) +
            ',prompt=' + Q(F[3]) + ',parent=' + Q(F[4]) + ',project=' +
            Q(F[5]) + ',secret=' + Q(F[6]) + ',host=' + Q(F[7]) + ',port=' +
            QI(F[8]) + ',dial=' + QI(F[9]) + ',tmux_session=' + Q(F[10]) +
            ',launch=' + Q(F[11]) + ',usr=' + Q(F[12]) + ',slave=' +
            QI(F[13]) + ',workdir=' + Q(F[14]) + ',delegate=' + Q(F[15]) +
            ',hold_when_blocked=' + IntToStr(StrToIntDef(Trim(F[16]), 0)) +
            ' WHERE name=' + Q(F[1]) + ';', Err) then
            Exit;
          Continue;
        end;
        { Never infer a rename and never assign a different numeric identity.
          A name/ID collision means two sources disagree; the preflight rejects
          it, and the UNIQUE constraint is the final guard. }
        Tmp := F[0];
        if not Exec(FOrg,
          'INSERT INTO team(id,name,speciality,prompt,parent,project,secret,' +
          'host,port,dial,tmux_session,launch,usr,slave,workdir,delegate,' +
          'hold_when_blocked) VALUES(' + QI(Tmp) + ',' +
          Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[3]) + ',' + Q(F[4]) + ',' +
          Q(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ',' + QI(F[8]) + ',' + QI(F[9]) +
          ',' + Q(F[10]) + ',' + Q(F[11]) + ',' + Q(F[12]) + ',' + QI(F[13]) +
          ',' + Q(F[14]) + ',' + Q(F[15]) + ',' +
          IntToStr(StrToIntDef(Trim(F[16]), 0)) + ');', Err) then
          Exit;
        Inc(N);
      end;

      Keep := '';
      for i := 0 to GroupRows.Count - 1 do
      begin
        F.DelimitedText := GroupRows[i];
        { name,project,boss,members,excluded,on_idle,on_idle_msg,on_idle_from,
          on_idle_reply,hdr_note,on_block }
        while F.Count < 11 do
          F.Add('');
        DecodeRowFields(F, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        if Keep <> '' then
          Keep := Keep + ',';
        Keep := Keep + Q(F[0]);
        if not Exec(FOrg,
          'INSERT INTO grp(name,project,boss,muted,on_idle,on_idle_msg,' +
          'on_idle_from,on_idle_reply,hdr_note,on_block) VALUES(' +
          Q(F[0]) + ',' + Q(F[1]) + ',' + Q(F[2]) + ',' + Q(F[4]) + ',' +
          Q(F[5]) + ',' + Q(F[6]) + ',' + Q(F[7]) + ',' + Q(F[8]) + ',' +
          Q(F[9]) + ',' + Q(F[10]) + ')' +
          ' ON CONFLICT(name) DO UPDATE SET project=excluded.project,' +
          'boss=excluded.boss,muted=excluded.muted,on_idle=excluded.on_idle,' +
          'on_idle_msg=excluded.on_idle_msg,on_idle_from=excluded.on_idle_from,' +
          'on_idle_reply=excluded.on_idle_reply,hdr_note=excluded.hdr_note,' +
          'on_block=excluded.on_block;', Err) then
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
        DecodeRowFields(F, [0, 1]);
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
  end;
end;

function TPzDb.MigrateApps(const Names, Teams, Repos, Paths, Purposes,
  Details, Docs, DocPresent: TStringList; out N, NDocs: Integer;
  out Err: string): Boolean;
var
  i: Integer;
  Tmp, ExistingBody: string;
  Inserted: Boolean;
  Count: Int64;
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
      Inserted := QueryInt(FApps, 'SELECT changes();') > 0;
      if Inserted then
      begin
        Inc(N);
        if not HistAdd(FApps, '(migration)', 'app', Names[i], 'add', '', '', '',
          '', '{"team":"' + JsonEsc(Teams[i]) + '"}', False, Err) then
          Exit;
      end;
      if (i < DocPresent.Count) and (DocPresent[i] = '1') then
      begin
        if not QueryIntChecked(FApps,
          'SELECT COUNT(*) FROM app_doc WHERE app=' + Q(Names[i]) + ';',
          Count, Err) then
          Exit;
        if Count = 0 then
        begin
          if not Exec(FApps,
            'INSERT INTO app_doc(app,body,bytes,updated_ts,updated_by)' +
            ' VALUES(' + Q(Names[i]) + ',' + Q(Docs[i]) + ',' +
            IntToStr(Length(Docs[i])) + ',' +
            Q(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)) + ',' +
            Q('(migration)') + ');', Err) then
            Exit;
          Inc(NDocs);
        end
        else
        begin
          if not QueryStrChecked(FApps,
            'SELECT body FROM app_doc WHERE app=' + Q(Names[i]) + ';',
            ExistingBody, Err) then
            Exit;
          if ExistingBody <> Docs[i] then
          begin
            { app_doc in SQLite was already the live manual source before this
              registry cutover. Keep it current, but move a divergent legacy
              appdocs/*.md body into the SAME SQLite history so consolidation
              loses neither version. The exact-row guard makes retries quiet. }
            if not QueryIntChecked(FApps,
              'SELECT COUNT(*) FROM history WHERE kind=''appdoc'' AND subject=' +
              Q(Names[i]) + ' AND op=''legacy-archive'' AND before=' +
              Q(ExistingBody) + ' AND after=' + Q(Docs[i]) + ';', Count, Err) then
              Exit;
            if Count = 0 then
            begin
              if not HistAdd(FApps, '(migration)', 'appdoc', Names[i],
                'legacy-archive', 'body',
                IntToStr(Length(ExistingBody)) + ' bytes',
                IntToStr(Length(Docs[i])) + ' bytes', ExistingBody, Docs[i],
                True, Err) then
                Exit;
              Inc(NDocs);
            end;
          end;
        end;
      end;
    end;
    Result := Exec(FApps, 'COMMIT;', Err);
  finally
    if not Result then
      Exec(FApps, 'ROLLBACK;', Tmp);
  end;
end;

function TPzDb.MigrateTasks(const TaskRows, NoteRows: TStringList;
  out NT, NN: Integer; out Err: string): Boolean;
var
  i, Idx, TaskId: Integer;
  F, SeenKeys, SeenCounts: TStringList;
  Tmp, Key: string;
  Existing, ExactCount, Desired: Int64;
begin
  Result := False;
  NT := 0; NN := 0;
  if not Exec(FWork, 'BEGIN IMMEDIATE;', Err) then
    Exit;
  F := TStringList.Create;
  SeenKeys := TStringList.Create;
  SeenCounts := TStringList.Create;
  try
    SeenKeys.CaseSensitive := True;
    { Recheck under the write transaction. Two simultaneous cold starts may
      both have observed a missing marker before the first committed. }
    if MetaGet(FWork, 'ini_migrated') <> '' then
    begin
      Result := Exec(FWork, 'COMMIT;', Err);
      Exit;
    end;
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
      DecodeRowFields(F, [1, 2, 3, 4, 6, 7]);
      if (not TryStrToInt(Trim(F[0]), TaskId)) or (TaskId <= 0) then
      begin
        Err := 'legacy task has invalid id "' + F[0] + '"';
        Exit;
      end;
      if not QueryIntChecked(FWork, 'SELECT COUNT(*) FROM task WHERE id=' +
        IntToStr(TaskId) + ';', Existing, Err) then
        Exit;
      if Existing > 0 then
      begin
        { A partial pre-marker work.sqlite is legitimate migration input too.
          Preserve an exact overlap, but never attach JSON notes to a different
          task merely because INSERT OR IGNORE hid an ID collision. Explicit
          BINARY overrides the team's NOCASE column for byte-faithful proof. }
        if not QueryIntChecked(FWork,
          'SELECT COUNT(*) FROM task WHERE id=' + IntToStr(TaskId) +
          ' AND title COLLATE BINARY=' + Q(F[1]) +
          ' AND team COLLATE BINARY=' + Q(F[2]) +
          ' AND state COLLATE BINARY=' + Q(F[3]) +
          ' AND hito COLLATE BINARY=' + Q(F[4]) +
          ' AND parent=' + QI(F[5]) +
          ' AND created COLLATE BINARY=' + Q(F[6]) +
          ' AND closed COLLATE BINARY=' + Q(F[7]) + ';', ExactCount, Err) then
          Exit;
        if ExactCount <> 1 then
        begin
          Err := 'legacy task id ' + IntToStr(TaskId) +
            ' conflicts with the existing SQLite task; nothing was migrated';
          Exit;
        end;
      end
      else
      begin
        if not Exec(FWork,
          'INSERT INTO task(id,title,team,state,hito,parent,created,closed) ' +
          'VALUES(' + IntToStr(TaskId) + ',' + Q(F[1]) + ',' + Q(F[2]) + ',' +
          Q(F[3]) + ',' + Q(F[4]) + ',' + QI(F[5]) + ',' + Q(F[6]) + ',' +
          Q(F[7]) + ');', Err) then
          Exit;
        Inc(NT);
      end;
    end;
    { Notes use RowFieldEncode/Decode, so newlines, #1, NUL, and future fields
      retain exact byte boundaries. }
    for i := 0 to NoteRows.Count - 1 do
    begin
      F.DelimitedText := NoteRows[i];
      while F.Count < 4 do
        F.Add('');
      DecodeRowFields(F, [1, 2, 3]);
      if (not TryStrToInt(Trim(F[0]), TaskId)) or (TaskId <= 0) then
      begin
        Err := 'legacy task note has invalid task id "' + F[0] + '"';
        Exit;
      end;
      { Reconcile note multiplicity, not merely presence: two byte-identical
        notes in tareas.json remain two notes, while a retry over a partial DB
        does not duplicate either one. }
      Key := IntToStr(TaskId) + #1 + RowFieldEncode(F[1]) + #1 +
        RowFieldEncode(F[2]) + #1 + RowFieldEncode(F[3]);
      Idx := SeenKeys.IndexOf(Key);
      if Idx < 0 then
      begin
        SeenKeys.Add(Key);
        SeenCounts.Add('1');
        Desired := 1;
      end
      else
      begin
        Desired := StrToInt64Def(SeenCounts[Idx], 0) + 1;
        SeenCounts[Idx] := IntToStr(Desired);
      end;
      if not QueryIntChecked(FWork,
        'SELECT COUNT(*) FROM task_note WHERE task_id=' + IntToStr(TaskId) +
        ' AND ts COLLATE BINARY=' + Q(F[1]) +
        ' AND by_who COLLATE BINARY=' + Q(F[2]) +
        ' AND text COLLATE BINARY=' + Q(F[3]) + ';', Existing, Err) then
        Exit;
      if Existing < Desired then
      begin
        if not Exec(FWork,
          'INSERT INTO task_note(task_id,ts,by_who,text) VALUES(' +
          IntToStr(TaskId) + ',' + Q(F[1]) + ',' + Q(F[2]) + ',' +
          Q(F[3]) + ');', Err) then
          Exit;
        Inc(NN);
      end;
    end;
    { The marker shares this transaction with every task and note. A crash can
      no longer commit notes and miss the marker, which duplicated all notes on
      the next startup. }
    if not MetaSet(FWork, 'ini_migrated',
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), Err) then
      Exit;
    Result := Exec(FWork, 'COMMIT;', Err);
  finally
    SeenCounts.Free;
    SeenKeys.Free;
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
    H, ErrNo, Retries: Integer;
    rc, FinishRc, CloseRc: cint;
  begin
    Result := False;
    Dst := nil;
    B := nil;
    P := IncludeTrailingPathDelimiter(OutDir) + FileName;
    if FileExists(string(P)) then
    begin
      Err := 'refusing to overwrite backup file ' + string(P);
      Exit;
    end;
    if sqlite3_open_v2(PAnsiChar(P), @Dst,
      SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil) <> SQLITE_OK then
    begin
      Err := 'cannot create ' + FileName;
      if Dst <> nil then
        sqlite3_close(Dst);
      Exit;
    end;
    try
      if FpChmod(string(P), &600) <> 0 then
      begin
        ErrNo := fpgeterrno;
        Err := FileName + ': cannot protect backup as mode 0600: ' +
          SysErrorMessage(ErrNo);
        Exit;
      end;
      sqlite3_busy_timeout(Dst, 5000);
      B := sqlite3_backup_init(Dst, 'main', Src.Handle, 'main');
      if B = nil then
      begin
        Err := FileName + ': ' + string(sqlite3_errmsg(Dst));
        Exit;
      end;
      { Copy 256 pages at a time. SQLITE_BUSY/LOCKED means retry later, not a
        tight spin; cap the wait so a stuck writer cannot hang the hub. }
      Retries := 0;
      repeat
        rc := sqlite3_backup_step(B, 256);
        if (rc = SQLITE_BUSY) or (rc = SQLITE_LOCKED) then
        begin
          Inc(Retries);
          if Retries > 500 then
            Break;
          Sleep(10);
        end
        else
          Retries := 0;
      until (rc <> SQLITE_OK) and (rc <> SQLITE_BUSY) and
            (rc <> SQLITE_LOCKED);
      FinishRc := sqlite3_backup_finish(B);
      B := nil;
      if (rc <> SQLITE_DONE) or (FinishRc <> SQLITE_OK) then
      begin
        Err := FileName + ': incomplete copy (step ' + IntToStr(rc) +
          ', finish ' + IntToStr(FinishRc) + ')';
        Exit;
      end;
      Result := True;
    finally
      if B <> nil then
        sqlite3_backup_finish(B);
      CloseRc := sqlite3_close(Dst);
      if CloseRc <> SQLITE_OK then
      begin
        sqlite3_close_v2(Dst);
        Result := False;
        Err := FileName + ': sqlite close failed (code ' +
          IntToStr(CloseRc) + ')';
      end;
      if not Result then
        DeleteFile(string(P));
    end;
    if not Result then
      Exit;
    if FpChmod(string(P), &600) <> 0 then
    begin
      Err := FileName + ': could not retain mode 0600 after backup';
      DeleteFile(string(P));
      Exit(False);
    end;
    H := FpOpen(string(P), O_RDONLY);
    if H < 0 then
    begin
      Err := FileName + ': cannot reopen completed backup for fsync';
      DeleteFile(string(P));
      Exit(False);
    end;
    try
      if PzFsync(H) <> 0 then
      begin
        Err := FileName + ': fsync failed: ' + SysErrorMessage(fpgeterrno);
        DeleteFile(string(P));
        Exit(False);
      end;
    finally
      FpClose(H);
    end;
  end;

  function SyncOutDir: Boolean;
  var
    H, ErrNo: Integer;
  begin
    Result := False;
    H := PzOpenDirFd(OutDir);
    if H < 0 then
    begin
      ErrNo := fpgeterrno;
      Err := 'cannot open backup directory for fsync: ' +
        SysErrorMessage(ErrNo);
      Exit;
    end;
    try
      if PzFsync(H) <> 0 then
      begin
        ErrNo := fpgeterrno;
        Err := 'cannot fsync backup directory: ' + SysErrorMessage(ErrNo);
        Exit;
      end;
    finally
      FpClose(H);
    end;
    Result := True;
  end;

begin
  Result := False;
  Err := '';
  if not FAvail then
  begin
    Err := FWhy;
    Exit;
  end;
  if not EnsurePrivateRuntimeDir(OutDir, Err) then
    Exit;
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
    if not SyncOutDir then
      Exit;
    { fsyncing OutDir persists its children; fsyncing the parent persists the
      OutDir name itself when this backup directory was just created. }
    if not PzSyncDirectory(ExtractFileDir(ExpandFileName(OutDir)), Err) then
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
  Line, Part: string;
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
            SetString(Part, P, sqlite3_column_bytes(St, i))
          else
            Part := '';
          Line := Line + RowFieldEncode(Part);
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

function TPzDb.LoadRegistry(var Cfg: TPizarraConfig;
  out Err: string): Boolean;
var
  NewTeams: TTeamArray;
  NewGroups: TGroupArray;
  NewProjects: TProjectArray;
  NewApps: TAppArray;
  St: psqlite3_stmt;
  rc: cint;
  n, i, Idx, PortV: Integer;
  IdV: Int64;
  Csv, AppName, RelName: string;
  Parts: TStringArray;

  function ColText(ASt: psqlite3_stmt; Col: Integer): string;
  var
    P: PAnsiChar;
  begin
    P := sqlite3_column_text(ASt, Col);
    if P = nil then
      Result := ''
    else
      SetString(Result, P, sqlite3_column_bytes(ASt, Col));
  end;

  function PrepareStmt(const SQL, What: string;
    out ASt: psqlite3_stmt): Boolean;
  var
    A: AnsiString;
  begin
    ASt := nil;
    A := SQL;
    Result := sqlite3_prepare_v2(FOrg.Handle, PAnsiChar(A), -1, @ASt,
      nil) = SQLITE_OK;
    if not Result then
      Err := 'load registry (' + What + '): ' +
        string(sqlite3_errmsg(FOrg.Handle));
  end;

  function StepComplete(Code: cint; const What: string): Boolean;
  begin
    Result := Code = SQLITE_DONE;
    if not Result then
      Err := 'load registry (' + What + '): ' +
        string(sqlite3_errmsg(FOrg.Handle));
  end;

  function GroupIndex(const Name: string): Integer;
  var
    k: Integer;
  begin
    for k := 0 to High(NewGroups) do
      if SameText(NewGroups[k].Name, Name) then
        Exit(k);
    Result := -1;
  end;

  function AppIndex(const Name: string): Integer;
  var
    k: Integer;
  begin
    for k := 0 to High(NewApps) do
      if SameText(NewApps[k].Name, Name) then
        Exit(k);
    Result := -1;
  end;

begin
  Result := False;
  Err := '';
  if (not FAvail) or (FOrg.Handle = nil) then
  begin
    if FWhy <> '' then
      Err := FWhy
    else
      Err := 'SQLite unavailable';
    Exit;
  end;
  NewTeams := nil;
  NewGroups := nil;
  NewProjects := nil;
  NewApps := nil;

  { Hold the database lock across the complete projection. Apart from keeping
    prepared statements private, this prevents another operation on this
    connection from interleaving between registry tables. The caller holds
    FCfgLock, so the established FCfgLock -> FLock order remains intact. }
  FLock.Enter;
  try
    try
      if not PrepareStmt(
        'SELECT id,name,speciality,prompt,parent,project,secret,host,port,dial,' +
        'tmux_session,launch,usr,slave,workdir,delegate,hold_when_blocked ' +
        'FROM team ORDER BY id;', 'teams', St) then
        Exit;
      try
        rc := sqlite3_step(St);
        while rc = SQLITE_ROW do
        begin
          n := Length(NewTeams);
          SetLength(NewTeams, n + 1);
          IdV := sqlite3_column_int64(St, 0);
          if (IdV < Low(Integer)) or (IdV > High(Integer)) then
          begin
            Err := 'load registry (teams): id outside Integer range';
            Exit;
          end;
          NewTeams[n].Id := Integer(IdV);
          NewTeams[n].Name := ColText(St, 1);
          NewTeams[n].Speciality := ColText(St, 2);
          NewTeams[n].Prompt := ColText(St, 3);
          NewTeams[n].Parent := ColText(St, 4);
          NewTeams[n].Project := ColText(St, 5);
          NewTeams[n].Secret := ColText(St, 6);
          NewTeams[n].Host := ColText(St, 7);
          PortV := sqlite3_column_int(St, 8);
          if (PortV < 0) or (PortV > High(Word)) then
          begin
            Err := 'load registry (teams): invalid port for ' +
              NewTeams[n].Name;
            Exit;
          end;
          NewTeams[n].Port := Word(PortV);
          NewTeams[n].Dial := sqlite3_column_int(St, 9) <> 0;
          NewTeams[n].TmuxSession := ColText(St, 10);
          NewTeams[n].Launch := ColText(St, 11);
          NewTeams[n].User := ColText(St, 12);
          NewTeams[n].Slave := sqlite3_column_int(St, 13) <> 0;
          NewTeams[n].Workdir := ColText(St, 14);
          NewTeams[n].Delegate := ColText(St, 15);
          NewTeams[n].HoldBlocked := sqlite3_column_int(St, 16) <> 0;
          rc := sqlite3_step(St);
        end;
        if not StepComplete(rc, 'teams') then
          Exit;
      finally
        sqlite3_finalize(St);
      end;

      if not PrepareStmt(
        'SELECT name,project,boss,muted,on_idle,on_idle_msg,on_idle_from,' +
        'on_idle_reply,hdr_note,on_block FROM grp ORDER BY name COLLATE NOCASE;',
        'groups', St) then
        Exit;
      try
        rc := sqlite3_step(St);
        while rc = SQLITE_ROW do
        begin
          n := Length(NewGroups);
          SetLength(NewGroups, n + 1);
          NewGroups[n].Name := ColText(St, 0);
          NewGroups[n].Project := ColText(St, 1);
          NewGroups[n].Boss := ColText(St, 2);
          Csv := ColText(St, 3);
          Parts := SplitList(Csv);
          SetLength(NewGroups[n].Excluded, Length(Parts));
          for i := 0 to High(Parts) do
            NewGroups[n].Excluded[i] := Parts[i];
          NewGroups[n].OnIdle := ColText(St, 4);
          NewGroups[n].OnIdleMsg := ColText(St, 5);
          NewGroups[n].OnIdleFrom := ColText(St, 6);
          NewGroups[n].OnIdleReply := ColText(St, 7);
          NewGroups[n].HdrNote := ColText(St, 8);
          NewGroups[n].OnBlock := ColText(St, 9);
          rc := sqlite3_step(St);
        end;
        if not StepComplete(rc, 'groups') then
          Exit;
      finally
        sqlite3_finalize(St);
      end;

      if not PrepareStmt(
        'SELECT grp,team FROM grp_member ' +
        'ORDER BY grp COLLATE NOCASE,ord,team COLLATE NOCASE;',
        'group members', St) then
        Exit;
      try
        rc := sqlite3_step(St);
        while rc = SQLITE_ROW do
        begin
          RelName := ColText(St, 0);
          Idx := GroupIndex(RelName);
          if Idx < 0 then
          begin
            Err := 'load registry (group members): orphan group ' + RelName;
            Exit;
          end;
          n := Length(NewGroups[Idx].Members);
          SetLength(NewGroups[Idx].Members, n + 1);
          NewGroups[Idx].Members[n] := ColText(St, 1);
          rc := sqlite3_step(St);
        end;
        if not StepComplete(rc, 'group members') then
          Exit;
      finally
        sqlite3_finalize(St);
      end;

      if not PrepareStmt(
        'SELECT name,boss FROM project ORDER BY name COLLATE NOCASE;',
        'projects', St) then
        Exit;
      try
        rc := sqlite3_step(St);
        while rc = SQLITE_ROW do
        begin
          n := Length(NewProjects);
          SetLength(NewProjects, n + 1);
          NewProjects[n].Name := ColText(St, 0);
          NewProjects[n].Boss := ColText(St, 1);
          rc := sqlite3_step(St);
        end;
        if not StepComplete(rc, 'projects') then
          Exit;
      finally
        sqlite3_finalize(St);
      end;

      if not PrepareStmt(
        'SELECT a.name,a.team,a.repo,a.path,a.purpose,a.detail,' +
        'EXISTS(SELECT 1 FROM app_doc d WHERE d.app=a.name AND d.bytes>0) ' +
        'FROM app a ORDER BY a.name COLLATE NOCASE;', 'apps', St) then
        Exit;
      try
        rc := sqlite3_step(St);
        while rc = SQLITE_ROW do
        begin
          n := Length(NewApps);
          SetLength(NewApps, n + 1);
          NewApps[n].Name := ColText(St, 0);
          NewApps[n].Team := ColText(St, 1);
          NewApps[n].Repo := ColText(St, 2);
          NewApps[n].Path := ColText(St, 3);
          NewApps[n].Purpose := ColText(St, 4);
          NewApps[n].Detail := ColText(St, 5);
          NewApps[n].HasDoc := sqlite3_column_int(St, 6) <> 0;
          NewApps[n].Projects := '';
          rc := sqlite3_step(St);
        end;
        if not StepComplete(rc, 'apps') then
          Exit;
      finally
        sqlite3_finalize(St);
      end;

      if not PrepareStmt(
        'SELECT app,project FROM app_project ' +
        'ORDER BY app COLLATE NOCASE,project COLLATE NOCASE;',
        'app projects', St) then
        Exit;
      try
        rc := sqlite3_step(St);
        while rc = SQLITE_ROW do
        begin
          AppName := ColText(St, 0);
          Idx := AppIndex(AppName);
          if Idx < 0 then
          begin
            Err := 'load registry (app projects): orphan app ' + AppName;
            Exit;
          end;
          if NewApps[Idx].Projects <> '' then
            NewApps[Idx].Projects := NewApps[Idx].Projects + ',';
          NewApps[Idx].Projects := NewApps[Idx].Projects + ColText(St, 1);
          rc := sqlite3_step(St);
        end;
        if not StepComplete(rc, 'app projects') then
          Exit;
      finally
        sqlite3_finalize(St);
      end;
    except
      on E: Exception do
      begin
        Err := 'load registry: ' + E.Message;
        Exit;
      end;
    end;
  finally
    FLock.Leave;
  end;

  { Publication happens only after every table and relationship has loaded.
    All bootstrap/network/log/header settings in Cfg remain untouched. }
  Cfg.Teams := NewTeams;
  Cfg.Groups := NewGroups;
  Cfg.Projects := NewProjects;
  Cfg.Apps := NewApps;
  Result := True;
end;

function TPzDb.EnsureSchema(out Err: string): Boolean;
var
  Tmp: string;
  Count: Int64;
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
    { ATTACH works across databases even though foreign keys do not. Refuse a
      divergent overlap before OR IGNORE can silently choose one version. The
      physical legacy database and mandatory pre-cutover backup remain intact
      for an operator-led reconciliation. }
    if not Exec(FOrg, 'ATTACH DATABASE ' + Q(FAppsViejo.Path) + ' AS vieja;',
      Err) then
      Exit;
    if not QueryIntChecked(FOrg,
      'SELECT COUNT(*) FROM vieja.app v JOIN main.app o ON v.name=o.name ' +
      'WHERE v.team COLLATE BINARY<>o.team COLLATE BINARY ' +
      'OR v.repo COLLATE BINARY<>o.repo COLLATE BINARY ' +
      'OR v.path COLLATE BINARY<>o.path COLLATE BINARY ' +
      'OR v.purpose COLLATE BINARY<>o.purpose COLLATE BINARY ' +
      'OR v.detail COLLATE BINARY<>o.detail COLLATE BINARY;', Count, Err) then
    begin
      Exec(FOrg, 'DETACH DATABASE vieja;', Tmp);
      Exit;
    end;
    if Count > 0 then
    begin
      Err := IntToStr(Count) + ' application row(s) differ between apps.sqlite ' +
        'and org.sqlite; refusing an automatic choice';
      Exec(FOrg, 'DETACH DATABASE vieja;', Tmp);
      Exit;
    end;
    if not QueryIntChecked(FOrg,
      'SELECT COUNT(*) FROM vieja.app_doc v JOIN main.app_doc o ON v.app=o.app ' +
      'WHERE v.body COLLATE BINARY<>o.body COLLATE BINARY OR v.bytes<>o.bytes ' +
      'OR v.sha256 COLLATE BINARY<>o.sha256 COLLATE BINARY ' +
      'OR v.updated_ts COLLATE BINARY<>o.updated_ts COLLATE BINARY ' +
      'OR v.updated_by COLLATE BINARY<>o.updated_by COLLATE BINARY;', Count,
      Err) then
    begin
      Exec(FOrg, 'DETACH DATABASE vieja;', Tmp);
      Exit;
    end;
    if Count > 0 then
    begin
      Err := IntToStr(Count) + ' manual row(s) differ between apps.sqlite and ' +
        'org.sqlite; refusing an automatic choice';
      Exec(FOrg, 'DETACH DATABASE vieja;', Tmp);
      Exit;
    end;
    { Apps go before manuals because app_doc has an active foreign key to app.
      The authority marker shares the transaction with rows and history: after
      any crash either none of them committed or startup will never recopy. }
    if not Exec(FOrg,
      'BEGIN IMMEDIATE;' +
      'INSERT OR IGNORE INTO app(name,team,repo,path,purpose,detail) ' +
      '  SELECT name,team,repo,path,purpose,detail FROM vieja.app;' +
      'INSERT OR IGNORE INTO app_doc(app,body,bytes,sha256,updated_ts,updated_by) ' +
      '  SELECT app,body,bytes,sha256,updated_ts,updated_by FROM vieja.app_doc;' +
      'INSERT INTO history(ts,who,kind,subject,op,field,oldval,newval,before,after,keep) ' +
      '  SELECT ts,who,kind,subject,op,field,oldval,newval,before,after,keep ' +
      '  FROM vieja.history WHERE kind IN (''app'',''appdoc'');' +
      'INSERT INTO meta(k,v) VALUES(''apps_en_org'',''1'') ' +
      '  ON CONFLICT(k) DO UPDATE SET v=excluded.v;' +
      'COMMIT;' +
      'DETACH DATABASE vieja;', Err) then
    begin
      { Do NOT mark a failed migration. Keep FApps at its original location so
        the hub continues serving apps instead of losing them. }
      Exec(FOrg, 'ROLLBACK;', Tmp);
      Exec(FOrg, 'DETACH DATABASE vieja;', Tmp);
      Exit;
    end;
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
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''team'') ' +
     'WHERE name=''delegate''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE team ADD COLUMN delegate TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''team'') ' +
     'WHERE name=''hold_when_blocked''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE team ADD COLUMN hold_when_blocked INTEGER NOT NULL DEFAULT 0;',
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
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''on_idle''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN on_idle TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''on_idle_msg''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN on_idle_msg TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''on_idle_from''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN on_idle_from TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''on_idle_reply''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN on_idle_reply TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''hdr_note''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN hdr_note TEXT NOT NULL DEFAULT '''';',
      Err) then
      Exit;
  if QueryStr(FOrg, 'SELECT COUNT(*) FROM pragma_table_info(''grp'') ' +
     'WHERE name=''on_block''') = '0' then
    if not Exec(FOrg,
      'ALTER TABLE grp ADD COLUMN on_block TEXT NOT NULL DEFAULT '''';',
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
