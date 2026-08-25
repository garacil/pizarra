{ pztasks - milestones/tasks engine for the pizarra hub. Manual tracking: the
  human creates/assigns/closes tasks from `tiza chat`; each team's OPEN tasks
  are rendered into every delivery header (RenderOpenBlock).

  Persistence: one human-readable JSON file (tareas.json), written atomically
  (tmp + rename). A corrupt file is renamed aside (.bad-<ts>) and never
  overwritten — no silent data loss. Ids are sequential and never reused.

  Future automation fits without redesign: StateS is a free string; 'done',
  'superseded', and 'cancelled' are terminal, while 'waiting' is live but not
  actionable. Notes carry the author (`By`), so teams can later update states
  and notes themselves via protocol operations.

  Thread-safe: one internal critical section.                                }
unit pztasks;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Unix, fpjson, jsonparser, pzdb;

type
  TTaskNote = record
    Ts, By, Text: string;
  end;

  TTask = record
    Id:      Integer;
    Title:   string;
    Team:    string;    { '' = backlog / unassigned }
    StateS:  string;    { open | done | (future: in_progress, blocked...) }
    Hito:    string;    { milestone label; '' = none }
    Parent:  Integer;   { parent task id (0 = top-level); the delegation tree }
    { The workflow step projected by this task (0 = none). Store the step's
      IMMUTABLE identity, not its number: numbers may be reused after `wf undo`
      lowers the allocator and issues one again. Linking by number could give
      an old task to a DIFFERENT milestone. Keep the workflow name separately
      instead of deriving it from Hito, because a presentation label must not
      serve as identity. }
    WfName:    string;
    WfStepUid: Int64;
    Created: string;
    Closed:  string;
    Notes:   array of TTaskNote;
    Depends: array of Integer;   { shown, not enforced }
  end;
  TTaskArray = array of TTask;
  TIntArray = array of Integer;

  TTaskStore = class
  private
    FPath:  string;
    FDiskImage: string;   { latest state known to have reached disk }
    FLock:  TCriticalSection;
    FTasks: TTaskArray;
    FCount: Integer;
    FNextId: Integer;
    FDb: TPzDb;        { SQLite mirror; nil = JSON only (no history) }
    procedure DbTask(const T: TTask; const Who, Op, ChField, ChOld,
      ChNew: string);
    procedure LoadFromDisk;
    { False means the state did not reach disk; callers MUST NOT assume it did. }
    function SaveToDisk: Boolean;   { caller holds FLock }
    { DEEP snapshot through the existing serializer. Copy() on a dynamic array
      of records does NOT isolate the managed fields inside it
      (dynarr.inc:302-370), so a top-level copy would restore nothing. A round
      trip through TaskToJson/JsonToTask is deep by construction and cannot
      drift from the on-disk format because it IS that format. }
    function SnapshotAll: string;
    procedure RestoreAll(const Snap: string);
    { Snap ALWAYS reflects disk. After a successful save it is refreshed from
      the text just written, so a later failure rolls back to the real durable
      state and no further. }
    function SaveOrRollback(var Snap: string): Boolean;
    function  IndexOf(Id: Integer): Integer;
    { Create the COMPLETE task, including its workflow identity, and persist it
      ONCE. Saving first and adding identity in a second write allowed the
      second write to fail after a task with a valid id but NO identity had
      been accepted as successful. Projection then failed to find it after a
      restart and created a duplicate. The caller holds the lock. }
    function CreateLocked(const Title, Team, Hito: string;
      const Deps: array of Integer; AParent: Integer;
      const AWfName: string; AWfStepUid: Int64; out Why: string): TTask;
  public
    { Used by the hub's global backup barrier. Workflow must be locked before
      tasks; callers release in reverse order. }
    procedure LockForSnapshot;
    procedure UnlockForSnapshot;
    { The hub attaches this after creating the database; subsequent changes are
      also mirrored to work.sqlite with a history entry. }
    procedure SetDb(D: TPzDb);
    constructor Create(const APath: string);
    destructor Destroy; override;
    { IMPORTANT: the failure reason travels WITH the call (out Why), not in a
      store field. A shared field would be read after releasing the lock, when
      another connection could already have overwritten it. The first caller
      could then receive another caller's error, or none. This is a real race
      in a hub serving several connections concurrently. }
    function Add(const Title, Team, Hito: string;
      const Deps: array of Integer; AParent: Integer = 0): TTask; overload;
    function Add(const Title, Team, Hito: string;
      const Deps: array of Integer; AParent: Integer;
      out Why: string): TTask; overload;
    function SetState(Id: Integer; const State, By: string; out T: TTask): Boolean; overload;
    function SetState(Id: Integer; const State, By: string; out T: TTask;
      out Why: string): Boolean; overload;
    function AssignTo(Id: Integer; const Team: string; out T: TTask): Boolean; overload;
    function AssignTo(Id: Integer; const Team: string; out T: TTask;
      out Why: string): Boolean; overload;
    function Delete(Id: Integer; const By: string; out Why: string): Boolean;
    { Detach tasks from a workflow being deleted: they cease to belong to the
      workflow and remain as ordinary tasks. Returns the number detached. }
    function UnlinkWf(const Wf: string): Integer;
    function AddNote(Id: Integer; const By, Text: string; out T: TTask): Boolean; overload;
    function AddNote(Id: Integer; const By, Text: string; out T: TTask;
      out Why: string): Boolean; overload;
    { Idempotent workflow-step insertion: return the existing task for the same
      (workflow, step) pair instead of creating another. Otherwise a retry after
      a lost connection creates duplicates, and reordering writes only changes
      which orphan state is possible. }
    function AddForStep(const Title, Team, Wf: string; StepUid: Int64;
      out Why: string): TTask;
    { Tasks projected by one workflow (by name). The projector needs them for
      the INVERSE operation: find tasks that no longer correspond to a step in
      the current workflow record. }
    { Highest step identity still present in tasks. The workflow store needs it
      at startup because its counter lives in workflows.json. If that file is
      lost or quarantined while the tasks survive, the allocator would restart
      at 1 and a workflow recreated under the same name could adopt OLD work.
      Seeding above this value prevents that. }
    function MaxWfStepUid: Int64;
    function TasksOfWf(const Wf: string): TTaskArray;
    { Move a task to a TERMINAL state with its explanation in ONE write. Doing
      this as note-then-state would recreate the two-commit problem removed
      from DoneStep. }
    function CloseAs(Id: Integer; const State, NoteText: string;
      out Why: string): Boolean;
    { Align a task with its step--title, owner and desired state--in ONE write.
      This is the projector primitive: reopening a superseded task when its
      identity returns to the workflow record, or aligning it after undo,
      cannot be split into two writes without restoring the two-commit problem.
      Empty Title/Team means keep the current value. }
    function AlignTask(Id: Integer; const Title, Team, State, NoteText: string;
      out Why: string): Boolean;
    { Detach a task from its step while retaining its history. The projector
      uses this when a step becomes ACTIVE again but its previous task was
      already completed. That work really was completed and cannot be reopened
      or denied, but it is no longer the projection of a step that needs a new
      attempt. }
    function DetachFromStep(Id: Integer; const NoteText: string;
      out Why: string): Boolean;
    function Get(Id: Integer; out T: TTask): Boolean;
    { Filter: 'open' (default), 'done', 'all'. Team: '' = any. }
    function List(const Filter, Team: string): TTaskArray;
    { '  #id [milestone] title'#10 lines for the delivery header, capped at Max
      with an '(and N more)' line. '' when the team has no open tasks. }
    function RenderOpenBlock(const Team: string; Max: Integer): string;
    { Capture the task block and actionable count under ONE lock, skipping
      entries the projector already knows are stale. This gives the header one
      linearization point; fetching the block and count separately could mix
      two different states. }
    { IMMUTABLE copy, under ONE lock, of the tasks needed by the header: the
      team's tasks, whether or not they come from a workflow, plus every task
      linked to any workflow. Tasks linked to OTHER teams are included on
      purpose; without them a reassigned, now-misaligned task cannot be found.
      Classifying tasks one by one took N locks and allowed a mutation between
      any two reads. }
    function CaptureTasks(const Team: string): TTaskArray;
    { Ids of the direct subtasks of task Id, in id order. }
    function ChildrenOf(Id: Integer): TIntArray;
    { LIVE, non-terminal tasks. Used both as an integrity guard against deleting
      a team with work and as the honest value of 'open_tasks'. }
    function OpenCount(const Team: string): Integer;
    { ACTIONABLE tasks: work due NOW. Header display only--a presentation filter
      must not serve as a deletion guard. }
    function ActionableCount(const Team: string): Integer;
    { Timestamp of the newest note on task Id ('' = none/unknown task) —
      narrow accessor so callers need not copy the whole record. }
    function LastNoteTs(Id: Integer): string;
  end;

