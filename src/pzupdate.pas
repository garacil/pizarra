{ pzupdate - the tiza daemon's static self-update. Everything here is
  deterministic compiled code: download the release artifact from the hub in
  chunks (cmd=upget), verify its SHA-256, run the CANDIDATE binary's own
  hermetic self-test (`--version` must print exactly the target release),
  back up the installed binary, install ATOMICALLY, verify what landed, and
  roll back if that final gate fails. Hosts with no prebuilt artifact for
  their os-cpu (the Apple Silicon Mac) take the build-from-source route:
  fetch src.tar.gz, verify, compile with the local fpc, same gates after.
  No operator, no AI, no shell scripts - the recipe is compiled in. }
unit pzupdate;

{$mode objfpc}{$H+}

interface

uses
  pzconfig;

type
  { What the update did to the installed binary - the caller must report it
    truthfully and must NOT restart when the new code is not what will come
    back up. }
  TUpdateOutcome = record
    Ok:        Boolean;   { installed AND verified }
    Changed:   Boolean;   { the file at UpdatePath was modified at any point }
    RolledBack:Boolean;   { a failed install was restored from the backup }
    SelfImage: Boolean;   { UpdatePath IS this process's own image (restart ok) }
    Err:       string;
  end;

{ Full self-update to TargetVer over Cfg.UpdatePath. Never raises. }
function RunSelfUpdate(const Cfg: TTizaDaemonConfig; const TargetVer: string;
  Force: Boolean): TUpdateOutcome;

implementation

uses
  SysUtils, Classes, BaseUnix, base64, process, fpjson,
  pznet, pzproto, pzsha256, pzver;

const
  CHUNK    = 262144;      { 256 KB raw -> ~350 KB base64, under the 1 MB cap }
  MAX_ART  = 134217728;   { 128 MB hard cap: a bogus size must not fill /tmp }

{ run a binary with args, capture stdout+stderr; True on exit code 0 }
function RunCap(const Bin: string; const Args: array of string;
  out OutS: string): Boolean;
var
  S: string;
begin
  OutS := '';
  try
    Result := RunCommand(Bin, Args, S, [poStderrToOutPut, poUsePipes], swoHIDE);
    OutS := S;
  except
    on E: Exception do
    begin
      OutS := E.Message;
      Result := False;
    end;
  end;
end;

{ the release a tiza binary reports about ITSELF; '' when it cannot run.
  --version is hermetic by contract (no config, no hub) - see tiza.pas. }
function BinVersion(const Bin: string): string;
var
  OutS: string;
  p: Integer;
begin
  Result := '';
  if not RunCap(Bin, ['--version'], OutS) then
    Exit;
  p := Pos(#10, OutS);
  if p > 0 then
    OutS := Copy(OutS, 1, p - 1);
  OutS := Trim(OutS);
  if Copy(OutS, 1, 5) = 'tiza ' then
    Result := Trim(Copy(OutS, 6, Length(OutS)));
end;

{ This process's own executable, resolved. MUST be read BEFORE the install:
  once the file is replaced, /proc/self/exe reports "<path> (deleted)" — the
  suffix is stripped here too, but the pre-install read is what makes the
  comparison meaningful. }
function SelfExe: string;
var
  L: string;
  p: Integer;
begin
  L := '';
  {$IFDEF LINUX}
  L := FpReadLink('/proc/self/exe');
  {$ENDIF}
  if L = '' then
    L := ExpandFileName(ParamStr(0));
  p := Pos(' (deleted)', L);
  if p > 0 then
    L := Copy(L, 1, p - 1);
  Result := L;
end;

function CopyFilePlain(const Src, Dst: string): Boolean;
var
  A, B: TFileStream;
begin
  Result := False;
  try
    { Shared access: see pzsha256. Without sharing bits, FPC requests LOCK_EX. }
    A := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      B := TFileStream.Create(Dst, fmCreate);
      try
        B.CopyFrom(A, 0);
      finally
        B.Free;
      end;
    finally
      A.Free;
    end;
    FpChmod(Dst, &755);   { a rollback copy must stay executable }
    Result := True;
  except
    Result := False;
  end;
end;

{ private work dir: 0700, created fresh, never an existing path (a fixed
  /tmp name would let a local user pre-plant symlinks under our writes) }
function MakeWorkDir(out Dir: string): Boolean;
var
  Base: string;
  i: Integer;
begin
  Result := False;
  Dir := '';
  Base := IncludeTrailingPathDelimiter(GetTempDir) + 'pizarra-up-' +
    IntToStr(FpGetpid) + '-';
  for i := 1 to 200 do
    if FpMkdir(Base + IntToStr(i), &700) = 0 then
    begin
      Dir := Base + IntToStr(i);
      Exit(True);
    end;
end;

procedure WipeDir(const Dir: string);
var
  OutS: string;
begin
  if (Dir <> '') and (Pos('/pizarra-up-', Dir) > 0) and DirectoryExists(Dir) then
    RunCap('/bin/rm', ['-rf', Dir], OutS);
end;

{ download one artifact ('bin' or 'src') into OutFile; verifies size+sha256.
  NoArtifact=True distinguishes "the hub has no build for this platform"
  (try the source route) from a hard error. Partial files never survive. }
function FetchArtifact(const Cfg: TTizaDaemonConfig;
  const Kind, TargetVer, OutFile: string; out Err: string;
  out NoArtifact: Boolean): Boolean;
var
  OsS, CpuS, Reply, ErrS, Sha, Data, Hex: string;
  Obj: TJSONObject;
  FS: TFileStream;
  Offset, Size: Int64;
begin
  Result := False;
  NoArtifact := False;
  Err := '';
  OsS := LowerCase({$I %FPCTARGETOS%});
  CpuS := LowerCase({$I %FPCTARGETCPU%});
  Sha := '';
  Size := -1;
  Offset := 0;
  try
    FS := TFileStream.Create(OutFile, fmCreate);
  except
    on E: Exception do
    begin
      Err := 'cannot create ' + OutFile + ': ' + E.Message;
      Exit;
    end;
  end;
  try
    try
      repeat
        if not RequestLine(Cfg.HubHost, Cfg.HubPort, 10000,
          { Identify WHO is asking as well as proving the secret. The identity
            was irrelevant with the master secret, but the hub requires it to
            match a team-scoped secret; an empty value broke self-update. }
          BuildUpget(Cfg.HubSecret, OsS, CpuS, Kind, Offset, CHUNK, Cfg.SelfId),
          Reply, ErrS) then
        begin
          Err := 'hub unreachable during download: ' + ErrS;
          Exit;
        end;
        Obj := ParseObj(Reply);
        if Obj = nil then
        begin
          Err := 'bad upget reply';
          Exit;
        end;
        try
          if not Obj.Get('ok', False) then
          begin
            Err := Obj.Get('error', 'upget refused');
            NoArtifact := Pos('no artifact', Err) > 0;
            Exit;
          end;
          if Offset = 0 then
          begin
            { the hub serves exactly ONE published release. A mismatch means
              it moved on (or never published) - abort, never guess. }
            if Obj.Get('ver', '') <> TargetVer then
            begin
              Err := Format('hub offers %s, wanted %s - retrigger',
                [Obj.Get('ver', '?'), TargetVer]);
              Exit;
            end;
            Size := Obj.Get('size', Int64(-1));
            Sha := Obj.Get('sha256', '');
            if (Size < 0) or (Length(Sha) <> 64) then
            begin
              Err := 'upget reply missing size/sha256';
              Exit;
            end;
            if Size > MAX_ART then
            begin
              Err := Format('artifact too large (%d bytes)', [Size]);
              Exit;
            end;
          end;
          Data := DecodeStringBase64(Obj.Get('data', ''));
        finally
          Obj.Free;
        end;
        if Data <> '' then
          FS.WriteBuffer(Data[1], Length(Data));
        Inc(Offset, Length(Data));
        if (Data = '') and (Offset < Size) then
        begin
          Err := 'short read from hub';
          Exit;
        end;
      until Offset >= Size;
      Result := True;
    except
      on E: Exception do
        Err := 'download error: ' + E.Message;
    end;
  finally
    FS.Free;
    if not Result then
      DeleteFile(OutFile);   { no partial file survives a failure }
  end;
  if not Result then
    Exit;
  Result := False;
  if not Sha256OfFile(OutFile, Hex) then
  begin
    Err := 'cannot hash downloaded file';
    DeleteFile(OutFile);
    Exit;
  end;
  if Hex <> Sha then
  begin
    Err := 'sha256 mismatch on download (got ' + Hex + ')';
    DeleteFile(OutFile);
    Exit;
  end;
  Result := True;
end;

{ the candidate must report EXACTLY the target release, hermetically }
function SelfTest(const Bin, TargetVer: string; out Err: string): Boolean;
var
  Got: string;
begin
  Got := BinVersion(Bin);
  if Got = '' then
  begin
    Err := 'candidate did not run (no --version output)';
    Exit(False);
  end;
  if Got <> TargetVer then
  begin
    Err := Format('self-test mismatch: candidate is %s, wanted %s',
      [Got, TargetVer]);
    Exit(False);
  end;
  Result := True;
end;

{ install Src over Dst atomically. sudo hosts stage next to the target and
  rename with sudo, so the target is never a half-written file. }
function InstallAtomic(const Cfg: TTizaDaemonConfig; const Src, Dst: string;
  out Err: string): Boolean;
var
  Staged, OutS: string;
begin
  Result := False;
  Staged := Dst + '.new';
  if Cfg.UpdateSudo then
  begin
    if not RunCap('sudo', ['-n', 'install', '-m0755', Src, Staged], OutS) then
    begin
      Err := 'staging (sudo install) failed: ' + Copy(OutS, 1, 200);
      Exit;
    end;
    if not RunCap('sudo', ['-n', 'mv', '-f', Staged, Dst], OutS) then
    begin
      Err := 'install (sudo mv) failed: ' + Copy(OutS, 1, 200);
      RunCap('sudo', ['-n', 'rm', '-f', Staged], OutS);
      Exit;
    end;
  end
  else
  begin
    if not CopyFilePlain(Src, Staged) then
    begin
      Err := 'cannot stage ' + Staged;
      Exit;
    end;
    if FpRename(PChar(Staged), PChar(Dst)) <> 0 then
    begin
      Err := 'rename over ' + Dst + ' failed: ' + SysErrorMessage(fpgeterrno);
      DeleteFile(Staged);
      Exit;
    end;
  end;
  Result := True;
end;

{ keep-0 retention (operator request): once an install is VERIFIED good, no
  rollback copy is needed any more, so delete every <UpdatePath>.bak-* that sits
  beside the binary — both the copy made this cycle and any historical ones that
  piled up before pruning existed. Best-effort: a prune failure must never fail
  or roll back the update, so errors are swallowed. }
procedure PruneBackups(const Cfg: TTizaDaemonConfig);
var
  Dir, Full, OutS: string;
  Info: TSearchRec;
begin
  Dir := ExtractFilePath(Cfg.UpdatePath);
  if FindFirst(Cfg.UpdatePath + '.bak-*', faAnyFile, Info) <> 0 then
    Exit;
  try
    repeat
      if (Info.Attr and faDirectory) <> 0 then
        Continue;
      Full := Dir + Info.Name;
      if Cfg.UpdateSudo then
        RunCap('sudo', ['-n', 'rm', '-f', Full], OutS)
      else
        DeleteFile(Full);
    until FindNext(Info) <> 0;
  finally
    FindClose(Info);
  end;
end;

function RunSelfUpdate(const Cfg: TTizaDaemonConfig; const TargetVer: string;
  Force: Boolean): TUpdateOutcome;
var
  TmpDir, NewBin, SrcTar, BuildDir, OutS, BakPath, OldVer, E2, MyExe: string;
  NoArt, HaveBak: Boolean;
begin
  Result := Default(TUpdateOutcome);
  { read our own image path NOW: after the install the link would read
    "<path> (deleted)" and the comparison would be meaningless. Decide
    SelfImage here too: leaving it True by default meant that a failed
    install with a failed rollback still looked restartable. }
  MyExe := SelfExe;
  Result.SelfImage := SameText(ExpandFileName(Cfg.UpdatePath), MyExe);
  if TargetVer = '' then
  begin
    Result.Err := 'no target release';
    Exit;
  end;
  if (not Force) and (not VerNewer(TargetVer, PizarraVersion)) then
  begin
    Result.Err := 'already at ' + PizarraVersion + ' (target ' + TargetVer +
      '); use force to reinstall';
    Exit;
  end;
  if not MakeWorkDir(TmpDir) then
  begin
    Result.Err := 'cannot create a private work dir under ' + GetTempDir;
    Exit;
  end;
  try
    NewBin := TmpDir + '/tiza.new';
    { route 1: prebuilt binary for this os-cpu }
    if not FetchArtifact(Cfg, 'bin', TargetVer, NewBin, Result.Err, NoArt) then
    begin
      if not NoArt then
        Exit;
      { route 2: no artifact for this platform - build from source (the mac) }
      SrcTar := TmpDir + '/src.tar.gz';
      if not FetchArtifact(Cfg, 'src', TargetVer, SrcTar, Result.Err, NoArt) then
        Exit;
      BuildDir := TmpDir + '/build';
      if not ForceDirectories(BuildDir) then
      begin
        Result.Err := 'cannot create ' + BuildDir;
        Exit;
      end;
      if not RunCap('/usr/bin/tar', ['xzf', SrcTar, '-C', BuildDir], OutS) then
      begin
        Result.Err := 'tar failed: ' + Copy(OutS, 1, 200);
        Exit;
      end;
      ForceDirectories(BuildDir + '/pizarra/build');
      if not RunCap(Cfg.UpdateFpc,
        ['-XX', '-CX', '-Sc', '-Sew', '-Fu' + BuildDir + '/pizarra/src',
         '-FU' + BuildDir + '/pizarra/build', '-FE' + BuildDir + '/pizarra',
         '-O3', '-Os', '-otiza', BuildDir + '/pizarra/src/tiza.pas'],
        OutS) then
      begin
        if Length(OutS) > 400 then
          OutS := Copy(OutS, Length(OutS) - 399, 400);
        Result.Err := 'build failed: ' + OutS;
        Exit;
      end;
      NewBin := BuildDir + '/pizarra/tiza';
    end;
    FpChmod(NewBin, &755);
    { GATE 1 - before touching anything installed }
    if not SelfTest(NewBin, TargetVer, Result.Err) then
      Exit;
    { back up the file we are about to replace, named after ITS OWN release
      (not ours: a retry before the restart must not clobber the good copy) }
    HaveBak := False;
    BakPath := '';
    if FileExists(Cfg.UpdatePath) then
    begin
      OldVer := BinVersion(Cfg.UpdatePath);
      if OldVer = '' then
        OldVer := 'unknown';
      BakPath := Cfg.UpdatePath + '.bak-' + OldVer;
      if FileExists(BakPath) then
        HaveBak := True    { same release already backed up - keep it }
      else if Cfg.UpdateSudo then
        HaveBak := RunCap('sudo', ['-n', 'cp', '-p', Cfg.UpdatePath, BakPath],
          OutS)
      else
        HaveBak := CopyFilePlain(Cfg.UpdatePath, BakPath);
      if not HaveBak then
      begin
        Result.Err := 'cannot write the rollback copy ' + BakPath +
          ' - refusing to install';
        Exit;
      end;
    end;
    if not InstallAtomic(Cfg, NewBin, Cfg.UpdatePath, Result.Err) then
      Exit;   { atomic: the target is either old or new, never partial }
    Result.Changed := True;
    { GATE 2 - what actually landed must report the target release }
    if not SelfTest(Cfg.UpdatePath, TargetVer, Result.Err) then
    begin
      Result.Err := 'installed binary failed verification: ' + Result.Err;
      if HaveBak then
      begin
        if InstallAtomic(Cfg, BakPath, Cfg.UpdatePath, E2) then
        begin
          Result.RolledBack := True;
          Result.Err := Result.Err + ' - ROLLED BACK to ' + BakPath;
        end
        else
          Result.Err := Result.Err + ' - ROLLBACK ALSO FAILED (' + E2 +
            '); the binary at ' + Cfg.UpdatePath + ' is unverified';
      end
      else
        Result.Err := Result.Err + ' - no rollback copy existed';
      Exit;
    end;
    { restarting is only correct when the file we replaced IS what comes back
      up; otherwise the supervisor would relaunch the OLD image and (with
      autoupdate) loop forever }
    Result.Ok := True;
    { verified good -> keep NO rollback copies: prune every .bak-* beside the
      binary (this also sweeps the historical pile from before pruning existed) }
    PruneBackups(Cfg);
  finally
    WipeDir(TmpDir);
  end;
end;

end.
