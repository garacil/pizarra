{ pzshare - shared-directory file exchange helpers, used by the tiza CLI and
  the chat console. The shared root is an NFS path visible on every server
  (hub config [shared] dir); each team plus 'console' has a flat directory
  named after it. Policy:

  - destination basename restricted to [A-Za-z0-9._-], first char
    alphanumeric (no traversal, no hidden files, no leading dash)
  - 10 MB cap per file (coordination channel, not bulk transfer)
  - copy via /bin/cp under a 5 s deadline: an NFS hang must never freeze a
    model; the child cp is the only process ever terminated
  - name collisions auto-rename to <name>.2, .3, ... (bus message carries
    the final path, so readability beats prefixing)                          }
unit pzshare;

{$mode objfpc}{$H+}

interface

const
  SHARE_MAX_BYTES  = 10485760;   { 10 MB, now genuinely REACHABLE. }
  { Maximum chunk per bus line. Base64 expands 512 KB to about 683 KB, safely
    below the 1 MB MAX_LINE_BYTES limit with room for the rest of the JSON. The
    complete file previously traveled in one line, making the 10 MB limit an
    impossible promise: the real ceiling was about 750 KB. }
  SHARE_CHUNK_MAX  = 524288;     { 512 KB }
  { Active partial uploads per destination. Ownerless state on disk accumulates:
    chunks arrive through different connections, so no single disconnect can
    trigger cleanup. Bound the collection and expire old entries. }
  MAX_PARTIAL_UPLOADS = 8;
  SHARE_COPY_MS    = 5000;

{ '' when valid; otherwise an English error message. }
function ShareNameError(const BaseName: string): string;

{ First free destination path for BaseName inside Dir (name, name.2, ...). }
function PickFreeName(const Dir, BaseName: string): string;

{ Validate + copy Src into DestDir. On success returns True and the final
  absolute path in FinalPath; on failure returns False with Err set. Never
  blocks longer than ~SHARE_COPY_MS on the copy itself. }
function ShareCopy(const Src, DestDir: string;
  out FinalPath, Err: string): Boolean;

implementation

uses
  SysUtils, Classes, Process, BaseUnix, Unix, Errors;

function ShareNameError(const BaseName: string): string;
var
  i: Integer;
  c: Char;
begin
  if BaseName = '' then
    Exit('empty file name');
  c := BaseName[1];
  if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
          ((c >= '0') and (c <= '9'))) then
    Exit('file name must start with a letter or digit: ' + BaseName);
  for i := 1 to Length(BaseName) do
  begin
    c := BaseName[i];
    if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
            ((c >= '0') and (c <= '9')) or (c = '.') or (c = '_') or (c = '-')) then
      Exit('file name may only contain letters, digits, dot, underscore, hyphen: '
        + BaseName);
  end;
  Result := '';
end;

function PickFreeName(const Dir, BaseName: string): string;
var
  n: Integer;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + BaseName;
  n := 2;
  while FileExists(Result) do
  begin
    Result := IncludeTrailingPathDelimiter(Dir) + BaseName + '.' + IntToStr(n);
    Inc(n);
  end;
end;

{ Run cp with a deadline; True on exit code 0 within the deadline. }
function CpWithDeadline(const Src, Dst: string; DeadlineMs: Integer): Boolean;
var
  P: TProcess;
  Waited: Integer;
begin
  Result := False;
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/cp';
    P.Parameters.Add('--');
    P.Parameters.Add(Src);
    P.Parameters.Add(Dst);
    try
      P.Execute;
    except
      Exit;
    end;
    Waited := 0;
    while P.Running and (Waited < DeadlineMs) do
    begin
      Sleep(50);
      Inc(Waited, 50);
    end;
    if P.Running then
    begin
      { NFS hang: abandon the copy; this child cp is ours to stop. Reap it so
        it does not linger as a zombie until init collects it. }
        { Send SIGTERM and wait. A cp stuck on a hard NFS mount (D state) cannot
          handle the signal; releasing it here left a zombie until init reaped
          it. Escalate to SIGKILL so it exits as soon as disk activity resumes,
          then wait a little longer. }
      P.Terminate(1);
      Waited := 0;
      while P.Running and (Waited < 1000) do
      begin
        Sleep(20);
        Inc(Waited, 20);
      end;
      if P.Running then
      begin
        FpKill(P.ProcessID, SIGKILL);
        Waited := 0;
        while P.Running and (Waited < 2000) do
        begin
          Sleep(20);
          Inc(Waited, 20);
        end;
      end;
      Exit;
    end;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
  end;
