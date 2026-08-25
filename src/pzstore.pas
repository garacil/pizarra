{ pzstore - durable message store for the pizarra hub.

  Files (under a store directory):
    messages.jsonl  append-only journal, one JSON object per line with the
                    fields seq, ts, from, to, text, via
    state.json      fields next_seq, delivered (team=seq), cursors (who=seq);
                    rewritten atomically (tmp + rename) on every change.

  Semantics:
    - The hub assigns a monotonic Int64 seq and the timestamp (only the hub
      stamps time — team hosts never do).
    - delivered[team] is a per-team high-water mark: a message addressed to a
      team is PENDING while seq > delivered[team]. Delivery must be confirmed
      in seq order (MarkDelivered) to preserve conversation order.
    - cursors[who] backs `tiza inbox`: Unread returns messages to `who` with
      seq > cursors[who] and (unless peeking) advances the cursor.

  Startup: replay the journal, then compact — keep all pending/unconsumed
  messages plus the newest KEEP_DELIVERED consumed ones.

  Thread-safe: one internal critical section around all state.               }
unit pzstore;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Unix, BaseUnix, fpjson, jsonparser, pzproto;

const
  KEEP_DELIVERED = 5000;   { consumed messages kept at startup compaction }

type
  { A complete write whose SYNC failed: its bytes may or may not be on disk.
    Distinguish this from a write failure because the required handling is the
    opposite--a write failure is rolled back, while this MUST NOT be rolled
    back because that could produce two messages with the same sequence. }
  EPzSyncUnknown = class(Exception);

  { Distinct from an ordinary internal failure so a caller can report "this
    view cannot be certified" instead of "the service broke". }
  EPzStoreAmbiguous = class(Exception);

  TPzMsgEvent = procedure(const M: TPzMsg) of object;

  TPzStore = class
  private
    FDir:   string;
    FLock:  TCriticalSection;
    { An acknowledgement recorded in memory has NOT reached disk. }
    FStateDirty: Boolean;
    FMsgs:  TPzMsgArray;     { in-memory copy of the live journal, seq order }
    FCount: Integer;
    FNextSeq: Int64;
    { A sync or rollback that cannot be proven leaves the journal AMBIGUOUS.
      From that point the store fails closed until restart. Another write could
      place the next record after a partial one and make both unreadable. Also,
      watchers were never notified about the ambiguous message, so a later sync
      could make it durable without anyone having observed it. }
    FAmbiguous: Boolean;
    FDelivered: TStringList; { team=seq high-water }
    FCursors:   TStringList; { who=seq inbox cursor }
    FOnAppend: TPzMsgEvent;
    function  JournalPath: string;
    function  StatePath: string;
    function  GetMark(L: TStringList; const Key: string): Int64;
    procedure SetMark(L: TStringList; const Key: string; V: Int64);
    function  MsgConsumed(const M: TPzMsg): Boolean;
    function TruncateBackTo(Pos: Int64): Boolean;
    procedure AppendJournal(const M: TPzMsg);
    { False means the ACKNOWLEDGEMENT did not reach disk. It MUST NOT be rolled
      back: the external effect--pasting text into a session or someone reading
      an inbox--ALREADY HAPPENED, and rolling memory back would repeat it at
      once. Retain what was observed, REPORT that the receipt is not durable,
      and retry. The remaining window provides at-least-once delivery. }
    function SaveState: Boolean;   { caller holds FLock }
    { Record the receipt. If it does not reach disk, report that ONCE and leave
      it pending for retry instead of logging one line per attempt. }
    procedure Receipt(const What: string);   { caller holds FLock }
  public
    { A restore-oriented backup holds this while copying messages.jsonl and
      state.json together. Callers must release it in finally. }
    procedure LockForSnapshot;
    procedure UnlockForSnapshot;
    procedure RetryReceipt;
    procedure LoadAll;
    procedure Compact;            { caller holds FLock }
  public
    constructor Create(const ADir: string);
    destructor Destroy; override;

    { Record a new message; assigns seq + ts, appends to the journal. OnAppend
      (if set) fires INSIDE the store lock, so subscribers see messages in
      strict seq order with no gaps. }
    { Ident is 'proven' when the sender presented its team's own secret, and
      'claimed' when it used the master key, which may claim any name. }
    function Append(const From, Dest, Text, Via: string;
      const Ident: string = ''; AMinimal: Boolean = False;
      const AReplyTo: string = ''): TPzMsg;
    property OnAppend: TPzMsgEvent read FOnAppend write FOnAppend;

    { Confirm delivery of Seq to Team (advances the high-water mark). }
    procedure MarkDelivered(const Team: string; Seq: Int64);
    function DeliveredMark(const Team: string): Int64;
    { Register Team as a delivery target so compaction protects its messages
      by the delivered high-water mark (never by an inbox read cursor) even
      before the first successful delivery. }
    procedure EnsureDest(const Team: string);

    { Oldest-first messages addressed to Team with seq > delivered[Team]. }
    function PendingFor(const Team: string): TPzMsgArray;
    function PendingCountBefore(const Team: string; Seq: Int64): Integer;

    { Inbox for `who`: unread (seq > cursor), oldest-first, capped at Max —
      repeated calls page through a backlog without skipping. Advances the
      cursor only to the highest RETURNED seq, unless Peek. All=True ignores
      the cursor and returns the newest Max (never moves the cursor). }
    function Unread(const Who: string; Max: Integer; Peek, All: Boolean): TPzMsgArray;
    function UnreadOutside(const Who: string; Max: Integer; All: Boolean): Integer;
    { Inbox PAGE: entries AFTER a position, oldest first. It never consumes
      messages--viewing is not acknowledging--and never moves the cursor;
      reading page two must not mark page one as read. }
    function UnreadPage(const Who: string; After: Int64; Max: Integer;
      All: Boolean): TPzMsgArray;
    { Number remaining AFTER that page, so the reader knows whether the end is
      the actual end. }
    function UnreadAfter(const Who: string; After: Int64; All: Boolean): Integer;

    { Explicit cursor advance (chat acks what it has rendered). }
    function Ack(const Who: string; UpTo: Int64): Boolean;

    { Messages with seq > Since, oldest-first, capped at Max (watch replay). }
    function Since(SinceSeq: Int64; Max: Integer): TPzMsgArray;

    function LastSeq: Int64;
    function Ambiguous: Boolean;
    procedure RequireCertainLocked;
    function GreatestMissingSeq: Int64;
  end;

implementation

constructor TPzStore.Create(const ADir: string);
begin
  inherited Create;
  FDir := ExcludeTrailingPathDelimiter(ADir);
  FLock := TCriticalSection.Create;
  FDelivered := TStringList.Create;
  FCursors := TStringList.Create;
  FNextSeq := 1;
  FAmbiguous := False;
  FCount := 0;
  SetLength(FMsgs, 0);
  if not DirectoryExists(FDir) then
    if not ForceDirectories(FDir) then
      raise Exception.CreateFmt('cannot create store dir: %s', [FDir]);
  LoadAll;
end;

destructor TPzStore.Destroy;
begin
  FCursors.Free;
  FDelivered.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPzStore.LockForSnapshot;
begin
  FLock.Enter;
end;

procedure TPzStore.UnlockForSnapshot;
begin
  FLock.Leave;
end;

function TPzStore.JournalPath: string;
begin
  Result := FDir + '/messages.jsonl';
end;

function TPzStore.StatePath: string;
begin
  Result := FDir + '/state.json';
end;

function TPzStore.GetMark(L: TStringList; const Key: string): Int64;
var
  i: Integer;
begin
  i := L.IndexOfName(Key);
  if i < 0 then
    Result := 0
  else
    Result := StrToInt64Def(L.ValueFromIndex[i], 0);
end;

procedure TPzStore.SetMark(L: TStringList; const Key: string; V: Int64);
begin
  L.Values[Key] := IntToStr(V);
end;

{ Truncate the journal to its size before a failed write, then sync it. Without
  the sync, removal of the partial record cannot be asserted. Return False on
  failure; the caller MUST NOT reuse the sequence in that case. }
function TPzStore.TruncateBackTo(Pos: Int64): Boolean;
var
  H: THandle;
begin
  Result := False;
  try
    H := FileOpen(JournalPath, fmOpenWrite or fmShareDenyNone);
    if H = THandle(-1) then
      Exit;
    try
      { Unix RTL FileTruncate (sysutils.pp:583-595) returns res>=0, therefore
        False on failure; it does not raise. }
      if not FileTruncate(H, Pos) then
        Exit;
      Result := fpfsync(H) = 0;
    finally
      FileClose(H);
    end;
  except
    Result := False;
  end;
end;

procedure TPzStore.AppendJournal(const M: TPzMsg);
var
  FS: TFileStream;
  Line: string;
  StartPos: Int64;
begin
  { -1 means there is no valid rollback point yet. This is essential: if open
    or Seek fails, control reaches the handler WITHOUT capturing EOF, and
    truncating to an uninitialized value could destroy the entire journal. }
  StartPos := -1;
  Line := MsgToJson(M) + #10;
  try
    if FileExists(JournalPath) then
    begin
      FS := TFileStream.Create(JournalPath, fmOpenReadWrite or fmShareDenyNone);
      FS.Seek(0, soEnd);
    end
    else
      FS := TFileStream.Create(JournalPath, fmCreate);
    StartPos := FS.Position;   { EOF before writing: the rollback point }
    try
      FS.WriteBuffer(Line[1], Length(Line));
      { fpfsync returns the system call status, and the Linux RTL does NOT raise
        on failure (unxsysc.inc; sysutils.pp defines success as fpfsync=0).
        Ignoring it left the handler below unaware and acknowledged data that
        might not be on disk. The bytes have ALREADY been written here. This is
        not "not persisted" but an UNKNOWN RESULT, represented by a distinct
        exception because rollback must not reuse the sequence. }
      if fpfsync(FS.Handle) <> 0 then
        raise EPzSyncUnknown.CreateFmt(
          'journal fsync failed (errno %d): the bytes may or may not be on disk',
          [fpgeterrno]);
    finally
      FS.Free;
    end;
  except
    on E: EPzSyncUnknown do
    begin
      Writeln(StdErr, 'pizarra: store: DEGRADED: ', E.Message);
      raise;
    end;
    on E: Exception do
    begin
      { A write exception does NOT mean zero bytes were written: TStream loops
        and raises only when the total falls short
        (rtl/objpas/classes/streams.inc), so a partial line may remain. Reusing
        the sequence would then issue it again over a dirty journal. Rollback is
        safe only if the file can be truncated to its previous EOF; otherwise
        the result is unknown and nothing is rolled back. }
      Writeln(StdErr, 'pizarra: store: cannot append journal: ', E.Message);
      { A failure BEFORE opening/seeking wrote nothing and is safe to roll back.
        Truncation is needed only after reaching the write position. }
      if (StartPos >= 0) and (not TruncateBackTo(StartPos)) then
        raise EPzSyncUnknown.Create(
          'journal write failed and could not be truncated back: a partial ' +
          'record may remain (sequence NOT reused)');
      raise;
    end;
  end;
end;

function TPzStore.SaveState: Boolean;
var
  Root, DObj, CObj: TJSONObject;
  i: Integer;
  S, Tmp: string;
  FS: TFileStream;
begin
  { The caller holds FLock. This closes a back door: after ambiguity, FNextSeq
    has already advanced, and any receipt or cursor saved here would publish it
    to disk as certified state. }
  RequireCertainLocked;
  Result := False;
  Root := TJSONObject.Create;
  try
    Root.Add('next_seq', FNextSeq);
    DObj := TJSONObject.Create;
    for i := 0 to FDelivered.Count - 1 do
      DObj.Add(FDelivered.Names[i], StrToInt64Def(FDelivered.ValueFromIndex[i], 0));
    Root.Add('delivered', DObj);
    CObj := TJSONObject.Create;
    for i := 0 to FCursors.Count - 1 do
      CObj.Add(FCursors.Names[i], StrToInt64Def(FCursors.ValueFromIndex[i], 0));
    Root.Add('cursors', CObj);
    S := Root.FormatJSON();
  finally
    Root.Free;
  end;
  Tmp := StatePath + '.tmp';
  try
    FS := TFileStream.Create(Tmp, fmCreate);
    try
      if S <> '' then
        FS.WriteBuffer(S[1], Length(S));
      { Rename must never publish a partial file. If sync fails, publish nothing
        and retain the previous, internally consistent state.json. }
      if fpfsync(FS.Handle) <> 0 then
        raise Exception.CreateFmt('state.json fsync failed (errno %d)',
          [fpgeterrno]);
    finally
      FS.Free;
    end;
    if not RenameFile(Tmp, StatePath) then
    begin
      Writeln(StdErr, 'pizarra: store: cannot rename state.json.tmp');
      Exit;
    end;
    { state.json is written IN FULL, so every successful write also settles any
      pending receipt, regardless of which path persists it. Tracking this only
      in Receipt was incorrect: another path, such as message creation, could
      persist it unnoticed while the warning promised retries forever. }
    if FStateDirty then
    begin
      Writeln(StdErr, 'pizarra: receipt backlog persisted');
      FStateDirty := False;
    end;
    Result := True;
  except
    on E: Exception do
      Writeln(StdErr, 'pizarra: store: cannot save state: ', E.Message);
  end;
end;

procedure TPzStore.Receipt(const What: string);
begin
  if SaveState then
    Exit;   { SaveState also settles any pending receipt. }
  if not FStateDirty then
    Writeln(StdErr, 'pizarra: receipt NOT durable (', What, '): the effect ',
      'ALREADY happened; after a restart it may be repeated. Will retry.');
  FStateDirty := True;
end;

{ Retry a pending receipt. The watchdog calls this so a transient disk failure
  does not leave the mark only in memory until the restart that loses it. }
procedure TPzStore.RetryReceipt;
begin
  FLock.Enter;
  try
      RequireCertainLocked;
    if FStateDirty then
      Receipt('retry');
  finally
    FLock.Leave;
  end;
end;

procedure TPzStore.LoadAll;
var
  Line: string;
  Obj: TJSONObject;
  Root: TJSONData;
  D: TJSONObject;
  M: TPzMsg;
  i: Integer;
  SL: TStringList;
  { Read the entire journal and split it manually; each line's OFFSET is needed
    to truncate a torn tail. }
  JBytes: RawByteString;
  JFS: TFileStream;
  LineIni, Nl: Integer;
  Entera: Boolean;
  Nl2: Byte;
begin
  { state.json }
  if FileExists(StatePath) then
  begin
    SL := TStringList.Create;
    try
      SL.LoadFromFile(StatePath);
      Root := nil;
      try
        Root := GetJSON(SL.Text);
      except
        Root := nil;
      end;
      if (Root <> nil) and (Root.JSONType = jtObject) then
      begin
        FNextSeq := TJSONObject(Root).Get('next_seq', Int64(1));
        D := TJSONObject(Root).Get('delivered', TJSONObject(nil));
        if D <> nil then
          for i := 0 to D.Count - 1 do
            SetMark(FDelivered, D.Names[i], D.Items[i].AsInt64);
        D := TJSONObject(Root).Get('cursors', TJSONObject(nil));
        if D <> nil then
          for i := 0 to D.Count - 1 do
            SetMark(FCursors, D.Names[i], D.Items[i].AsInt64);
      end;
      if Root <> nil then
        Root.Free;
    finally
      SL.Free;
    end;
  end;

  { READ THE JOURNAL WITH BYTE OFFSETS, not line by line, because repairing a
    torn tail requires knowing WHERE it starts.
    Silently skipping an unparseable line without truncation or a failure mark
    left compaction with nothing to rewrite. The next Append then sought to EOF
    and wrote ATTACHED to the previous fragment. The hub acknowledged a message
    that vanished on restart, while the gap left watchers below it permanently
    reporting 'history_unavailable'.
    These are TWO distinct failures and require different handling:
      - a FINAL line without its newline is a crash-torn write. Repair it by
        truncating an invalid fragment or appending the missing newline to a
        valid record, because only the last line can be incomplete;
      - an invalid line IN THE MIDDLE is corruption, not a torn write, and
        nothing can be certified. Mark the store AMBIGUOUS, the existing
        mechanism for "this state cannot be proven". }
  if FileExists(JournalPath) then
  begin
    JBytes := '';
    JFS := TFileStream.Create(JournalPath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(JBytes, JFS.Size);
      if JFS.Size > 0 then
        JFS.ReadBuffer(JBytes[1], JFS.Size);
    finally
      JFS.Free;
    end;
    LineIni := 1;
    while LineIni <= Length(JBytes) do
    begin
      Nl := LineIni;
      while (Nl <= Length(JBytes)) and (JBytes[Nl] <> #10) do
        Inc(Nl);
      Entera := Nl <= Length(JBytes);          { found its newline }
      Line := Copy(JBytes, LineIni, Nl - LineIni);
      if Trim(Line) <> '' then
      begin
        Obj := ParseObj(Line);
        if Obj = nil then
        begin
          if Entera then
          begin
            { Broken IN THE MIDDLE: corruption, not a torn tail. }
            FAmbiguous := True;
            Writeln(StdErr, Format('pizarra: journal has an unreadable record ' +
              'at byte %d - NOT a torn tail but corruption in the middle. The ' +
              'store cannot certify its history and refuses to write.',
              [LineIni - 1]));
          end
          else
          begin
            { TORN TAIL: truncate to its starting offset so the next record
              cannot merge with the fragment. }
            if TruncateBackTo(LineIni - 1) then
              Writeln(StdErr, Format('pizarra: journal had a torn tail of %d ' +
                'byte(s) at byte %d (a write cut by a crash); truncated so the ' +
                'next record cannot fuse with its remains.',
                [Length(Line), LineIni - 1]))
            else
            begin
              FAmbiguous := True;
              Writeln(StdErr, 'pizarra: journal has a torn tail that could ' +
                'NOT be truncated; the store refuses to write.');
            end;
          end;
        end
        else
        begin
          try
            M := JsonToMsg(Obj);
          finally
            Obj.Free;
          end;
          if M.Seq > 0 then
          begin
            if FCount >= Length(FMsgs) then
              SetLength(FMsgs, (Length(FMsgs) * 2) + 32);
            FMsgs[FCount] := M;
            Inc(FCount);
            if M.Seq >= FNextSeq then
              FNextSeq := M.Seq + 1;
          end;
          if not Entera then
          begin
            { The FINAL record is valid but lost its newline. Without repairing
              it, the next Append still attaches to it, so fix the file even
              though the record content itself is valid. }
            JFS := TFileStream.Create(JournalPath,
              fmOpenWrite or fmShareDenyNone);
            try
              JFS.Seek(0, soEnd);
              Nl2 := 10;
              JFS.WriteBuffer(Nl2, 1);
            finally
              JFS.Free;
            end;
            Writeln(StdErr, 'pizarra: journal''s last record had no line ' +
              'ending (a crash between the record and its newline); closed it ' +
              'so the next one starts clean.');
          end;
        end;
      end;
      LineIni := Nl + 1;
    end;
  end;

  Compact;
end;

{ True when a message no longer needs to be retained. A destination that has
  a delivered high-water mark is a delivery target (team): only the delivered
  mark counts — an inbox cursor must NEVER consume a still-pending delivery
  (a team running `tiza inbox` would otherwise let compaction drop queued
  messages). Destinations without a delivered mark (console and friends) are
  consumed by their read cursor. }
function TPzStore.MsgConsumed(const M: TPzMsg): Boolean;
var
  Key: string;
begin
  Key := LowerCase(M.Dest);
  if FDelivered.IndexOfName(Key) >= 0 then
    Result := M.Seq <= GetMark(FDelivered, Key)
  else
    Result := M.Seq <= GetMark(FCursors, Key);
end;

{ Keep all unconsumed messages plus the newest KEEP_DELIVERED consumed ones,
  and rewrite the journal (tmp + rename). }
procedure TPzStore.Compact;
var
  Keep: TPzMsgArray;
  n, i, ConsumedSeen, ConsumedTotal: Integer;
  Line, Tmp: string;
  FS: TFileStream;
  Durable: Boolean;
begin
  { Compact rewrites the journal from FMsgs. Publishing an uncertain in-memory
    image as the good version would certify exactly what cannot be proven. This
    currently runs only during load, before concurrency exists, so it reads the
    field directly without locking. If it is ever called live, this check must
    become RequireCertainLocked under FLock. }
  if FAmbiguous then
  begin
    Writeln(StdErr, 'pizarra: store: refusing to compact an ambiguous journal');
    Exit;
  end;
  Durable := False;
  ConsumedTotal := 0;
  for i := 0 to FCount - 1 do
    if MsgConsumed(FMsgs[i]) then
      Inc(ConsumedTotal);

  SetLength(Keep, FCount);
  n := 0;
  ConsumedSeen := 0;
  for i := 0 to FCount - 1 do
  begin
    if MsgConsumed(FMsgs[i]) then
    begin
      Inc(ConsumedSeen);
      { drop the oldest consumed beyond the cap }
      if ConsumedTotal - ConsumedSeen >= KEEP_DELIVERED then
        Continue;
    end;
    Keep[n] := FMsgs[i];
    Inc(n);
  end;
  SetLength(Keep, n);

  if n <> FCount then
  begin
    Tmp := JournalPath + '.tmp';
    try
      FS := TFileStream.Create(Tmp, fmCreate);
      try
        for i := 0 to n - 1 do
        begin
          Line := MsgToJson(Keep[i]) + #10;
          FS.WriteBuffer(Line[1], Length(Line));
        end;
        if fpfsync(FS.Handle) <> 0 then
          raise Exception.CreateFmt('compacted journal fsync failed (errno %d)',
            [fpgeterrno]);
      finally
        FS.Free;
      end;
      if not RenameFile(Tmp, JournalPath) then
        raise Exception.Create('cannot rename compacted journal');
      Durable := True;
    except
      on E: Exception do
        Writeln(StdErr, 'pizarra: store: compaction failed: ', E.Message);
    end;
  end
  else
    Durable := True;   { nothing needed compaction }

  { Memory MUST NOT advance beyond disk. If compaction did not become durable,
    retain the previous image. Publishing Keep would make the hub serve a
    shortened journal while the full one remains on disk, so records considered
    gone in memory would reappear after restart. }
  if Durable then
  begin
    FMsgs := Keep;
    FCount := n;
  end;
end;

function TPzStore.Append(const From, Dest, Text, Via: string;
  const Ident: string = ''; AMinimal: Boolean = False;
  const AReplyTo: string = ''): TPzMsg;
begin
  FLock.Enter;
  try
    if FAmbiguous then
      raise EPzStoreAmbiguous.Create('store is in an unrecoverable ambiguous state ' +
        'after a failed journal sync/rollback: refusing further appends until ' +
        'the hub is restarted (the journal may hold a partial record)');
    Result.Seq := FNextSeq;
    Inc(FNextSeq);
    Result.Ts := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
    Result.From := From;
    Result.Dest := Dest;
    Result.Text := Text;
    Result.Via := Via;
    Result.Ident := Ident;
    Result.Minimal := AMinimal;
    Result.ReplyTo := AReplyTo;
    if FCount >= Length(FMsgs) then
      SetLength(FMsgs, (Length(FMsgs) * 2) + 32);   { amortized growth }
    FMsgs[FCount] := Result;
    Inc(FCount);
    try
      AppendJournal(Result);
    except
      on EPzSyncUnknown do
      begin
        { The bytes were ALREADY written and only sync failed; they may or may
          not be on disk. Do NOT roll this back. Returning the sequence to the
          allocator could create TWO distinct messages with the same identity.
          Retain both record and sequence, mark the store AMBIGUOUS so it
          refuses further writes, and propagate WITHOUT acknowledging. Tell the
          sender the result is unknown--the truth--instead of claiming success
          that cannot be supported. }
        FAmbiguous := True;
        raise;
      end;
      on E: Exception do
      begin
        { journal write failed (disk full / EIO): undo the in-memory record and
          release the seq, then propagate so the caller reports an error }
        Dec(FCount);
        FMsgs[FCount] := Default(TPzMsg);
        Dec(FNextSeq);
        raise;
      end;
    end;
    SaveState;
    if Assigned(FOnAppend) then
      FOnAppend(Result);   { inside the lock: strict seq order for watchers }
  finally
    FLock.Leave;
  end;
end;

procedure TPzStore.MarkDelivered(const Team: string; Seq: Int64);
begin
  FLock.Enter;
  try
    RequireCertainLocked;   { before mutation, not after }
    { THE MARK MUST NOT ADVANCE BEYOND THE JOURNAL. It is persistent and only
      increases, so an invented sequence--or simply one beyond the current
      end--would mark the team's ENTIRE future as delivered: messages would stop
      leaving the hub while senders saw them as sent. Enforce the limit for ALL
      callers, not only a currently known faulty one. }
    if Seq > FNextSeq - 1 then
      Seq := FNextSeq - 1;
    if Seq > GetMark(FDelivered, LowerCase(Team)) then
    begin
      SetMark(FDelivered, LowerCase(Team), Seq);
      Receipt('delivered ' + Team);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzStore.DeliveredMark(const Team: string): Int64;
begin
  FLock.Enter;
  try
    Result := GetMark(FDelivered, LowerCase(Team));
  finally
    FLock.Leave;
  end;
end;

procedure TPzStore.EnsureDest(const Team: string);
begin
  FLock.Enter;
  try
    RequireCertainLocked;   { before mutation, not after }
    if FDelivered.IndexOfName(LowerCase(Team)) < 0 then
    begin
      SetMark(FDelivered, LowerCase(Team), 0);
      SaveState;
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzStore.PendingFor(const Team: string): TPzMsgArray;
var
  i, n: Integer;
  HW: Int64;
begin
  Result := nil;
  FLock.Enter;
  try
      RequireCertainLocked;
    HW := GetMark(FDelivered, LowerCase(Team));
    SetLength(Result, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
      if SameText(FMsgs[i].Dest, Team) and (FMsgs[i].Seq > HW) then
      begin
        Result[n] := FMsgs[i];
        Inc(n);
      end;
    SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

function TPzStore.PendingCountBefore(const Team: string; Seq: Int64): Integer;
var
  i: Integer;
  HW: Int64;
begin
  FLock.Enter;
  try
      RequireCertainLocked;
    HW := GetMark(FDelivered, LowerCase(Team));
    Result := 0;
    for i := 0 to FCount - 1 do
      if SameText(FMsgs[i].Dest, Team) and (FMsgs[i].Seq > HW) and
         (FMsgs[i].Seq < Seq) then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

{ NUMBER OF UNREAD MESSAGES OUTSIDE THE WINDOW. Use "outside", not "below", on
  purpose: the history view returns the NEWEST records and omits older ones,
  while the unread view returns the OLDEST records and omits newer ones. A name
  true in only half the cases is misleading.
  This matters because acknowledging the greatest visible sequence silently
  skips everything outside the window, even though nobody displayed those
  messages. The server cannot know WHAT was rendered and must not pretend it
  can; it can report how many records were omitted. }
function TPzStore.UnreadOutside(const Who: string; Max: Integer;
  All: Boolean): Integer;
var
  i, n: Integer;
  Cur: Int64;
begin
  Result := 0;
  FLock.Enter;
  try
    RequireCertainLocked;
    if All then
      Cur := 0
    else
      Cur := GetMark(FCursors, LowerCase(Who));
    n := 0;
    for i := 0 to FCount - 1 do
      if SameText(FMsgs[i].Dest, Who) and (FMsgs[i].Seq > Cur) then
        Inc(n);
    if (Max > 0) and (n > Max) then
      Result := n - Max;
  finally
    FLock.Leave;
  end;
end;

function TPzStore.UnreadPage(const Who: string; After: Int64; Max: Integer;
  All: Boolean): TPzMsgArray;
var
  i, n: Integer;
  Cur, StartSeq: Int64;
begin
  Result := nil;
  FLock.Enter;
  try
    RequireCertainLocked;
    if All then
      Cur := 0
    else
      Cur := GetMark(FCursors, LowerCase(Who));
    { Start at the GREATER value: the cursor prevents already acknowledged
      records from being served as unread, while After records pagination. }
    StartSeq := Cur;
    if After > StartSeq then
      StartSeq := After;
    SetLength(Result, 0);
    n := 0;
    for i := 0 to FCount - 1 do
      if SameText(FMsgs[i].Dest, Who) and (FMsgs[i].Seq > StartSeq) then
      begin
        if (Max > 0) and (n >= Max) then
          Break;
        SetLength(Result, n + 1);
        Result[n] := FMsgs[i];
        Inc(n);
      end;
  finally
    FLock.Leave;
  end;
end;

function TPzStore.UnreadAfter(const Who: string; After: Int64;
  All: Boolean): Integer;
var
  i: Integer;
  Cur, StartSeq: Int64;
begin
  Result := 0;
  FLock.Enter;
  try
    RequireCertainLocked;
    if All then
      Cur := 0
    else
      Cur := GetMark(FCursors, LowerCase(Who));
    StartSeq := Cur;
    if After > StartSeq then
      StartSeq := After;
    for i := 0 to FCount - 1 do
      if SameText(FMsgs[i].Dest, Who) and (FMsgs[i].Seq > StartSeq) then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TPzStore.Unread(const Who: string; Max: Integer; Peek, All: Boolean): TPzMsgArray;
var
  i, n: Integer;
  Cur, Highest: Int64;
  Tmp: TPzMsgArray;
begin
  Result := nil;
  FLock.Enter;
  try
      RequireCertainLocked;
    if All then
      Cur := 0
    else
      Cur := GetMark(FCursors, LowerCase(Who));
    SetLength(Tmp, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
      if SameText(FMsgs[i].Dest, Who) and (FMsgs[i].Seq > Cur) then
      begin
        Tmp[n] := FMsgs[i];
        Inc(n);
      end;
    SetLength(Tmp, n);
    if (Max > 0) and (n > Max) then
    begin
      if All then
      begin
        { history view: the newest Max }
        SetLength(Result, Max);
        for i := 0 to Max - 1 do
          Result[i] := Tmp[n - Max + i];
      end
      else
      begin
        { unread paging: the OLDEST Max — never mark unseen messages read }
        SetLength(Result, Max);
        for i := 0 to Max - 1 do
          Result[i] := Tmp[i];
      end;
    end
    else
      Result := Tmp;
    if (not Peek) and (not All) and (Length(Result) > 0) then
    begin
      Highest := Result[High(Result)].Seq;
      if Highest > GetMark(FCursors, LowerCase(Who)) then
      begin
        SetMark(FCursors, LowerCase(Who), Highest);
        Receipt('inbox read by ' + Who);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{ THE CURSOR MUST NOT PASS THE LAST EXISTING MESSAGE. This is a STORE INVARIANT,
  not a client-side check.

  Without it, one 'ack upto=999999' could leave a team PERMANENTLY BLIND: the
  hub returned ok:true, the inbox became empty, and later messages entered the
  journal already considered read. Recovery required manually editing
  state.json because all three cursor paths--state load, inbox auto-ack, and
  this operation--only increase it.

  The upper bound once existed only in pzweb (peek, TopeSinLeer and a 409), so
  it protected the browser but not the bus; any wire client could bypass it.
  Enforcing the invariant here makes it a product guarantee rather than one
  client's convention.

  REFUSE instead of silently clamping. An acknowledgement past the last message
  indicates a broken client, and clamping would falsely tell it that the exact
  request succeeded. There is no race: the upper bound can only increase. }
function TPzStore.Ack(const Who: string; UpTo: Int64): Boolean;
begin
  FLock.Enter;
  try
    RequireCertainLocked;   { before mutation, not after }
    { Use FNextSeq - 1 DIRECTLY, not LastSeq, which would reacquire the lock we
      already hold. FPC allows that because critical sections are recursive
      under cthreads, but relying on it is fragile and the field is available. }
    Result := UpTo <= (FNextSeq - 1);
    if not Result then
      Exit;
    if UpTo > GetMark(FCursors, LowerCase(Who)) then
    begin
      SetMark(FCursors, LowerCase(Who), UpTo);
      Receipt('ack by ' + Who);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzStore.Since(SinceSeq: Int64; Max: Integer): TPzMsgArray;
var
  i, n: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
      RequireCertainLocked;
    SetLength(Result, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
      if FMsgs[i].Seq > SinceSeq then
      begin
        Result[n] := FMsgs[i];
        Inc(n);
        if (Max > 0) and (n >= Max) then
          Break;
      end;
    SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

{ Greatest global sequence MISSING from the retained journal, or 0 if none is
  missing. This is the completeness boundary: a cursor BELOW this value cannot
  be served reliably because a record between it and the present is gone, with
  neither sender nor destination known, so the server cannot even determine
  whether the caller should have seen it.

  Startup compaction removes old consumed records but retains pending ones
  regardless of age, so "the first retained sequence" proves NOTHING. An old
  pending message may precede a gap.

  Walk backward from FNextSeq-1. While retained records are contiguous nothing
  is missing; the first jump is the greatest gap, so stop there. }
function TPzStore.GreatestMissingSeq: Int64;
var
  i: Integer;
  Expect: Int64;
begin
  FLock.Enter;
  try
    Result := 0;
    Expect := FNextSeq - 1;
    for i := FCount - 1 downto 0 do
    begin
      if FMsgs[i].Seq <> Expect then
      begin
        Result := Expect;   { greatest missing sequence }
        Exit;
      end;
      Dec(Expect);
    end;
    { No gaps within retained records. If the journal begins above 1, everything
      before it was compacted; the greatest missing value is its predecessor. }
    if (FCount > 0) and (FMsgs[0].Seq > 1) then
      Result := FMsgs[0].Seq - 1
    else if (FCount = 0) and (FNextSeq > 1) then
      Result := FNextSeq - 1;
  finally
    FLock.Leave;
  end;
end;

{ ALWAYS called with FLock held. Checking ambiguity outside the lock races: a
  thread may observe false and block; Append then marks ambiguity and releases;
  the first thread enters and exposes the ambiguous record anyway. }
procedure TPzStore.RequireCertainLocked;
begin
  if FAmbiguous then
    raise EPzStoreAmbiguous.Create('store is ambiguous after a failed journal ' +
      'sync/rollback: refusing to expose or act on messages until restart');
end;

function TPzStore.Ambiguous: Boolean;
begin
  FLock.Enter;
  try
    Result := FAmbiguous;
  finally
    FLock.Leave;
  end;
end;

function TPzStore.LastSeq: Int64;
begin
  FLock.Enter;
  try
    Result := FNextSeq - 1;
  finally
    FLock.Leave;
  end;
end;

end.
