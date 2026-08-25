program pzshare_symlink_test;

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, pzshare;

var
  SourcePath, DestDir, ProtectedPath, AttackPath, FinalPath, Why: string;
begin
  if ParamCount <> 3 then
  begin
    Writeln(StdErr, 'usage: pzshare-symlink-test SOURCE DESTDIR PROTECTED');
    Halt(64);
  end;
  SourcePath := ParamStr(1);
  DestDir := ParamStr(2);
  ProtectedPath := ParamStr(3);
  AttackPath := IncludeTrailingPathDelimiter(DestDir) +
    Format('.pzshare-%d-1-%s.partial', [FpGetpid, ExtractFileName(SourcePath)]);
  if FpSymlink(PChar(ProtectedPath), PChar(AttackPath)) <> 0 then
  begin
    Writeln(StdErr, 'could not plant the adversarial symlink: ',
      SysErrorMessage(fpgeterrno));
    Halt(65);
  end;
  if not ShareCopy(SourcePath, DestDir, FinalPath, Why) then
  begin
    Writeln(StdErr, 'ShareCopy failed: ', Why);
    Halt(66);
  end;
  Writeln(FinalPath);
end.
