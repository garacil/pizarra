{ pzworkflow - dependency-tree milestone plans ("workflows") for the hub.

  A workflow is a named plan bound to one group: numbered steps, each with one
  owner team and a list of dependencies on other steps. Step numbers are
  stable visible references within a card, not array positions or immutable
  identities. Draft editing (insert/remove/set) splices the tree freely, so
  deps may point at any existing step and every structural
  mutation runs a Kahn cycle check (a cycle is refused, never stored).
  A step ACTIVATES when all its deps are done; roots activate at start;
  independent branches run in parallel; the workflow is done when every step
  is done. On an error the WHOLE workflow halts: nothing advances until the
  owner fixes it and ANOTHER party verifies the fix. Structure is editable
  in DRAFT only; a running plan changes through the error protocol or abort.

  The hub is the only activator. Each active step is projected into an
  ordinary task (Hito = workflow name) created AT activation, so a future
  step has no work surface anywhere. workflows.json is authoritative; linked
  tasks are maintained only by this engine (By='pizarra').

  Crash safety: every transition persists its state change PLUS an outbox of
  notices in the same atomic save; the hub drains the outbox to the bus and
  clears entries only after the store append succeeds. Reconcile (hub start +
  watchdog tick) finishes half-done activations and re-projects steps onto
  their linked tasks; the hub re-drains stranded outbox entries each tick.

  LOCK ORDER: FLock (this unit) may nest FTasks' internal lock (engine ->
  task store), NEVER the reverse; the hub must not call into this unit while
  holding a lock the task store also takes. Bus deliveries (FanOne) happen
  strictly OUTSIDE FLock - transitions only queue outbox entries.

  Persistence mirrors pztasks: atomic tmp+fsync+rename, corrupt files
  quarantined aside (.bad-<ts>), never overwritten. Thread-safe.            }
unit pzworkflow;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Unix, fpjson, jsonparser, pztasks, pzansi;

