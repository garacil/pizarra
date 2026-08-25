{ pzlayout - canonical Unix paths and secure first-run initialization.

  Runtime configuration is never discovered in the source tree. The hub may
  create the canonical configuration on its first implicit start; explicit
  paths and environment overrides are resolved by pzconfig and never reach the
  bootstrap below. }
unit pzlayout;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, BaseUnix, Unix{$IFDEF LINUX}, Linux{$ENDIF};

const
  PZ_CONFIG_DIR          = '/etc/pizarra';
  PZ_STATE_DIR           = '/var/lib/pizarra';
  PZ_RELEASE_DIR         = PZ_STATE_DIR + '/releases';
  PZ_LOG_DIR             = '/var/log/pizarra';
  PZ_WEB_ASSETS_DIR      = '/usr/local/share/pizarra/web/apps';
  PZ_HUB_CONFIG_PATH     = PZ_CONFIG_DIR + '/pizarra.conf';
  PZ_TIZA_CONFIG_PATH    = PZ_CONFIG_DIR + '/tiza.conf';
  PZ_WEB_CONFIG_PATH     = PZ_CONFIG_DIR + '/pzweb.conf';
  PZ_TIZA_STATE_PATH     = PZ_STATE_DIR + '/tiza.state';
  PZ_HUB_LOCK_NAME       = '.pizarra-hub.lock';

function PzDefaultConfigPath(const BaseName: string): string;

{ BaseUnix.FpFsync is a single raw syscall in FPC 3.2.2. Retry only EINTR so
  durable writes do not fail spuriously when a signal interrupts fsync. }
function PzFsync(Fd: Integer): Integer;
function PzSyncDirectory(const Path: string; out Why: string): Boolean;

{ Open a credential-bearing INI for reading without following symbolic links.
  Every ancestor is checked before the open; group/other-writable ancestors are
  rejected except for a root-owned sticky directory such as /tmp. The final
  file must be regular and mode 0600 exactly. The caller owns Handle. }
function PzOpenPrivateConfig(const Path: string; out Handle: Integer;
  out ResolvedPath, Why: string): Boolean;

{ Hold one non-blocking exclusive flock for the complete lifetime of a hub or
  restore operation. A listening-port probe alone has a race: the hub opens
  SQLite before it starts listening. The lock file itself remains in the
  store; ownership is represented by the open locked descriptor, not by the
  mere presence of its pathname. }
function PzAcquireHubStoreLock(const StoreDir: string; CreateIfMissing: Boolean;
  out Handle: Integer; out Why: string): Boolean;
procedure PzReleaseHubStoreLock(var Handle: Integer);

{ Validate or create a state directory that may contain credentials. Existing
  directories must not grant any group/other access; newly created directories
  are mode 0700. This is public so SQLite applies the same rule to custom
  [store] paths, not just to the canonical first-run layout. A privileged
  restore may explicitly validate a stopped dedicated-user store without
  becoming its runtime owner; normal hub/database callers may not. }
function EnsurePrivateRuntimeDir(const Path: string; out Why: string;
  ProbeWritable: Boolean = True; AllowCreate: Boolean = True;
  AllowRootForeignOwner: Boolean = False): Boolean;

{ Testable implementation of the secure first-run bootstrap. Production calls
  it only through BootstrapDefaultHub with the constants above; explicit paths
  let the regression suite exercise the identical filesystem operations below
  a private temporary root. }
function BootstrapHubLayout(const ConfigDir, StateDir, LogDir: string;
  out Why: string): Boolean;

{ Create the canonical hub/client configuration and runtime directories,
  including mode-0700 releases/. Nothing existing is overwritten. The two
  files receive the same freshly generated secret and mode 0600. The hub file
  is published last and therefore acts as the completed-bootstrap marker. }
function BootstrapDefaultHub(out Why: string): Boolean;

implementation

function ErrText(ErrNo: Integer): string;
begin
  Result := SysErrorMessage(ErrNo) + ' (errno ' + IntToStr(ErrNo) + ')';
end;

function PzFsync(Fd: Integer): Integer;
begin
  repeat
    Result := FpFsync(Fd);
  until (Result = 0) or (fpgeterrno <> ESysEINTR);
end;