{ A TERMINAL state represents work no longer in anyone's queue. 'done' means it
  was completed; 'superseded' means the task belonged to a real workflow branch
  whose step identity is no longer in the current record--not that the work was
  done; 'cancelled' means its step still exists but the workflow was aborted.
  The distinction matters: marking an abandoned branch 'done' would falsify
  history and completed-work counts. }
function IsTerminal(const T: TTask): Boolean;
function IsOpen(const T: TTask): Boolean;
{ ACTIONABLE means open AND due now. 'waiting' is live work whose step became
  pending again after time travel: it is neither completed nor superseded, but
  it is not assigned to anyone yet either, so it must not appear in a team's
  header as work to do. }
function IsActionable(const T: TTask): Boolean;
function TaskToJson(const T: TTask): TJSONObject;
{ THE SAME TASK WITHOUT ITS NOTES, for LISTS.
  Notes are the only unbounded part of a task: they accumulate for its entire
  life. Including them in list responses made every console filter change fetch
  every note ever written, even though the screen only displays their count.
  Bodies are fetched only when opening the detail view, which has its own route.
  Send the COUNT under the distinct name 'notes_count', rather than making
  'notes' sometimes a list and sometimes a number: t.notes.length on a number
  produces 'undefined', not an error, and silently displays zero notes. A new
  name turns that silent failure into a visible one. }