type
  TWfNote = record
    Ts, By, Text: string;
  end;

  { A dependency on a step of ANOTHER workflow ('--after otherwf#3'). }
  TWfXDep = record
    Wf: string;
    N:  Integer;
  end;

  TWfStep = record
    N:       Integer;             { visible ordering number, not identity }
    { IMMUTABLE step identity. This is not N, which may be reused. `wf undo`
      restores an older card with a lower maximum step number, so a later insert
      may assign that visible number to a DIFFERENT milestone while the old
      task remains alive. Linking by number would attach the wrong work. Keep
      the identity counter in the STORE, outside undoable workflow cards. }
    Uid:     Int64;
    Hito:    string;              { milestone title }
    Team:    string;              { exactly one owner; 'console' = human GATE }
    Deps:    array of Integer;    { same-workflow deps; [] = root }
    XDeps:   array of TWfXDep;    { cross-workflow deps (both must be done) }
    StateS:  string;              { pending | active | done | error | fixed }
    PriorS:  string;              { state before an error (for verify-ok restore) }
    TaskId:  Integer;             { linked task; 0 until activation; -1 = GATE
                                    (console step: notice queued, no task) }
    Eta:     Integer;             { stall threshold secs; 0=inherit, -1=off }
    LastNudge: string;            { when the last stall nudge went out }
    Started: string;
    Closed:  string;
  end;

  { One queued bus notice (persisted with its transition; drained by the hub). }
  TWfOut = record
    OutId: Integer;               { store-wide monotonic, for removal }
    Kind:  string;                { start|activate|stop|fix|verify_req|verify_fail|resume|complete|abort }
    StepN: Integer;
    Team:  string;
    Text:  string;
  end;
  TWfOutArray = array of TWfOut;

  TWorkflow = record
    Name:    string;              { unique key }
    Group:   string;
    Members: array of string;     { membership snapshot taken at start }
    StateS:  string;              { draft | running | halted | done | aborted }
    ErrStep: Integer;             { 1-based; 0 = none }
    ErrBy:   string;              { who reported the active error }
    Frozen:  array of Integer;    { steps active at halt (for STOP/RESUME) }
    EtaDef:  Integer;             { default stall threshold secs; 0=factory(24h),
                                    -1=nudging off for this workflow }
    Strict:  Boolean;             { done requires a how-tested proof text }
    Created: string;
    Started: string;
    Closed:  string;
    Steps:   array of TWfStep;
    Log:     array of TWfNote;
    Outbox:  array of TWfOut;
  end;
  TWorkflowArray = array of TWorkflow;
  TWfStrings = array of string;

  { group -> admin pairs, computed by the hub from live config at call time
    (the engine never reads configuration). }
  TWfAdmin = record
    Group, Admin: string;
  end;
  TWfAdminMap = array of TWfAdmin;

  { Verdict of a transition: refusal text + feed lines to broadcast. Bus
    deliveries are NOT here - they are in the persisted outbox. }
  TWfResult = record
    Ok:   Boolean;
    Err:  string;
    Feed: array of string;
  end;

  { Verdict of the pre-SetState task gate. }
  TWfGate = record
    Allow:  Boolean;
    Why:    string;               { refusal text when not Allow }
    WfDone: Boolean;              { True: perform the workflow done transition
                                    (the engine closes the task itself) }
    WfName: string;
    StepN:  Integer;
  end;

  TWorkflowStore = class
  private
    FPath:   string;
    FDiskImage: string;  { latest state known to have reached disk }
    { PENDING history. SnapshotLocked no longer writes; it RECORDS the PREVIOUS
      workflow card and flushes it after commit. Writing it before the save
      consumed a number and left history for a rejected transition that never
      occurred. Simply moving that write after the save would capture the NEW
      card and make undo useless: capture before, write after. }
    FPendSnap: Boolean;
    FPendSnapWf: TWorkflow;
    FPendSnapReason: string;
    FHistDir: string;
    FNextSnap: Integer;
    FLock:   TCriticalSection;
    FWfs:    TWorkflowArray;
    FCount:  Integer;
    FNextOut: Integer;
    { Step identity allocator. It lives here, NOT in the workflow card; otherwise
      `wf undo` would rewind it and issue existing identities again. }
    FNextUid: Int64;
    FTasks:  TTaskStore;
    procedure LoadFromDisk;
    { False means the state did not reach disk; callers MUST NOT publish or say ok. }
    function SaveToDisk: Boolean;                  { caller holds FLock }
    { DEEP snapshot of the complete store through the existing serializer. A
      top-level copy provides no isolation because nested arrays (Steps, Deps,
      XDeps, Log, Outbox) remain shared by reference; mutating a copied step
      would mutate live state (dynarr.inc:302-370). }
    function SnapshotAll: string;
    procedure RestoreAll(const Snap: string);
    { Save, or on failure ROLL BACK the entire mutation from the snapshot. }
    function SaveOrRollback(var Snap: string): Boolean;
    { Auto-history: stage the CURRENT state of W before mutation and flush it to
      wfhistory/ only after commit (undo pops the newest). Caller holds FLock. }
    procedure SnapshotLocked(const W: TWorkflow; const Reason: string);
    procedure FlushSnapshot;
    { After undo/restore: reopen/close linked tasks to match the steps and
      drop stale TaskIds so activation recreates them. Caller holds FLock. }
    function  IndexOf(const Name: string): Integer;
    procedure AddLog(var W: TWorkflow; const By, Text: string);
    procedure QueueOut(var W: TWorkflow; const Kind: string; StepN: Integer;
      const Team, Text: string);
    procedure ActivateReady(var W: TWorkflow);   { pending + deps done -> active }
    { When a step closes, tell the owners of what lies ahead that it is their
      turn. The ACTIVATE notice only fires on the TRANSITION to active
      (FinishActivations requires TaskId=0), so in a fan-out - several steps
      opened at once by the same predecessor - the ones already active were
      NEVER announced again: one closed and the plan moved on in silence. It
      goes to whoever holds the step, never to whoever closed. }
    procedure QueueNextUp(var W: TWorkflow; ClosedN: Integer);
    { A HALT FREEZES EVERYONE, SO EVERYONE MUST HEAR IT. The 'fix' notice goes
      to the owner of the broken step and 'stop' to the owners of steps that
      were ACTIVE; nobody else in the plan is told. When the broken step
      belongs to whoever reported it - a console gate, say - those two notices
      reach only the person who already knew, and the plan stops in silence for
      everybody who built it. This tells every remaining owner. }
    procedure QueueHaltedAll(var W: TWorkflow; const Why, By: string);
    { activation may ripple into OTHER workflows via cross-deps; no saves -
      the caller's whole-store SaveToDisk persists everything at once }
    { Return the number of failed projections in SIBLING workflows--those that
      depended on this one and just became unblocked. Ignoring this count let a
      closed step leave an ACTIVE step in ANOTHER workflow without a task while
      the command reported clean success. }
    function CrossActivateLocked(const SourceWf: string): Integer;
    { Kahn over the combined graph of ALL workflows (intra + cross deps). }
    function HasCycleAllLocked: Boolean;
    function XDepOk(const OwnWf: string; const X: TWfXDep;
      out Why: string): Boolean;
    { Assign identities to steps without one and advance the allocator beyond
      every imported identity. Called during load, undo and restore so an old
      or external card cannot enter without identities or make the allocator
      repeat an existing one. }
    procedure EnsureUids(var W: TWorkflow);
    { Preserve by IDENTITY the cross-workflow dependencies pointing to workflow
      wi when its entire card is replaced (undo or restore). Return the number
      retargeted; MissingDependants identifies dependants whose milestone is not
      in the replacement card. If it is nonempty, nothing was changed. }
    function RetargetCrossDeps(wi: Integer; const Replacement: TWorkflow;
      ApplyChanges: Boolean; out MissingDependants: string): Integer;
    { Check an EXTERNAL card (a restore or edited file) BEFORE touching live
      state: reject duplicate or negative identities. Return '' when coherent.
      Run before EnsureUids because a rejected card must not advance the
      allocator. }
    { An EXTERNAL card--a restore file or historical snapshot--may carry task
      links meaningless here: a number referring to someone else's task, or
      the -1 sentinel for an approval gate whose notice no longer exists.
      Sanitize BEFORE commit, not afterward. Normalizing during projection left
      the sentinel on disk and silenced the gate forever. A link survives only
      when the task exists AND carries this exact step identity. }
    procedure SanitizeImported(var W: TWorkflow);
    function UidsCoherent(const W: TWorkflow): string;
    { INVERSE projection: workflow tasks whose step identity is NO LONGER in the
      current card. Do not mark them done--that would falsify history--but as
      SUPERSEDED, which describes what happened: the branch existed and is no
      longer part of the workflow. If the workflow was aborted but the step
      still exists, the state is 'cancelled', a different case. This is
      reversible: if undo restores that identity, projection finds the task. }
    function SupersedeGone(var W: TWorkflow; out Failed: Integer): Integer;
    { Return the number of steps left UNPROJECTED because their tasks could not
      be created. Returning nothing let callers see only whether the workflow
      file was saved: with task storage down, `wf start` reported clean success
      while leaving an ACTIVE step without a task or notice. }
    function FinishActivations(var W: TWorkflow): Integer;
    { Project into task storage AFTER the workflow transition is already on
      disk. A command has ONE commit point: later work may be retried but must
      not fail or undo what already happened. If projection does not reach
      disk, memory returns to committed state (ACTIVE steps with TaskId=0, the
      durable "projection pending" marker) and repair retries it. Return '' on
      complete success, otherwise the degraded warning to add to the response. }
    function ProjectAfterCommit(wi: Integer; var Snap: string;
      TaskFails: Integer): string;
    procedure QueueComplete(var W: TWorkflow);
    procedure QueueStopResume(var W: TWorkflow; const Kind, Why: string;
      const Extra: string = '');
  public
    constructor Create(const APath: string; ATasks: TTaskStore);
    destructor Destroy; override;

    function CreateWf(const Name, Group, By: string): TWfResult;
    function AddStep(const WfName, Team, Hito: string;
      const After: array of Integer; const XAfter: array of TWfXDep;
      const By: string; const GroupMembers: array of string;
      const EtaS: string = ''): TWfResult;
    { Splice a new step in AFTER step AfterN (0 = before everything): every
      step that depended on AfterN (every root, for 0) is re-hung onto the
      new one. Draft only. }
    function InsertStep(const WfName, Team, Hito: string; AfterN: Integer;
      const By: string; const GroupMembers: array of string;
      const EtaS: string = ''): TWfResult;
    { Splice a step OUT: its dependents inherit its deps. Draft only. }
    function RemoveStep(const WfName: string; StepN: Integer;
      const By: string): TWfResult;
    { Edit a draft step: Field is 'team' | 'hito' | 'after' (Value = comma
      list of step ids; '0' = root). Cycle-checked. }
    function SetStep(const WfName: string; StepN: Integer;
      const Field, Value, By: string;
      const GroupMembers: array of string): TWfResult;
    function StartWf(const WfName, By: string;
      const GroupMembers: array of string): TWfResult;
    function DoneStep(const WfName: string; StepN: Integer;
      const By: string; IsBoss, IsConsole: Boolean;
      const Proof: string = ''): TWfResult;
    function FlagError(const WfName: string; StepN: Integer;
      const Why, By: string; IsConsole: Boolean): TWfResult;
    function MarkFixed(const WfName, Text, By, Boss: string;
      IsConsole: Boolean): TWfResult;
    function Verify(const WfName: string; Pass: Boolean;
      const Note, By: string; IsBoss, IsConsole: Boolean): TWfResult;
    function AbortWf(const WfName, Why, By: string): TWfResult;
    { DELETE an entire workflow. DETACH its tasks; do not delete them. }
    function DeleteWf(const WfName, By, Reason: string): TWfResult;

    { Pre-SetState gate for cmd=task op=state on a linked task. }
    function GateTask(TaskId: Integer; const NewState, From: string;
      IsConsole: Boolean): TWfGate;
    { cmd=task op=assign guard: linked tasks may not be reassigned. }
    function GateAssign(TaskId: Integer; out Why: string): Boolean;

    { Heal after crashes: re-project steps onto linked tasks, finish
      activations. Returns feed lines to broadcast (empty = nothing done). }
    function Reconcile: TWfStrings;

    { Outbox draining (hub): snapshot entries, then clear one by OutId after
      its bus append succeeded. }
    function TakeOutbox(const WfName: string): TWfOutArray;
    procedure OutboxDone(const WfName: string; OutId: Integer);
    { Delivery to an unknown/vanished team can never succeed: halt visibly. }
    function AutoHalt(const WfName, Reason: string): TWfResult;

    { Stall detection (recurring, non-interrupting): for every ACTIVE step of
      a running workflow whose newest sign of life (activation, last linked-
      task note, last nudge) is older than its threshold (step Eta -> workflow
      EtaDef -> 24 h; -1 = off), queue a 'nudge' notice to the owner and an
      escalation to the group's admin. Called from the hub watchdog tick;
      returns feed lines. }
    function NudgeStale(const Admins: TWfAdminMap): TWfStrings;
    { Workflow-level options: Field 'eta' (duration|off|factory) or 'strict'
      (on|off). Allowed on draft/running/halted. }
    function SetWfOption(const WfName, Field, Value, By: string): TWfResult;
    { Linked tasks of one workflow in dependency (Kahn) order, pre-rendered. }
    function TasksView(const WfName: string; out Text: string): Boolean;

    { Copy a workflow into a pristine NEW draft (states reset, tasks/log/
      outbox/members dropped) - the template mechanism. NewMembers = the
      TARGET group's membership; every non-console owner must be in it. }
    function CloneWf(const SrcName, NewName, NewGroup, By: string;
      const NewMembers: array of string): TWfResult;

    { Backups & full time-travel. Every mutating op snapshots the pre-change
      state into <store>/wfhistory/ automatically; HistoryOf lists every
      point; UndoWf returns to the newest point (SnapN=0) or JUMPS to any
      listed snapshot - the current state is snapshotted first (reason
      'undo'), so the jump itself is reversible. Restore replaces a workflow
      with caller-supplied JSON (from wf save). }
    function HistoryOf(const WfName: string): TWfStrings;
    function UndoWf(const WfName, By: string; SnapN: Integer = 0): TWfResult;
    function RestoreWf(const WfName, JsonText, By: string): TWfResult;

    function Get(const Name: string; out W: TWorkflow): Boolean;
    function ListAll: TWorkflowArray;
    { COMBINED SNAPSHOT for a delivery header. Lock workflows, copy them DEEPLY,
      derive their RELATION to tasks (which entries are stale and why), and
      capture the task block and count WITHOUT releasing the workflow lock.
      Lock order is always workflows -> tasks. Separate requests could combine
      an old workflow with new tasks or vice versa; neither view alone could
      detect the reverse mismatch of an open task whose step is already done.
      Formatting happens afterward from the completed copies. }
    function CaptureHeader(const TeamName: string; MaxTasks: Integer;
      out TaskBlock: string; out ActionableN: Integer;
      out Cleanup: TWfStrings): TWorkflowArray;
    { non-terminal workflow bound to this team / group ('' = none) }
    function TeamBusy(const Team: string): string;
    function GroupBusy(const Group: string): string;
  end;

function WfToJson(const W: TWorkflow): TJSONObject;
{ '90m'/'4h'/'2d'/'30s' -> seconds; 'off' -> -1; 'inherit' -> 0. }
function ParseDur(const S: string; out Secs: Integer): Boolean;
{ Parse the store's local 'yyyy-mm-dd"T"hh:nn:ss' stamps (never raises). }
function ParseStamp(const S: string; out DT: TDateTime): Boolean;
{ '30s' / '45m' / '3h12m' / '2d4h' from a second count. }
function AgeStr(Secs: Int64): string;
{ ASCII dependency tree (pure; no lock needed on a copy). FromN > 0 renders
  only the subtree hanging under that step; MaxDepth > 0 stops that many
  levels below the start (a truncation line counts what was cut); Detail
  adds a facts line per node (deps, linked task, timestamps). }
function RenderWfTree(const W: TWorkflow; FromN: Integer = 0;
  MaxDepth: Integer = 0; Detail: Boolean = False): string;
{ '#2 "build api", #4 "e2e"' - the steps a team owns ('' = none). }
function ListStepsOf(const W: TWorkflow; const Team: string): string;
{ '2/4' style progress + one-line summary for lists and headers. }
function DoneCountOf(const W: TWorkflow): Integer;
function WfActiveSummary(const W: TWorkflow): string;
function WfSummaryLine(const W: TWorkflow): string;
function WfProgress(const W: TWorkflow): string;

implementation

function NowStamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
end;

function ParseDur(const S: string; out Secs: Integer): Boolean;
var
  T: string;
  n: Integer;
begin
  Result := False;
  Secs := 0;
  T := LowerCase(Trim(S));
  if T = '' then
    Exit;
  if (T = 'off') or (T = 'no') then
  begin
    Secs := -1;
    Exit(True);
  end;
  if (T = 'inherit') or (T = 'default') then
  begin
    Secs := 0;
    Exit(True);
  end;
  n := StrToIntDef(Copy(T, 1, Length(T) - 1), -1);
  if n < 0 then
    Exit;
  case T[Length(T)] of
    's': Secs := n;
    'm': Secs := n * 60;
    'h': Secs := n * 3600;
    'd': Secs := n * 86400;
  else
    Exit;
  end;
  Result := Secs > 0;
end;

function ParseStamp(const S: string; out DT: TDateTime): Boolean;
var
  Y, Mo, D, H, Mi, Sec: Integer;
  DPart, TPart: TDateTime;
begin
  Result := False;
  DT := 0;
  { 'yyyy-mm-ddThh:nn:ss' = 19 chars, fixed layout }
  if Length(S) < 19 then
    Exit;
  Y := StrToIntDef(Copy(S, 1, 4), -1);
  Mo := StrToIntDef(Copy(S, 6, 2), -1);
  D := StrToIntDef(Copy(S, 9, 2), -1);
  H := StrToIntDef(Copy(S, 12, 2), -1);
  Mi := StrToIntDef(Copy(S, 15, 2), -1);
  Sec := StrToIntDef(Copy(S, 18, 2), -1);
  if (Y < 0) or (Mo < 0) or (D < 0) or (H < 0) or (Mi < 0) or (Sec < 0) then
    Exit;
  if not TryEncodeDate(Y, Mo, D, DPart) then
    Exit;
  if not TryEncodeTime(H, Mi, Sec, 0, TPart) then
    Exit;
  DT := DPart + TPart;
  Result := True;
end;

function AgeStr(Secs: Int64): string;
begin
  if Secs < 0 then
    Secs := 0;
  if Secs < 60 then
    Result := Format('%ds', [Secs])
  else if Secs < 3600 then
    Result := Format('%dm', [Secs div 60])
  else if Secs < 86400 then
    Result := Format('%dh%dm', [Secs div 3600, (Secs mod 3600) div 60])
  else
    Result := Format('%dd%dh', [Secs div 86400, (Secs mod 86400) div 3600]);
end;

{ Age of a stamp in seconds against Now; -1 when unparseable. }
function StampAge(const S: string): Int64;
var
  DT: TDateTime;
begin
  if not ParseStamp(S, DT) then
    Exit(-1);
  Result := Round((Now - DT) * 86400.0);
end;

function IsDoneS(const S: string): Boolean;
begin
  Result := SameText(S, 'done');
end;

function StepIdx(const W: TWorkflow; N: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(W.Steps) do
    if W.Steps[i].N = N then
      Exit(i);
  Result := -1;
end;

function StepLabelOf(const W: TWorkflow; N: Integer): string;
var
  i: Integer;
begin
  i := StepIdx(W, N);
  if i < 0 then
    Result := Format('#%d', [N])
  else
    Result := Format('#%d "%s" (%s)', [N, W.Steps[i].Hito, W.Steps[i].Team]);
end;

function DoneCountOf(const W: TWorkflow): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(W.Steps) do
    if IsDoneS(W.Steps[i].StateS) then
      Inc(Result);
end;

{ A step's LEVEL: how many steps stand ahead of it, at most, along the chain of
  dependencies. A step with no deps is level 0; every other one is one more than
  the highest of its own. This is what "the steps of THAT level" means: the ones
  that can be done at the same time because none waits for another.
  Only deps INSIDE the plan count. Cross-plan deps tie to another plan with its
  own numbering, and mixing them would yield a level meaning nothing in either.
  Depth bounds the recursion: the store forbids cycles at edit time, but a card
  restored by hand never goes through that, and a cycle would hang the hub. }
function LevelOf(const W: TWorkflow; idx, Depth: Integer): Integer;
var
  j, di, n: Integer;
begin
  Result := 0;
  if (idx < 0) or (idx > High(W.Steps)) or (Depth > 64) then
    Exit;
  for j := 0 to High(W.Steps[idx].Deps) do
  begin
    di := StepIdx(W, W.Steps[idx].Deps[j]);
    if di < 0 then
      Continue;
    n := LevelOf(W, di, Depth + 1) + 1;
    if n > Result then
      Result := n;
  end;
end;

{ Next free visible step number (ordinary removal holes are never reused). }
function MaxStepN(const W: TWorkflow): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(W.Steps) do
    if W.Steps[i].N > Result then
      Result := W.Steps[i].N;
end;

{ Kahn's algorithm: True when the dependency graph has a cycle. Editing may
  create forward references (splice-in re-hangs children onto a NEWER id),
  so numeric ordering proves nothing - this check does. }
function HasCycleW(const W: TWorkflow): Boolean;
var
  Left: array of Boolean;
  i, j, k, Remaining: Integer;
  Progress, Ready: Boolean;
begin
  SetLength(Left, Length(W.Steps));
  for i := 0 to High(Left) do
    Left[i] := True;
  Remaining := Length(W.Steps);
  repeat
    Progress := False;
    for i := 0 to High(W.Steps) do
      if Left[i] then
      begin
        Ready := True;
        for j := 0 to High(W.Steps[i].Deps) do
        begin
          k := StepIdx(W, W.Steps[i].Deps[j]);
          if (k >= 0) and Left[k] then
            Ready := False;
        end;
        if Ready then
        begin
          Left[i] := False;
          Dec(Remaining);
          Progress := True;
        end;
      end;
  until not Progress;
  Result := Remaining > 0;
end;

function ListStepsOf(const W: TWorkflow; const Team: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(W.Steps) do
    if SameText(W.Steps[i].Team, Team) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + Format('#%d "%s"', [W.Steps[i].N, W.Steps[i].Hito]);
    end;
end;

function WfProgress(const W: TWorkflow): string;
begin
  Result := Format('%d/%d', [DoneCountOf(W), Length(W.Steps)]);
end;

{ The workflow facts worth SEEING immediately: where it is halted or who owns
  active work. Keep this separate so a client can render its own column without
  parsing the summary line. }
function WfActiveSummary(const W: TWorkflow): string;
var
  i: Integer;
begin
  Result := '';
  if SameText(W.StateS, 'halted') then
    Exit('HALTED at ' + StepLabelOf(W, W.ErrStep));
  if not SameText(W.StateS, 'running') then
    Exit;
  for i := 0 to High(W.Steps) do
    if SameText(W.Steps[i].StateS, 'active') then
    begin
      if Result <> '' then
        Result := Result + ' ';
      if StampAge(W.Steps[i].Started) >= 0 then
        Result := Result + Format('#%d(%s %s)', [W.Steps[i].N, W.Steps[i].Team,
          AgeStr(StampAge(W.Steps[i].Started))])
      else
        Result := Result + Format('#%d(%s)', [W.Steps[i].N, W.Steps[i].Team]);
    end;
end;

function WfSummaryLine(const W: TWorkflow): string;
var
  i: Integer;
  Acts: string;
begin
  Result := Format('%s  @%s  %s  %d/%d done',
    [W.Name, W.Group, W.StateS, DoneCountOf(W), Length(W.Steps)]);
  if SameText(W.StateS, 'halted') then
    Result := Result + '  HALTED at ' + StepLabelOf(W, W.ErrStep)
  else if SameText(W.StateS, 'running') then
  begin
    Acts := '';
    for i := 0 to High(W.Steps) do
      if SameText(W.Steps[i].StateS, 'active') then
      begin
        if Acts <> '' then
          Acts := Acts + ' ';
        if StampAge(W.Steps[i].Started) >= 0 then
          Acts := Acts + Format('#%d(%s %s)', [W.Steps[i].N, W.Steps[i].Team,
            AgeStr(StampAge(W.Steps[i].Started))])
        else
          Acts := Acts + Format('#%d(%s)', [W.Steps[i].N, W.Steps[i].Team]);
      end;
    if Acts <> '' then
      Result := Result + '  active: ' + Acts;
  end;
end;

{ Tree layout: a step hangs under its PRIMARY parent (its highest-numbered
  dep); other deps show as '(also after #k)'. Roots hang under START. }
function RenderWfTree(const W: TWorkflow; FromN: Integer;
  MaxDepth: Integer; Detail: Boolean): string;
var
  Lines: string;

  function MarkerOf(const S: string): string;
  begin
    if SameText(S, 'active') then
      Result := '[ACTIVE]'
    else if SameText(S, 'error') then
      Result := '[ERROR]'
    else if SameText(S, 'pending') then
      Result := '[pend]'
    else
      Result := '[' + LowerCase(S) + ']';
  end;

  { Apply color AFTER fixed-width padding. Otherwise ANSI codes count as Format
    characters and misalign precisely the colored rows users need to inspect. }
  function PaintMarker(const S, Padded: string): string;
  begin
    if SameText(S, 'done') then
      Result := Fg(2, Padded)             { green: completed }
    else if SameText(S, 'active') then
      Result := FgBold(11, Padded)        { bright yellow: due NOW }
    else if SameText(S, 'error') then
      Result := FgBold(9, Padded)         { red: halted by an error }
    else if SameText(S, 'pending') then
      Result := Dim(Padded)               { dim: not due yet }
    else
      Result := Fg(6, Padded);            { any other state, visible }
  end;

  function PrimaryParent(const S: TWfStep): Integer;
  var
    i: Integer;
  begin
    Result := 0;
    for i := 0 to High(S.Deps) do
      if S.Deps[i] > Result then
        Result := S.Deps[i];
  end;

  { count every node of the subtree under N (primary-parent edges) }
  function SubtreeSize(N: Integer): Integer;
  var
    i: Integer;
  begin
    Result := 1;
    for i := 0 to High(W.Steps) do
      if PrimaryParent(W.Steps[i]) = N then
        Inc(Result, SubtreeSize(W.Steps[i].N));
  end;

  procedure PrintNode(N: Integer; const Prefix: string; IsLast: Boolean;
    Depth: Integer);
  var
    i, si, Cut: Integer;
    Glyph, Also, ChildPrefix, Facts, Mark: string;
    Kids: array of Integer;
  begin
    si := StepIdx(W, N);
    if si < 0 then
      Exit;
    if IsLast then
    begin
      Glyph := '`-- ';
      ChildPrefix := Prefix + '    ';
    end
    else
    begin
      Glyph := '|-- ';
      ChildPrefix := Prefix + '|   ';
    end;
    Also := '';
    for i := 0 to High(W.Steps[si].Deps) do
      if W.Steps[si].Deps[i] <> PrimaryParent(W.Steps[si]) then
      begin
        if Also = '' then
          Also := '  (also after #' + IntToStr(W.Steps[si].Deps[i])
        else
          Also := Also + ',#' + IntToStr(W.Steps[si].Deps[i]);
      end;
    for i := 0 to High(W.Steps[si].XDeps) do
    begin
      if Also = '' then
        Also := '  (also after ' + W.Steps[si].XDeps[i].Wf + '#' +
          IntToStr(W.Steps[si].XDeps[i].N)
      else
        Also := Also + ',' + W.Steps[si].XDeps[i].Wf + '#' +
          IntToStr(W.Steps[si].XDeps[i].N);
    end;
    if Also <> '' then
      Also := Also + ')';
    { Compose after applying width, then paint over it. Bold the step number
      because that is what users type to close it; keep the team's stable color
      so branch ownership is recognizable at a glance. }
    Mark := PaintMarker(W.Steps[si].StateS,
              Format('%-8s', [MarkerOf(W.Steps[si].StateS)]));
    if SameText(W.Steps[si].Team, 'console') then
      Lines := Lines + Format('%s%s%s %s %s -- %s%s'#10,
        [Prefix, Glyph, Bold(IntToStr(N)), Mark, W.Steps[si].Hito,
         FgBold(13, 'console [GATE]'), Dim(Also)])
    else
      Lines := Lines + Format('%s%s%s %s %s -- %s%s'#10,
        [Prefix, Glyph, Bold(IntToStr(N)), Mark, W.Steps[si].Hito,
         Fg(TeamColor(W.Steps[si].Team), W.Steps[si].Team), Dim(Also)]);
    if Detail then
    begin
      Facts := '';
      for i := 0 to High(W.Steps[si].Deps) do
      begin
        if Facts <> '' then
          Facts := Facts + ',';
        Facts := Facts + '#' + IntToStr(W.Steps[si].Deps[i]);
      end;
      for i := 0 to High(W.Steps[si].XDeps) do
      begin
        if Facts <> '' then
          Facts := Facts + ',';
        Facts := Facts + W.Steps[si].XDeps[i].Wf + '#' +
          IntToStr(W.Steps[si].XDeps[i].N);
      end;
      if Facts = '' then
        Facts := 'root'
      else
        Facts := 'after ' + Facts;
      if W.Steps[si].TaskId > 0 then
        Facts := Facts + Format('  task #%d', [W.Steps[si].TaskId])
      else if W.Steps[si].TaskId = -1 then
        Facts := Facts + '  gate';
      if W.Steps[si].Eta > 0 then
        Facts := Facts + '  eta ' + AgeStr(W.Steps[si].Eta)
      else if W.Steps[si].Eta < 0 then
        Facts := Facts + '  eta off';
      if SameText(W.Steps[si].StateS, 'active') and
         (StampAge(W.Steps[si].Started) >= 0) then
        Facts := Facts + '  age ' + AgeStr(StampAge(W.Steps[si].Started));
      if W.Steps[si].Started <> '' then
        Facts := Facts + '  started ' + W.Steps[si].Started;
      if W.Steps[si].Closed <> '' then
        Facts := Facts + '  closed ' + W.Steps[si].Closed;
      Lines := Lines + ChildPrefix + '. ' + Facts + #10;
    end;
    Kids := nil;
    for i := 0 to High(W.Steps) do
      if PrimaryParent(W.Steps[i]) = N then
      begin
        SetLength(Kids, Length(Kids) + 1);
        Kids[High(Kids)] := W.Steps[i].N;
      end;
    if (MaxDepth > 0) and (Depth >= MaxDepth) and (Length(Kids) > 0) then
    begin
      Cut := 0;
      for i := 0 to High(Kids) do
        Inc(Cut, SubtreeSize(Kids[i]));
      Lines := Lines + ChildPrefix + Format(
        '... (%d more step(s) below - deeper: --depth %d or no --depth)'#10,
        [Cut, MaxDepth + 1]);
      Exit;
    end;
    for i := 0 to High(Kids) do
      PrintNode(Kids[i], ChildPrefix, i = High(Kids), Depth + 1);
  end;

var
  i: Integer;
  Roots: array of Integer;
begin
  Lines := 'WORKFLOW ' + WfSummaryLine(W) + #10;
  if FromN > 0 then
  begin
    if StepIdx(W, FromN) < 0 then
      Exit('WORKFLOW ' + WfSummaryLine(W) + #10 +
        Format('(no step #%d)', [FromN]));
    Lines := Lines + Format('SUBTREE of #%d'#10, [FromN]);
    PrintNode(FromN, '', True, 1);
    Lines := Lines + Format('END  %d/%d done',
      [DoneCountOf(W), Length(W.Steps)]);
  end
  else
  begin
    Lines := Lines + 'START'#10;
    Roots := nil;
    for i := 0 to High(W.Steps) do
      if Length(W.Steps[i].Deps) = 0 then
      begin
        SetLength(Roots, Length(Roots) + 1);
        Roots[High(Roots)] := W.Steps[i].N;
      end;
    for i := 0 to High(Roots) do
      PrintNode(Roots[i], '', i = High(Roots), 1);
    Lines := Lines + Format('END  %d/%d done',
      [DoneCountOf(W), Length(W.Steps)]);
  end;
  if SameText(W.StateS, 'halted') then
    Lines := Lines + '  HALTED at ' + StepLabelOf(W, W.ErrStep);
  Result := Lines;
end;

{ ---------- JSON ---------- }

function StepToJson(const S: TWfStep): TJSONObject;
var
  D: TJSONArray;
  X: TJSONObject;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('n', S.N);
  Result.Add('uid', S.Uid);
  Result.Add('hito', S.Hito);
  Result.Add('team', S.Team);
  D := TJSONArray.Create;
  for i := 0 to High(S.Deps) do
    D.Add(S.Deps[i]);
  Result.Add('deps', D);
  if Length(S.XDeps) > 0 then
  begin
    D := TJSONArray.Create;
    for i := 0 to High(S.XDeps) do
    begin
      X := TJSONObject.Create;
      X.Add('wf', S.XDeps[i].Wf);
      X.Add('n', S.XDeps[i].N);
      D.Add(X);
    end;
    Result.Add('xdeps', D);
  end;
  Result.Add('state', S.StateS);
  Result.Add('prior', S.PriorS);
  Result.Add('task', S.TaskId);
  if S.Eta <> 0 then
    Result.Add('eta', S.Eta);
  if S.LastNudge <> '' then
    Result.Add('lastnudge', S.LastNudge);
  Result.Add('started', S.Started);
  Result.Add('closed', S.Closed);
end;

function WfToJson(const W: TWorkflow): TJSONObject;
var
  A: TJSONArray;
  O: TJSONObject;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('name', W.Name);
  Result.Add('group', W.Group);
  A := TJSONArray.Create;
  for i := 0 to High(W.Members) do
    A.Add(W.Members[i]);
  Result.Add('members', A);
  Result.Add('state', W.StateS);
  Result.Add('errstep', W.ErrStep);
  Result.Add('errby', W.ErrBy);
  if W.EtaDef <> 0 then
    Result.Add('etadef', W.EtaDef);
  if W.Strict then
    Result.Add('strict', True);
  A := TJSONArray.Create;
  for i := 0 to High(W.Frozen) do
    A.Add(W.Frozen[i]);
  Result.Add('frozen', A);
  Result.Add('created', W.Created);
  Result.Add('started', W.Started);
  Result.Add('closed', W.Closed);
  A := TJSONArray.Create;
  for i := 0 to High(W.Steps) do
    A.Add(StepToJson(W.Steps[i]));
  Result.Add('steps', A);
  A := TJSONArray.Create;
  for i := 0 to High(W.Log) do
  begin
    O := TJSONObject.Create;
    O.Add('ts', W.Log[i].Ts);
    O.Add('by', W.Log[i].By);
    O.Add('text', W.Log[i].Text);
    A.Add(O);
  end;
  Result.Add('log', A);
  A := TJSONArray.Create;
  for i := 0 to High(W.Outbox) do
  begin
    O := TJSONObject.Create;
    O.Add('id', W.Outbox[i].OutId);
    O.Add('kind', W.Outbox[i].Kind);
    O.Add('step', W.Outbox[i].StepN);
    O.Add('team', W.Outbox[i].Team);
    O.Add('text', W.Outbox[i].Text);
    A.Add(O);
  end;
  Result.Add('outbox', A);
end;

function JsonToWf(O: TJSONObject): TWorkflow;
var
  A, D: TJSONArray;
  S: TJSONObject;
  i, j: Integer;
begin
  Result := Default(TWorkflow);
  Result.Name := O.Get('name', '');
  Result.Group := O.Get('group', '');
  Result.StateS := O.Get('state', 'draft');
  Result.ErrStep := O.Get('errstep', 0);
  Result.ErrBy := O.Get('errby', '');
  Result.EtaDef := O.Get('etadef', 0);
  Result.Strict := O.Get('strict', False);
  Result.Created := O.Get('created', '');
  Result.Started := O.Get('started', '');
  Result.Closed := O.Get('closed', '');
  A := O.Get('members', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Members, A.Count);
    for i := 0 to A.Count - 1 do
      Result.Members[i] := A.Items[i].AsString;
  end;
  A := O.Get('frozen', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Frozen, A.Count);
    for i := 0 to A.Count - 1 do
      Result.Frozen[i] := A.Items[i].AsInteger;
  end;
  A := O.Get('steps', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Steps, A.Count);
    for i := 0 to A.Count - 1 do
    begin
      S := TJSONObject(A.Items[i]);
      Result.Steps[i] := Default(TWfStep);
      Result.Steps[i].N := S.Get('n', 0);
      { 0 = card predating identities; LoadFromDisk assigns a new one. }
      Result.Steps[i].Uid := S.Get('uid', Int64(0));
      Result.Steps[i].Hito := S.Get('hito', '');
      Result.Steps[i].Team := S.Get('team', '');
      Result.Steps[i].StateS := S.Get('state', 'pending');
      Result.Steps[i].PriorS := S.Get('prior', '');
      Result.Steps[i].TaskId := S.Get('task', 0);
      Result.Steps[i].Eta := S.Get('eta', 0);
      Result.Steps[i].LastNudge := S.Get('lastnudge', '');
      Result.Steps[i].Started := S.Get('started', '');
      Result.Steps[i].Closed := S.Get('closed', '');
      D := S.Get('deps', TJSONArray(nil));
      if D <> nil then
      begin
        SetLength(Result.Steps[i].Deps, D.Count);
        for j := 0 to D.Count - 1 do
          Result.Steps[i].Deps[j] := D.Items[j].AsInteger;
      end;
      D := S.Get('xdeps', TJSONArray(nil));
      if D <> nil then
      begin
        SetLength(Result.Steps[i].XDeps, D.Count);
        for j := 0 to D.Count - 1 do
        begin
          Result.Steps[i].XDeps[j].Wf :=
            TJSONObject(D.Items[j]).Get('wf', '');
          Result.Steps[i].XDeps[j].N :=
            TJSONObject(D.Items[j]).Get('n', 0);
        end;
      end;
    end;
  end;
  A := O.Get('log', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Log, A.Count);
    for i := 0 to A.Count - 1 do
    begin
      S := TJSONObject(A.Items[i]);
      Result.Log[i].Ts := S.Get('ts', '');
      Result.Log[i].By := S.Get('by', '');
      Result.Log[i].Text := S.Get('text', '');
    end;
  end;
  A := O.Get('outbox', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(Result.Outbox, A.Count);
    for i := 0 to A.Count - 1 do
    begin
      S := TJSONObject(A.Items[i]);
      Result.Outbox[i].OutId := S.Get('id', 0);
      Result.Outbox[i].Kind := S.Get('kind', '');
      Result.Outbox[i].StepN := S.Get('step', 0);
      Result.Outbox[i].Team := S.Get('team', '');
      Result.Outbox[i].Text := S.Get('text', '');
    end;
  end;
end;

{ ---------- result helpers ---------- }

procedure OkFeed(out R: TWfResult; const Feed: array of string);
var
  i: Integer;
begin
  R.Ok := True;
  R.Err := '';
  SetLength(R.Feed, Length(Feed));
  for i := 0 to High(Feed) do
    R.Feed[i] := Feed[i];
end;

procedure Refuse(out R: TWfResult; const Why: string);
begin
  R.Ok := False;
  R.Err := Why;
  R.Feed := nil;
end;

{ ---------- store ---------- }

constructor TWorkflowStore.Create(const APath: string; ATasks: TTaskStore);
var
  SR: TSearchRec;
  p1, p2, v: Integer;
begin
  inherited Create;
  FPath := APath;
  FHistDir := ExtractFilePath(APath) + 'wfhistory';
  FLock := TCriticalSection.Create;
  FTasks := ATasks;
  FCount := 0;
  FNextOut := 1;
  FNextUid := 1;
  FNextSnap := 1;
  SetLength(FWfs, 0);
  ForceDirectories(FHistDir);
  { resume the snapshot counter from the newest file: <name>.<n>.json }
  if FindFirst(FHistDir + '/*.json', faAnyFile, SR) = 0 then
  begin
    repeat
      p2 := Length(SR.Name) - 5;   { last digit sits before '.json' }
      p1 := p2;
      while (p1 > 1) and (SR.Name[p1 - 1] <> '.') do
        Dec(p1);
      v := StrToIntDef(Copy(SR.Name, p1, p2 - p1 + 1), 0);
      if v >= FNextSnap then
        FNextSnap := v + 1;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  LoadFromDisk;
  { The identity counter lives in workflows.json. If that file is LOST or
    quarantined while tareas.json survives, it would restart at 1 and a
    workflow recreated under the same name could adopt OLD tasks--the exact
    wrong-work linkage identity exists to prevent, entering through recovery.
    Seed above every identity still present in tasks. }
  if Assigned(FTasks) and (FTasks.MaxWfStepUid >= FNextUid) then
    FNextUid := FTasks.MaxWfStepUid + 1;
end;

destructor TWorkflowStore.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TWorkflowStore.LoadFromDisk;
var
  WhyUid: string;
  SL: TStringList;
  Root: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  i, j: Integer;

  procedure Quarantine;
  begin
    RenameFile(FPath, FPath + '.bad-' +
      FormatDateTime('yyyymmdd"-"hhnnss', Now));
    Writeln(StdErr, 'pizarra: workflows.json corrupt - quarantined, starting empty');
    FCount := 0;
    SetLength(FWfs, 0);
    FNextOut := 1;
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
        FNextOut := Obj.Get('next_out', 1);
        FNextUid := Obj.Get('next_uid', Int64(1));
        Arr := Obj.Get('workflows', TJSONArray(nil));
        if Arr <> nil then
        begin
          SetLength(FWfs, Arr.Count);
          FCount := Arr.Count;
          for i := 0 to Arr.Count - 1 do
          begin
            FWfs[i] := JsonToWf(TJSONObject(Arr.Items[i]));
            { Duplicate identities in the AUTHORITATIVE file would make two
              steps share a task and send both notices there. This is
              inconsistent and cannot be repaired blindly; quarantine the file
              with the evidence intact, as with any corruption. }
            WhyUid := UidsCoherent(FWfs[i]);
            if WhyUid <> '' then
            begin
              Writeln(StdErr, 'pizarra: workflows.json incoherent (',
                FWfs[i].Name, ': ', WhyUid, ')');
              Quarantine;
              Exit;
            end;
            EnsureUids(FWfs[i]);
            for j := 0 to High(FWfs[i].Outbox) do
              if FWfs[i].Outbox[j].OutId >= FNextOut then
                FNextOut := FWfs[i].Outbox[j].OutId + 1;
          end;
        end;
      except
        Quarantine;
      end;
    finally
      Root.Free;
    end;
  finally
    SL.Free;
  end;
end;

{ Return False when state did NOT reach disk. Swallowing exceptions and treating
  a failed rename as a warning would let the caller report success after
  mutating memory, then lose the accepted object on reopen. }
function TWorkflowStore.SaveToDisk: Boolean;
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
    Root.Add('next_out', FNextOut);
    Root.Add('next_uid', FNextUid);
    Arr := TJSONArray.Create;
    for i := 0 to FCount - 1 do
      Arr.Add(WfToJson(FWfs[i]));
    Root.Add('workflows', Arr);
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
      Synced := fpfsync(FS.Handle) = 0;
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
      Writeln(StdErr, 'pizarra: cannot rename workflows.json.tmp');
      Exit;
    end;
    FDiskImage := S;   { what ACTUALLY reached disk }
  Result := True;
  except
    on E: Exception do
      Writeln(StdErr, 'pizarra: cannot save workflows: ', E.Message);
  end;
end;

function DeepCopyWf(const W: TWorkflow): TWorkflow; forward;

function TWorkflowStore.SnapshotAll: string;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  { Every command starts here immediately after acquiring the lock. Discard any
    recorded history that never committed: some paths record the card and THEN
    reject (`set` validates after recording), and otherwise the next command
    would write that stale snapshot with the timestamp of another transition. }
  FPendSnap := False;
  Root := TJSONObject.Create;
  try
    Root.Add('next_out', FNextOut);
    Root.Add('next_uid', FNextUid);
    Arr := TJSONArray.Create;
    for i := 0 to FCount - 1 do
      Arr.Add(WfToJson(FWfs[i]));
    Root.Add('workflows', Arr);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

procedure TWorkflowStore.RestoreAll(const Snap: string);
var
  D: TJSONData;
  Root: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  if Snap = '' then
    Exit;
  D := nil;
  try
    D := GetJSON(Snap);
    if not (D is TJSONObject) then
      Exit;
    Root := TJSONObject(D);
    FNextOut := Root.Get('next_out', 1);
    FNextUid := Root.Get('next_uid', Int64(1));
    Arr := Root.Get('workflows', TJSONArray(nil));
    FCount := 0;
    if Arr <> nil then
    begin
      SetLength(FWfs, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        FWfs[i] := JsonToWf(TJSONObject(Arr.Items[i]));
        Inc(FCount);
      end;
    end;
  except
    { An unreadable snapshot is worse than no restore; leave state unchanged. }
  end;
  D.Free;
end;

function TWorkflowStore.SaveOrRollback(var Snap: string): Boolean;
begin
  Result := SaveToDisk;
  if Result then
    { Snap ALWAYS reflects disk. This matters when one command saves twice
      (DoneStep persists the step and then projects it onto the task): if the
      second save failed, restoring the ENTRY snapshot would put memory behind
      state already written. Reuse the text SaveToDisk just serialized, making
      refresh free. }
  begin
    Snap := FDiskImage;
    FlushSnapshot;   { receipt: the transition already occurred }
  end
  else
  begin
    RestoreAll(Snap);   { return memory to the on-disk state }
    { It did not occur: leave no history and consume no snapshot number. }
    FPendSnap := False;
  end;
end;

function TWorkflowStore.IndexOf(const Name: string): Integer;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if SameText(FWfs[i].Name, Name) then
      Exit(i);
  Result := -1;
end;

procedure TWorkflowStore.AddLog(var W: TWorkflow; const By, Text: string);
var
  n: Integer;
begin
  n := Length(W.Log);
  SetLength(W.Log, n + 1);
  W.Log[n].Ts := NowStamp;
  W.Log[n].By := By;
  W.Log[n].Text := Text;
end;

procedure TWorkflowStore.QueueOut(var W: TWorkflow; const Kind: string;
  StepN: Integer; const Team, Text: string);
var
  n: Integer;
begin
  n := Length(W.Outbox);
  SetLength(W.Outbox, n + 1);
  W.Outbox[n].OutId := FNextOut;
  Inc(FNextOut);
  W.Outbox[n].Kind := Kind;
  W.Outbox[n].StepN := StepN;
  W.Outbox[n].Team := Team;
  W.Outbox[n].Text := Text;
end;

{ Mark every pending step whose deps are all done as active. Task creation
  and the ACTIVATE notice happen in FinishActivations, so a crash in between
  leaves an active step with TaskId=0 - exactly what Reconcile re-finishes. }
procedure TWorkflowStore.ActivateReady(var W: TWorkflow);
var
  i, j, di: Integer;
  Ready: Boolean;

  { A LEVEL DOES NOT OPEN UNTIL THE ONE BEFORE IT IS CLOSED WHOLE. Direct
    dependencies alone can activate a step while another step one level BELOW
    it remains open. That runs two levels at once and hides the purpose of
    levels: showing what the whole team must finish before anyone moves on. A
    step waits for its deps AND every step in every lower level. This cannot
    deadlock: levels form a topological layering, so the lowest open level
    always contains a step whose dependencies are done. }
  function LowerLevelsClosed(L: Integer): Boolean;
  var
    k: Integer;
  begin
    Result := True;
    if L <= 0 then
      Exit;
    for k := 0 to High(W.Steps) do
      if (not IsDoneS(W.Steps[k].StateS)) and (LevelOf(W, k, 0) < L) then
        Exit(False);
  end;

begin
  if not SameText(W.StateS, 'running') then
    Exit;
  for i := 0 to High(W.Steps) do
    if SameText(W.Steps[i].StateS, 'pending') then
    begin
      Ready := True;
      for j := 0 to High(W.Steps[i].Deps) do
      begin
        di := StepIdx(W, W.Steps[i].Deps[j]);
        if (di < 0) or (not IsDoneS(W.Steps[di].StateS)) then
          Ready := False;
      end;
      { cross-workflow deps: the target step (in FWfs, never W itself -
        self-references are refused at edit time) must be done too }
      for j := 0 to High(W.Steps[i].XDeps) do
      begin
        di := IndexOf(W.Steps[i].XDeps[j].Wf);
        if di < 0 then
          Ready := False
        else
        begin
          di := StepIdx(FWfs[di], W.Steps[i].XDeps[j].N);
          if (di < 0) or
             (not IsDoneS(FWfs[IndexOf(W.Steps[i].XDeps[j].Wf)].Steps[di].StateS)) then
            Ready := False;
        end;
      end;
      { Check the level barrier LAST. It does not change the verdict, but walking
        every step only after dependencies match avoids the scan in the common
        case where nothing activates. }
      if Ready and (not LowerLevelsClosed(LevelOf(W, i, 0))) then
        Ready := False;
      if Ready then
      begin
        W.Steps[i].StateS := 'active';
        W.Steps[i].Started := NowStamp;
      end;
    end;
end;

{ A step has just closed: tell the owners of what lies ahead. The notice is
  built per LEVEL, so everyone sees which sibling steps are still open and who
  answers for each, and is told to do only their own. }
procedure TWorkflowStore.QueueHaltedAll(var W: TWorkflow;
  const Why, By: string);
var
  i, si: Integer;
  ErrTeam, Recipient: string;
  Teams: TStringList;

  { already covered: the owner of the broken step gets 'fix', and the owners of
    the steps frozen mid-flight get 'stop'. Telling them twice would train
    everyone to skim the second one. }
  function YaAvisado(const T: string): Boolean;
  var
    k, d: Integer;
  begin
    Result := SameText(T, ErrTeam);
    if Result then
      Exit;
    for k := 0 to High(W.Frozen) do
    begin
      d := StepIdx(W, W.Frozen[k]);
      if (d >= 0) and SameText(W.Steps[d].Team, T) then
        Exit(True);
    end;
  end;

begin
  ErrTeam := '';
  si := StepIdx(W, W.ErrStep);
  if si >= 0 then
    ErrTeam := W.Steps[si].Team;
  Teams := TStringList.Create;
  try
    Teams.Duplicates := dupIgnore;
    Teams.CaseSensitive := False;
    Teams.Sorted := True;
    { EVERY owner in the plan, not only the ones caught mid-step: someone whose
      steps are all done still needs to know the plan they built is stopped,
      and someone with pending steps needs to know they will not open. }
    for i := 0 to High(W.Steps) do
      if not YaAvisado(W.Steps[i].Team) then
        Teams.Add(W.Steps[i].Team);
    for i := 0 to Teams.Count - 1 do
    begin
      Recipient := Teams[i];
      QueueOut(W, 'halted', W.ErrStep, Recipient, Format(
        'WORKFLOW %s HALTED at step #%d (%s), reported by %s: %s'#10 +
        'Nothing in this plan advances until it is fixed and verified - your ' +
        'steps included, done or pending. You are told because you hold work ' +
        'in it, not because this one is yours.'#10 +
        'Plan: tiza wf show %s',
        [W.Name, W.ErrStep, ErrTeam, By, Why, W.Name]));
    end;
  finally
    Teams.Free;
  end;
end;

procedure TWorkflowStore.QueueNextUp(var W: TWorkflow; ClosedN: Integer);
var
  i, ci, Lvl, Mine: Integer;
  List_, Yours, Who: string;
  Teams: TStringList;

  { A step's title can be a whole paragraph - in real plans it is. Pasted whole,
    it turned the notice into a screenful nobody reads at a glance. The full
    text is never lost: it is one 'tiza wf show' away. }
  function Short_(const S: string): string;
  begin
    if Length(S) <= 60 then
      Exit(S);
    Result := Copy(S, 1, 57) + '...';
  end;

  { One line per open step of the level, naming who answers for it. }
  function LevelList(L: Integer): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 0 to High(W.Steps) do
      if (SameText(W.Steps[k].StateS, 'active') or
          SameText(W.Steps[k].StateS, 'pending')) and
         (LevelOf(W, k, 0) = L) then
        Result := Result + Format('  #%d "%s" -> %s'#10,
          [W.Steps[k].N, Short_(W.Steps[k].Hito), W.Steps[k].Team]);
  end;

begin
  if not SameText(W.StateS, 'running') then
    Exit;
  ci := StepIdx(W, ClosedN);
  if ci < 0 then
    Exit;
  { THE LEVEL OF THE STEP JUST CLOSED. While anything is still open there, the
    plan has not moved down a level: what people need is WHAT IS LEFT HERE. Once
    the level is complete, what must be announced is the next one. }
  Lvl := LevelOf(W, ci, 0);
  List_ := LevelList(Lvl);
  if List_ = '' then
  begin
    Inc(Lvl);
    List_ := LevelList(Lvl);
  end;
  if List_ = '' then
    Exit;   { nothing ahead: the completion notice says so }
  { ONE NOTICE PER OWNER, not one per step: whoever holds two steps of the same
    level would get the same list twice. And everyone sees the WHOLE list, with
    who answers for each step, so they know who they are waiting for and who is
    waiting for them; what changes per recipient is the line marking THEIRS. }
  Teams := TStringList.Create;
  try
    Teams.Duplicates := dupIgnore;
    Teams.CaseSensitive := False;
    Teams.Sorted := True;
    for i := 0 to High(W.Steps) do
      if (SameText(W.Steps[i].StateS, 'active') or
          SameText(W.Steps[i].StateS, 'pending')) and
         (LevelOf(W, i, 0) = Lvl) then
        Teams.Add(W.Steps[i].Team);
    for ci := 0 to Teams.Count - 1 do
    begin
      Who := Teams[ci];
      Yours := '';
      Mine := 0;
      for i := 0 to High(W.Steps) do
        if SameText(W.Steps[i].Team, Who) and
           (SameText(W.Steps[i].StateS, 'active') or
            SameText(W.Steps[i].StateS, 'pending')) and
           (LevelOf(W, i, 0) = Lvl) then
        begin
          if Yours <> '' then
            Yours := Yours + ', ';
          Yours := Yours + '#' + IntToStr(W.Steps[i].N);
          if Mine = 0 then
            Mine := W.Steps[i].N;
        end;
      if Yours = '' then
        Continue;
      QueueOut(W, 'nextup', Mine, Who, Format(
        'WORKFLOW %s: step #%d closed. LEVEL %d - steps still open at this ' +
        'level and who answers for each:'#10 + '%s' +
        'YOURS: %s - do ONLY yours, the rest are not for you. START NOW, no ' +
        'pause: finish AND test, then tiza wf done %s %d'#10 +
        'Whole plan: tiza wf show %s',
        [W.Name, ClosedN, Lvl, List_, Yours, W.Name, Mine, W.Name]));
    end;
  finally
    Teams.Free;
  end;
end;

{ Create the linked task and queue the ACTIVATE notice for every active step
  that has no task yet. Nested FTasks call: lock order engine -> tasks. }
function TWorkflowStore.SupersedeGone(var W: TWorkflow;
  out Failed: Integer): Integer;
var
  Ts: TTaskArray;
  i, j, si: Integer;
  Found: Boolean;
  Want, Note, Why: string;

  procedure Apply(Id: Integer; const NewState, Txt: string;
    const NTitle, NTeam: string);
  begin
    if FTasks.AlignTask(Id, NTitle, NTeam, NewState, Txt, Why) then
      Inc(Result)
    else
      { Do NOT hide a task-store failure. Continuing silently made a failed disk
        indistinguishable from "nothing needed repair". }
      Inc(Failed);
  end;

begin
  Result := 0;
  Failed := 0;
  Ts := FTasks.TasksOfWf(W.Name);
  for i := 0 to High(Ts) do
  begin
    { Find the step by IDENTITY, not by number. }
    Found := False;
    si := -1;
    for j := 0 to High(W.Steps) do
      if W.Steps[j].Uid = Ts[i].WfStepUid then
      begin
        Found := True;
        si := j;
        Break;
      end;

    if not Found then
    begin
      { The identity is absent from the current card. Preserve 'done' because
        that work WAS completed in its branch; everything else is superseded,
        not completed. }
      if IsTerminal(Ts[i]) then
        Continue;
      Apply(Ts[i].Id, 'superseded', Format('superseded: the current card of ' +
        'workflow %s no longer contains the step this task tracked',
        [W.Name]), '', '');
      Continue;
    end;

    { The identity REMAINS in the card; derive the desired state from the step. }
    if SameText(W.StateS, 'aborted') then
    begin
      if not IsTerminal(Ts[i]) then
        Apply(Ts[i].Id, 'cancelled',
          Format('cancelled: workflow %s was aborted', [W.Name]), '', '');
      Continue;
    end;
    if IsDoneS(W.Steps[si].StateS) then
      Want := 'done'
    else if SameText(W.Steps[si].StateS, 'error') then
      Want := 'error'
    else if SameText(W.Steps[si].StateS, 'active') then
    begin
      { The step is ACTIVE again but its task was already DONE. This happens
        when time travel crosses an activation. The task cannot be reopened--
        that work really was completed, and denying it would falsify history--
        or retained as-is, which would leave an active step with an invisible
        task. Detach the identity while retaining the record as a previous
        attempt, and clear the step link so a NEW attempt can be created. }
      if SameText(Ts[i].StateS, 'done') then
      begin
        if FTasks.DetachFromStep(Ts[i].Id, Format(
          'earlier attempt at step #%d of workflow %s: the plan travelled ' +
          'back and the step is active again, so a new task tracks it',
          [W.Steps[si].N, W.Name]), Why) then
        begin
          W.Steps[si].TaskId := 0;   { activation creates the new attempt }
          Inc(Result);
        end
        else
          Inc(Failed);
        Continue;
      end;
      Want := 'open';
    end
    else
      { The step is PENDING again. Its task remains live--neither completed nor
        abandoned--but is due to nobody now. 'waiting' removes it from headers
        without misrepresenting it; activation returns it to 'open'. }
      Want := 'waiting';

    if SameText(Ts[i].StateS, Want) and (Ts[i].Title = W.Steps[si].Hito) and
       SameText(Ts[i].Team, W.Steps[si].Team) then
      Continue;   { already aligned: avoid a pointless write }

    { Historical 'done' is NEVER degraded. }
    if SameText(Ts[i].StateS, 'done') and (Want <> 'done') then
      Continue;

    Note := '';
    if IsTerminal(Ts[i]) and (Want <> 'done') then
      { Time travel restored this identity to the card, so the task exists for
        its owner again. Without this, an ACTIVE step retained a terminal task
        invisible from the header, and repair reported no change. }
      Note := Format('reopened: step identity %d is part of workflow %s again',
        [Ts[i].WfStepUid, W.Name]);
    Apply(Ts[i].Id, Want, Note, W.Steps[si].Hito, W.Steps[si].Team);
  end;
end;
procedure TWorkflowStore.SanitizeImported(var W: TWorkflow);
var
  i: Integer;
  T: TTask;
begin
  T := Default(TTask);
  W.Outbox := nil;   { never resend historical notices }
  for i := 0 to High(W.Steps) do
  begin
    if W.Steps[i].TaskId = 0 then
      Continue;
    if (W.Steps[i].TaskId > 0) and (W.Steps[i].Uid > 0) and
       FTasks.Get(W.Steps[i].TaskId, T) and
       SameText(T.WfName, W.Name) and (T.WfStepUid = W.Steps[i].Uid) then
      Continue;   { verified link: the task exists and belongs to THIS step }
    { Clear a foreign number or gate sentinel. Later projection relinks by
      identity and queues the gate notice again. }
    W.Steps[i].TaskId := 0;
  end;
end;

function TWorkflowStore.UidsCoherent(const W: TWorkflow): string;
var
  i, j: Integer;
begin
  Result := '';
  for i := 0 to High(W.Steps) do
  begin
    if W.Steps[i].Uid < 0 then
      Exit(Format('step #%d has a negative identity (%d)',
        [W.Steps[i].N, W.Steps[i].Uid]));
    if W.Steps[i].Uid = 0 then
      Continue;   { 0 = old card; EnsureUids assigns an identity }
    for j := i + 1 to High(W.Steps) do
      if W.Steps[j].Uid = W.Steps[i].Uid then
        { Two steps with the same identity would share ONE task and send both
          notices there--exactly the wrong-work linkage identity prevents. }
        Exit(Format('steps #%d and #%d share identity %d',
          [W.Steps[i].N, W.Steps[j].N, W.Steps[i].Uid]));
  end;
end;

procedure TWorkflowStore.EnsureUids(var W: TWorkflow);
var
  i: Integer;
begin
  { Advance the allocator first: if the card carries high identities, new ones
    must be issued above them to avoid duplicates. }
  for i := 0 to High(W.Steps) do
    if W.Steps[i].Uid >= FNextUid then
      FNextUid := W.Steps[i].Uid + 1;
  for i := 0 to High(W.Steps) do
    if W.Steps[i].Uid = 0 then
    begin
      W.Steps[i].Uid := FNextUid;
      Inc(FNextUid);
    end;
end;

function TWorkflowStore.ProjectAfterCommit(wi: Integer;
  var Snap: string; TaskFails: Integer): string;
var
  Fails, Bad: Integer;
begin
  Result := '';
  { Combine failures supplied by the caller (for example SetState on the closed
    step's task) with projector and activation failures. }
  Fails := TaskFails;
  { 1. Align tasks to the CURRENT card by identity: supersede absent entries,
       detach a completed attempt from a reactivated step, and mark tasks of
       newly pending steps as waiting. }
  SupersedeGone(FWfs[wi], Bad);
  Inc(Fails, Bad);
  { 2. Project missing work: create tasks and queue notices. }
  Inc(Fails, FinishActivations(FWfs[wi]));
  { 3. DERIVE completion from committed state. Completion was once queued only
       between the command's two writes; if the second failed, the workflow
       remained 'running' with every step done FOREVER because repair never
       reconsidered it, and nobody received completion. This is idempotent: it
       acts only while the workflow is running and no work remains. }
  if SameText(FWfs[wi].StateS, 'running') and
     (Length(FWfs[wi].Steps) > 0) and
     (DoneCountOf(FWfs[wi]) = Length(FWfs[wi].Steps)) then
    QueueComplete(FWfs[wi]);
  if not SaveOrRollback(Snap) then
    Inc(Fails);
  if Fails > 0 then
    { Say "attempt(s)", not "task(s)": one disk failure may be counted twice,
      once by the direct write and once by the projector. Reporting two tasks
      when only one exists would be false; attempts are what is measured. }
    Result := Format(' (%d projection attempt(s) PENDING: the task ' +
      'projection could not be saved; maintenance will retry)', [Fails]);
end;

function TWorkflowStore.FinishActivations(var W: TWorkflow): Integer;
var
  i, j: Integer;
  T: TTask;
  DepTxt, TaskWhy: string;
begin
  Result := 0;
  if not SameText(W.StateS, 'running') then
    Exit;
  for i := 0 to High(W.Steps) do
    if SameText(W.Steps[i].StateS, 'active') and (W.Steps[i].TaskId = 0) then
    begin
      if SameText(W.Steps[i].Team, 'console') then
      begin
        { human APPROVAL GATE: no linked task; the notice reaches the human
          via the console inbox + feed (hub drain branches on 'console').
          TaskId=-1 marks "gate, notice queued" so this loop never re-fires. }
        W.Steps[i].TaskId := -1;
        QueueOut(W, 'activate', W.Steps[i].N, 'console', Format(
          'WORKFLOW %s: APPROVAL GATE #%d "%s" is waiting for YOU.'#10 +
          'Inspect the work, then approve: tiza wf done %s %d   ' +
          'Problem? tiza wf error %s "<why>" --step %d'#10 +
          'Plan: tiza wf show %s',
          [W.Name, W.Steps[i].N, W.Steps[i].Hito, W.Name, W.Steps[i].N,
           W.Name, W.Steps[i].N, W.Name]));
        AddLog(W, 'pizarra', Format('gate #%d activated (awaiting console)',
          [W.Steps[i].N]));
        Continue;
      end;
      { IDEMPOTENT creation by (workflow, step): if a prior link was lost--the
        task reached disk but the workflow did not persist its TaskId--find the
        same task again instead of creating a second one. }
      T := FTasks.AddForStep(W.Steps[i].Hito, W.Steps[i].Team, W.Name,
        W.Steps[i].Uid, TaskWhy);
      if T.Id = 0 then
      begin
        { The task DOES NOT exist. Do not link or announce it. Copying zero once
          queued a notice saying "Task #0 tracks it" and told the team to run
          `tiza task done 0`. Leave the step unprojected so Reconcile retries;
          the workflow state remains correct. }
        { Do NOT append to the workflow log. When the write also failed, each
          repair pass used to add another identical in-memory line (4 -> 5 ->
          6...), all of which a later successful save would persist together.
          The log records transitions that happened; a pending retry is not one.
          COUNT it so callers report it in both response and repair output. }
        Inc(Result);
        Continue;
      end;
      W.Steps[i].TaskId := T.Id;
      DepTxt := '';
      for j := 0 to High(W.Steps[i].Deps) do
      begin
        if DepTxt <> '' then
          DepTxt := DepTxt + ', ';
        DepTxt := DepTxt + StepLabelOf(W, W.Steps[i].Deps[j]);
      end;
      if DepTxt = '' then
        DepTxt := 'it is a root step'
      else
        DepTxt := 'all its dependencies are done: ' + DepTxt;
      QueueOut(W, 'activate', W.Steps[i].N, W.Steps[i].Team, Format(
        'WORKFLOW %s: step #%d "%s" is now ACTIVE for you - %s.'#10 +
        'Task #%d tracks it. Finish AND test, then: tiza task done %d' +
        '  (or: tiza wf done %s %d)'#10 +
        'Whole plan: tiza wf show %s',
        [W.Name, W.Steps[i].N, W.Steps[i].Hito, DepTxt,
         T.Id, T.Id, W.Name, W.Steps[i].N, W.Name]));
      AddLog(W, 'pizarra', Format('step #%d activated (task #%d)',
        [W.Steps[i].N, T.Id]));
    end;
end;

procedure TWorkflowStore.QueueComplete(var W: TWorkflow);
var
  i: Integer;
begin
  W.StateS := 'done';
  W.Closed := NowStamp;
  AddLog(W, 'pizarra', 'workflow complete');
  for i := 0 to High(W.Members) do
    QueueOut(W, 'complete', 0, W.Members[i], Format(
      'WORKFLOW %s COMPLETE - all %d milestone(s) done. Summary: ' +
      'tiza wf show %s', [W.Name, Length(W.Steps), W.Name]));
end;

{ STOP/RESUME fan-out to the owners of the frozen steps, one notice per team
  (dedup), never to the error-step owner (it gets FIX / its own resume text). }
procedure TWorkflowStore.QueueStopResume(var W: TWorkflow;
  const Kind, Why: string; const Extra: string);
var
  i, j, si: Integer;
  Teams: array of string;
  Mine, ErrTeam: string;
  Seen: Boolean;
begin
  ErrTeam := '';
  si := StepIdx(W, W.ErrStep);
  if si >= 0 then
    ErrTeam := W.Steps[si].Team;
  Teams := nil;
  for i := 0 to High(W.Frozen) do
  begin
    si := StepIdx(W, W.Frozen[i]);
    if si < 0 then
      Continue;
    if SameText(W.Steps[si].Team, ErrTeam) then
      Continue;
    Seen := False;
    for j := 0 to High(Teams) do
      if SameText(Teams[j], W.Steps[si].Team) then
        Seen := True;
    if Seen then
      Continue;
    SetLength(Teams, Length(Teams) + 1);
    Teams[High(Teams)] := W.Steps[si].Team;
  end;
  for i := 0 to High(Teams) do
  begin
    Mine := '';
    for j := 0 to High(W.Frozen) do
    begin
      si := StepIdx(W, W.Frozen[j]);
      if (si >= 0) and SameText(W.Steps[si].Team, Teams[i]) then
      begin
        if Mine <> '' then
          Mine := Mine + ', ';
        Mine := Mine + '#' + IntToStr(W.Frozen[j]);
      end;
    end;
    if Kind = 'stop' then
      QueueOut(W, 'stop', W.ErrStep, Teams[i], Format(
        'WORKFLOW %s HALTED at step %s: %s.'#10 +
        'STOP all work on this workflow - including your active step(s) %s - ' +
        'until pizarra announces it is RESUMED.',
        [W.Name, StepLabelOf(W, W.ErrStep), Why, Mine]))
    else
      QueueOut(W, 'resume', W.ErrStep, Teams[i], Format(
        'WORKFLOW %s RESUMED - step %s is fixed and verified.'#10 +
        'Continue your active step(s) %s; finish AND test, then close the ' +
        'linked task (tiza task list shows it).%s',
        [W.Name, StepLabelOf(W, W.ErrStep), Mine, Extra]));
  end;
end;

{ ---------- transitions ---------- }

function TWorkflowStore.CreateWf(const Name, Group, By: string): TWfResult;
var
  W: TWorkflow;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    if IndexOf(Name) >= 0 then
    begin
      Refuse(Result, 'workflow already exists: ' + Name);
      Exit;
    end;
    W := Default(TWorkflow);
    W.Name := Name;
    W.Group := Group;
    W.StateS := 'draft';
    W.Created := NowStamp;
    AddLog(W, By, 'created (group @' + Group + ')');
    SetLength(FWfs, FCount + 1);
    FWfs[FCount] := W;
    Inc(FCount);
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format('workflow %s created for @%s (%s) - draft: add ' +
      'steps, then start', [Name, Group, By])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.AddStep(const WfName, Team, Hito: string;
  const After: array of Integer; const XAfter: array of TWfXDep;
  const By: string; const GroupMembers: array of string;
  const EtaS: string): TWfResult;
var
  wi, i, n, NewN, EtaSecs: Integer;
  IsMember: Boolean;
  DepTxt, WhyX, WfSnap: string;
begin
  EtaSecs := 0;
  if (EtaS <> '') and (not ParseDur(EtaS, EtaSecs)) then
  begin
    Refuse(Result, 'bad --eta value: ' + EtaS +
      ' (accepted: 30s|45m|4h|2d or off)');
    Exit;
  end;
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if not SameText(FWfs[wi].StateS, 'draft') then
    begin
      Refuse(Result, Format('workflow %s is %s - steps can only be added in ' +
        'draft (abort and recreate to replan)', [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    IsMember := SameText(Team, 'console');   { human APPROVAL GATE }
    for i := 0 to High(GroupMembers) do
      if SameText(GroupMembers[i], Team) then
        IsMember := True;
    if not IsMember then
    begin
      Refuse(Result, Format('%s is not a member of group @%s - every step ' +
        'owner must be in the workflow''s group (or ''console'' for a human ' +
        'approval gate)', [Team, FWfs[wi].Group]));
      Exit;
    end;
    NewN := MaxStepN(FWfs[wi]) + 1;
    { deps: default = the last added step; --after 0 = root; each value must
      name an EXISTING step id (holes from removals stay invalid) }
    for i := 0 to High(After) do
    begin
      if (After[i] <> 0) and (StepIdx(FWfs[wi], After[i]) < 0) then
      begin
        Refuse(Result, Format('unknown step #%d in --after (see the ids: ' +
          'tiza wf show %s; use --after 0 for a root step)',
          [After[i], WfName]));
        Exit;
      end;
      if (After[i] = 0) and ((Length(After) > 1) or (Length(XAfter) > 0)) then
      begin
        Refuse(Result, '--after 0 means a root step and cannot be combined ' +
          'with other dependencies');
        Exit;
      end;
    end;
    { cross-workflow deps: validated now; a NEW step has no in-edges, so it
      can never create a cycle by itself }
    for i := 0 to High(XAfter) do
      if not XDepOk(WfName, XAfter[i], WhyX) then
      begin
        Refuse(Result, WhyX);
        Exit;
      end;
    SnapshotLocked(FWfs[wi], 'step');
    n := Length(FWfs[wi].Steps);
    SetLength(FWfs[wi].Steps, n + 1);
    FWfs[wi].Steps[n] := Default(TWfStep);
    FWfs[wi].Steps[n].N := NewN;
    FWfs[wi].Steps[n].Uid := FNextUid;
    Inc(FNextUid);
    FWfs[wi].Steps[n].Hito := Hito;
    FWfs[wi].Steps[n].Team := Team;
    FWfs[wi].Steps[n].StateS := 'pending';
    FWfs[wi].Steps[n].Eta := EtaSecs;
    SetLength(FWfs[wi].Steps[n].XDeps, Length(XAfter));
    for i := 0 to High(XAfter) do
      FWfs[wi].Steps[n].XDeps[i] := XAfter[i];
    if (Length(After) = 0) and (Length(XAfter) > 0) then
      { only cross-deps named: no implicit previous-step dependency }
    else if Length(After) = 0 then
    begin
      { default: linear - depend on the last added step (root when first) }
      if n > 0 then
      begin
        SetLength(FWfs[wi].Steps[n].Deps, 1);
        FWfs[wi].Steps[n].Deps[0] := FWfs[wi].Steps[n - 1].N;
      end;
    end
    else if (Length(After) = 1) and (After[0] = 0) then
      FWfs[wi].Steps[n].Deps := nil    { explicit root }
    else
    begin
      SetLength(FWfs[wi].Steps[n].Deps, Length(After));
      for i := 0 to High(After) do
        FWfs[wi].Steps[n].Deps[i] := After[i];
    end;
    DepTxt := '';
    for i := 0 to High(FWfs[wi].Steps[n].Deps) do
    begin
      if DepTxt <> '' then
        DepTxt := DepTxt + ',';
      DepTxt := DepTxt + '#' + IntToStr(FWfs[wi].Steps[n].Deps[i]);
    end;
    for i := 0 to High(FWfs[wi].Steps[n].XDeps) do
    begin
      if DepTxt <> '' then
        DepTxt := DepTxt + ',';
      DepTxt := DepTxt + FWfs[wi].Steps[n].XDeps[i].Wf + '#' +
        IntToStr(FWfs[wi].Steps[n].XDeps[i].N);
    end;
    if DepTxt = '' then
      DepTxt := 'root'
    else
      DepTxt := 'after ' + DepTxt;
    AddLog(FWfs[wi], By, Format('step #%d "%s" -> %s (%s)',
      [NewN, Hito, Team, DepTxt]));
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format('workflow %s step #%d added: %s -> %s (%s)',
      [WfName, NewN, Hito, Team, DepTxt])]);
  finally
    FLock.Leave;
  end;
end;

{ Common draft-only lookup for the editing ops. }
function DraftCheck(const W: TWorkflow; const WfName: string;
  out R: TWfResult): Boolean;
begin
  Result := False;
  if SameText(W.StateS, 'draft') then
    Exit(True);
  Refuse(R, Format('workflow %s is %s - the structure is editable in draft ' +
    'only (running plans change via wf error / wf abort)',
    [WfName, W.StateS]));
end;

function TWorkflowStore.InsertStep(const WfName, Team, Hito: string;
  AfterN: Integer; const By: string;
  const GroupMembers: array of string; const EtaS: string): TWfResult;
var
  wi, i, j, n, NewN, Moved, EtaSecs: Integer;
  IsMember: Boolean;
  WfSnap: string;
begin
  EtaSecs := 0;
  if (EtaS <> '') and (not ParseDur(EtaS, EtaSecs)) then
  begin
    Refuse(Result, 'bad --eta value: ' + EtaS +
      ' (accepted: 30s|45m|4h|2d or off)');
    Exit;
  end;
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if not DraftCheck(FWfs[wi], WfName, Result) then
      Exit;
    IsMember := SameText(Team, 'console');
    for i := 0 to High(GroupMembers) do
      if SameText(GroupMembers[i], Team) then
        IsMember := True;
    if not IsMember then
    begin
      Refuse(Result, Format('%s is not a member of group @%s - every step ' +
        'owner must be in the workflow''s group (or ''console'' for a human ' +
        'approval gate)', [Team, FWfs[wi].Group]));
      Exit;
    end;
    if (AfterN <> 0) and (StepIdx(FWfs[wi], AfterN) < 0) then
    begin
      Refuse(Result, Format('unknown step #%d (see the ids: tiza wf show ' +
        '%s; --after 0 inserts before everything)', [AfterN, WfName]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'insert');
    NewN := MaxStepN(FWfs[wi]) + 1;
    { splice: every step hanging on AfterN (every root, for 0) re-hangs on
      the new one; the new step itself hangs on AfterN }
    Moved := 0;
    for i := 0 to High(FWfs[wi].Steps) do
      if AfterN = 0 then
      begin
        if Length(FWfs[wi].Steps[i].Deps) = 0 then
        begin
          SetLength(FWfs[wi].Steps[i].Deps, 1);
          FWfs[wi].Steps[i].Deps[0] := NewN;
          Inc(Moved);
        end;
      end
      else
        for j := 0 to High(FWfs[wi].Steps[i].Deps) do
          if FWfs[wi].Steps[i].Deps[j] = AfterN then
          begin
            FWfs[wi].Steps[i].Deps[j] := NewN;
            Inc(Moved);
          end;
    n := Length(FWfs[wi].Steps);
    SetLength(FWfs[wi].Steps, n + 1);
    FWfs[wi].Steps[n] := Default(TWfStep);
    FWfs[wi].Steps[n].N := NewN;
    FWfs[wi].Steps[n].Uid := FNextUid;
    Inc(FNextUid);
    FWfs[wi].Steps[n].Hito := Hito;
    FWfs[wi].Steps[n].Team := Team;
    FWfs[wi].Steps[n].StateS := 'pending';
    FWfs[wi].Steps[n].Eta := EtaSecs;
    if AfterN <> 0 then
    begin
      SetLength(FWfs[wi].Steps[n].Deps, 1);
      FWfs[wi].Steps[n].Deps[0] := AfterN;
    end;
    AddLog(FWfs[wi], By, Format(
      'step #%d "%s" -> %s inserted after #%d (%d dependent(s) re-hung)',
      [NewN, Hito, Team, AfterN, Moved]));
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format(
      'workflow %s step #%d inserted: %s -> %s (after #%d; %d step(s) now ' +
      'hang below it)', [WfName, NewN, Hito, Team, AfterN, Moved])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.RemoveStep(const WfName: string; StepN: Integer;
  const By: string): TWfResult;
var
  wi, si, i, j, k, n: Integer;
  Inherited_: array of Integer;
  InheritedX: array of TWfXDep;
  Seen: Boolean;
  XWho: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if not DraftCheck(FWfs[wi], WfName, Result) then
      Exit;
    si := StepIdx(FWfs[wi], StepN);
    if si < 0 then
    begin
      Refuse(Result, Format('workflow %s has no step #%d', [WfName, StepN]));
      Exit;
    end;
    { A step in ANOTHER workflow may depend on this one. RemoveStep correctly
      spliced same-workflow dependencies but ignored cross-workflow ones,
      leaving the dependant waiting forever on a nonexistent step in [pend],
      without a notice or stall reminder (reminders inspect ACTIVE steps only).
      Refuse the operation, as `team remove` already does for applications and
      open tasks: a silently stranded workflow is worse than a denied delete.
      `wf abort` DOES notify waiting steps (xwarn); deletion lacked that hygiene. }
    XWho := '';
    for i := 0 to FCount - 1 do
      if i <> wi then
        for j := 0 to High(FWfs[i].Steps) do
          for k := 0 to High(FWfs[i].Steps[j].XDeps) do
            if SameText(FWfs[i].Steps[j].XDeps[k].Wf, FWfs[wi].Name) and
               (FWfs[i].Steps[j].XDeps[k].N = StepN) then
            begin
              if XWho <> '' then
                XWho := XWho + ', ';
              XWho := XWho + Format('%s#%d', [FWfs[i].Name, FWfs[i].Steps[j].N]);
            end;
    if XWho <> '' then
    begin
      Refuse(Result, Format('cannot remove %s#%d: %s depend(s) on it - ' +
        're-hang or remove them first (tiza wf set <plan> <step> after ...)',
        [WfName, StepN, XWho]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'remove');
    Inherited_ := Copy(FWfs[wi].Steps[si].Deps);
    { INHERIT MEANS INHERIT EVERYTHING. Dependants inherited same-workflow
      dependencies from the removed step but not CROSS-workflow ones. If the
      step waited on another workflow, removing it erased that wait and started
      its dependants too early, while the response claimed the opposite. This
      splice cannot create a new cycle: a dependant already depended
      transitively on everything the removed step awaited. }
    InheritedX := Copy(FWfs[wi].Steps[si].XDeps);
    { splice out: dependents inherit the removed step's deps (dedup) }
    for i := 0 to High(FWfs[wi].Steps) do
      if i <> si then
      begin
        n := 0;
        for j := 0 to High(FWfs[wi].Steps[i].Deps) do
          if FWfs[wi].Steps[i].Deps[j] <> StepN then
          begin
            FWfs[wi].Steps[i].Deps[n] := FWfs[wi].Steps[i].Deps[j];
            Inc(n);
          end;
        if n <> Length(FWfs[wi].Steps[i].Deps) then
        begin
          SetLength(FWfs[wi].Steps[i].Deps, n);
          for j := 0 to High(Inherited_) do
          begin
            Seen := False;
            for k := 0 to High(FWfs[wi].Steps[i].Deps) do
              if FWfs[wi].Steps[i].Deps[k] = Inherited_[j] then
                Seen := True;
            if not Seen then
            begin
              SetLength(FWfs[wi].Steps[i].Deps,
                Length(FWfs[wi].Steps[i].Deps) + 1);
              FWfs[wi].Steps[i].Deps[High(FWfs[wi].Steps[i].Deps)] :=
                Inherited_[j];
            end;
          end;
          { Include cross-dependencies under the same rule; compare workflow
            names case-insensitively because the name is the identity. }
          for j := 0 to High(InheritedX) do
          begin
            Seen := False;
            for k := 0 to High(FWfs[wi].Steps[i].XDeps) do
              if SameText(FWfs[wi].Steps[i].XDeps[k].Wf, InheritedX[j].Wf) and
                 (FWfs[wi].Steps[i].XDeps[k].N = InheritedX[j].N) then
                Seen := True;
            if not Seen then
            begin
              SetLength(FWfs[wi].Steps[i].XDeps,
                Length(FWfs[wi].Steps[i].XDeps) + 1);
              FWfs[wi].Steps[i].XDeps[High(FWfs[wi].Steps[i].XDeps)] :=
                InheritedX[j];
            end;
          end;
        end;
      end;
    AddLog(FWfs[wi], By, Format('step #%d "%s" removed (dependents re-hung ' +
      'on its dependencies)', [StepN, FWfs[wi].Steps[si].Hito]));
    for i := si to High(FWfs[wi].Steps) - 1 do
      FWfs[wi].Steps[i] := FWfs[wi].Steps[i + 1];
    SetLength(FWfs[wi].Steps, Length(FWfs[wi].Steps) - 1);
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format('workflow %s step #%d removed - its dependents ' +
      'hang on what it depended on', [WfName, StepN])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.SetStep(const WfName: string; StepN: Integer;
  const Field, Value, By: string;
  const GroupMembers: array of string): TWfResult;
var
  wi, si, i, v: Integer;
  IsMember: Boolean;
  NewDeps: array of Integer;
  NewX: array of TWfXDep;
  P, Tok, PrevDeps: string;
  Backup: TWorkflow;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    { eta is not structural: tunable on a RUNNING step (that is the point);
      everything else is draft-only }
    if (not SameText(Field, 'eta')) and
       (not DraftCheck(FWfs[wi], WfName, Result)) then
      Exit;
    si := StepIdx(FWfs[wi], StepN);
    if si < 0 then
    begin
      Refuse(Result, Format('workflow %s has no step #%d', [WfName, StepN]));
      Exit;
    end;
    if SameText(Field, 'eta') then
    begin
      if SameText(FWfs[wi].StateS, 'done') or
         SameText(FWfs[wi].StateS, 'aborted') then
      begin
        Refuse(Result, Format('workflow %s is %s',
          [WfName, FWfs[wi].StateS]));
        Exit;
      end;
      if not ParseDur(Value, v) then
      begin
        Refuse(Result, 'eta must be a duration (30s|45m|4h|2d), off, or ' +
          'inherit');
        Exit;
      end;
      SnapshotLocked(FWfs[wi], 'set');
      FWfs[wi].Steps[si].Eta := v;
    end
    else if SameText(Field, 'team') then
    begin
      IsMember := SameText(Trim(Value), 'console');
      for i := 0 to High(GroupMembers) do
        if SameText(GroupMembers[i], Trim(Value)) then
          IsMember := True;
      if not IsMember then
      begin
        Refuse(Result, Format('%s is not a member of group @%s',
          [Trim(Value), FWfs[wi].Group]));
        Exit;
      end;
      SnapshotLocked(FWfs[wi], 'set');
      FWfs[wi].Steps[si].Team := Trim(Value);
    end
    else if SameText(Field, 'hito') or SameText(Field, 'title') then
    begin
      if Trim(Value) = '' then
      begin
        Refuse(Result, 'empty milestone title');
        Exit;
      end;
      SnapshotLocked(FWfs[wi], 'set');
      FWfs[wi].Steps[si].Hito := Trim(Value);
    end
    else if SameText(Field, 'after') or SameText(Field, 'deps') then
    begin
      { parse the comma list; '0' alone = root; 'wf#n' = cross-workflow dep }
      NewDeps := nil;
      NewX := nil;
      P := Trim(Value);
      while P <> '' do
      begin
        i := Pos(',', P);
        if i = 0 then
        begin
          Tok := Trim(P);
          P := '';
        end
        else
        begin
          Tok := Trim(Copy(P, 1, i - 1));
          P := Trim(Copy(P, i + 1, Length(P)));
        end;
        if Tok = '' then
          Continue;
        i := Pos('#', Tok);
        if i > 1 then
        begin
          SetLength(NewX, Length(NewX) + 1);
          NewX[High(NewX)].Wf := Copy(Tok, 1, i - 1);
          NewX[High(NewX)].N := StrToIntDef(Copy(Tok, i + 1, Length(Tok)), 0);
          if not XDepOk(WfName, NewX[High(NewX)], Tok) then
          begin
            Refuse(Result, Tok);
            Exit;
          end;
          Continue;
        end;
        v := StrToIntDef(Tok, -1);
        if v < 0 then
        begin
          Refuse(Result, 'bad step id in after: ' + Tok +
            ' (cross-plan form: otherwf#3)');
          Exit;
        end;
        if v = StepN then
        begin
          Refuse(Result, Format('step #%d cannot depend on itself', [StepN]));
          Exit;
        end;
        if (v <> 0) and (StepIdx(FWfs[wi], v) < 0) then
        begin
          Refuse(Result, Format('unknown step #%d (tiza wf show %s lists ' +
            'the ids)', [v, WfName]));
          Exit;
        end;
        if v <> 0 then
        begin
          SetLength(NewDeps, Length(NewDeps) + 1);
          NewDeps[High(NewDeps)] := v;
        end;
      end;
      Backup := FWfs[wi];
      Backup.Steps := Copy(FWfs[wi].Steps);
      for i := 0 to High(Backup.Steps) do
      begin
        Backup.Steps[i].Deps := Copy(FWfs[wi].Steps[i].Deps);
        Backup.Steps[i].XDeps := Copy(FWfs[wi].Steps[i].XDeps);
      end;
      PrevDeps := '';
      for i := 0 to High(FWfs[wi].Steps[si].Deps) do
      begin
        if PrevDeps <> '' then
          PrevDeps := PrevDeps + ',';
        PrevDeps := PrevDeps + IntToStr(FWfs[wi].Steps[si].Deps[i]);
      end;
      for i := 0 to High(FWfs[wi].Steps[si].XDeps) do
      begin
        if PrevDeps <> '' then
          PrevDeps := PrevDeps + ',';
        PrevDeps := PrevDeps + FWfs[wi].Steps[si].XDeps[i].Wf + '#' +
          IntToStr(FWfs[wi].Steps[si].XDeps[i].N);
      end;
      FWfs[wi].Steps[si].Deps := NewDeps;
      FWfs[wi].Steps[si].XDeps := NewX;
      if HasCycleW(FWfs[wi]) or HasCycleAllLocked then
      begin
        FWfs[wi] := Backup;
        Refuse(Result, Format('rejected: making #%d depend on [%s] would ' +
          'create a cycle', [StepN, Trim(Value)]));
        Exit;
      end;
      SnapshotLocked(Backup, 'set');
    end
    else
    begin
      Refuse(Result, 'unknown field ' + Field + ' (team|hito|after)');
      Exit;
    end;
    AddLog(FWfs[wi], By, Format('step #%d %s = %s',
      [StepN, LowerCase(Field), Trim(Value)]));
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    { 'after' REPLACES the entire list. Someone running `wf set p 3 after 2`
      expecting to ADD a dependency loses the existing ones. Reporting the
      previous list makes that loss visible instead of merely echoing the new
      value. }
    if SameText(Field, 'after') and (PrevDeps <> '') and
       (PrevDeps <> Trim(Value)) then
      OkFeed(Result, [Format('workflow %s step #%d: after = %s ' +
        '(REPLACES the previous value: %s)',
        [WfName, StepN, Trim(Value), PrevDeps])])
    else
      OkFeed(Result, [Format('workflow %s step #%d: %s = %s',
        [WfName, StepN, LowerCase(Field), Trim(Value)])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.StartWf(const WfName, By: string;
  const GroupMembers: array of string): TWfResult;
var
  Degraded: string;
  wi, i: Integer;
  Mine, Tree: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if not SameText(FWfs[wi].StateS, 'draft') then
    begin
      Refuse(Result, Format('workflow %s is already %s',
        [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    if Length(FWfs[wi].Steps) = 0 then
    begin
      Refuse(Result, Format('workflow %s has no steps - add at least one: ' +
        'tiza wf step %s <team> <milestone>', [WfName, WfName]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'start');
    SetLength(FWfs[wi].Members, Length(GroupMembers));
    for i := 0 to High(GroupMembers) do
      FWfs[wi].Members[i] := GroupMembers[i];
    FWfs[wi].StateS := 'running';
    FWfs[wi].Started := NowStamp;
    AddLog(FWfs[wi], By, 'started');
    ActivateReady(FWfs[wi]);
    { START notice to every member: the whole plan + an explicit WAIT rule.
      Root owners additionally receive their ACTIVATE notice (from
      FinishActivations) telling them to begin now. }
    Tree := RenderWfTree(FWfs[wi]);
    for i := 0 to High(FWfs[wi].Members) do
    begin
      Mine := ListStepsOf(FWfs[wi], FWfs[wi].Members[i]);
      if Mine = '' then
        Mine := '(none - you are informed as a member of @' +
          FWfs[wi].Group + ')'
      else
        Mine := Mine + '. WAIT - do NOT start a step until pizarra tells ' +
          'you it is ACTIVE';
      QueueOut(FWfs[wi], 'start', 0, FWfs[wi].Members[i], Format(
        'WORKFLOW %s STARTED for @%s - %d milestone(s):'#10'%s'#10 +
        'Your milestone(s): %s.'#10'Plan anytime: tiza wf show %s',
        [FWfs[wi].Name, FWfs[wi].Group, Length(FWfs[wi].Steps), Tree,
         Mine, FWfs[wi].Name]));
    end;
    Mine := ListStepsOf(FWfs[wi], 'console');
    if Mine <> '' then
      QueueOut(FWfs[wi], 'start', 0, 'console', Format(
        'WORKFLOW %s STARTED for @%s - you hold approval gate(s): %s. ' +
        'pizarra will tell you when each is waiting.',
        [FWfs[wi].Name, FWfs[wi].Group, Mine]));
    { COMMIT first. If this does not reach disk, nothing was projected, so an
      orphan task cannot remain for a workflow still in draft. }
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    Degraded := ProjectAfterCommit(wi, WfSnap, 0);
    OkFeed(Result, [Format('workflow %s STARTED (%d steps, group @%s)%s',
      [WfName, Length(FWfs[wi].Steps), FWfs[wi].Group, Degraded])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.DoneStep(const WfName: string; StepN: Integer;
  const By: string; IsBoss, IsConsole: Boolean;
  const Proof: string): TWfResult;
var
  TaskWhy: string;
  wi, si, i, TaskFails: Integer;
  T: TTask;
  Acts, Feed: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if SameText(FWfs[wi].StateS, 'halted') then
    begin
      Refuse(Result, Format('workflow %s is HALTED at step %s - fix and ' +
        'verify first; plan: tiza wf show %s',
        [WfName, StepLabelOf(FWfs[wi], FWfs[wi].ErrStep), WfName]));
      Exit;
    end;
    if not SameText(FWfs[wi].StateS, 'running') then
    begin
      Refuse(Result, Format('workflow %s is %s', [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    { step defaulting: the caller's single active step }
    if StepN = 0 then
    begin
      Acts := '';
      for i := 0 to High(FWfs[wi].Steps) do
        if SameText(FWfs[wi].Steps[i].StateS, 'active') and
           SameText(FWfs[wi].Steps[i].Team, By) then
        begin
          if StepN = 0 then
            StepN := FWfs[wi].Steps[i].N
          else
          begin
            if Acts = '' then
              Acts := '#' + IntToStr(StepN);
            Acts := Acts + ', #' + IntToStr(FWfs[wi].Steps[i].N);
          end;
        end;
      if StepN = 0 then
      begin
        { A bare "you have no active step" left the operator without a command,
          even though the console CAN close a named step via its boss override.
          List current active steps so the dead end becomes a command to copy. }
        Acts := '';
        for i := 0 to High(FWfs[wi].Steps) do
          if SameText(FWfs[wi].Steps[i].StateS, 'active') then
          begin
            if Acts <> '' then
              Acts := Acts + ', ';
            Acts := Acts + Format('#%d (%s)',
              [FWfs[wi].Steps[i].N, FWfs[wi].Steps[i].Team]);
          end;
        if Acts <> '' then
          Refuse(Result, Format('you hold no active step in %s - name the ' +
            'one you mean: tiza wf done %s <step>   (active now: %s)',
            [WfName, WfName, Acts]))
        else
          Refuse(Result, Format('you own no active step in workflow %s ' +
            '(no step is active right now)', [WfName]));
        Exit;
      end;
      if Acts <> '' then
      begin
        Refuse(Result, Format('you own several active steps (%s) - name ' +
          'one: tiza wf done %s <step>', [Acts, WfName]));
        Exit;
      end;
    end;
    si := StepIdx(FWfs[wi], StepN);
    if si < 0 then
    begin
      Refuse(Result, Format('workflow %s has no step #%d', [WfName, StepN]));
      Exit;
    end;
    if not SameText(FWfs[wi].Steps[si].StateS, 'active') then
    begin
      if SameText(FWfs[wi].Steps[si].StateS, 'pending') then
        Refuse(Result, Format('step %s is not active yet - waiting on its ' +
          'dependencies; plan: tiza wf show %s',
          [StepLabelOf(FWfs[wi], StepN), WfName]))
      else
        Refuse(Result, Format('step %s is %s',
          [StepLabelOf(FWfs[wi], StepN), FWfs[wi].Steps[si].StateS]));
      Exit;
    end;
    if (not IsConsole) and (not IsBoss) and
       (not SameText(FWfs[wi].Steps[si].Team, By)) then
    begin
      Refuse(Result, Format('only %s (the owner), the group boss or the ' +
        'console may close step #%d', [FWfs[wi].Steps[si].Team, StepN]));
      Exit;
    end;
    { human approval gates are closed by the human only - the whole point }
    if SameText(FWfs[wi].Steps[si].Team, 'console') and (not IsConsole) then
    begin
      Refuse(Result, Format('step #%d is an APPROVAL GATE - only the ' +
        'console may approve it', [StepN]));
      Exit;
    end;
    if FWfs[wi].Strict and (Trim(Proof) = '') then
    begin
      Refuse(Result, Format('workflow %s is STRICT - describe how you ' +
        'tested: tiza wf done %s %d "<how you tested>"',
        [WfName, WfName, StepN]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'done');
    FWfs[wi].Steps[si].StateS := 'done';
    FWfs[wi].Steps[si].Closed := NowStamp;
    if Trim(Proof) <> '' then
      AddLog(FWfs[wi], By, Format('step #%d done: %s', [StepN, Trim(Proof)]))
    else
      AddLog(FWfs[wi], By, Format('step #%d done', [StepN]));
    { workflows.json is authoritative: persist the step first, then project
      onto the linked task; Reconcile heals a crash in between }
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    TaskFails := 0;
    if FWfs[wi].Steps[si].TaskId > 0 then
      { ONE write to the task. The proof is already saved in the authoritative
        workflow log. Also copying it as a task note required two consecutive
        commits, and retrying projection after a failure between them could add
        the same proof twice. A duplicate note is not worth that cost.
        COUNT failures: ignoring them let the command report clean success with
        task storage down, leaving an open task behind a closed step. }
      if not FTasks.SetState(FWfs[wi].Steps[si].TaskId, 'done', 'pizarra', T,
        TaskWhy) then
        Inc(TaskFails);
    ActivateReady(FWfs[wi]);
    { BEFORE projecting: newly activated steps still have TaskId=0 here, which
      is how they are told apart from the ones that were already active. After
      FinishActivations they would all have a task and there would be no way to
      know which one has just been announced. }
    QueueNextUp(FWfs[wi], StepN);
    Acts := '';
    for i := 0 to High(FWfs[wi].Steps) do
      if SameText(FWfs[wi].Steps[i].StateS, 'active') then
      begin
        if Acts <> '' then
          Acts := Acts + ', ';
        Acts := Acts + Format('#%d (%s)', [FWfs[wi].Steps[i].N,
          FWfs[wi].Steps[i].Team]);
      end;
    if DoneCountOf(FWfs[wi]) = Length(FWfs[wi].Steps) then
    begin
      QueueComplete(FWfs[wi]);
      { ALWAYS name the closed step. When defaulted from the caller's sole
        active step, this is the only notice identifying an unnamed closure; if
        it was wrong, the team must see that before continuing. }
      Feed := Format('workflow %s #%d done (%s) - COMPLETE (%d steps). ' +
        'If that was the wrong step: tiza wf undo %s',
        [WfName, StepN, By, Length(FWfs[wi].Steps), WfName]);
    end
    else if Acts <> '' then
      Feed := Format('workflow %s #%d done (%s) -> active: %s',
        [WfName, StepN, By, Acts])
    else
      Feed := Format('workflow %s #%d done (%s)', [WfName, StepN, By]);
    { a finished step may unblock steps in OTHER plans (cross-deps); the
      single whole-store save below persists every touched workflow }
    Inc(TaskFails, CrossActivateLocked(WfName));
    { The step ALREADY committed above. What follows is PROJECTION: failure must
      not claim "the change was undone"--the step is done on disk--or encourage
      repetition of a command that occurred. Memory returns to committed state,
      repair retries projection, and the command reports SUCCESS plus exactly
      WHAT remains pending. }
    Feed := Feed + ProjectAfterCommit(wi, WfSnap, TaskFails);
    OkFeed(Result, [Feed]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.FlagError(const WfName: string; StepN: Integer;
  const Why, By: string; IsConsole: Boolean): TWfResult;
var
  TaskFails: Integer;
  TaskWhy, Feed: string;
  wi, si, i, n: Integer;
  T: TTask;
  IsMember: Boolean;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if SameText(FWfs[wi].StateS, 'halted') then
    begin
      { do not lose the report: log it, refuse the second halt }
      AddLog(FWfs[wi], By, 'additional error report: ' + Why);
      if not SaveOrRollback(WfSnap) then
      begin
        Refuse(Result, 'not saved: the change was undone (disk write failed)');
        Exit;
      end;
      Refuse(Result, Format('workflow %s is already HALTED at step %s - ' +
        'your report was logged; resolve the current error first',
        [WfName, StepLabelOf(FWfs[wi], FWfs[wi].ErrStep)]));
      Exit;
    end;
    if not SameText(FWfs[wi].StateS, 'running') then
    begin
      Refuse(Result, Format('workflow %s is %s', [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    if not IsConsole then
    begin
      IsMember := False;
      for i := 0 to High(FWfs[wi].Members) do
        if SameText(FWfs[wi].Members[i], By) then
          IsMember := True;
      if not IsMember then
      begin
        Refuse(Result, Format('only members of @%s (or the console) may ' +
          'report errors on workflow %s', [FWfs[wi].Group, WfName]));
        Exit;
      end;
    end;
    if Trim(Why) = '' then
    begin
      Refuse(Result,
        'describe the error: tiza wf error ' + WfName + ' "<what is wrong>"');
      Exit;
    end;
    { target defaulting: the single active step }
    if StepN = 0 then
    begin
      n := 0;
      for i := 0 to High(FWfs[wi].Steps) do
        if SameText(FWfs[wi].Steps[i].StateS, 'active') then
        begin
          Inc(n);
          StepN := FWfs[wi].Steps[i].N;
        end;
      if n = 0 then
      begin
        Refuse(Result, Format('no active step in workflow %s - name the ' +
          'step: tiza wf error %s "<why>" --step <n>', [WfName, WfName]));
        Exit;
      end;
      if n > 1 then
      begin
        Refuse(Result, Format('several steps are active - name one: ' +
          'tiza wf error %s "<why>" --step <n>', [WfName, WfName]));
        Exit;
      end;
    end;
    si := StepIdx(FWfs[wi], StepN);
    if si < 0 then
    begin
      Refuse(Result, Format('workflow %s has no step #%d', [WfName, StepN]));
      Exit;
    end;
    if (not SameText(FWfs[wi].Steps[si].StateS, 'active')) and
       (not IsDoneS(FWfs[wi].Steps[si].StateS)) then
    begin
      Refuse(Result, Format('step %s is %s - errors are reported on active ' +
        'or done steps (nothing was built yet for a pending one)',
        [StepLabelOf(FWfs[wi], StepN), FWfs[wi].Steps[si].StateS]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'error');
    { snapshot the active set BEFORE the halt, for STOP now / RESUME later }
    FWfs[wi].Frozen := nil;
    for i := 0 to High(FWfs[wi].Steps) do
      if SameText(FWfs[wi].Steps[i].StateS, 'active') then
      begin
        SetLength(FWfs[wi].Frozen, Length(FWfs[wi].Frozen) + 1);
        FWfs[wi].Frozen[High(FWfs[wi].Frozen)] := FWfs[wi].Steps[i].N;
      end;
    FWfs[wi].StateS := 'halted';
    FWfs[wi].ErrStep := StepN;
    FWfs[wi].ErrBy := By;
    FWfs[wi].Steps[si].PriorS := FWfs[wi].Steps[si].StateS;
    FWfs[wi].Steps[si].StateS := 'error';
    FWfs[wi].Steps[si].Closed := '';
    AddLog(FWfs[wi], By, Format('ERROR on step #%d: %s', [StepN, Why]));
    QueueOut(FWfs[wi], 'fix', StepN, FWfs[wi].Steps[si].Team, Format(
      'WORKFLOW %s HALTED - ERROR in YOUR step #%d "%s": %s (reported by ' +
      '%s).'#10'The whole workflow is STOPPED waiting for you. Fix it, ' +
      'TEST the fix, then: tiza wf fixed %s "what you fixed + how you ' +
      'tested"'#10'Plan: tiza wf show %s',
      [WfName, StepN, FWfs[wi].Steps[si].Hito, Why, By, WfName, WfName]));
    QueueStopResume(FWfs[wi], 'stop', Why);
    QueueHaltedAll(FWfs[wi], Why, By);
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    { Reopen the linked task so the owner's header shows the broken step. The
      workflow is ALREADY halted on disk: report a failure here, but do not undo
      the halt or turn the command into an error. }
    TaskFails := 0;
    if FWfs[wi].Steps[si].TaskId > 0 then
      if not FTasks.SetState(FWfs[wi].Steps[si].TaskId, 'error', 'pizarra', T,
        TaskWhy) then
        Inc(TaskFails);
    Feed := Format('workflow %s HALTED: #%d (%s) by %s: %s',
      [WfName, StepN, FWfs[wi].Steps[si].Team, By, Why]);
    if TaskFails > 0 then
      Feed := Feed + ' (the linked task could NOT be marked in error: the ' +
        'task store refused the write; maintenance will retry)';
    OkFeed(Result, [Feed]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.MarkFixed(const WfName, Text, By, Boss: string;
  IsConsole: Boolean): TWfResult;
var
  wi, si: Integer;
  Verifier, Note, FeedTail: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if not SameText(FWfs[wi].StateS, 'halted') then
    begin
      Refuse(Result, Format('workflow %s is not halted', [WfName]));
      Exit;
    end;
    si := StepIdx(FWfs[wi], FWfs[wi].ErrStep);
    if si < 0 then
    begin
      Refuse(Result, Format('workflow %s: error step #%d vanished',
        [WfName, FWfs[wi].ErrStep]));
      Exit;
    end;
    if (not IsConsole) and (not SameText(FWfs[wi].Steps[si].Team, By)) then
    begin
      Refuse(Result, Format('only %s (the step owner) may mark #%d fixed',
        [FWfs[wi].Steps[si].Team, FWfs[wi].ErrStep]));
      Exit;
    end;
    if Trim(Text) = '' then
    begin
      Refuse(Result, 'describe the fix and how you tested it: tiza wf fixed '
        + WfName + ' "<what you fixed + how you tested>"');
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'fixed');
    FWfs[wi].Steps[si].StateS := 'fixed';
    Note := Format('step #%d fixed by %s: %s', [FWfs[wi].ErrStep, By, Text]);
    if IsConsole and (not SameText(FWfs[wi].Steps[si].Team, By)) then
      Note := Note + ' [console override]';
    AddLog(FWfs[wi], By, Note);
    { verifier chain (never the fixer): error reporter -> group boss ->
      the human console (feed line names it) }
    Verifier := '';
    if (FWfs[wi].ErrBy <> '') and
       (not SameText(FWfs[wi].ErrBy, 'console')) and
       (not SameText(FWfs[wi].ErrBy, FWfs[wi].Steps[si].Team)) then
      Verifier := FWfs[wi].ErrBy
    else if (Boss <> '') and
            (not SameText(Boss, FWfs[wi].Steps[si].Team)) then
      Verifier := Boss;
    if Verifier <> '' then
    begin
      QueueOut(FWfs[wi], 'verify_req', FWfs[wi].ErrStep, Verifier, Format(
        'WORKFLOW %s: %s reports step #%d "%s" FIXED: %s'#10 +
        'VERIFY it yourself (re-test), then: tiza wf verify %s ok   ' +
        '(or: tiza wf verify %s fail "why")',
        [WfName, FWfs[wi].Steps[si].Team, FWfs[wi].ErrStep,
         FWfs[wi].Steps[si].Hito, Text, WfName, WfName]));
      FeedTail := ' (verifier: ' + Verifier + ')';
    end
    else
      FeedTail := ' (console is the verifier: tiza wf verify ' + WfName +
        ' ok)';
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format('workflow %s #%d fixed by %s, awaiting verify%s',
      [WfName, FWfs[wi].ErrStep, By, FeedTail])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.Verify(const WfName: string; Pass: Boolean;
  const Note, By: string; IsBoss, IsConsole: Boolean): TWfResult;
var
  TaskFails: Integer;
  TaskWhy: string;
  Ok2: Boolean;
  wi, si, i, j, k: Integer;
  T: TTask;
  IsReporter, WasDone, Grew: Boolean;
  Feed, Hint, Built: string;
  InClo: array of Boolean;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if not SameText(FWfs[wi].StateS, 'halted') then
    begin
      Refuse(Result, Format('workflow %s is not halted', [WfName]));
      Exit;
    end;
    si := StepIdx(FWfs[wi], FWfs[wi].ErrStep);
    if si < 0 then
    begin
      Refuse(Result, Format('workflow %s: error step #%d vanished',
        [WfName, FWfs[wi].ErrStep]));
      Exit;
    end;
    if not SameText(FWfs[wi].Steps[si].StateS, 'fixed') then
    begin
      Refuse(Result, Format('step #%d is not marked fixed yet - the owner ' +
        '(%s) must first run: tiza wf fixed %s "<what+how tested>"',
        [FWfs[wi].ErrStep, FWfs[wi].Steps[si].Team, WfName]));
      Exit;
    end;
    { the fixer NEVER verifies its own fix - not even as group boss; the
      console is exempt (operator override doctrine, loudly logged) }
    if (not IsConsole) and SameText(By, FWfs[wi].Steps[si].Team) then
    begin
      Refuse(Result, 'verification must come from another party - you ' +
        'fixed it (the reporter, the group boss or the console verifies)');
      Exit;
    end;
    IsReporter := SameText(By, FWfs[wi].ErrBy);
    if (not IsConsole) and (not IsBoss) and (not IsReporter) then
    begin
      Refuse(Result, Format('only the error reporter (%s), the group boss ' +
        'or the console may verify workflow %s', [FWfs[wi].ErrBy, WfName]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'verify');
    if not Pass then
    begin
      FWfs[wi].Steps[si].StateS := 'error';
      AddLog(FWfs[wi], By, Format('verification FAILED for #%d: %s',
        [FWfs[wi].ErrStep, Note]));
      QueueOut(FWfs[wi], 'verify_fail', FWfs[wi].ErrStep,
        FWfs[wi].Steps[si].Team, Format(
        'WORKFLOW %s - verification FAILED for #%d "%s": %s (by %s). ' +
        'Still HALTED. Fix again, TEST, then: tiza wf fixed %s "..."',
        [WfName, FWfs[wi].ErrStep, FWfs[wi].Steps[si].Hito, Note, By,
         WfName]));
      if not SaveOrRollback(WfSnap) then
      begin
        Refuse(Result, 'not saved: the change was undone (disk write failed)');
        Exit;
      end;
      OkFeed(Result, [Format('workflow %s verify FAIL by %s - still halted',
        [WfName, By])]);
      Exit;
    end;
    { verified: restore the step to what it was before the error }
    WasDone := IsDoneS(FWfs[wi].Steps[si].PriorS);
    if WasDone then
    begin
      FWfs[wi].Steps[si].StateS := 'done';
      FWfs[wi].Steps[si].Closed := NowStamp;
    end
    else
      FWfs[wi].Steps[si].StateS := 'active';
    FWfs[wi].Steps[si].PriorS := '';
    FWfs[wi].StateS := 'running';
    AddLog(FWfs[wi], By, Format('verify OK for #%d - workflow resumed',
      [FWfs[wi].ErrStep]));
    { repair ripple hint: what was already built ON TOP of a repaired DONE
      step deserves a re-check (informational only - no state changes) }
    Hint := '';
    if WasDone then
    begin
      SetLength(InClo, Length(FWfs[wi].Steps));
      for i := 0 to High(InClo) do
        InClo[i] := FWfs[wi].Steps[i].N = FWfs[wi].ErrStep;
      repeat
        Grew := False;
        for i := 0 to High(FWfs[wi].Steps) do
          if not InClo[i] then
            for j := 0 to High(FWfs[wi].Steps[i].Deps) do
            begin
              k := StepIdx(FWfs[wi], FWfs[wi].Steps[i].Deps[j]);
              if (k >= 0) and InClo[k] then
              begin
                InClo[i] := True;
                Grew := True;
              end;
            end;
      until not Grew;
      Built := '';
      for i := 0 to High(FWfs[wi].Steps) do
        if InClo[i] and (FWfs[wi].Steps[i].N <> FWfs[wi].ErrStep) and
           (IsDoneS(FWfs[wi].Steps[i].StateS) or
            SameText(FWfs[wi].Steps[i].StateS, 'active')) then
        begin
          if Built <> '' then
            Built := Built + ',';
          Built := Built + '#' + IntToStr(FWfs[wi].Steps[i].N);
        end;
      if Built <> '' then
        Hint := Format(#10'NOTE: step(s) %s were built on top of #%d - ' +
          're-check each; if the fix invalidated one, flag it: ' +
          'tiza wf error %s "<why>" --step <k>' + '.' +
          '',
          [Built, FWfs[wi].ErrStep, WfName]);
    end;
    QueueStopResume(FWfs[wi], 'resume', '', Hint);
    { The RESUMED notice MUST NOT depend on whether the step was already done.
      The team's last message told it the workflow was HALTED by its step and
      to STOP until resume. If the restored step was already done,
      QueueStopResume skipped its owner (the error team) and an `if not WasDone`
      guard used to suppress this notice as well. The team then obeyed STOP
      forever while ANOTHER of its steps silently became active. ALWAYS notify
      it; only the requested next action changes--finish this step or continue
      with the others. }
    if not WasDone then
      QueueOut(FWfs[wi], 'resume', FWfs[wi].ErrStep, FWfs[wi].Steps[si].Team,
        Format('WORKFLOW %s RESUMED - your fix for #%d "%s" is VERIFIED. ' +
          'Continue and finish the step; then: tiza wf done %s %d',
          [WfName, FWfs[wi].ErrStep, FWfs[wi].Steps[si].Hito, WfName,
           FWfs[wi].ErrStep]))
    else
      QueueOut(FWfs[wi], 'resume', FWfs[wi].ErrStep, FWfs[wi].Steps[si].Team,
        Format('WORKFLOW %s RESUMED - your fix for #%d "%s" is VERIFIED and ' +
          'that step is DONE again. The workflow is no longer stopped: carry ' +
          'on with your other steps (tiza wf show %s).%s',
          [WfName, FWfs[wi].ErrStep, FWfs[wi].Steps[si].Hito, WfName, Hint]));
    Feed := Format('workflow %s verify ok (%s) - RESUMED', [WfName, By]);
    if Hint <> '' then
      Feed := Feed + StringReplace(Hint, #10, ' ', [rfReplaceAll]);
    FWfs[wi].ErrStep := 0;
    FWfs[wi].ErrBy := '';
    FWfs[wi].Frozen := nil;
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    { Verification ALREADY committed above. What follows is PROJECTION under the
      same rule as `wf done`: failure does NOT turn the command into an error or
      claim the change was undone while disk already says RUNNING. Report
      success and identify the pending work instead of inviting a duplicate. }
    TaskFails := 0;
    if FWfs[wi].Steps[si].TaskId > 0 then
    begin
      if WasDone then
        Ok2 := FTasks.SetState(FWfs[wi].Steps[si].TaskId, 'done', 'pizarra', T,
          TaskWhy)
      else
        Ok2 := FTasks.SetState(FWfs[wi].Steps[si].TaskId, 'open', 'pizarra', T,
          TaskWhy);
      if not Ok2 then
        Inc(TaskFails);
    end;
    ActivateReady(FWfs[wi]);
    if DoneCountOf(FWfs[wi]) = Length(FWfs[wi].Steps) then
    begin
      QueueComplete(FWfs[wi]);
      Feed := Feed + ' and COMPLETE';
    end;
    Inc(TaskFails, CrossActivateLocked(WfName));
    Feed := Feed + ProjectAfterCommit(wi, WfSnap, TaskFails);
    OkFeed(Result, [Feed]);
  finally
    FLock.Leave;
  end;
end;

{ Delete a workflow. This is destructive and has no recycle bin, therefore:

  - A RUNNING workflow is not deleted; abort it first. Otherwise a team with an
    active step keeps waiting for work that vanished, without notification.
  - Its tasks are NOT deleted: the work happened and they are its record. Detach
    and retain them as ordinary tasks. Report the count so the operator knows
    how many unlinked tasks remain. }
function TWorkflowStore.DeleteWf(const WfName, By, Reason: string): TWfResult;
var
  wi, i, j, k, Soltadas: Integer;
  XWho, Info: string;
  YaEsta: Boolean;
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if SameText(FWfs[wi].StateS, 'running') or
       SameText(FWfs[wi].StateS, 'halted') then
    begin
      Refuse(Result, Format('workflow %s is %s: abort it first, so its teams ' +
        'learn the plan is over instead of waiting for a step that vanished',
        [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    { A WORKFLOW NEVER DISAPPEARS ALONE: ANOTHER MAY BE WAITING ON IT. A step in
      another workflow may depend on one here (`--after thiswf#3`). Deleting it
      makes activation fail to find the source and leaves the dependant in
      [pend] FOREVER, silently, because stall reminders inspect ACTIVE steps
      only. The waiting team receives neither task nor notice, and cannot even
      inspect the vanished blocker. Refuse while naming each dependant, as
      `wf remove` does for a single step: silent stranding is worse than a
      denied delete. }
    XWho := '';
    for i := 0 to FCount - 1 do
      if i <> wi then
        for j := 0 to High(FWfs[i].Steps) do
        begin
          YaEsta := False;
          for k := 0 to High(FWfs[i].Steps[j].XDeps) do
            if (not YaEsta) and
               SameText(FWfs[i].Steps[j].XDeps[k].Wf, FWfs[wi].Name) then
            begin
              YaEsta := True;
              if XWho <> '' then
                XWho := XWho + ', ';
              XWho := XWho + Format('%s#%d', [FWfs[i].Name, FWfs[i].Steps[j].N]);
            end;
        end;
    if XWho <> '' then
    begin
      Refuse(Result, Format('cannot delete %s: %s depend(s) on its steps - ' +
        're-hang or remove those deps first (tiza wf set <plan> <step> after ...)',
        [WfName, XWho]));
      Exit;
    end;
    { Use FCount, not Length(FWfs): like task storage, the array is a BUFFER with
      spare capacity. Shrinking it with SetLength left the counter pointing out
      of bounds and crashed the hub on its next access. }
    for i := wi to FCount - 2 do
      FWfs[i] := FWfs[i + 1];
    Dec(FCount);
    FWfs[FCount] := Default(TWorkflow);
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the deletion was undone (disk write failed)');
      Exit;
    end;
    { After the commit point this is PROJECTION. Report failure without undoing
      a deletion already on disk. }
    Soltadas := FTasks.UnlinkWf(WfName);
    Result.Ok := True;
    SetLength(Result.Feed, 1);
    { WHO and WHY, both in the feed line that is logged + broadcast: six months
      on, a reader must be able to tell a plan deleted because its section left
      the project from one deleted by mistake. }
    Info := Format('workflow %s deleted by %s', [WfName, By]);
    if Trim(Reason) <> '' then
      Info := Info + ': ' + Reason;
    if Soltadas < 0 then
      Result.Feed[0] := Info + ' - but its tasks could NOT be unlinked (disk ' +
        'write failed): they still name a plan that is gone'
    else if Soltadas > 0 then
      Result.Feed[0] := Format('%s; %d task(s) unlinked and kept', [Info, Soltadas])
    else
      Result.Feed[0] := Info;
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.AbortWf(const WfName, Why, By: string): TWfResult;
var
  AbFeed: string;
  TaskFails: Integer;
  CancelWhy: string;
  wi, i, si2, x2: Integer;
  T: TTask;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if SameText(FWfs[wi].StateS, 'done') or
       SameText(FWfs[wi].StateS, 'aborted') then
    begin
      Refuse(Result, Format('workflow %s is already %s',
        [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    SnapshotLocked(FWfs[wi], 'abort');
    FWfs[wi].StateS := 'aborted';
    FWfs[wi].Closed := NowStamp;
    FWfs[wi].ErrStep := 0;
    FWfs[wi].ErrBy := '';
    FWfs[wi].Frozen := nil;
    AddLog(FWfs[wi], By, 'aborted: ' + Why);
    for i := 0 to High(FWfs[wi].Members) do
      QueueOut(FWfs[wi], 'abort', 0, FWfs[wi].Members[i], Format(
        { Do not claim tasks were closed. This notice is queued BEFORE attempting
          that write, so failed task storage would turn the assertion into a
          false and durable statement. Say only what is known. }
        'WORKFLOW %s ABORTED by %s: %s. Stop workflow work; its linked ' +
        'tasks are being cancelled.', [WfName, By, Why]));
    { warn every step in OTHER plans that waits on this one - it will
      never activate now }
    for i := 0 to FCount - 1 do
      if (i <> wi) and (not SameText(FWfs[i].StateS, 'done')) and
         (not SameText(FWfs[i].StateS, 'aborted')) then
        for si2 := 0 to High(FWfs[i].Steps) do
          if not IsDoneS(FWfs[i].Steps[si2].StateS) then
            for x2 := 0 to High(FWfs[i].Steps[si2].XDeps) do
              if SameText(FWfs[i].Steps[si2].XDeps[x2].Wf, WfName) then
                QueueOut(FWfs[i], 'xwarn', FWfs[i].Steps[si2].N,
                  FWfs[i].Steps[si2].Team, Format(
                  'WORKFLOW %s was ABORTED - your step #%d "%s" in %s ' +
                  'waits on %s#%d and will NEVER activate. Replan: tiza wf ' +
                  'set %s %d after <...> (or wf abort %s).',
                  [WfName, FWfs[i].Steps[si2].N, FWfs[i].Steps[si2].Hito,
                   FWfs[i].Name, WfName, FWfs[i].Steps[si2].XDeps[x2].N,
                   FWfs[i].Name, FWfs[i].Steps[si2].N, FWfs[i].Name]));
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    TaskFails := 0;
    { Close linked tasks so they do not pollute headers, but mark them CANCELLED,
      not done: aborting a workflow does not complete its work, and 'done'
      falsifies history and completed-work counts. It also made the inverse
      projector's 'cancelled' branch unreachable because terminal tasks are
      skipped. }
    for i := 0 to High(FWfs[wi].Steps) do
      if (FWfs[wi].Steps[i].TaskId > 0) and
         (not IsDoneS(FWfs[wi].Steps[i].StateS)) and
         FTasks.Get(FWfs[wi].Steps[i].TaskId, T) and (not IsTerminal(T)) then
        if not FTasks.CloseAs(FWfs[wi].Steps[i].TaskId, 'cancelled',
          Format('cancelled: workflow %s was aborted by %s (%s)',
          [WfName, By, Why]), CancelWhy) then
          Inc(TaskFails);
    AbFeed := Format('workflow %s ABORTED by %s: %s', [WfName, By, Why]);
    if TaskFails > 0 then
      { The workflow is ALREADY aborted on disk; only task closure failed.
        Hiding that would leave dead work in someone's header. }
      AbFeed := AbFeed + Format(' (%d linked task(s) could NOT be cancelled: ' +
        'the task store refused the write; maintenance will retry)',
        [TaskFails]);
    OkFeed(Result, [AbFeed]);
  finally
    FLock.Leave;
  end;
end;

{ ---------- task gate ---------- }

function TWorkflowStore.GateTask(TaskId: Integer;
  const NewState, From: string; IsConsole: Boolean): TWfGate;
var
  wi, i, si: Integer;
  NS: string;
begin
  Result.Allow := True;
  Result.Why := '';
  Result.WfDone := False;
  Result.WfName := '';
  Result.StepN := 0;
  if TaskId <= 0 then
    Exit;
  NS := LowerCase(Trim(NewState));
  FLock.Enter;
  try
    for wi := 0 to FCount - 1 do
    begin
      if (not SameText(FWfs[wi].StateS, 'running')) and
         (not SameText(FWfs[wi].StateS, 'halted')) then
        Continue;
      si := -1;
      for i := 0 to High(FWfs[wi].Steps) do
        if FWfs[wi].Steps[i].TaskId = TaskId then
          si := i;
      if si < 0 then
        Continue;
      { the task belongs to a live workflow step }
      Result.WfName := FWfs[wi].Name;
      Result.StepN := FWfs[wi].Steps[si].N;
      if SameText(FWfs[wi].StateS, 'halted') then
      begin
        Result.Allow := False;
        if FWfs[wi].ErrStep = FWfs[wi].Steps[si].N then
          Result.Why := Format('task #%d tracks the ERROR step #%d of ' +
            'workflow %s - use: tiza wf fixed %s "<what you fixed + how ' +
            'you tested>"', [TaskId, FWfs[wi].Steps[si].N, FWfs[wi].Name,
            FWfs[wi].Name])
        else
          Result.Why := Format('workflow %s is HALTED at step %s - nothing ' +
            'advances until it is fixed and verified; plan: tiza wf show %s',
            [FWfs[wi].Name, StepLabelOf(FWfs[wi], FWfs[wi].ErrStep),
             FWfs[wi].Name]);
        Exit;
      end;
      { running workflow }
      if IsDoneS(FWfs[wi].Steps[si].StateS) then
      begin
        Result.Allow := False;
        Result.Why := Format('task #%d tracks the finished step #%d of ' +
          'workflow %s - found a problem there? report it: tiza wf error ' +
          '%s "<why>" --step %d', [TaskId, FWfs[wi].Steps[si].N,
          FWfs[wi].Name, FWfs[wi].Name, FWfs[wi].Steps[si].N]);
        Exit;
      end;
      if (NS = 'superseded') or (NS = 'cancelled') or (NS = 'waiting') then
      begin
        { These states terminate a task but do NOT complete its milestone. The
          PROJECTOR writes them when a step identity leaves the card or the
          workflow is aborted. Routing them through the "done" transition would
          turn abandoned work into completed work--the distinction these states
          exist to preserve. Allowing them directly would remove an ACTIVE
          milestone from the header. }
        Result.Allow := False;
        Result.WfDone := False;
        Result.Why := Format('task #%d tracks step #%d of workflow %s: "%s" ' +
          'is set by pizarra itself, not by hand. Finished? tiza wf done %s ' +
          '%d. Plan changed? tiza wf undo|restore %s. Dropping the plan? ' +
          'tiza wf abort %s "<why>"',
          [TaskId, FWfs[wi].Steps[si].N, FWfs[wi].Name, NS, FWfs[wi].Name,
           FWfs[wi].Steps[si].N, FWfs[wi].Name, FWfs[wi].Name]);
        Exit;
      end;
      if NS = 'done' then
      begin
        { finishing the linked task IS finishing the milestone - route it
          through the workflow transition (owner/boss/console checked there) }
        Result.Allow := False;
        Result.WfDone := True;
        Exit;
      end;
      { non-done progress states on the owner's own active task: fine }
      if (not IsConsole) and (not SameText(From, FWfs[wi].Steps[si].Team)) then
      begin
        Result.Allow := False;
        Result.Why := Format('task #%d tracks step #%d of workflow %s and ' +
          'belongs to %s - only the owner records progress on it',
          [TaskId, FWfs[wi].Steps[si].N, FWfs[wi].Name,
           FWfs[wi].Steps[si].Team]);
      end;
      Exit;
    end;
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.GateAssign(TaskId: Integer; out Why: string): Boolean;
var
  wi, i: Integer;
begin
  Result := True;
  Why := '';
  if TaskId <= 0 then
    Exit;
  FLock.Enter;
  try
    for wi := 0 to FCount - 1 do
    begin
      if (not SameText(FWfs[wi].StateS, 'running')) and
         (not SameText(FWfs[wi].StateS, 'halted')) then
        Continue;
      for i := 0 to High(FWfs[wi].Steps) do
        if FWfs[wi].Steps[i].TaskId = TaskId then
        begin
          Why := Format('task #%d tracks step #%d of workflow %s - ' +
            'milestone ownership lives in the workflow and cannot be ' +
            'reassigned', [TaskId, FWfs[wi].Steps[i].N, FWfs[wi].Name]);
          Exit(False);
        end;
    end;
  finally
    FLock.Leave;
  end;
end;

{ ---------- reconcile / outbox ---------- }

function TWorkflowStore.Reconcile: TWfStrings;
var
  wi, i, OutBefore, Gone, GoneBad, Pend: Integer;
  T: TTask;
  Changed: Boolean;
  WfSnap: string;
begin
  Result := nil;
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    for wi := 0 to FCount - 1 do
    begin
      { PHASE 1 for EVERY workflow state: tasks whose step no longer exists.
        Skipping workflows not currently running left permanent drift after a
        halt or abort: open tasks assigned for work no longer in the workflow. }
      Gone := SupersedeGone(FWfs[wi], GoneBad);
      if Gone > 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Format(
          'workflow %s: %d linked task(s) re-aligned with the current plan',
          [FWfs[wi].Name, Gone]);
      end;
      if GoneBad > 0 then
      begin
        { REPORT failure: a task store rejecting writes otherwise looked exactly
          like "nothing needed repair". }
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Format(
          'workflow %s: %d linked task(s) could NOT be re-aligned (task store ' +
          'write failed) - will retry', [FWfs[wi].Name, GoneBad]);
      end;
      { PHASE 2 only while running: activate and project pending work. A halted
        or aborted workflow MUST NOT emit activation notices. }
      if not SameText(FWfs[wi].StateS, 'running') then
        Continue;
      Changed := False;
      OutBefore := Length(FWfs[wi].Outbox);
      for i := 0 to High(FWfs[wi].Steps) do
      begin
        { crash between wf save and task projection in DoneStep }
        if IsDoneS(FWfs[wi].Steps[i].StateS) and
           (FWfs[wi].Steps[i].TaskId > 0) and
           FTasks.Get(FWfs[wi].Steps[i].TaskId, T) and IsOpen(T) then
        begin
          FTasks.SetState(FWfs[wi].Steps[i].TaskId, 'done', 'pizarra', T);
          Changed := True;
        end;
        { Verify links by IDENTITY, not mere existence. A task detached while
          recreating an attempt still existed but no longer carried this
          (workflow, step), so an existence check never cleared the stale link
          and the new attempt was never created. }
        if SameText(FWfs[wi].Steps[i].StateS, 'active') and
           (FWfs[wi].Steps[i].TaskId > 0) and
           ((not FTasks.Get(FWfs[wi].Steps[i].TaskId, T)) or
            (T.WfStepUid <> FWfs[wi].Steps[i].Uid) or
            (not SameText(T.WfName, FWfs[wi].Name))) then
        begin
          FWfs[wi].Steps[i].TaskId := 0;
          Changed := True;
        end;
      end;
      ActivateReady(FWfs[wi]);
      Pend := FinishActivations(FWfs[wi]);
      { Derive completion here too, so a workflow left running with all work done
        after its command's second write failed is repaired. }
      if SameText(FWfs[wi].StateS, 'running') and
         (Length(FWfs[wi].Steps) > 0) and
         (DoneCountOf(FWfs[wi]) = Length(FWfs[wi].Steps)) then
      begin
        QueueComplete(FWfs[wi]);
        Changed := True;
      end;
      if Pend > 0 then
      begin
        { REPORT this even when no persistable state changed. Otherwise a failed
          task store produced silent pass after silent pass, indistinguishable
          from "nothing needed repair", while a step stayed ACTIVE without a
          task. }
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Format(
          'workflow %s: %d active step(s) still have NO task (the task store ' +
          'refused the write) - not startable yet, will retry',
          [FWfs[wi].Name, Pend]);
      end;
      if Changed or (Length(FWfs[wi].Outbox) <> OutBefore) then
      begin
        SetLength(Result, Length(Result) + 1);
        { Repair pass: if it does not reach disk, roll back and retry next time.
          Reconcile is idempotent--it observes and repairs the same divergence
          again--so retry is correct, while advancing memory beyond disk is not. }
        if SaveOrRollback(WfSnap) then
          Result[High(Result)] :=
            Format('workflow %s reconciled', [FWfs[wi].Name])
        else
          Result[High(Result)] := Format(
            'workflow %s: reconcile NOT saved - undone, will retry',
            [FWfs[wi].Name]);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.TakeOutbox(const WfName: string): TWfOutArray;
var
  wi, i: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    wi := IndexOf(WfName);
    if wi < 0 then
      Exit;
    SetLength(Result, Length(FWfs[wi].Outbox));
    for i := 0 to High(FWfs[wi].Outbox) do
      Result[i] := FWfs[wi].Outbox[i];
  finally
    FLock.Leave;
  end;
end;

procedure TWorkflowStore.OutboxDone(const WfName: string; OutId: Integer);
var
  wi, i, n: Integer;
begin
  FLock.Enter;
  try
    wi := IndexOf(WfName);
    if wi < 0 then
      Exit;
    n := 0;
    for i := 0 to High(FWfs[wi].Outbox) do
      if FWfs[wi].Outbox[i].OutId <> OutId then
      begin
        FWfs[wi].Outbox[n] := FWfs[wi].Outbox[i];
        Inc(n);
      end;
    if n <> Length(FWfs[wi].Outbox) then
    begin
      SetLength(FWfs[wi].Outbox, n);
      { RECEIPT, not transition: the notice is already in the journal. If its
        delivery receipt cannot be persisted, log and continue. Rolling back or
        returning an error would retry something that DID occur. Restart may
        offer it again: explicitly at-least-once delivery. }
    if not SaveToDisk then
      Writeln(StdErr, 'pizarra: workflow outbox receipt NOT durable (the ',
        'notice WAS delivered; it may be re-offered after a restart)');
    end;
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.AutoHalt(const WfName, Reason: string): TWfResult;
var
  wi, i: Integer;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if (wi < 0) or (not SameText(FWfs[wi].StateS, 'running')) then
    begin
      Refuse(Result, '');
      Exit;
    end;
    FWfs[wi].Frozen := nil;
    for i := 0 to High(FWfs[wi].Steps) do
      if SameText(FWfs[wi].Steps[i].StateS, 'active') then
      begin
        SetLength(FWfs[wi].Frozen, Length(FWfs[wi].Frozen) + 1);
        FWfs[wi].Frozen[High(FWfs[wi].Frozen)] := FWfs[wi].Steps[i].N;
      end;
    FWfs[wi].StateS := 'halted';
    FWfs[wi].ErrBy := 'pizarra';
    { ErrStep must identify a REAL step. Leaving it at 0 made both `wf fixed` and
      `wf verify` answer "error step #0 vanished", halting the workflow with NO
      command-level recovery except abort or manual workflows.json editing. Use
      the first newly frozen active step--where the operator needs to inspect--
      or, if none exists, the workflow's first step. }
    if Length(FWfs[wi].Frozen) > 0 then
      FWfs[wi].ErrStep := FWfs[wi].Frozen[0]
    else if Length(FWfs[wi].Steps) > 0 then
      FWfs[wi].ErrStep := FWfs[wi].Steps[0].N
    else
      FWfs[wi].ErrStep := 0;
    AddLog(FWfs[wi], 'pizarra', 'AUTO-HALT: ' + Reason);
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    if FWfs[wi].ErrStep > 0 then
      OkFeed(Result, [Format('workflow %s AUTO-HALTED at #%d: %s (fix the ' +
        'cause, then: tiza wf fixed %s "what you did" and have another party ' +
        'run tiza wf verify %s ok)',
        [WfName, FWfs[wi].ErrStep, Reason, WfName, WfName])])
    else
      OkFeed(Result, [Format('workflow %s AUTO-HALTED: %s (console: check ' +
        'the config, then abort it)', [WfName, Reason])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.XDepOk(const OwnWf: string; const X: TWfXDep;
  out Why: string): Boolean;
var
  wi2: Integer;
begin
  Result := False;
  Why := '';
  if SameText(X.Wf, OwnWf) then
  begin
    Why := Format('use --after %d for a same-plan dependency', [X.N]);
    Exit;
  end;
  wi2 := IndexOf(X.Wf);
  if wi2 < 0 then
  begin
    Why := 'unknown workflow: ' + X.Wf;
    Exit;
  end;
  if StepIdx(FWfs[wi2], X.N) < 0 then
  begin
    Why := Format('workflow %s has no step #%d', [X.Wf, X.N]);
    Exit;
  end;
  Result := True;
end;

function TWorkflowStore.HasCycleAllLocked: Boolean;
var
  Left: array of array of Boolean;
  wi, i, j, k, wi2, Remaining: Integer;
  Progress, Ready: Boolean;
begin
  SetLength(Left, FCount);
  Remaining := 0;
  for wi := 0 to FCount - 1 do
  begin
    SetLength(Left[wi], Length(FWfs[wi].Steps));
    for i := 0 to High(Left[wi]) do
      Left[wi][i] := True;
    Inc(Remaining, Length(FWfs[wi].Steps));
  end;
  repeat
    Progress := False;
    for wi := 0 to FCount - 1 do
      for i := 0 to High(FWfs[wi].Steps) do
        if Left[wi][i] then
        begin
          Ready := True;
          for j := 0 to High(FWfs[wi].Steps[i].Deps) do
          begin
            k := StepIdx(FWfs[wi], FWfs[wi].Steps[i].Deps[j]);
            if (k >= 0) and Left[wi][k] then
              Ready := False;
          end;
          for j := 0 to High(FWfs[wi].Steps[i].XDeps) do
          begin
            wi2 := IndexOf(FWfs[wi].Steps[i].XDeps[j].Wf);
            if wi2 >= 0 then
            begin
              k := StepIdx(FWfs[wi2], FWfs[wi].Steps[i].XDeps[j].N);
              if (k >= 0) and Left[wi2][k] then
                Ready := False;
            end;
          end;
          if Ready then
          begin
            Left[wi][i] := False;
            Dec(Remaining);
            Progress := True;
          end;
        end;
  until not Progress;
  Result := Remaining > 0;
end;

function TWorkflowStore.CrossActivateLocked(const SourceWf: string): Integer;
var
  wi, i, j: Integer;
  Touched: Boolean;
begin
  Result := 0;
  for wi := 0 to FCount - 1 do
    if (not SameText(FWfs[wi].Name, SourceWf)) and
       SameText(FWfs[wi].StateS, 'running') then
    begin
      Touched := False;
      for i := 0 to High(FWfs[wi].Steps) do
        for j := 0 to High(FWfs[wi].Steps[i].XDeps) do
          if SameText(FWfs[wi].Steps[i].XDeps[j].Wf, SourceWf) then
            Touched := True;
      if Touched then
      begin
        ActivateReady(FWfs[wi]);
        Inc(Result, FinishActivations(FWfs[wi]));
      end;
    end;
end;

{ ---------- stall detection / options / views ---------- }

function TWorkflowStore.NudgeStale(const Admins: TWfAdminMap): TWfStrings;
var
  wi, i, j, thr: Integer;
  RefS, S2, Admin, AgeS, WfSnap: string;
  Age: Int64;
  Changed: Boolean;
begin
  Result := nil;
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    for wi := 0 to FCount - 1 do
    begin
      { halted workflows keep their frozen steps 'active' - never nudge them }
      if not SameText(FWfs[wi].StateS, 'running') then
        Continue;
      Changed := False;
      for i := 0 to High(FWfs[wi].Steps) do
        if SameText(FWfs[wi].Steps[i].StateS, 'active') then
        begin
          thr := FWfs[wi].Steps[i].Eta;
          if thr = 0 then
            thr := FWfs[wi].EtaDef;
          if thr = 0 then
            thr := 86400;                 { factory default: 24 h }
          if thr < 0 then
            Continue;                     { nudging off }
          { newest sign of life; the fixed-format stamps compare as strings }
          RefS := FWfs[wi].Steps[i].Started;
          if FWfs[wi].Steps[i].TaskId > 0 then
          begin
            S2 := FTasks.LastNoteTs(FWfs[wi].Steps[i].TaskId);
            if S2 > RefS then
              RefS := S2;
          end;
          if FWfs[wi].Steps[i].LastNudge > RefS then
            RefS := FWfs[wi].Steps[i].LastNudge;
          Age := StampAge(RefS);
          if (Age < 0) or (Age <= thr) then
            Continue;
          { Report the REAL silence since the latest sign of life--start, note,
            or previous reminder--not age since activation. Otherwise a step
            nudged 30 minutes ago but started five days ago reports "5d0h". }
          AgeS := AgeStr(Age);
          if FWfs[wi].Steps[i].TaskId = -1 then
            { human approval gate }
            QueueOut(FWfs[wi], 'nudge', FWfs[wi].Steps[i].N, 'console',
              Format('WORKFLOW %s: APPROVAL GATE #%d "%s" has waited %s ' +
                'for you. Approve: tiza wf done %s %d   Problem? tiza wf ' +
                'error %s "why" --step %d',
                [FWfs[wi].Name, FWfs[wi].Steps[i].N, FWfs[wi].Steps[i].Hito,
                 AgeS, FWfs[wi].Name, FWfs[wi].Steps[i].N, FWfs[wi].Name,
                 FWfs[wi].Steps[i].N]))
          else
            QueueOut(FWfs[wi], 'nudge', FWfs[wi].Steps[i].N,
              FWfs[wi].Steps[i].Team,
              Format('WORKFLOW %s: your step #%d "%s" looks STALLED - no ' +
                'recorded progress for %s. Report: tiza task note %d ' +
                '"progress" | finished? tiza task done %d | blocked? tiza ' +
                'wf error %s "why" --step %d. This reminder repeats until ' +
                'one of those happens.',
                [FWfs[wi].Name, FWfs[wi].Steps[i].N, FWfs[wi].Steps[i].Hito,
                 AgeS, FWfs[wi].Steps[i].TaskId, FWfs[wi].Steps[i].TaskId,
                 FWfs[wi].Name, FWfs[wi].Steps[i].N]));
          { escalate to the group admin (skip when owner IS the admin) }
          Admin := '';
          for j := 0 to High(Admins) do
            if SameText(Admins[j].Group, FWfs[wi].Group) then
              Admin := Admins[j].Admin;
          if (Admin <> '') and
             (not SameText(Admin, FWfs[wi].Steps[i].Team)) then
            QueueOut(FWfs[wi], 'nudge', FWfs[wi].Steps[i].N, Admin,
              Format('WORKFLOW %s: step #%d "%s" (%s) shows no progress ' +
                'for %s - check on it (the owner was nudged too). Plan: ' +
                'tiza wf show %s',
                [FWfs[wi].Name, FWfs[wi].Steps[i].N, FWfs[wi].Steps[i].Hito,
                 FWfs[wi].Steps[i].Team, AgeS, FWfs[wi].Name]));
          FWfs[wi].Steps[i].LastNudge := NowStamp;
          AddLog(FWfs[wi], 'pizarra', Format('nudge: step #%d stalled (%s)',
            [FWfs[wi].Steps[i].N, AgeS]));
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Format(
            'workflow %s: step #%d (%s) stalled %s - owner nudged',
            [FWfs[wi].Name, FWfs[wi].Steps[i].N, FWfs[wi].Steps[i].Team,
             AgeS]);
          Changed := True;
        end;
      if Changed and (not SaveOrRollback(WfSnap)) then
      begin
        { Queued notices live in the SAME record being saved, and the outbox is
          drained only under this lock. At rollback nothing has been delivered,
          so no notice is lost; it is simply recreated on the next pass. }
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Format(
          'workflow %s: stall reminders NOT saved - undone, will retry',
          [FWfs[wi].Name]);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.SetWfOption(const WfName, Field, Value,
  By: string): TWfResult;
var
  wi, Secs: Integer;
  Disp: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    wi := IndexOf(WfName);
    if wi < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + WfName);
      Exit;
    end;
    if SameText(FWfs[wi].StateS, 'done') or
       SameText(FWfs[wi].StateS, 'aborted') then
    begin
      Refuse(Result, Format('workflow %s is %s', [WfName, FWfs[wi].StateS]));
      Exit;
    end;
    if SameText(Field, 'eta') then
    begin
      if SameText(Trim(Value), 'factory') then
        Secs := 0
      else if not ParseDur(Value, Secs) then
      begin
        Refuse(Result, 'eta must be a duration (30s|45m|4h|2d), off, or ' +
          'factory (= the 24h default)');
        Exit;
      end;
      SnapshotLocked(FWfs[wi], 'set');
      FWfs[wi].EtaDef := Secs;
      if Secs < 0 then
        Disp := 'off'
      else if Secs = 0 then
        Disp := 'factory (24h)'
      else
        Disp := AgeStr(Secs);
      AddLog(FWfs[wi], By, 'default eta = ' + Disp);
    end
    else if SameText(Field, 'strict') then
    begin
      if not (SameText(Trim(Value), 'on') or SameText(Trim(Value), 'off')) then
      begin
        Refuse(Result, 'strict must be on or off');
        Exit;
      end;
      { Take the snapshot BEFORE mutation, as in the 'eta' branch. Taking it
        afterward puts the NEW value in the "before set" image, leaving
        `wf undo` with nothing to undo. }
      SnapshotLocked(FWfs[wi], 'set');
      FWfs[wi].Strict := SameText(Trim(Value), 'on');
      Disp := Trim(Value);
      AddLog(FWfs[wi], By, 'strict = ' + Disp);
    end
    else
    begin
      Refuse(Result, 'unknown workflow option ' + Field + ' (eta|strict)');
      Exit;
    end;
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format('workflow %s: %s = %s (%s)',
      [WfName, LowerCase(Field), Disp, By])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.TasksView(const WfName: string;
  out Text: string): Boolean;
var
  wi, i, j, k, Remaining: Integer;
  Emitted: array of Boolean;
  Order: array of Integer;
  Ready, Progress: Boolean;
  T: TTask;
  TaskCol: string;
begin
  Text := '';
  FLock.Enter;
  try
    wi := IndexOf(WfName);
    Result := wi >= 0;
    if not Result then
      Exit;
    { Kahn order (splice edits can create forward references, so ascending
      N alone is not guaranteed topological) }
    SetLength(Emitted, Length(FWfs[wi].Steps));
    Order := nil;
    Remaining := Length(FWfs[wi].Steps);
    repeat
      Progress := False;
      for i := 0 to High(FWfs[wi].Steps) do
        if not Emitted[i] then
        begin
          Ready := True;
          for j := 0 to High(FWfs[wi].Steps[i].Deps) do
          begin
            k := StepIdx(FWfs[wi], FWfs[wi].Steps[i].Deps[j]);
            if (k >= 0) and (not Emitted[k]) then
              Ready := False;
          end;
          if Ready then
          begin
            Emitted[i] := True;
            Dec(Remaining);
            Progress := True;
            SetLength(Order, Length(Order) + 1);
            Order[High(Order)] := i;
          end;
        end;
    until (not Progress) or (Remaining = 0);
    Text := 'WORKFLOW ' + WfSummaryLine(FWfs[wi]) + #10;
    for i := 0 to High(Order) do
    begin
      k := Order[i];
      if FWfs[wi].Steps[k].TaskId > 0 then
      begin
        if FTasks.Get(FWfs[wi].Steps[k].TaskId, T) then
          TaskCol := Format('task #%d (%s)',
            [FWfs[wi].Steps[k].TaskId, T.StateS])
        else
          TaskCol := Format('task #%d (missing)', [FWfs[wi].Steps[k].TaskId]);
      end
      else if FWfs[wi].Steps[k].TaskId = -1 then
        TaskCol := 'gate (console)'
      else
        TaskCol := 'task -';
      Text := Text + Format('#%-3d [%s] %s -- %s  %s'#10,
        [FWfs[wi].Steps[k].N, LowerCase(FWfs[wi].Steps[k].StateS),
         FWfs[wi].Steps[k].Hito, FWfs[wi].Steps[k].Team, TaskCol]);
    end;
    if Remaining > 0 then
      Text := Text + '(cycle detected - remaining steps omitted)'#10;
  finally
    FLock.Leave;
  end;
end;

{ ---------- history / backups ---------- }

{ Record the PREVIOUS card. SaveOrRollback writes it after the transition has
  committed, as a RECEIPT: report a write failure, but do not undo or fail a
  command that did occur. }
procedure TWorkflowStore.SnapshotLocked(const W: TWorkflow;
  const Reason: string);
begin
  FPendSnapWf := DeepCopyWf(W);
  FPendSnapReason := Reason;
  FPendSnap := True;
end;

procedure TWorkflowStore.FlushSnapshot;
var
  W: TWorkflow;
  O: TJSONObject;
  S, FN: string;
  FS: TFileStream;
  SR: TSearchRec;
  Counters: array of Integer;
  Pfx: string;
  i, j, v, p1, p2: Integer;
begin
  if not FPendSnap then
    Exit;
  FPendSnap := False;
  W := FPendSnapWf;
  O := TJSONObject.Create;
  try
    O.Add('reason', FPendSnapReason);
    O.Add('ts', NowStamp);
    O.Add('snap', FNextSnap);
    O.Add('workflow', WfToJson(W));
    S := O.FormatJSON();
  finally
    O.Free;
  end;
  FN := Format('%s/%s.%d.json', [FHistDir, LowerCase(W.Name), FNextSnap]);
  Inc(FNextSnap);
  try
    FS := TFileStream.Create(FN, fmCreate);
    try
      if S <> '' then
        FS.WriteBuffer(S[1], Length(S));
    finally
      FS.Free;
    end;
  except
    on E: Exception do
      Writeln(StdErr, 'pizarra: cannot write workflow snapshot: ', E.Message);
  end;
  { prune: keep the newest 30 snapshots per workflow }
  Counters := nil;
  Pfx := LowerCase(W.Name) + '.';
  if FindFirst(FHistDir + '/' + Pfx + '*.json', faAnyFile, SR) = 0 then
  begin
    repeat
      p2 := Length(SR.Name) - 5;   { last digit sits before '.json' }
      p1 := p2;
      while (p1 > 1) and (SR.Name[p1 - 1] <> '.') do
        Dec(p1);
      v := StrToIntDef(Copy(SR.Name, p1, p2 - p1 + 1), 0);
      if v > 0 then
      begin
        SetLength(Counters, Length(Counters) + 1);
        Counters[High(Counters)] := v;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  for i := 0 to High(Counters) do
    for j := i + 1 to High(Counters) do
      if Counters[j] > Counters[i] then
      begin
        v := Counters[i];
        Counters[i] := Counters[j];
        Counters[j] := v;
      end;
  for i := 30 to High(Counters) do
    DeleteFile(Format('%s/%s%d.json', [FHistDir, Pfx, Counters[i]]));
end;


type
  THistEntry = record
    N: Integer;
    Line: string;
  end;

function TWorkflowStore.HistoryOf(const WfName: string): TWfStrings;
var
  SR: TSearchRec;
  Entries: array of THistEntry;
  SL: TStringList;
  Root: TJSONData;
  O, WO: TJSONObject;
  i, j, v, p1, p2: Integer;
  Pfx: string;
  Tmp: THistEntry;
begin
  Result := nil;
  Entries := nil;
  Pfx := LowerCase(WfName) + '.';
  FLock.Enter;
  try
    if FindFirst(FHistDir + '/' + Pfx + '*.json', faAnyFile, SR) = 0 then
    begin
      repeat
        p2 := Length(SR.Name) - 5;   { last digit sits before '.json' }
        p1 := p2;
        while (p1 > 1) and (SR.Name[p1 - 1] <> '.') do
          Dec(p1);
        v := StrToIntDef(Copy(SR.Name, p1, p2 - p1 + 1), 0);
        if v = 0 then
          Continue;
        SL := TStringList.Create;
        try
          try
            SL.LoadFromFile(FHistDir + '/' + SR.Name);
            Root := GetJSON(SL.Text);
          except
            Root := nil;
          end;
          if (Root <> nil) and (Root.JSONType = jtObject) then
          begin
            O := TJSONObject(Root);
            SetLength(Entries, Length(Entries) + 1);
            Entries[High(Entries)].N := v;
            Entries[High(Entries)].Line := Format(
              'snap %-4d %s  before %-8s', [v, O.Get('ts', '?'),
              O.Get('reason', '?')]);
            WO := O.Get('workflow', TJSONObject(nil));
            if WO <> nil then
              Entries[High(Entries)].Line := Entries[High(Entries)].Line +
                '  was: ' + WfSummaryLine(JsonToWf(WO));
          end;
          if Root <> nil then
            Root.Free;
        finally
          SL.Free;
        end;
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
  finally
    FLock.Leave;
  end;
  { newest first }
  for i := 0 to High(Entries) do
    for j := i + 1 to High(Entries) do
      if Entries[j].N > Entries[i].N then
      begin
        Tmp := Entries[i];
        Entries[i] := Entries[j];
        Entries[j] := Tmp;
      end;
  SetLength(Result, Length(Entries));
  for i := 0 to High(Entries) do
    Result[i] := Entries[i].Line;
end;

{ A STEP NUMBER IS NOT ITS IDENTITY, YET CROSS-WORKFLOW DEPENDENCIES TRAVEL BY
  NUMBER. Replacing a workflow card through undo or restore may put a DIFFERENT
  MILESTONE at number 2. A dependant in another workflow would then silently
  wait on unrelated work and activate when the wrong work completes.
  Immutable Uid already lives in each step precisely because numbers are reused,
  so no format change is needed. Determine which milestone every dependant
  ACTUALLY awaited and give it that milestone's number in the new card. If the
  milestone is absent, there is no valid target; reject the replacement while
  identifying its dependants instead of stranding them forever.
  Leave a step without Uid (a card predating identities) unchanged: there is no
  identity to follow, and guessing from its title is worse than doing nothing. }
function TWorkflowStore.RetargetCrossDeps(wi: Integer;
  const Replacement: TWorkflow; ApplyChanges: Boolean;
  out MissingDependants: string): Integer;
var
  i, j, k, m, NewStepN: Integer;
  PreviousUid: Int64;
begin
  Result := 0;
  MissingDependants := '';
  if (wi < 0) or (wi >= FCount) then
    Exit;
  for i := 0 to FCount - 1 do
    if i <> wi then
      for j := 0 to High(FWfs[i].Steps) do
        for k := 0 to High(FWfs[i].Steps[j].XDeps) do
          if SameText(FWfs[i].Steps[j].XDeps[k].Wf, FWfs[wi].Name) then
          begin
            PreviousUid := 0;
            for m := 0 to High(FWfs[wi].Steps) do
              if FWfs[wi].Steps[m].N = FWfs[i].Steps[j].XDeps[k].N then
                PreviousUid := FWfs[wi].Steps[m].Uid;
            if PreviousUid = 0 then
              Continue;
            NewStepN := -1;
            for m := 0 to High(Replacement.Steps) do
              if Replacement.Steps[m].Uid = PreviousUid then
                NewStepN := Replacement.Steps[m].N;
            if NewStepN < 0 then
            begin
              if MissingDependants <> '' then
                MissingDependants := MissingDependants + ', ';
              MissingDependants := MissingDependants + Format('%s#%d', [FWfs[i].Name,
                FWfs[i].Steps[j].N]);
            end
            else if NewStepN <> FWfs[i].Steps[j].XDeps[k].N then
            begin
              Inc(Result);
              if ApplyChanges then
                FWfs[i].Steps[j].XDeps[k].N := NewStepN;
            end;
          end;
end;

function TWorkflowStore.UndoWf(const WfName, By: string;
  SnapN: Integer): TWfResult;
var
  Degraded: string;
  WhyUid: string;
  SR: TSearchRec;
  Pfx, FN, Reason, WfSnap: string;
  Best, v, p1, p2, wi: Integer;
  Retargeted: Integer;
  MissingDependants: string;
  SL: TStringList;
  Root: TJSONData;
  O, WO: TJSONObject;
  W: TWorkflow;
  Found: Boolean;
begin
  Pfx := LowerCase(WfName) + '.';
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    Best := 0;
    Found := False;
    if FindFirst(FHistDir + '/' + Pfx + '*.json', faAnyFile, SR) = 0 then
    begin
      repeat
        p2 := Length(SR.Name) - 5;   { last digit sits before '.json' }
        p1 := p2;
        while (p1 > 1) and (SR.Name[p1 - 1] <> '.') do
          Dec(p1);
        v := StrToIntDef(Copy(SR.Name, p1, p2 - p1 + 1), 0);
        if v > Best then
          Best := v;
        if (SnapN > 0) and (v = SnapN) then
          Found := True;
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    if Best = 0 then
    begin
      Refuse(Result, Format('no history for workflow %s (snapshots are ' +
        'taken automatically before every change)', [WfName]));
      Exit;
    end;
    if SnapN = 0 then
      SnapN := Best             { plain undo: the newest point }
    else if not Found then
    begin
      Refuse(Result, Format('no snapshot %d for workflow %s - list them: ' +
        'tiza wf history %s', [SnapN, WfName, WfName]));
      Exit;
    end;
    FN := Format('%s/%s%d.json', [FHistDir, Pfx, SnapN]);
    SL := TStringList.Create;
    try
      try
        SL.LoadFromFile(FN);
        Root := GetJSON(SL.Text);
      except
        Root := nil;
      end;
      if (Root = nil) or (Root.JSONType <> jtObject) then
      begin
        if Root <> nil then
          Root.Free;
        Refuse(Result, 'snapshot unreadable: ' + FN);
        Exit;
      end;
      O := TJSONObject(Root);
      try
        Reason := O.Get('reason', '?');
        WO := O.Get('workflow', TJSONObject(nil));
        if WO = nil then
        begin
          Refuse(Result, 'snapshot has no workflow card: ' + FN);
          Exit;
        end;
        W := JsonToWf(WO);
        WhyUid := UidsCoherent(W);
      finally
        Root.Free;
      end;
    finally
      SL.Free;
    end;
    if WhyUid <> '' then
    begin
      { The saved card contains incoherent identities. Reject it before it has
        touched either the allocator or live workflow. }
      Refuse(Result, Format('snapshot %d is incoherent: %s', [SnapN, WhyUid]));
      Exit;
    end;
    EnsureUids(W);   { validated: assigning identities is now safe }
    SanitizeImported(W);
    { Preserve cross-workflow dependencies by identity. If an awaited milestone
      is absent from the target card, do not jump. }
    wi := IndexOf(WfName);
    RetargetCrossDeps(wi, W, False, MissingDependants);
    if MissingDependants <> '' then
    begin
      Refuse(Result, Format('cannot restore %s to snapshot %d: the milestone(s) ' +
        'that %s wait for are not in that card - re-hang them first ' +
        '(tiza wf set <plan> <step> after ...)',
        [WfName, SnapN, MissingDependants]));
      Exit;
    end;
    Retargeted := RetargetCrossDeps(wi, W, True, MissingDependants);
    { the jump is itself reversible: keep the CURRENT state as a new
      snapshot before replacing it, so 'wf history' can bring it back }
    wi := IndexOf(WfName);
    if wi >= 0 then
      SnapshotLocked(FWfs[wi], 'undo');
    W.Outbox := nil;   { never resend notices from the past }
    if wi >= 0 then
      FWfs[wi] := W
    else
    begin
      SetLength(FWfs, FCount + 1);
      FWfs[FCount] := W;
      Inc(FCount);
    end;
    AddLog(FWfs[IndexOf(WfName)], By,
      Format('time-travel: restored snapshot %d (before %s)',
      [SnapN, Reason]));
    { COMMIT first: the old card must not alter tasks if the jump does not land.
      Once the card is on disk, the projector aligns tasks to it and repair
      retries any failed alignment. }
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    Degraded := ProjectAfterCommit(IndexOf(WfName), WfSnap, 0);
    { Report when the jump moves dependencies in ANOTHER workflow; silently
      correcting them would leave its owner unaware that the awaited step
      changed number. }
    if Retargeted > 0 then
      Degraded := Degraded + Format(' - %d cross-plan dep(s) re-pointed to the ' +
        'same milestone at its new number', [Retargeted]);
    OkFeed(Result, [Format('workflow %s restored to snapshot %d (its state ' +
      'before "%s"; by %s) - the jump itself was snapshotted, wf history ' +
      'lists every point%s', [WfName, SnapN, Reason, By, Degraded])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.CloneWf(const SrcName, NewName, NewGroup, By: string;
  const NewMembers: array of string): TWfResult;
var
  si, i, j: Integer;
  W: TWorkflow;
  IsMember: Boolean;
  Offenders: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    si := IndexOf(SrcName);
    if si < 0 then
    begin
      Refuse(Result, 'unknown workflow: ' + SrcName);
      Exit;
    end;
    if IndexOf(NewName) >= 0 then
    begin
      Refuse(Result, 'workflow already exists: ' + NewName);
      Exit;
    end;
    { deep copy, then reset to a pristine draft }
    W := FWfs[si];
    W.Steps := Copy(FWfs[si].Steps);
    for i := 0 to High(W.Steps) do
    begin
      W.Steps[i].Deps := Copy(FWfs[si].Steps[i].Deps);
      W.Steps[i].XDeps := Copy(FWfs[si].Steps[i].XDeps);
      W.Steps[i].StateS := 'pending';
      W.Steps[i].PriorS := '';
      W.Steps[i].TaskId := 0;     { NEVER carry task links into a clone }
      { NEW identity: a clone is a separate entity even when it looks the same.
        Inheriting identity would make its projection adopt the original task. }
      W.Steps[i].Uid := 0;
      W.Steps[i].LastNudge := '';
      W.Steps[i].Started := '';
      W.Steps[i].Closed := '';
    end;
    EnsureUids(W);   { fresh identities for the entire clone }
    W.Name := NewName;
    if NewGroup <> '' then
      W.Group := NewGroup;
    W.StateS := 'draft';
    W.ErrStep := 0;
    W.ErrBy := '';
    W.Frozen := nil;
    W.Members := nil;
    W.Log := nil;
    W.Outbox := nil;
    W.Created := NowStamp;
    W.Started := '';
    W.Closed := '';
    { every owner must exist in the TARGET group (membership may have
      changed since the source was built); gates are exempt }
    Offenders := '';
    for i := 0 to High(W.Steps) do
      if not SameText(W.Steps[i].Team, 'console') then
      begin
        IsMember := False;
        for j := 0 to High(NewMembers) do
          if SameText(NewMembers[j], W.Steps[i].Team) then
            IsMember := True;
        if not IsMember then
        begin
          if Offenders <> '' then
            Offenders := Offenders + ', ';
          Offenders := Offenders + Format('%s (#%d)',
            [W.Steps[i].Team, W.Steps[i].N]);
        end;
      end;
    if Offenders <> '' then
    begin
      Refuse(Result, Format('owners not in group @%s: %s - clone into ' +
        'their group or re-own the steps first', [W.Group, Offenders]));
      Exit;
    end;
    AddLog(W, By, 'cloned from ' + SrcName);
    SetLength(FWfs, FCount + 1);
    FWfs[FCount] := W;
    Inc(FCount);
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    OkFeed(Result, [Format('workflow %s cloned from %s (@%s, %d steps, ' +
      'pristine draft) by %s', [NewName, SrcName, W.Group,
      Length(W.Steps), By])]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.RestoreWf(const WfName, JsonText, By: string): TWfResult;
var
  Degraded: string;
  WhyUid: string;
  Root: TJSONData;
  O, WO: TJSONObject;
  W: TWorkflow;
  wi, xi: Integer;
  RetargetedRestore: Integer;
  WhyX, MissingDependantsRestore: string;
var
  WfSnap: string;
begin
  FLock.Enter;
  try
    WfSnap := SnapshotAll;
    try
      Root := GetJSON(JsonText);
    except
      Root := nil;
    end;
    if (Root = nil) or (Root.JSONType <> jtObject) then
    begin
      if Root <> nil then
        Root.Free;
      Refuse(Result, 'restore: the file is not a JSON object');
      Exit;
    end;
    O := TJSONObject(Root);
    try
      { accept a bare card, a show reply, or an auto-snapshot }
      WO := O.Get('workflow', TJSONObject(nil));
      if WO = nil then
        WO := O;
      W := JsonToWf(WO);
    finally
      Root.Free;
    end;
    { Check coherence BEFORE any live state, and assign identities only when
      ACCEPTING the card. Doing it here advanced the allocator even if a later
      name or cycle check rejected the card. }
    WhyUid := UidsCoherent(W);
    if WhyUid <> '' then
    begin
      Refuse(Result, 'restore: ' + WhyUid);
      Exit;
    end;
    if not SameText(W.Name, WfName) then
    begin
      Refuse(Result, Format('the file holds workflow "%s", not "%s"',
        [W.Name, WfName]));
      Exit;
    end;
    if Length(W.Steps) = 0 then
    begin
      Refuse(Result, 'restore: the card has no steps');
      Exit;
    end;
    if HasCycleW(W) then
    begin
      Refuse(Result, 'restore: the card contains a dependency cycle');
      Exit;
    end;
    { cross-deps must point at existing targets and stay acyclic globally }
    for wi := 0 to High(W.Steps) do
      for xi := 0 to High(W.Steps[wi].XDeps) do
        if not XDepOk(WfName, W.Steps[wi].XDeps[xi], WhyX) then
        begin
          Refuse(Result, 'restore: ' + WhyX);
          Exit;
        end;
    { Identity assignment and sanitization happen BEFORE branching. Restoring a
      workflow that did NOT yet exist followed the other branch and once skipped
      both, allowing a card with uid=0 and a task link to a FOREIGN task to enter
      unchanged and alter that task's state. Only the history snapshot depends
      on whether the workflow already exists. }
    EnsureUids(W);
    SanitizeImported(W);
    wi := IndexOf(WfName);
    { An edited saved card may contain the same milestones under DIFFERENT
      numbers. A dependant must continue waiting for THE SAME milestone, not
      whichever one inherits its number. }
    RetargetCrossDeps(wi, W, False, MissingDependantsRestore);
    if MissingDependantsRestore <> '' then
    begin
      Refuse(Result, Format('cannot restore %s from that card: the milestone(s) ' +
        'that %s wait for are not in it - re-hang them first ' +
        '(tiza wf set <plan> <step> after ...)',
        [WfName, MissingDependantsRestore]));
      Exit;
    end;
    RetargetedRestore := RetargetCrossDeps(wi, W, True,
      MissingDependantsRestore);
    if wi >= 0 then
    begin
      SnapshotLocked(FWfs[wi], 'restore');
      FWfs[wi] := W;
    end
    else
    begin
      SetLength(FWfs, FCount + 1);
      FWfs[FCount] := W;
      Inc(FCount);
    end;
    AddLog(FWfs[IndexOf(WfName)], By, 'restored from a saved card');
    { COMMIT first: a card that does not reach disk must not leave tasks aligned
      with it. }
    if not SaveOrRollback(WfSnap) then
    begin
      Refuse(Result, 'not saved: the change was undone (disk write failed)');
      Exit;
    end;
    Degraded := ProjectAfterCommit(IndexOf(WfName), WfSnap, 0);
    if RetargetedRestore > 0 then
      Degraded := Degraded + Format(' - %d cross-plan dep(s) re-pointed to the ' +
        'same milestone at its new number', [RetargetedRestore]);
    OkFeed(Result, [Format('workflow %s restored from a saved card (%s, ' +
      'state %s, %d steps)%s',
      [WfName, By, W.StateS, Length(W.Steps), Degraded])]);
  finally
    FLock.Leave;
  end;
end;

{ ---------- queries ---------- }

{ A genuinely DEEP copy. Assigning the record is insufficient: FPC shares a
  dynamic array nested in a record by reference--fpc_dynarray_copy moves the
  record and only increments references to managed members (dynarr.inc:302-370).
  A recipient of that "copy" would still observe the SAME steps as the store.
  The delivery thread walks workflow steps after releasing the lock while
  another thread may mutate them, so copy each member explicitly. }
function DeepCopyWf(const W: TWorkflow): TWorkflow;
var
  i: Integer;
begin
  Result := W;
  SetLength(Result.Steps, Length(W.Steps));
  for i := 0 to High(W.Steps) do
  begin
    Result.Steps[i] := W.Steps[i];
    { Copy() DOES isolate these: they are arrays of scalars or records containing
      only strings, and copy-on-write strings give an added reference value
      semantics. Copy() does NOT isolate an array nested in another array,
      hence the explicit Steps loop. Do not use Move: TWfXDep contains a string,
      and copying its bytes would bypass reference counting. }
    Result.Steps[i].Deps := Copy(W.Steps[i].Deps);
    Result.Steps[i].XDeps := Copy(W.Steps[i].XDeps);
  end;
  Result.Members := Copy(W.Members);
  Result.Frozen := Copy(W.Frozen);
  Result.Log := Copy(W.Log);
  Result.Outbox := Copy(W.Outbox);
end;

function TWorkflowStore.Get(const Name: string; out W: TWorkflow): Boolean;
var
  wi: Integer;
begin
  W := Default(TWorkflow);
  FLock.Enter;
  try
    wi := IndexOf(Name);
    Result := wi >= 0;
    if Result then
      W := DeepCopyWf(FWfs[wi]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.CaptureHeader(const TeamName: string;
  MaxTasks: Integer; out TaskBlock: string; out ActionableN: Integer;
  out Cleanup: TWfStrings): TWorkflowArray;
var
  Tasks: TTaskArray;
  Wfs: TWorkflowArray;   { Result belongs to nested functions; use a local name. }
  i, j, k, si, wi2, Shown: Integer;
  Ok: Boolean;
  Why: string;

  { Find the ACCEPTED step by IDENTITY, never by its cached task number, which
    may point to a foreign task. }
  function FindStep(const T: TTask; out W, St: Integer): Boolean;
  var
    a, b: Integer;
  begin
    Result := False;
    W := -1; St := -1;
    if T.WfStepUid <= 0 then
      Exit;
    for a := 0 to High(Wfs) do
      for b := 0 to High(Wfs[a].Steps) do
        if (Wfs[a].Steps[b].Uid = T.WfStepUid) and
           SameText(Wfs[a].Name, T.WfName) then
        begin
          W := a; St := b;
          Exit(True);
        end;
  end;

  procedure Note(Id: Integer; const Txt: string);
  begin
    SetLength(Cleanup, Length(Cleanup) + 1);
    Cleanup[High(Cleanup)] := Format('task #%d: %s', [Id, Txt]);
  end;

begin
  Wfs := nil;
  TaskBlock := '';
  ActionableN := 0;
  Cleanup := nil;
  Shown := 0;
  FLock.Enter;
  try
    SetLength(Wfs, FCount);
    for i := 0 to FCount - 1 do
      Wfs[i] := DeepCopyWf(FWfs[i]);
    { ONE task snapshot under a single acquisition of its lock. Everything that
      follows uses immutable copies, giving the header one instant in time.
      Reading tasks separately allowed mutations between reads, so the notice
      could describe one state while the list showed another. }
    Tasks := FTasks.CaptureTasks(TeamName);
  finally
    FLock.Leave;
  end;

  { PRESENTATION: display a workflow link that cannot be VERIFIED against a real
    task with the same identity as pending projection. Otherwise the workflow
    promises a nonexistent or foreign task. }
  for i := 0 to High(Wfs) do
    for j := 0 to High(Wfs[i].Steps) do
    begin
      if Wfs[i].Steps[j].TaskId <= 0 then
        Continue;
      { Matching identity alone is insufficient for ANNOUNCING a task; it must be
        USABLE. If accepted owner or title differs because realignment did not
        reach disk, the notice would direct a team to another owner's task or an
        old title. Announcing a task no longer actionable--superseded, cancelled,
        or waiting after a failed reopen--likewise requests nonexistent work.
        On any mismatch clear the link in this presentation copy and show
        pending projection, the only fact known at that moment. }
      Ok := False;
      for k := 0 to High(Tasks) do
        if (Tasks[k].Id = Wfs[i].Steps[j].TaskId) and
           (Tasks[k].WfStepUid = Wfs[i].Steps[j].Uid) and
           SameText(Tasks[k].WfName, Wfs[i].Name) and
           SameText(Tasks[k].Team, Wfs[i].Steps[j].Team) and
           (Tasks[k].Title = Wfs[i].Steps[j].Hito) and
           IsActionable(Tasks[k]) then
        begin
          Ok := True;
          Break;
        end;
      if not Ok then
        Wfs[i].Steps[j].TaskId := 0;
    end;

  { RELATION: walk TASKS, not steps. Walking steps cannot discover a task whose
    identity is NO LONGER in the card. }
  for k := 0 to High(Tasks) do
  begin
    if not SameText(Tasks[k].Team, TeamName) then
      Continue;
    if not IsActionable(Tasks[k]) then
      Continue;
    if Tasks[k].WfStepUid <= 0 then
    begin
      { Standalone task: ordinary work not originating in a workflow. }
      Inc(ActionableN);
      if Shown < MaxTasks then
      begin
        TaskBlock := TaskBlock + Format('  #%d %s%s'#10,
          [Tasks[k].Id,
           BoolToStr(Tasks[k].Hito <> '', '[' + Tasks[k].Hito + '] ', ''),
           Tasks[k].Title]);
        Inc(Shown);
      end;
      Continue;
    end;
    Why := '';
    if not FindStep(Tasks[k], wi2, si) then
      Why := Format('its step is no longer in workflow %s - pizarra is ' +
        'superseding it; do NOT work it', [Tasks[k].WfName])
    else if SameText(Wfs[wi2].StateS, 'aborted') then
      Why := Format('workflow %s was ABORTED - pizarra is cancelling it; do ' +
        'NOT work it', [Wfs[wi2].Name])
    else if IsDoneS(Wfs[wi2].Steps[si].StateS) then
      Why := Format('workflow %s step #%d is already DONE - pizarra is ' +
        'closing it; do NOT work it',
        [Wfs[wi2].Name, Wfs[wi2].Steps[si].N])
    else if SameText(Wfs[wi2].StateS, 'halted') then
      Why := Format('workflow %s is HALTED - PAUSED until it is RESUMED; do ' +
        'not work it now (nothing to close)', [Wfs[wi2].Name])
    else if not SameText(Wfs[wi2].Steps[si].Team, TeamName) then
      Why := Format('workflow %s step #%d now belongs to %s - pizarra is ' +
        're-aligning it; do NOT work it',
        [Wfs[wi2].Name, Wfs[wi2].Steps[si].N,
         Wfs[wi2].Steps[si].Team])
    else if not SameText(Wfs[wi2].Steps[si].StateS, 'active') then
      Why := Format('workflow %s step #%d is not active yet - it is being ' +
        'set aside until it is your turn', [Wfs[wi2].Name,
        Wfs[wi2].Steps[si].N])
    { ORDER MATTERS: check title BEFORE link. The presentation pass has already
      cleared links for everything unusable, including a title mismatch. Checking
      the link first always answered "not linked yet" and made the title branch
      unreachable--technically true, but not the actual cause. }
    else if Tasks[k].Title <> Wfs[wi2].Steps[si].Hito then
      { The accepted milestone and task disagree; one header would show two
        titles for the same work. }
      Why := Format('workflow %s step #%d now reads "%s" - pizarra is ' +
        're-aligning it; do NOT work it from this description',
        [Wfs[wi2].Name, Wfs[wi2].Steps[si].N, Wfs[wi2].Steps[si].Hito])
    else if Wfs[wi2].Steps[si].TaskId <> Tasks[k].Id then
      Why := Format('workflow %s step #%d is not bound to it yet - wait for ' +
        'pizarra to announce it', [Wfs[wi2].Name, Wfs[wi2].Steps[si].N]);
    if Why <> '' then
    begin
      Note(Tasks[k].Id, Why);
      Continue;   { exclude from count and list: this is not an instruction }
    end;
    Inc(ActionableN);
    if Shown < MaxTasks then
    begin
      TaskBlock := TaskBlock + Format('  #%d %s%s'#10,
        [Tasks[k].Id,
         BoolToStr(Tasks[k].Hito <> '', '[' + Tasks[k].Hito + '] ', ''),
         Tasks[k].Title]);
      Inc(Shown);
    end;
  end;
  if ActionableN > Shown then
    TaskBlock := TaskBlock + Format('  (and %d more)'#10,
      [ActionableN - Shown]);
  Result := Wfs;
end;

function TWorkflowStore.ListAll: TWorkflowArray;
var
  i: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FCount);
    for i := 0 to FCount - 1 do
      Result[i] := DeepCopyWf(FWfs[i]);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.TeamBusy(const Team: string): string;
var
  wi, i: Integer;
begin
  Result := '';
  FLock.Enter;
  try
    { 'draft' counts. Deleting a team that owned a step in a DRAFT sent the
      start notice to a ghost and auto-halted the engine much later, in another
      command. The deletion creates the trap, so it must guard against it. }
    for wi := 0 to FCount - 1 do
      if SameText(FWfs[wi].StateS, 'running') or
         SameText(FWfs[wi].StateS, 'halted') or
         SameText(FWfs[wi].StateS, 'draft') then
        for i := 0 to High(FWfs[wi].Steps) do
          if SameText(FWfs[wi].Steps[i].Team, Team) then
            Exit(FWfs[wi].Name);
  finally
    FLock.Leave;
  end;
end;

function TWorkflowStore.GroupBusy(const Group: string): string;
var
  wi: Integer;
begin
  Result := '';
  FLock.Enter;
  try
    { Likewise, removing the group of a DRAFT workflow made it impossible to
      start ('unknown group'), without data loss but also without warning. }
    for wi := 0 to FCount - 1 do
      if SameText(FWfs[wi].Group, Group) and
         (SameText(FWfs[wi].StateS, 'running') or
          SameText(FWfs[wi].StateS, 'halted') or
          SameText(FWfs[wi].StateS, 'draft')) then
        Exit(FWfs[wi].Name);
  finally
    FLock.Leave;
  end;
end;

end.