function PzDefaultConfigPath(const BaseName: string): string;
begin
  if SameText(BaseName, 'pizarra.conf') then
    Result := PZ_HUB_CONFIG_PATH
  else if SameText(BaseName, 'tiza.conf') then
    Result := PZ_TIZA_CONFIG_PATH
  else if SameText(BaseName, 'pzweb.conf') then
    Result := PZ_WEB_CONFIG_PATH
  else
    Result := PZ_CONFIG_DIR + '/' + ExtractFileName(BaseName);
end;

function HasDotPathComponent(const Path: string): Boolean;
var
  Wrapped: string;
begin
  Wrapped := '/' + Path + '/';
  Result := (Pos('/./', Wrapped) > 0) or (Pos('/../', Wrapped) > 0);
end;

function PzOpenPrivateConfig(const Path: string; out Handle: Integer;
  out ResolvedPath, Why: string): Boolean;
var
  Full, Acc, Part: string;
  StartAt, StopAt, Flags, ErrNo: Integer;
  BeforeOpen, AfterOpen: TStat;
  IsFinal, UnsafeWritable, SafeSticky: Boolean;
begin
  Result := False;
  Handle := -1;
  ResolvedPath := '';
  Why := '';
  BeforeOpen := Default(TStat);
  if Trim(Path) = '' then
  begin
    Why := 'configuration path is empty';
    Exit;
  end;
  if HasDotPathComponent(Path) then
  begin
    Why := Path + ' contains a . or .. component';
    Exit;
  end;
  Full := ExpandFileName(Path);
  if (Full = '') or (Full[1] <> PathDelim) then
  begin
    Why := 'cannot normalize configuration path ' + Path;
    Exit;
  end;

  Acc := '';
  StartAt := 2;
  while StartAt <= Length(Full) do
  begin
    StopAt := StartAt;
    while (StopAt <= Length(Full)) and (Full[StopAt] <> PathDelim) do
      Inc(StopAt);
    Part := Copy(Full, StartAt, StopAt - StartAt);
    if Part <> '' then
    begin
      Acc := Acc + PathDelim + Part;
      IsFinal := StopAt > Length(Full);
      BeforeOpen := Default(TStat);
      if FpLStat(Acc, BeforeOpen) <> 0 then
      begin
        Why := 'cannot inspect configuration path ' + Acc + ': ' +
          ErrText(fpgeterrno);
        Exit;
      end;
      if fpS_ISLNK(BeforeOpen.st_mode) then
      begin
        Why := 'configuration path contains a symbolic link: ' + Acc;
        Exit;
      end;
      if not IsFinal then
      begin
        if not fpS_ISDIR(BeforeOpen.st_mode) then
        begin
          Why := 'configuration ancestor is not a directory: ' + Acc;
          Exit;
        end;
        UnsafeWritable := (BeforeOpen.st_mode and (S_IWGRP or S_IWOTH)) <> 0;
        SafeSticky := ((BeforeOpen.st_mode and S_ISVTX) <> 0) and
          (BeforeOpen.st_uid = 0);
        if UnsafeWritable and not SafeSticky then
        begin
          Why := 'configuration ancestor is writable by group/other users: ' + Acc;
          Exit;
        end;
      end
      else
      begin
        if (not fpS_ISREG(BeforeOpen.st_mode)) or
           ((BeforeOpen.st_mode and &777) <> &600) then
        begin
          Why := 'credential configuration must be a regular mode-0600 file: ' + Acc;
          Exit;
        end;
      end;
    end;
    StartAt := StopAt + 1;
  end;

  Flags := O_RDONLY;
  {$IFDEF LINUX}
  Flags := Flags or O_NOFOLLOW or O_CLOEXEC;
  {$ENDIF}
  repeat
    Handle := FpOpen(Full, Flags);
  until (Handle >= 0) or (fpgeterrno <> ESysEINTR);
  if Handle < 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot securely open credential configuration ' + Full + ': ' +
      ErrText(ErrNo);
    Exit;
  end;
  AfterOpen := Default(TStat);
  if (FpFStat(Handle, AfterOpen) <> 0) or
     (not fpS_ISREG(AfterOpen.st_mode)) or
     ((AfterOpen.st_mode and &777) <> &600) or
     (AfterOpen.st_dev <> BeforeOpen.st_dev) or
     (AfterOpen.st_ino <> BeforeOpen.st_ino) then
  begin
    Why := 'credential configuration changed or became unsafe while opening: ' + Full;
    FpClose(Handle);
    Handle := -1;
    Exit;
  end;
  ResolvedPath := Full;
  Result := True;