function TaskToJsonLight(const T: TTask): TJSONObject;

implementation

function IsTerminal(const T: TTask): Boolean;
begin
  Result := SameText(T.StateS, 'done') or SameText(T.StateS, 'superseded') or
            SameText(T.StateS, 'cancelled');
end;

function IsActionable(const T: TTask): Boolean;
begin
  Result := IsOpen(T) and (not SameText(T.StateS, 'waiting'));
end;

function IsOpen(const T: TTask): Boolean;
begin
  { IMPORTANT: this is not simply "not done". Otherwise a superseded task would
    still count as open in headers, totals, and guards against deleting a team
    with pending work. }
  Result := not IsTerminal(T);
end;

function NowStamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
end;

{ Every task field EXCEPT notes. Keeping the shared fields here prevents detail
  and list views from maintaining two field lists: a new field added here
  appears in both. They differ only in the data that motivated the split. }
function TaskFieldsJson(const T: TTask): TJSONObject;
var
  D: TJSONArray;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('id', T.Id);
  Result.Add('title', T.Title);
  Result.Add('team', T.Team);
  Result.Add('state', T.StateS);
  Result.Add('hito', T.Hito);
  Result.Add('parent', T.Parent);
  Result.Add('wf_name', T.WfName);
  Result.Add('wf_step_uid', T.WfStepUid);
  Result.Add('created', T.Created);
  Result.Add('closed', T.Closed);
  D := TJSONArray.Create;
  for i := 0 to High(T.Depends) do
    D.Add(T.Depends[i]);
  Result.Add('depends', D);
end;

function TaskToJson(const T: TTask): TJSONObject;
var
  A: TJSONArray;
  N: TJSONObject;
  i: Integer;
begin
  Result := TaskFieldsJson(T);
  A := TJSONArray.Create;
  for i := 0 to High(T.Notes) do
  begin
    N := TJSONObject.Create;
    N.Add('ts', T.Notes[i].Ts);
    N.Add('by', T.Notes[i].By);
    N.Add('text', T.Notes[i].Text);
    A.Add(N);
  end;
  Result.Add('notes', A);
end;

function TaskToJsonLight(const T: TTask): TJSONObject;
begin
  Result := TaskFieldsJson(T);
  Result.Add('notes_count', Length(T.Notes));
end;

function JsonToTask(O: TJSONObject): TTask;
var
  A: TJSONArray;
  N: TJSONObject;
  i: Integer;
begin
  Result.Id := O.Get('id', 0);
  Result.Title := O.Get('title', '');
  Result.Team := O.Get('team', '');
  Result.StateS := O.Get('state', 'open');
  Result.Hito := O.Get('hito', '');
  Result.Parent := O.Get('parent', 0);
  { Absent in older tareas.json files: no workflow link. }
  Result.WfName := O.Get('wf_name', '');
  Result.WfStepUid := O.Get('wf_step_uid', Int64(0));
  Result.Created := O.Get('created', '');
  Result.Closed := O.Get('closed', '');
  Result.Notes := nil;
  Result.Depends := nil;
  A := O.Get('notes', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Notes, A.Count);
    for i := 0 to A.Count - 1 do
    begin
      N := TJSONObject(A.Items[i]);
      Result.Notes[i].Ts := N.Get('ts', '');
      Result.Notes[i].By := N.Get('by', '');
      Result.Notes[i].Text := N.Get('text', '');
    end;
  end;
  A := O.Get('depends', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Depends, A.Count);
    for i := 0 to A.Count - 1 do
      Result.Depends[i] := A.Items[i].AsInteger;
  end;
end;


procedure TTaskStore.SetDb(D: TPzDb);
begin
  FDb := D;
end;

{ Write the task and its history entry to the database; never fail the operation
  because JSON remains the tested load path. }
procedure TTaskStore.DbTask(const T: TTask; const Who, Op, ChField, ChOld,
  ChNew: string);
var
  Err, Row: string;
begin
  if (FDb = nil) or (not FDb.Available) then
    Exit;
  Row := IntToStr(T.Id) + #1 + RowFieldEncode(T.Title) + #1 +
    RowFieldEncode(T.Team) + #1 + RowFieldEncode(T.StateS) + #1 +
    RowFieldEncode(T.Hito) + #1 + IntToStr(T.Parent) + #1 +
    RowFieldEncode(T.Created) + #1 + RowFieldEncode(T.Closed);
  FDb.TaskUpsert(Row, Who, Op, ChField, ChOld, ChNew, Err);