end;

function ShareCopy(const Src, DestDir: string;
  out FinalPath, Err: string): Boolean;
var
  Base, Scratch: string;
  Size: Int64;
  FS: TFileStream;
  i: Integer;
begin
  Result := False;
  FinalPath := '';
  Err := '';

  if not FileExists(Src) then
  begin
    Err := 'file not found: ' + Src;
    Exit;
  end;
  Base := ExtractFileName(Src);
  Err := ShareNameError(Base);
  if Err <> '' then
    Exit;

  { size via a read-only stream — Reset() opens read/write (FileMode) and
    fails on a read-only source with a misleading error }
  try
    FS := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      Size := FS.Size;
    finally
      FS.Free;
    end;
  except
    Err := 'cannot read: ' + Src;
    Exit;
  end;
  if Size > SHARE_MAX_BYTES then
  begin
    Err := Format('file too big for the shared exchange (max %d MB)',
      [SHARE_MAX_BYTES div 1048576]);
    Exit;
  end;

  if not DirectoryExists(DestDir) then
  begin
    Err := 'shared directory does not exist (hub not configured or NFS down): '
      + DestDir;
    Exit;
  end;

  { Copy to a PRIVATE name and rename only after completion. Copying directly
    to the final name creates two hazards:

    1. Two simultaneous sends with the same basename can both observe a free
       name and copy to the SAME PATH. If one copy fails, its cleanup may remove
       the file completed by the other, leaving a FILE SHARED notice that points
       to a missing file.
    2. A partial file is visible under its final name during the copy, across
       the entire NFS cluster. Another team may read it as complete, and an
       abrupt process exit may leave the partial content looking valid forever.

    A per-transfer temporary name isolates cleanup and makes the final name
    visible only after all content is present. This is the same tmp+rename
    pattern used for configuration, the journal, and tasks. }
  Scratch := IncludeTrailingPathDelimiter(DestDir) +
    Format('.pzshare-%d-%s.partial', [FpGetpid, Base]);
  DeleteFile(Scratch);
  if not CpWithDeadline(Src, Scratch, SHARE_COPY_MS) then
  begin
    { Remove only our own temporary file; nobody else can own this name. }
    if FileExists(Scratch) and (not DeleteFile(Scratch)) then
      Err := 'share copy failed AND the partial could not be removed: ' +
        Scratch + ' - '
    else
      Err := '';
    Err := Err + 'share copy failed or timed out (NFS slow/unmounted or disk full)';
    FinalPath := '';
    Exit;
  end;
  { Select the name HERE, after the content is complete, and reserve it with
    link(), NOT rename(). Unix rename silently OVERWRITES its destination, so
    two simultaneous sends could announce the SAME path while the second
    replaced the first file: two bus notices, one file, and the later reader
    received content different from what was announced. link() fails with
    EEXIST when the name exists, providing the required atomic reservation;
    release the temporary file afterward. }
  for i := 1 to 64 do
  begin
    FinalPath := PickFreeName(DestDir, Base);
    if FpLink(Scratch, FinalPath) = 0 then
    begin
      DeleteFile(Scratch);
      Result := True;
      Exit;
    end;
    if fpgeterrno <> ESysEEXIST then
      Break;   { This is not a collision; do not retry 64 times. }
  end;
  DeleteFile(Scratch);
  FinalPath := '';
  Err := 'share failed: could not place the file in ' + DestDir;
end;

end.