end;

function EnsureDir(const Path: string; CreateMode: Cardinal;
  PrivateContents, AllowCreate, AllowRootForeignOwner: Boolean;
  out Why: string): Boolean;
var
  Clean: string;
  St: TStat;
  ErrNo: Integer;
  UnsafeMask: Cardinal;
begin
  Result := False;
  Why := '';
  Clean := Trim(Path);
  { FPC's ExcludeTrailingPathDelimiter removes only one separator. Normalize
    all of them so `link//` cannot turn lstat into a symlink-following lookup. }
  while (Length(Clean) > 1) and (Clean[Length(Clean)] = PathDelim) do
    Delete(Clean, Length(Clean), 1);
  if (Clean = '') or (Clean = PathDelim) then
  begin
    Why := 'refusing unsafe runtime directory path "' + Path + '"';
    Exit;
  end;
  St := Default(TStat);
  if FpLStat(Clean, St) = 0 then
  begin
    if fpS_ISLNK(St.st_mode) then
    begin
      Why := Clean + ' is a symbolic link; refusing first-run initialization';
      Exit;
    end;
    if not fpS_ISDIR(St.st_mode) then
    begin
      Why := Clean + ' exists but is not a directory';
      Exit;
    end;
    if PrivateContents and (St.st_uid <> FpGeteuid) and
       not (AllowRootForeignOwner and (FpGeteuid = 0)) then
    begin
      Why := Clean + ' is owned by uid ' + IntToStr(St.st_uid) +
        ', not the runtime uid ' + IntToStr(FpGeteuid);
      Exit;
    end;
    if PrivateContents then
      UnsafeMask := &077
    else
      UnsafeMask := S_IWGRP or S_IWOTH;
    if (St.st_mode and UnsafeMask) <> 0 then
    begin
      if PrivateContents then
        Why := Clean + ' grants group/other access; protect it as mode 0700'
      else
        Why := Clean + ' is writable by group or other users';
      Exit;
    end;
    Result := True;
    Exit;
  end;
  ErrNo := fpgeterrno;
  if ErrNo <> ESysENOENT then
  begin
    Why := 'cannot inspect ' + Clean + ': ' + ErrText(ErrNo);
    Exit;
  end;
  if not AllowCreate then
  begin
    Why := 'required runtime directory does not exist: ' + Clean;
    Exit;
  end;
  if not ForceDirectories(Clean) then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot create ' + Clean + ': ' + ErrText(ErrNo);
    Exit;
  end;
  { ForceDirectories uses 0777 subject to umask in FPC 3.2.2. Protect the
    final directory before any secret or SQLite file is created in it. }
  if (FpLStat(Clean, St) <> 0) or fpS_ISLNK(St.st_mode) or
     (not fpS_ISDIR(St.st_mode)) then
  begin
    Why := 'new runtime path is not a real directory: ' + Clean;
    Exit;
  end;
  if PrivateContents and (St.st_uid <> FpGeteuid) and
     not (AllowRootForeignOwner and (FpGeteuid = 0)) then
  begin
    Why := 'new runtime directory ' + Clean + ' is not owned by uid ' +
      IntToStr(FpGeteuid);
    Exit;
  end;
  if FpChmod(Clean, CreateMode) <> 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot protect new directory ' + Clean + ': ' + ErrText(ErrNo);
    Exit;
  end;
  Result := True;
end;

function ProbeDirectoryWrite(const Path: string; out Why: string): Boolean; forward;

function EnsurePrivateRuntimeDir(const Path: string; out Why: string;
  ProbeWritable, AllowCreate, AllowRootForeignOwner: Boolean): Boolean;
begin
  Result := EnsureDir(Path, &700, True, AllowCreate, AllowRootForeignOwner,
    Why);
  if Result and ProbeWritable then
    Result := ProbeDirectoryWrite(Path, Why);
end;

function EnsureConfigDir(const Path: string; out Why: string): Boolean;
begin
  { 0711 permits separately-owned pizarra, tiza, and pzweb files to be opened
    by their service accounts without exposing directory listings. Each
    credential file is itself created mode 0600. }
  Result := EnsureDir(Path, &711, False, True, False, Why);