end;

constructor TTaskStore.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FLock := TCriticalSection.Create;
  FCount := 0;
  FNextId := 1;
  SetLength(FTasks, 0);
  LoadFromDisk;
end;

destructor TTaskStore.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TTaskStore.LockForSnapshot;
begin
  FLock.Enter;
end;

procedure TTaskStore.UnlockForSnapshot;
begin
  FLock.Leave;
end;

procedure TTaskStore.LoadFromDisk;
var
  SL: TStringList;
  Root: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  i: Integer;

  procedure Quarantine;
  begin
    { corrupt: keep the evidence, start empty — never crash the hub }
    RenameFile(FPath, FPath + '.bad-' +
      FormatDateTime('yyyymmdd"-"hhnnss', Now));
    Writeln(StdErr, 'pizarra: tareas.json corrupt - quarantined, starting empty');
    FCount := 0;
    SetLength(FTasks, 0);
    FNextId := 1;
  end;

begin
  if not FileExists(FPath) then
    Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FPath);
    Root := nil;
    try
      Root := GetJSON(SL.Text);
    except
      Root := nil;
    end;
    if (Root = nil) or (Root.JSONType <> jtObject) then
    begin
      if Root <> nil then
        Root.Free;
      Quarantine;
      Exit;
    end;
    Obj := TJSONObject(Root);
    try
      try
        FNextId := Obj.Get('next_id', 1);
        Arr := Obj.Get('tareas', TJSONArray(nil));
        if Arr <> nil then
        begin
          SetLength(FTasks, Arr.Count);
          FCount := Arr.Count;
          for i := 0 to Arr.Count - 1 do
          begin
            FTasks[i] := JsonToTask(TJSONObject(Arr.Items[i]));
            if FTasks[i].Id >= FNextId then
              FNextId := FTasks[i].Id + 1;
          end;
        end;
      except
        { wrong-typed fields (e.g. notes as string) raise on conversion —
          same treatment as unparseable JSON }
        Quarantine;
      end;
    finally
      Root.Free;
    end;
  finally
    SL.Free;
  end;
end;

function TTaskStore.SaveToDisk: Boolean;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  S, Tmp: string;
  FS: TFileStream;
  Synced: Boolean;
begin
  Result := False;
  Root := TJSONObject.Create;
  try
    Root.Add('next_id', FNextId);
    Arr := TJSONArray.Create;
    for i := 0 to FCount - 1 do
      Arr.Add(TaskToJson(FTasks[i]));
    Root.Add('tareas', Arr);
    S := Root.FormatJSON();
  finally
    Root.Free;
  end;
  Tmp := FPath + '.tmp';
  try
    FS := TFileStream.Create(Tmp, fmCreate);
    try
      if S <> '' then
        FS.WriteBuffer(S[1], Length(S));
      { fpfsync returns the system call's status (unxsysc.inc:40-44), and the RTL
        itself accepts only zero (sysutils.pp:490-493). Ignoring it allowed a
        file that might not be on disk to be renamed, published and confirmed. }
      Synced := fpfsync(FS.Handle) = 0;   { same durability rule as pzstore: rename never lands empty }
    finally
      FS.Free;
    end;
    if not Synced then
    begin
      Writeln(StdErr, 'pizarra: fsync failed, refusing to publish ', Tmp);
      Exit;
    end;
    if not RenameFile(Tmp, FPath) then
    begin
      Writeln(StdErr, 'pizarra: cannot rename tareas.json.tmp');
      Exit;
    end;
    FDiskImage := S;   { what ACTUALLY reached disk }
    Result := True;
  except
    on E: Exception do
      Writeln(StdErr, 'pizarra: cannot save tasks: ', E.Message);
  end;
end;

function TTaskStore.SnapshotAll: string;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('next_id', FNextId);
    Arr := TJSONArray.Create;
    for i := 0 to FCount - 1 do
      Arr.Add(TaskToJson(FTasks[i]));
    Root.Add('tareas', Arr);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

procedure TTaskStore.RestoreAll(const Snap: string);
var
  Root: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  Root := nil;
  try
    Root := GetJSON(Snap);
  except
    Root := nil;
  end;
  if (Root = nil) or (Root.JSONType <> jtObject) then
  begin
    { This unit created the snapshot itself. If it cannot read it back, that is
      our bug, and reporting it is safer than leaving memory half restored. }
    if Root <> nil then
      Root.Free;
    Writeln(StdErr, 'pizarra: cannot roll back tasks - snapshot unreadable');
    Exit;
  end;
  Obj := TJSONObject(Root);
  try
    FNextId := Obj.Get('next_id', 1);
    Arr := Obj.Get('tareas', TJSONArray(nil));
    FCount := 0;
    SetLength(FTasks, 0);
    if Arr <> nil then
    begin
      SetLength(FTasks, Arr.Count);
      for i := 0 to Arr.Count - 1 do
        if Arr.Items[i].JSONType = jtObject then
        begin
          FTasks[FCount] := JsonToTask(TJSONObject(Arr.Items[i]));
          Inc(FCount);
        end;
      SetLength(FTasks, FCount);
    end;
  finally
    Root.Free;
  end;
