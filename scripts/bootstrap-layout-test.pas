program BootstrapLayoutTest;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, BaseUnix, IniFiles, pzlayout;

procedure Fail(const Msg: string);
begin
  Writeln(StdErr, 'not ok: ', Msg);
  Halt(1);
end;

procedure CheckDirectory(const Path: string; ExpectedMode: Cardinal);
var
  St: TStat;
begin
  St := Default(TStat);
  if (FpLStat(Path, St) <> 0) or (not fpS_ISDIR(St.st_mode)) or
     (Cardinal(St.st_mode) and &777 <> ExpectedMode) then
    Fail(Path + ' does not have the expected private directory mode');
end;

procedure CheckFile(const Path: string; ExpectedMode: Cardinal);
var
  St: TStat;
begin
  St := Default(TStat);
  if (FpLStat(Path, St) <> 0) or (not fpS_ISREG(St.st_mode)) or
     (Cardinal(St.st_mode) and &777 <> ExpectedMode) then
    Fail(Path + ' does not have the expected private file mode');
end;

function FileText(const Path: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure WritePrivate(const Path, Content: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmCreate, &600);
  try
    if Content <> '' then
      Stream.WriteBuffer(Content[1], Length(Content));
  finally
    Stream.Free;
  end;
  if FpChmod(Path, &600) <> 0 then
    Fail('could not protect private recovery fixture ' + Path);
end;

var
  Root, ConfigDir, StateDir, ReleaseDir, LogDir: string;
  HubPath, TizaPath, Why, HubSecret, TizaSecret, BeforeText: string;
  HubIni, TizaIni: TIniFile;
begin
  if ParamCount <> 2 then
    Fail('usage: bootstrap-layout-test TEMP_ROOT EXPECTED_RELEASE_DIR');
  Root := ExcludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
  ConfigDir := Root + '/etc/pizarra';
  StateDir := Root + '/var/lib/pizarra';
  ReleaseDir := StateDir + '/releases';
  LogDir := Root + '/var/log/pizarra';
  HubPath := ConfigDir + '/pizarra.conf';
  TizaPath := ConfigDir + '/tiza.conf';

  if PZ_RELEASE_DIR <> ParamStr(2) then
    Fail('production PZ_RELEASE_DIR is not the Unix canonical path');
  if not BootstrapHubLayout(ConfigDir, StateDir, LogDir, Why) then
    Fail('first bootstrap failed: ' + Why);

  CheckDirectory(ConfigDir, &711);
  CheckDirectory(StateDir, &700);
  CheckDirectory(ReleaseDir, &700);
  CheckDirectory(LogDir, &700);
  CheckFile(HubPath, &600);
  CheckFile(TizaPath, &600);

  HubIni := TIniFile.Create(HubPath);
  TizaIni := TIniFile.Create(TizaPath);
  try
    if HubIni.ReadString('server', 'releases', '') <> ReleaseDir then
      Fail('generated [server] releases does not name state/releases');
    if HubIni.ReadString('store', 'dir', '') <> StateDir then
      Fail('generated [store] dir is not the selected state directory');
    HubSecret := HubIni.ReadString('server', 'secret', '');
    TizaSecret := TizaIni.ReadString('pizarra', 'secret', '');
    if (HubSecret = '') or (HubSecret <> TizaSecret) then
      Fail('generated hub/client credentials do not match');
  finally
    TizaIni.Free;
    HubIni.Free;
  end;

  BeforeText := FileText(HubPath);

  { A crashed initializer may leave a lock pathname and exactly one published
    credential. The journal is durable recovery state, not a stale O_EXCL
    barrier: the next run must reconstruct only the missing matching file. }
  if not DeleteFile(HubPath) then
    Fail('could not remove hub config for interrupted-bootstrap recovery');
  WritePrivate(ConfigDir + '/.first-run.lock',
    'pizarra-first-run-v1' + LineEnding + 'secret=' + HubSecret + LineEnding);
  if not BootstrapHubLayout(ConfigDir, StateDir, LogDir, Why) then
    Fail('bootstrap did not resume after client-first interruption: ' + Why);
  CheckFile(HubPath, &600);
  if FileText(HubPath) <> BeforeText then
    Fail('resumed bootstrap did not reproduce the matching hub configuration');

  if not DeleteFile(TizaPath) then
    Fail('could not remove client config for interrupted-bootstrap recovery');
  WritePrivate(ConfigDir + '/.first-run.lock',
    'pizarra-first-run-v1' + LineEnding + 'secret=' + HubSecret + LineEnding);
  if not BootstrapHubLayout(ConfigDir, StateDir, LogDir, Why) then
    Fail('bootstrap did not resume after hub-first interruption: ' + Why);
  CheckFile(TizaPath, &600);
  TizaIni := TIniFile.Create(TizaPath);
  try
    if TizaIni.ReadString('pizarra', 'secret', '') <> HubSecret then
      Fail('resumed bootstrap generated a mismatched client credential');
  finally
    TizaIni.Free;
  end;

  { A lock file without a live flock is recoverable even when it was created
    before the journal write. With a complete pair it is simply cleaned up. }
  WritePrivate(ConfigDir + '/.first-run.lock', '');
  if not BootstrapHubLayout(ConfigDir, StateDir, LogDir, Why) then
    Fail('bootstrap rejected a stale unlocked first-run file: ' + Why);
  if FileExists(ConfigDir + '/.first-run.lock') then
    Fail('bootstrap did not remove a recovered first-run journal');

  if not RemoveDir(ReleaseDir) then
    Fail('could not remove empty test release directory');
  if not BootstrapHubLayout(ConfigDir, StateDir, LogDir, Why) then
    Fail('bootstrap did not repair a missing releases directory: ' + Why);
  CheckDirectory(ReleaseDir, &700);
  if FileText(HubPath) <> BeforeText then
    Fail('bootstrap overwrote an existing hub configuration');

  if FpChmod(ReleaseDir, &755) <> 0 then
    Fail('could not make the temporary release directory unsafe for testing');
  if BootstrapHubLayout(ConfigDir, StateDir, LogDir, Why) then
    Fail('bootstrap accepted a release directory with group/other access');
  if Pos('group/other', Why) = 0 then
    Fail('unsafe release mode rejection was not explicit: ' + Why);
  if FpChmod(ReleaseDir, &700) <> 0 then
    Fail('could not restore temporary release directory mode');

  if FileExists(ConfigDir + '/.first-run.lock') then
    Fail('bootstrap left its first-run lock behind');
  Writeln('ok: secure first-run layout includes canonical releases');
end.