end;

function ProbeDirectoryWrite(const Path: string; out Why: string): Boolean;
var
  Probe: string;
  H, ErrNo: Integer;
begin
  Result := False;
  Probe := IncludeTrailingPathDelimiter(Path) +
    '.pizarra-first-run-write-test-' + IntToStr(FpGetpid);
  H := FpOpen(Probe, O_WRONLY or O_CREAT or O_EXCL, &600);
  if H < 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot create private runtime files in ' + Path + ': ' +
      ErrText(ErrNo);
    Exit;
  end;
  FpClose(H);
  if not DeleteFile(Probe) then
  begin
    Why := 'created a permission probe but cannot remove it: ' + Probe;
    Exit;
  end;
  Result := True;
end;

function ReadRandomSecret(out Secret, Why: string): Boolean;
const
  HEX: array[0..15] of Char = '0123456789abcdef';
var
  H, Got, N, i, ErrNo: Integer;
  B: array[0..31] of Byte;
begin
  Result := False;
  Secret := '';
  Why := '';
  H := FpOpen('/dev/urandom', O_RDONLY);
  if H < 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot open the operating-system random source: ' + ErrText(ErrNo);
    Exit;
  end;
  Got := 0;
  try
    while Got < SizeOf(B) do
    begin
      repeat
        N := FpRead(H, B[Got], SizeOf(B) - Got);
      until (N >= 0) or (fpgeterrno <> ESysEINTR);
      if N <= 0 then
      begin
        ErrNo := fpgeterrno;
        Why := 'cannot read the operating-system random source: ' +
          ErrText(ErrNo);
        Exit;
      end;
      Inc(Got, N);
    end;
  finally
    FpClose(H);
  end;
  SetLength(Secret, SizeOf(B) * 2);
  for i := 0 to High(B) do
  begin
    Secret[i * 2 + 1] := HEX[B[i] shr 4];
    Secret[i * 2 + 2] := HEX[B[i] and $0f];
    B[i] := 0;
  end;
  Result := True;
end;

function WriteExclusive(const Path, Content: string; out Why: string): Boolean;
var
  H, Done, N, ErrNo: Integer;
  Complete: Boolean;
begin
  Result := False;
  Complete := False;
  H := FpOpen(Path, O_WRONLY or O_CREAT or O_EXCL, &600);
  if H < 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot create ' + Path + ': ' + ErrText(ErrNo);
    Exit;
  end;
  try
    Done := 0;
    while Done < Length(Content) do
    begin
      repeat
        N := FpWrite(H, Content[Done + 1], Length(Content) - Done);
      until (N >= 0) or (fpgeterrno <> ESysEINTR);
      if N <= 0 then
      begin
        ErrNo := fpgeterrno;
        Why := 'cannot write ' + Path + ': ' + ErrText(ErrNo);
        Exit;
      end;
      Inc(Done, N);
    end;
    if PzFsync(H) <> 0 then
    begin
      ErrNo := fpgeterrno;
      Why := 'cannot sync ' + Path + ': ' + ErrText(ErrNo);
      Exit;
    end;
    Complete := True;
  finally
    FpClose(H);
    if not Complete then
      DeleteFile(Path);
  end;
  if FpChmod(Path, &600) <> 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot protect ' + Path + ' as mode 0600: ' + ErrText(ErrNo);
    DeleteFile(Path);
    Exit;
  end;
  Result := True;
end;

function PzSyncDirectory(const Path: string; out Why: string): Boolean;
var
  H, ErrNo: Integer;
begin
  Result := False;
  H := FpOpen(Path, O_RDONLY or O_DIRECTORY);
  if H < 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot open directory ' + Path + ' for fsync: ' + ErrText(ErrNo);
    Exit;
  end;
  try
    if PzFsync(H) <> 0 then
    begin
      ErrNo := fpgeterrno;
      Why := 'cannot fsync directory ' + Path + ': ' + ErrText(ErrNo);
      Exit;
    end;
  finally
    FpClose(H);
  end;
  Result := True;
end;

function PzAcquireHubStoreLock(const StoreDir: string; CreateIfMissing: Boolean;
  out Handle: Integer; out Why: string): Boolean;