end;

function TTaskStore.SaveOrRollback(var Snap: string): Boolean;
begin
  Result := SaveToDisk;
  if Result then
    Snap := FDiskImage          { track disk without serializing again }
  else
    RestoreAll(Snap);
end;

function TTaskStore.IndexOf(Id: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FTasks[i].Id = Id then
      Exit(i);
  Result := -1;
end;

{ Wrappers for callers that ignore the reason (internal workflow projection).
  They avoid forcing a throwaway variable, but code responding to an operator
  must ALWAYS use the overload that returns a reason. }
function TTaskStore.Add(const Title, Team, Hito: string;
  const Deps: array of Integer; AParent: Integer): TTask;
var
  Ignored: string;
begin
  Result := Add(Title, Team, Hito, Deps, AParent, Ignored);
end;

function TTaskStore.SetState(Id: Integer; const State, By: string;
  out T: TTask): Boolean;
var
  Ignored: string;
begin
  Result := SetState(Id, State, By, T, Ignored);
end;

function TTaskStore.AssignTo(Id: Integer; const Team: string;
  out T: TTask): Boolean;
var
  Ignored: string;
begin
  Result := AssignTo(Id, Team, T, Ignored);
end;

function TTaskStore.AddNote(Id: Integer; const By, Text: string;
  out T: TTask): Boolean;
var
  Ignored: string;
begin
  Result := AddNote(Id, By, Text, T, Ignored);
end;

function TTaskStore.CreateLocked(const Title, Team, Hito: string;
  const Deps: array of Integer; AParent: Integer;
  const AWfName: string; AWfStepUid: Int64; out Why: string): TTask;
var
  i: Integer;
  TSnap: string;
begin
  Why := '';
  { Initialize the ENTIRE record before assigning fields. Field-by-field setup
    left newer fields such as WfStepUid with stack residue, which could be
    serialized as a workflow identity on an ordinary task. }
  Result := Default(TTask);
  TSnap := SnapshotAll;
  Result.Id := FNextId;
  Inc(FNextId);
  Result.Title := Title;
  Result.Team := Team;
  Result.StateS := 'open';
  Result.Hito := Hito;
  Result.Parent := AParent;
  Result.Created := NowStamp;
  Result.WfName := AWfName;
  Result.WfStepUid := AWfStepUid;
  SetLength(Result.Depends, Length(Deps));
  for i := 0 to High(Deps) do
    Result.Depends[i] := Deps[i];
  SetLength(FTasks, FCount + 1);
  FTasks[FCount] := Result;
  Inc(FCount);
  if not SaveOrRollback(TSnap) then
  begin
    { Id=0 means nonexistent. Creation was rolled back in full, so returning the
      record would promise a task present in neither memory nor storage. }
    Why := 'not saved: the change was undone (disk write failed)';
    Result := Default(TTask);
    Exit;
  end;
  DbTask(Result, 'console', 'add', '', '', '');
end;

function TTaskStore.Add(const Title, Team, Hito: string;
  const Deps: array of Integer; AParent: Integer; out Why: string): TTask;
begin
  FLock.Enter;
  try
    Result := CreateLocked(Title, Team, Hito, Deps, AParent, '', 0, Why);
  finally
    FLock.Leave;
  end;
end;
function TTaskStore.SetState(Id: Integer; const State, By: string;
  out T: TTask;
  out Why: string): Boolean;
var
  Prev, DbErr: string;
  i, n: Integer;
var
  TSnap: string;
begin
  Why := '';
  FLock.Enter;
  try
    TSnap := SnapshotAll;
    i := IndexOf(Id);
    Result := i >= 0;
    if not Result then
      Exit;
    Prev := FTasks[i].StateS;   { previous state for history }
    FTasks[i].StateS := LowerCase(Trim(State));
    { decide Closed from the normalized state, so ' done ' (padded) still
      records a close timestamp and stays consistent with StateS/IsOpen }
    if IsTerminal(FTasks[i]) then
      FTasks[i].Closed := NowStamp
    else
      FTasks[i].Closed := '';
    n := Length(FTasks[i].Notes);
    SetLength(FTasks[i].Notes, n + 1);
    FTasks[i].Notes[n].Ts := NowStamp;
    FTasks[i].Notes[n].By := By;
    FTasks[i].Notes[n].Text := 'state -> ' + FTasks[i].StateS;
    T := FTasks[i];
    if not SaveOrRollback(TSnap) then
    begin
      T := Default(TTask);
      Why := 'not saved: the change was undone (disk write failed)';
      Exit(False);   { Why distinguishes this from "no such task". }
    end;
    DbTask(T, By, 'set', 'state', Prev, T.StateS);
    if FDb <> nil then
      FDb.TaskNoteAdd(T.Id, T.Notes[n].Ts, By, T.Notes[n].Text, DbErr);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.AssignTo(Id: Integer; const Team: string;
  out T: TTask;
  out Why: string): Boolean;
var
  Prev, DbErr: string;
  i: Integer;
var
  TSnap: string;
begin
  Why := '';
  FLock.Enter;
  try
    TSnap := SnapshotAll;
    i := IndexOf(Id);
    Result := i >= 0;
    if not Result then
      Exit;
    Prev := FTasks[i].Team;
    FTasks[i].Team := Team;
    T := FTasks[i];
    if not SaveOrRollback(TSnap) then
    begin
      T := Default(TTask);
      Why := 'not saved: the change was undone (disk write failed)';
      Exit(False);   { Why distinguishes this from "no such task". }
    end;
    DbTask(T, 'console', 'set', 'team', Prev, Team);
  finally
    FLock.Leave;
  end;
end;

{ DELETE a task. This is destructive and there is no recycle bin, so protect
  what cannot be reconstructed:

  - A task LINKED to a workflow step is NOT deleted. The step would point to a
    nonexistent task and the projector would recreate it on the next change: a
    deletion that does not delete. Remove the step from the workflow first.
  - A task with SUBTASKS is not deleted until they are. Orphaning them hides
    live work under a nonexistent parent, which is worse than retaining the
    unwanted task.

  Both refusals explain WHAT to do, not merely that the operation failed. }
function TTaskStore.Delete(Id: Integer; const By: string;
  out Why: string): Boolean;
var
  i, j, n: Integer;
  TSnap, DbErr: string;
  Gone: TTask;
begin
  Why := '';
  Result := False;
  FLock.Enter;
  try
    TSnap := SnapshotAll;
    i := IndexOf(Id);
    if i < 0 then
    begin
      Why := 'no such task';
      Exit;
    end;
    if FTasks[i].WfName <> '' then
    begin
      Why := Format('task #%d belongs to workflow %s: remove the step first ' +
        '(the projector would recreate it)', [Id, FTasks[i].WfName]);
      Exit;
    end;
    { Use FCount, not High(FTasks): the array is a BUFFER with spare capacity;
      only its first FCount slots are real tasks. Iterating to High read
      uninitialized records and caused an access violation during deletion. }
    n := 0;
    for j := 0 to FCount - 1 do
      if FTasks[j].Parent = Id then
        Inc(n);
    if n > 0 then
    begin
      Why := Format('task #%d has %d subtask(s): delete or reparent them first',
        [Id, n]);
      Exit;
    end;
    Gone := FTasks[i];
    for j := i to FCount - 2 do
      FTasks[j] := FTasks[j + 1];
    Dec(FCount);
    FTasks[FCount] := Default(TTask);   { do not leave a ghost copy behind }
    if not SaveOrRollback(TSnap) then
    begin
      Why := 'not saved: the change was undone (disk write failed)';
      Exit;
    end;
    { A delete is NOT an upsert: DbTask would reinsert the row just removed. }
    if (FDb <> nil) and FDb.Available then
      if not FDb.TaskDelete(Gone.Id, Gone.Title, By, DbErr) then
        Writeln(StdErr, 'pizarra: tasks: mirror delete failed: ', DbErr);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

{ Deleting a workflow does NOT delete its tasks: the work happened and they are
  its record. Detach them--drop workflow name and step identity--and retain them
  as ordinary tasks. Deleting them would destroy history nobody asked to erase;
  leaving them linked to a nonexistent workflow would be worse. }
function TTaskStore.UnlinkWf(const Wf: string): Integer;
var
  i: Integer;
  TSnap: string;
begin
  Result := 0;
  if Wf = '' then
    Exit;
  FLock.Enter;
  try
    TSnap := SnapshotAll;
    for i := 0 to FCount - 1 do
      if SameText(FTasks[i].WfName, Wf) then
      begin
        FTasks[i].WfName := '';
        FTasks[i].WfStepUid := 0;
        Inc(Result);
      end;
    if (Result > 0) and (not SaveOrRollback(TSnap)) then
      Result := -1;   { the caller must be able to report that saving failed }
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.AddNote(Id: Integer; const By, Text: string;
  out T: TTask;
  out Why: string): Boolean;
var
  Prev, DbErr: string;
  i, n: Integer;
var
  TSnap: string;
begin
  Why := '';
  FLock.Enter;
  try
    TSnap := SnapshotAll;
    i := IndexOf(Id);
    Result := i >= 0;
    if not Result then
      Exit;
    n := Length(FTasks[i].Notes);
    SetLength(FTasks[i].Notes, n + 1);
    FTasks[i].Notes[n].Ts := NowStamp;
    FTasks[i].Notes[n].By := By;
    FTasks[i].Notes[n].Text := Text;
    T := FTasks[i];
    if not SaveOrRollback(TSnap) then
    begin
      T := Default(TTask);
      Why := 'not saved: the change was undone (disk write failed)';
      Exit(False);   { Why distinguishes this from "no such task". }
    end;
    if FDb <> nil then
      FDb.TaskNoteAdd(T.Id, T.Notes[n].Ts, By, Text, DbErr);
    DbTask(T, By, 'note', '', '', Copy(Text, 1, 80));
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.AddForStep(const Title, Team, Wf: string; StepUid: Int64;
  out Why: string): TTask;
var
  i: Integer;
  TSnap: string;
begin
  Why := '';
  if (StepUid <= 0) or (Trim(Wf) = '') then
  begin
    { Idempotent projection is impossible without an identity; refuse rather
      than create a task that can never be found again. }
    Why := 'refusing to project a step without a workflow identity';
    Exit(Default(TTask));
  end;
  FLock.Enter;
  try
    for i := 0 to FCount - 1 do
      if (FTasks[i].WfStepUid = StepUid) and SameText(FTasks[i].WfName, Wf) then
      begin
        { Reuse is NOT merely lookup. A step may have changed title or owner
          while the workflow was a draft. Returning the stale record could tell
          one team to "use task #1" while the task still had another title and
          owner. Align it with the workflow and persist BEFORE returning; if the
          change does not reach disk, do not return a task that contradicts the
          notice about to be sent. }
        Result := FTasks[i];
        if (FTasks[i].Title = Title) and SameText(FTasks[i].Team, Team) then
          Exit;
        TSnap := SnapshotAll;
        FTasks[i].Title := Title;
        FTasks[i].Team := Team;
        if not SaveOrRollback(TSnap) then
        begin
          Why := 'not saved: the task could not be re-aligned with its step';
          Exit(Default(TTask));
        end;
        Result := FTasks[i];
        Exit;
      end;
    Result := CreateLocked(Title, Team, Wf, [], 0, Wf, StepUid, Why);
  finally
    FLock.Leave;
  end;
end;
function TTaskStore.MaxWfStepUid: Int64;
var
  i: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for i := 0 to FCount - 1 do
      if FTasks[i].WfStepUid > Result then
        Result := FTasks[i].WfStepUid;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.TasksOfWf(const Wf: string): TTaskArray;
var
  i, n: Integer;
begin
  Result := nil;
  if Trim(Wf) = '' then
    Exit;
  FLock.Enter;
  try
    SetLength(Result, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
      if SameText(FTasks[i].WfName, Wf) and (FTasks[i].WfStepUid > 0) then
      begin
        Result[n] := FTasks[i];
        Inc(n);
      end;
    SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.AlignTask(Id: Integer;
  const Title, Team, State, NoteText: string; out Why: string): Boolean;
var
  i, n: Integer;
  TSnap: string;
begin
  Why := '';
  Result := False;
  FLock.Enter;
  try
    i := IndexOf(Id);
    if i < 0 then
      Exit;
    TSnap := SnapshotAll;
    if Title <> '' then
      FTasks[i].Title := Title;
    if Team <> '' then
      FTasks[i].Team := Team;
    FTasks[i].StateS := LowerCase(Trim(State));
    if IsTerminal(FTasks[i]) then
      FTasks[i].Closed := NowStamp
    else
      { Reopening must clear the close timestamp, or the task would be both open
        and marked as closed. }
      FTasks[i].Closed := '';
    if NoteText <> '' then
    begin
      n := Length(FTasks[i].Notes);
      SetLength(FTasks[i].Notes, n + 1);
      FTasks[i].Notes[n].Ts := NowStamp;
      FTasks[i].Notes[n].By := 'pizarra';
      FTasks[i].Notes[n].Text := NoteText;
    end;
    if not SaveOrRollback(TSnap) then
    begin
      Why := 'not saved: the change was undone (disk write failed)';
      Exit;
    end;
    DbTask(FTasks[i], 'pizarra', 'state', 'state', '', FTasks[i].StateS);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.CloseAs(Id: Integer; const State, NoteText: string;
  out Why: string): Boolean;
begin
  Result := AlignTask(Id, '', '', State, NoteText, Why);
end;
function TTaskStore.DetachFromStep(Id: Integer; const NoteText: string;
  out Why: string): Boolean;
var
  i, n: Integer;
  TSnap: string;
begin
  Why := '';
  Result := False;
  FLock.Enter;
  try
    i := IndexOf(Id);
    if i < 0 then
      Exit;
    TSnap := SnapshotAll;
    { Keep WfName: the task still belonged to that workflow. Detach only the
      STEP IDENTITY so projection cannot find it again and can create the next
      attempt without producing two tasks with the same identity. }
    FTasks[i].WfStepUid := 0;
    n := Length(FTasks[i].Notes);
    SetLength(FTasks[i].Notes, n + 1);
    FTasks[i].Notes[n].Ts := NowStamp;
    FTasks[i].Notes[n].By := 'pizarra';
    FTasks[i].Notes[n].Text := NoteText;
    if not SaveOrRollback(TSnap) then
    begin
      Why := 'not saved: the change was undone (disk write failed)';
      Exit;
    end;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.Get(Id: Integer; out T: TTask): Boolean;
var
  i: Integer;
begin
  FLock.Enter;
  try
    i := IndexOf(Id);
    Result := i >= 0;
    if Result then
      T := FTasks[i];
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.List(const Filter, Team: string): TTaskArray;
var
  i, n: Integer;
  WantOpen, WantDone: Boolean;
  Exact: string;
begin
  Result := nil;
  { 'all' must enter BOTH branches: it means "no filter", not "closed only".
    Otherwise List('all') returns only terminal tasks, and the initial
    work.sqlite mirror loses every open task. }
  WantOpen := (Filter = '') or SameText(Filter, 'open') or
              SameText(Filter, 'all');
  WantDone := SameText(Filter, 'all');
  { Every other word is an EXACT state match ('done', 'error', 'superseded',
    'in_progress'...). 'done' deliberately follows this path. It once meant
    "everything that is not open", which was equivalent with one terminal
    state, but with 'superseded' would count an abandoned branch as completed
    work. }
  Exact := '';
  if (not WantOpen) and (not WantDone) then
    Exact := LowerCase(Trim(Filter));
  FLock.Enter;
  try
    SetLength(Result, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
    begin
      if (Team <> '') and (not SameText(FTasks[i].Team, Team)) then
        Continue;
      if Exact <> '' then
      begin
        if not SameText(FTasks[i].StateS, Exact) then
          Continue;
      end
      else if IsOpen(FTasks[i]) then
      begin
        if not WantOpen then
          Continue;
      end
      else if not WantDone then
        Continue;
      Result[n] := FTasks[i];
      Inc(n);
    end;
    SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.ChildrenOf(Id: Integer): TIntArray;
var
  i, n: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
      if FTasks[i].Parent = Id then
      begin
        Result[n] := FTasks[i].Id;
        Inc(n);
      end;
    SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.LastNoteTs(Id: Integer): string;
var
  i: Integer;
begin
  Result := '';
  FLock.Enter;
  try
    i := IndexOf(Id);
    if (i >= 0) and (Length(FTasks[i].Notes) > 0) then
      Result := FTasks[i].Notes[High(FTasks[i].Notes)].Ts;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.OpenCount(const Team: string): Integer;
var
  i: Integer;
begin
  FLock.Enter;
  try
    Result := 0;
    for i := 0 to FCount - 1 do
      { LIVE, not actionable. The guard against deleting a team with work uses
        this count. Filtering for "due now" would allow deleting a team with a
        waiting task that still belongs to it. ActionableCount answers the
        separate header-display question. }
      if SameText(FTasks[i].Team, Team) and IsOpen(FTasks[i]) then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.ActionableCount(const Team: string): Integer;
var
  i: Integer;
begin
  FLock.Enter;
  try
    Result := 0;
    for i := 0 to FCount - 1 do
      if SameText(FTasks[i].Team, Team) and IsActionable(FTasks[i]) then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.CaptureTasks(const Team: string): TTaskArray;
var
  i, n: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FCount);
    n := 0;
    for i := 0 to FCount - 1 do
      if SameText(FTasks[i].Team, Team) or (FTasks[i].WfStepUid > 0) then
      begin
        Result[n] := FTasks[i];
        Result[n].Notes := nil;   { the header does not use notes }
        Result[n].Depends := Copy(FTasks[i].Depends);
        Inc(n);
      end;
    SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.RenderOpenBlock(const Team: string; Max: Integer): string;
var
  i, Shown, Total: Integer;
  H: string;
begin
  Result := '';
  Shown := 0;
  Total := 0;
  FLock.Enter;
  try
    for i := 0 to FCount - 1 do
      { ACTIONABLE, not merely open: a 'waiting' task is live work whose step is
        pending again. Putting it in the header would request work not yet due. }
      if SameText(FTasks[i].Team, Team) and IsActionable(FTasks[i]) then
      begin
        Inc(Total);
        if Shown < Max then
        begin
          if FTasks[i].Hito <> '' then
            H := '[' + FTasks[i].Hito + '] '
          else
            H := '';
          Result := Result + Format('  #%d %s%s'#10,
            [FTasks[i].Id, H, FTasks[i].Title]);
          Inc(Shown);
        end;
      end;
  finally
    FLock.Leave;
  end;
  if Total > Shown then
    Result := Result + Format('  (and %d more)'#10, [Total - Shown]);
end;

end.