var
  Clean, LockPath: string;
  St: TStat;
  CreateFd, ErrNo, OpenFlags, LockRc: Integer;
begin
  Result := False;
  Handle := -1;
  Why := '';
  Clean := Trim(StoreDir);
  while (Length(Clean) > 1) and (Clean[Length(Clean)] = PathDelim) do
    Delete(Clean, Length(Clean), 1);
  if not CreateIfMissing then
  begin
    St := Default(TStat);
    if FpLStat(Clean, St) <> 0 then
    begin
      Why := 'cannot inspect existing state directory ' + Clean + ': ' +
        ErrText(fpgeterrno);
      Exit;
    end;
  end;
  if not EnsurePrivateRuntimeDir(Clean, Why, CreateIfMissing,
    CreateIfMissing, not CreateIfMissing) then
    Exit;
  if not CreateIfMissing then
  begin
    St := Default(TStat);
    if (FpLStat(Clean, St) <> 0) or
       ((St.st_mode and S_IRWXU) <> S_IRWXU) then
    begin
      Why := 'existing state directory must grant its owner mode 0700: ' + Clean;
      Exit;
    end;
  end;
  LockPath := IncludeTrailingPathDelimiter(Clean) + PZ_HUB_LOCK_NAME;

  St := Default(TStat);
  if FpLStat(LockPath, St) <> 0 then
  begin
    ErrNo := fpgeterrno;
    if ErrNo <> ESysENOENT then
    begin
      Why := 'cannot inspect hub store lock ' + LockPath + ': ' +
        ErrText(ErrNo);
      Exit;
    end;
    if not CreateIfMissing then
    begin
      Why := 'hub store lock is missing: ' + LockPath +
        ' (run the new pizarra --migrate-only once before restore)';
      Exit;
    end;
    repeat
      OpenFlags := O_RDWR or O_CREAT or O_EXCL;
      {$IFDEF LINUX}OpenFlags := OpenFlags or O_CLOEXEC;{$ENDIF}
      CreateFd := FpOpen(LockPath, OpenFlags, &600);
    until (CreateFd >= 0) or (fpgeterrno <> ESysEINTR);
    if CreateFd >= 0 then
    begin
      FpClose(CreateFd);
      { Persist the inode name before another process relies on it for mutual
        exclusion. A concurrent creator may win instead; EEXIST is expected. }
      if not PzSyncDirectory(Clean, Why) then
        Exit;
    end
    else if fpgeterrno <> ESysEEXIST then
    begin
      Why := 'cannot create hub store lock ' + LockPath + ': ' +
        ErrText(fpgeterrno);
      Exit;
    end;
  end;

  St := Default(TStat);
  if (FpLStat(LockPath, St) <> 0) or fpS_ISLNK(St.st_mode) or
     (not fpS_ISREG(St.st_mode)) or
     ((St.st_uid <> FpGeteuid) and (FpGeteuid <> 0)) then
  begin
    Why := 'unsafe hub store lock (must be a regular file owned by runtime uid): ' +
      LockPath;
    Exit;
  end;
  if CreateIfMissing and (FpChmod(LockPath, &600) <> 0) then
  begin
    Why := 'cannot protect hub store lock ' + LockPath + ': ' +
      ErrText(fpgeterrno);
    Exit;
  end;
  if (not CreateIfMissing) and ((St.st_mode and &777) <> &600) then
  begin
    Why := 'existing hub store lock must already be mode 0600: ' + LockPath;
    Exit;
  end;
  { Call flock directly and reject EVERY error. FPC 3.2.2 FileOpen's share
    emulation deliberately ignores ENOLCK/ENOTSUP, which is acceptable for an
    advisory convenience but not for the restore corruption barrier. CLOEXEC
    prevents tmux/TProcess children from keeping the lock after the hub dies. }
  OpenFlags := O_RDWR;
  {$IFDEF LINUX}OpenFlags := OpenFlags or O_CLOEXEC;{$ENDIF}
  repeat
    Handle := FpOpen(LockPath, OpenFlags);
  until (Handle >= 0) or (fpgeterrno <> ESysEINTR);
  if Handle < 0 then
  begin
    Why := 'cannot open hub store lock ' + LockPath + ': ' +
      ErrText(fpgeterrno);
    Exit;
  end;
  repeat
    LockRc := FpFlock(Handle, LOCK_EX or LOCK_NB);
  until (LockRc = 0) or (fpgeterrno <> ESysEINTR);
  if LockRc <> 0 then
  begin
    ErrNo := fpgeterrno;
    FpClose(Handle);
    Handle := -1;
    Why := 'state directory is already in use, or its filesystem cannot ' +
      'provide the required exclusive lock: ' + Clean + ': ' + ErrText(ErrNo);
    Exit;
  end;
  Result := True;
end;

procedure PzReleaseHubStoreLock(var Handle: Integer);
begin
  if Handle >= 0 then
  begin
    { Do not retry close after EINTR on Linux: the descriptor may already have
      been released and reused. Process exit is the final fallback. }
    FpClose(Handle);
    Handle := -1;
  end;
end;

function PublishExclusive(const Tmp, Dest: string; out Why: string): Boolean;
var
  ErrNo: Integer;
  Dir, IgnoreWhy: string;
begin
  Result := False;
  Dir := ExtractFileDir(Dest);
  { Verify directory syncing is supported before publishing the first durable
    credential name. }
  if not PzSyncDirectory(Dir, Why) then
    Exit;
  { link(), unlike rename(), cannot replace a configuration that appeared
    concurrently. Tmp and Dest are in the same canonical directory. }
  if FpLink(Tmp, Dest) <> 0 then
  begin
    ErrNo := fpgeterrno;
    Why := 'cannot publish ' + Dest + ' without overwriting it: ' +
      ErrText(ErrNo);
    Exit;
  end;
  if not PzSyncDirectory(Dir, Why) then
  begin
    DeleteFile(Dest);
    PzSyncDirectory(Dir, IgnoreWhy);
    Exit;
  end;
  if not DeleteFile(Tmp) then
  begin
    DeleteFile(Dest);
    PzSyncDirectory(Dir, IgnoreWhy);
    Why := 'published ' + Dest + ' but could not remove its private staging ' +
      'link; rolled the destination back';
    Exit;
  end;
  if not PzSyncDirectory(Dir, Why) then
  begin
    DeleteFile(Dest);
    PzSyncDirectory(Dir, IgnoreWhy);
    Exit;
  end;
  Result := True;
end;

function BootstrapHubLayout(const ConfigDir, StateDir, LogDir: string;
  out Why: string): Boolean;
var
  ConfigRoot, StateRoot, LogRoot, ReleaseRoot: string;
  HubConfigPath, TizaConfigPath, TizaStatePath: string;
  LockPath, HubTmp, TizaTmp, Secret, HubText, TizaText: string;
  LockFd, ErrNo: Integer;
  HubTmpOwned, TizaTmpOwned, TizaPublished: Boolean;

  function NormalizeRoot(const Value, LabelText: string;
    out Clean: string): Boolean;
  begin
    Result := False;
    Clean := Trim(Value);
    while (Length(Clean) > 1) and (Clean[Length(Clean)] = PathDelim) do
      Delete(Clean, Length(Clean), 1);
    if (Clean = '') or (Clean[1] <> PathDelim) then
    begin
      Why := LabelText + ' must be an absolute directory path';
      Exit;
    end;
    if HasDotPathComponent(Clean) then
    begin
      Why := LabelText + ' contains a . or .. path component: ' + Clean;
      Exit;
    end;
    Result := True;
  end;
begin
  Result := False;
  Why := '';
  HubTmpOwned := False;
  TizaTmpOwned := False;
  TizaPublished := False;
  if not NormalizeRoot(ConfigDir, 'configuration root', ConfigRoot) then Exit;
  if not NormalizeRoot(StateDir, 'state root', StateRoot) then Exit;
  if not NormalizeRoot(LogDir, 'log root', LogRoot) then Exit;
  ReleaseRoot := StateRoot + '/releases';
  HubConfigPath := ConfigRoot + '/pizarra.conf';
  TizaConfigPath := ConfigRoot + '/tiza.conf';
  TizaStatePath := StateRoot + '/tiza.state';
  { Ensure the complete canonical skeleton even when an administrator already
    supplied pizarra.conf. Previously that early return left the database and
    log parents to ForceDirectories, which FPC creates as 0777 masked by umask. }
  if not EnsureConfigDir(ConfigRoot, Why) then Exit;
  if not EnsurePrivateRuntimeDir(StateRoot, Why) then Exit;
  if not EnsurePrivateRuntimeDir(ReleaseRoot, Why) then Exit;
  if not EnsurePrivateRuntimeDir(LogRoot, Why) then Exit;
  if FileExists(HubConfigPath) then
    Exit(True);
  if not ProbeDirectoryWrite(ConfigRoot, Why) then Exit;

  LockPath := ConfigRoot + '/.first-run.lock';
  LockFd := FpOpen(LockPath, O_WRONLY or O_CREAT or O_EXCL, &600);
  if LockFd < 0 then
  begin
    ErrNo := fpgeterrno;
    if (ErrNo = ESysEEXIST) and FileExists(HubConfigPath) then
      Exit(True);
    Why := 'cannot acquire the first-run lock ' + LockPath + ': ' +
      ErrText(ErrNo) + '. If no initialization is running, inspect and remove ' +
      'the stale lock, then start pizarra again.';
    Exit;
  end;
  FpClose(LockFd);
  try
    { Recheck after acquiring the lock. }
    if FileExists(HubConfigPath) then
    begin
      Result := True;
      Exit;
    end;
    if FileExists(TizaConfigPath) then
    begin
      Why := TizaConfigPath + ' already exists while ' +
        HubConfigPath + ' does not. Refusing to overwrite a client ' +
        'identity: restore/create the hub config explicitly or move the ' +
        'orphaned tiza config aside after inspecting it.';
      Exit;
    end;
    if not ReadRandomSecret(Secret, Why) then Exit;

    HubText :=
      '; Created securely by pizarra on first start.' + LineEnding +
      '; Runtime registries and mutable state live in SQLite below /var/lib.' + LineEnding +
      LineEnding +
      '[server]' + LineEnding +
      'listen = 127.0.0.1' + LineEnding +
      'port = 7010' + LineEnding +
      'secret = ' + Secret + LineEnding +
      'releases = ' + ReleaseRoot + LineEnding +
      'master_console_only = on' + LineEnding +
      'header = short' + LineEnding +
      LineEnding +
      '[registry]' + LineEnding +
      'authority = sqlite' + LineEnding +
      LineEnding +
      '[log]' + LineEnding +
      'path = ' + LogRoot + '/pizarra.log' + LineEnding +
      LineEnding +
      '[store]' + LineEnding +
      'dir = ' + StateRoot + LineEnding;
    TizaText :=
      '; Created securely with the pizarra hub configuration.' + LineEnding +
      LineEnding +
      '[pizarra]' + LineEnding +
      'host = 127.0.0.1' + LineEnding +
      'port = 7010' + LineEnding +
      'secret = ' + Secret + LineEnding +
      'self = console' + LineEnding +
      LineEnding +
      '[daemon]' + LineEnding +
      'listen = 127.0.0.1' + LineEnding +
      'port = 7011' + LineEnding +
      'secret = ' + Secret + LineEnding +
      'state = ' + TizaStatePath + LineEnding;

    HubTmp := ConfigRoot + '/.pizarra.conf.first-run-' + IntToStr(FpGetpid);
    TizaTmp := ConfigRoot + '/.tiza.conf.first-run-' + IntToStr(FpGetpid);
    if not WriteExclusive(HubTmp, HubText, Why) then Exit;
    HubTmpOwned := True;
    if not WriteExclusive(TizaTmp, TizaText, Why) then Exit;
    TizaTmpOwned := True;
    { Publish the client first. Publishing the hub last is the commit point: a
      visible hub configuration always has its matching default client. }
    if not PublishExclusive(TizaTmp, TizaConfigPath, Why) then Exit;
    TizaTmpOwned := False;
    TizaPublished := True;
    if not PublishExclusive(HubTmp, HubConfigPath, Why) then Exit;
    HubTmpOwned := False;
    Result := True;
  finally
    if HubTmpOwned then
      DeleteFile(HubTmp);
    if TizaTmpOwned then
      DeleteFile(TizaTmp);
    if (not Result) and TizaPublished then
      DeleteFile(TizaConfigPath);
    DeleteFile(LockPath);
  end;
end;

function BootstrapDefaultHub(out Why: string): Boolean;
begin
  Result := BootstrapHubLayout(PZ_CONFIG_DIR, PZ_STATE_DIR, PZ_LOG_DIR, Why);
end;

end.
