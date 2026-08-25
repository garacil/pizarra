{ pzproto - shared wire protocol between tiza (client) and pizarra (daemon).

  One JSON object per line over a TCP stream:
    request : fields secret, cmd (send|inbox|...), from, to, text
    reply   : ok:true  |  ok:false + error  |  ok:true + messages[]

  All strings are UTF-8. The framing is a single '\n'-terminated line, so JSON
  values must not contain a raw newline: fpjson escapes them as \n automatically. }
unit pzproto;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser;

const
  { Maximum size of ONE bus line. This belongs in the interface because both
    pzproto and pznet read bus lines; different limits for the same line reveal
    themselves only when one reader accepts a message that the other truncates. }
  MAX_LINE_BYTES = 1048576;   { 1 MB: no legitimate message is bigger }

  CMD_SEND    = 'send';
  CMD_INBOX   = 'inbox';
  CMD_ACK     = 'ack';       { advance the sender's inbox cursor to 'upto' }
  CMD_WATCH   = 'watch';     { subscribe: server streams events on this conn }
  CMD_TEAMS   = 'teams';     { Team index (chat /equipos + shorthand check). }
  CMD_RECENT  = 'recent';    { last messages of ALL bus traffic (chat /log) }
  CMD_TASK    = 'task';      { Milestone/task operations selected by 'op'. }
  CMD_TEAM    = 'team';      { runtime team management; 'op' field selects }
  CMD_GROUP   = 'group';     { runtime group management; 'op' field selects }
  CMD_PROJECT = 'project';   { runtime project registry; 'op' field selects }
  CMD_HEADER  = 'header';    { runtime delivery-header config; 'op' field selects }
  CMD_DELIVER = 'deliver';   { pizarra -> tiza daemon: inject this text }
  CMD_PING    = 'ping';      { pizarra -> tiza daemon: health check }
  CMD_DIAL    = 'dial';      { tiza daemon -> pizarra: open a reverse delivery
                               channel (the daemon dials the hub and holds it;
                               the hub delivers over it — for NAT/dynamic-IP) }
  CMD_PUT     = 'put';       { tiza -> pizarra: upload a file's bytes; the hub
                               writes them into the shared dir (for hosts that
                               cannot mount the NFS, unlike 'share') }
  CMD_GET     = 'get';       { tiza -> pizarra: download a file FROM the shared
                               dir; the hub reads it and returns the bytes (for
                               NFS-less hosts to read what teammates deposited) }
  CMD_WORKFLOW = 'workflow'; { dependency-tree milestone plans; 'op' selects }
  CMD_VER     = 'ver';       { report the hub's release number (drift check);
                               the tiza daemon answers it too (fleet probe) }
  CMD_CAPS    = 'caps';      { What THE CALLER may do, derived from its
                               credential and NOT its claimed 'from' value.
                               A delegated console missing an operation family
                               can look healthy until first use, so its ceiling
                               must be inspectable rather than discovered by
                               failure. }
  CMD_FLEET   = 'fleet';     { hub probes every host: release + online state }
  CMD_UPGET   = 'upget';     { daemon <- hub: download a release artifact in
                               chunks (binary per os-cpu, or the src tarball) }
  CMD_APP     = 'app';       { application registry; 'op' field selects }
  CMD_BACKUP  = 'backup';    { Complete, restorable state backup. }
  CMD_UPDATE  = 'update';    { console -> hub: trigger self-updates; also
                               hub -> daemon: run YOUR self-update now }
  CMD_ACTIVITY = 'activity';  { tiza daemon -> hub: report a team's pane activity
                               state (moving/idle/blocked/busy) so the hub can
                               show who is free, hold delivery to a blocked team,
                               and see when a whole group has gone quiet }
  CMD_HOLD    = 'hold';       { console -> hub: manually hold/resume delivery to a
                               team (the operator's gate for a blocked agent) }

type
  { A single message as it travels on the bus and is stored for the inbox. }
  TPzMsg = record
    Seq:  Int64;    { hub-assigned monotonic id (0 = unassigned) }
    Ts:   string;
    From: string;
    Dest: string;   { 'to' is a reserved word, use Dest }
    Text: string;
    Via:  string;   { how it was delivered: tmux | ssh | headless | log }
    { PROVEN OR MERELY CLAIMED IDENTITY. 'proven' means the sender presented
      that team's OWN secret, allowing the hub to bind name to credential.
      'claimed' means the master key supplied an arbitrary name that the hub
      accepts but cannot verify. Empty means a record predating this field.
      Persist this in the JOURNAL because process memory is gone when an audit
      later needs to reconstruct who said what. }
    Ident: string;
    { DELIVERY HEADER, persisted because redelivery reconstructs it. An idle-group
      notice uses a MINIMAL header and its own reply target. Without journaled
      values, a watchdog retry after the destination was initially disconnected
      would rebuild a full header and direct replies to the sender instead of
      the intended target. Empty/False denotes a normal message. }
    Minimal: Boolean;
    ReplyTo: string;
  end;
  TPzMsgArray = array of TPzMsg;

{ Line I/O over any TStream (blocking). ReadLine returns the line without the
  trailing #10; on a closed/empty stream it returns '' . }
function  ReadLine(AStream: TStream): string;
procedure WriteLine(AStream: TStream; const S: string);

{ JSON helpers. ParseObj returns nil when the text is not a JSON object. }
function ParseObj(const S: string): TJSONObject; overload;
function ParseObj(const S: string; out Reason: string): TJSONObject; overload;

{ Message <-> JSON (journal lines and inbox entries share one shape). }
function MsgToJson(const M: TPzMsg): string;
function JsonToMsg(Obj: TJSONObject): TPzMsg;

{ Build a request line for tiza. }
function BuildSend(const Secret, From, Dest, Text: string): string;

{ Upload a file over the bus: the hub writes Data (base64 of the raw bytes) into
  the shared dir of team Dest as basename Name. For hosts that cannot mount the
  shared NFS (so 'share', which cp's locally, is unavailable). }
function BuildPut(const Secret, From, Dest, Name, Data: string): string;

{ CHUNKED PUT. A file does not fit in one bus line: MAX_LINE_BYTES is 1 MB and
  base64 expands data by 4/3, making the single-line ceiling about 750 KB while
  SHARE_MAX_BYTES promises 10 MB. An unenforced limit is worse than no limit.
  Use the existing fleet-artifact chunking pattern from CMD_UPGET.
  'Id' identifies the UPLOAD rather than the file because concurrent uploads of
  the same name cannot share a temporary file. 'Offset' declares the sender's
  position, which the hub requires to match bytes already received; otherwise a
  missing chunk leaves an invisible hole. 'Last' completes the upload, and only
  then is the declared SHA-256 compared with the computed value. }
function BuildPutChunk(const Secret, From, Dest, Name, Id, Data: string;
  Offset: Int64; Last: Boolean; const Sha: string): string;

{ Download a file FROM the shared dir over the bus: the hub reads Path (which
  must live under the [shared] dir) and returns its bytes (base64). The inverse
  of put, for NFS-less hosts to read what teammates deposited. }
function BuildGet(const Secret, From, Path: string): string;

{ CHUNKED GET for the same reason. The response carries TOTAL SIZE so the client
  knows what remains, and carries the complete file's SHA-256 ONLY on the last
  chunk; computing it for every chunk would reread the complete file each time.
  If the file changes during transfer, the digest no longer matches assembled
  data and the download is correctly discarded. }
function BuildGetChunk(const Secret, From, Path: string;
  Offset, Max: Int64): string;
{ After is the last sequence the client already has (0 starts at the beginning
  of unread data); Limit is page size (0 lets the hub decide). Requesting a page
  NEVER consumes it; only an acknowledgement advances the cursor. }
function BuildInbox(const Secret, From: string; Peek: Boolean = False;
  All: Boolean = False; After: Int64 = 0; Limit: Integer = 0): string;

{ Build hub -> tiza-daemon request lines. Text is the fully wrapped delivery
  (only the hub can build the live team index). }
function BuildDeliver(const Secret: string; Seq: Int64;
  const From, Team, Text: string): string;
function BuildPing(const Secret: string; const HubVer: string = ''): string;

{ Reverse delivery channel (dial-in). A daemon behind NAT / with a roaming
  (DHCP/VPN) IP dials the hub and keeps the connection open; the hub streams
  BuildDeliver envelopes over it and the daemon replies BuildDeliverAck. Teams
  is a comma list of the team names this daemon hosts. KeepAlive seconds bound
  hub->daemon pings that hold the NAT mapping open. }
function BuildDial(const Secret, From, Teams: string;
  KeepAlive: Integer; Since: Int64; const Ver: string = ''): string;
function BuildDeliverAck(const Team: string; Seq: Int64; Ok: Boolean): string;

{ Chat/console requests. }
function BuildWatch(const Secret, From: string; Since: Int64): string;
function BuildAck(const Secret, From: string; UpTo: Int64): string;
function BuildTeams(const Secret, From: string): string;
{ 'From' remains optional for compatibility because existing callers using the
  global secret do not need it. A credential BOUND to a team must identify its
  caller, however, or the hub's identity guard correctly rejects it. }
function BuildRecent(const Secret: string; Since: Int64; Max: Integer;
  const From: string = ''): string;
function BuildVer(const Secret, From: string): string;
function BuildCaps(const Secret, From: string): string;
function BuildFleet(const Secret, From: string): string;
{ tiza daemon -> hub: this team's pane just changed activity state. State is one
  of moving|idle|blocked|busy (see CMD_ACTIVITY); Note optionally carries the
  matched prompt line for a blocked report. Hold=true means the blocked report
  came from a RELIABLE source (a session-hook hint file), so the hub may auto-hold
  delivery; a heuristic (pane-regex) block reports Hold=false — alarm only. }
function BuildActivity(const Secret, From, State: string; const Note: string = '';
  Hold: Boolean = False): string;
{ console -> hub: hold (On=true) or resume (On=false) delivery to Team. }
function BuildHold(const Secret, From, Team: string; On_: Boolean): string;
function BuildAppOp(const Secret, From, Op, Name, Team, Repo, PathS,
  Purpose, Detail, Field, Value: string; const Text: string = '';
  Snap: Integer = 0; At: Integer = 0;
  const Project_: string = ''; const Role: string = ''): string;
function BuildBackup(const Secret, From, OutDir: string;
  Force: Boolean): string;
{ From identifies the requester. Sending it empty worked with the master key,
  but the hub rejected daemons presenting their own team secret and fleet
  self-update stopped. State who is asking as well as proving the secret. }
function BuildUpget(const Secret, OsS, CpuS, Kind: string;
  Offset, Max: Int64; const From: string = ''): string;
function BuildUpdate(const Secret, From, Name, Ver: string;
  Force: Boolean): string;

{ Task ops (all cmd=task, selected by op). }
function BuildTaskAdd(const Secret, From, Title, Team, Hito: string;
  Parent: Integer = 0): string;
function BuildTaskState(const Secret, From: string; Id: Integer;
  const State: string): string;
function BuildTaskAssign(const Secret, From: string; Id: Integer;
  const Team: string): string;
function BuildTaskNote(const Secret, From: string; Id: Integer;
  const Text: string): string;
function BuildTaskList(const Secret, From, Filter, Team: string): string;
function BuildTaskShow(const Secret, From: string; Id: Integer): string;
function BuildTaskDelete(const Secret, From: string; Id: Integer): string;

{ Workflow ops (all cmd=workflow, selected by op). 'after' is a comma list of
  step numbers ('' = default: the previous step; '0' = root). }
function BuildWfCreate(const Secret, From, Name, Group: string): string;
function BuildWfStep(const Secret, From, Name, Team, Hito, After: string;
  const EtaS: string = ''): string;
function BuildWfStart(const Secret, From, Name: string): string;
function BuildWfDone(const Secret, From, Name: string; Step: Integer;
  const Proof: string = ''): string;
function BuildWfError(const Secret, From, Name, Why: string; Step: Integer): string;
function BuildWfFixed(const Secret, From, Name, Text: string): string;
function BuildWfVerify(const Secret, From, Name: string; Pass: Boolean;
  const Note: string): string;
function BuildWfAbort(const Secret, From, Name, Why: string): string;
function BuildWfList(const Secret, From: string; Mine: Boolean = False;
  const Team: string = ''): string;
{ Linked tasks of one workflow, dependency-ordered (op=tasks). }
function BuildWfTasks(const Secret, From, Name: string): string;
{ Copy a workflow into a pristine NEW draft (op=clone). }
function BuildWfClone(const Secret, From, Src, NewName: string;
  const Group: string = ''): string;
{ FromN > 0 = subtree of that step; Depth > 0 = levels below the start;
  Detail = per-node facts line. }
function BuildWfShow(const Secret, From, Name: string; FromN: Integer = 0;
  Depth: Integer = 0; Detail: Boolean = False): string;
{ Draft editing: splice a step in after AfterN (dependents re-hang on it),
  splice one out, or edit team|hito|after of an existing step. }
function BuildWfInsert(const Secret, From, Name, Team, Hito: string;
  AfterN: Integer; const EtaS: string = ''): string;
function BuildWfRemove(const Secret, From, Name: string; Step: Integer): string;
function BuildWfSet(const Secret, From, Name: string; Step: Integer;
  const Field, Value: string): string;
{ Backups: list the automatic pre-change snapshots, pop the newest (undo),
  or replace the workflow with a saved card (Data = its JSON text). }
function BuildWfHistory(const Secret, From, Name: string): string;
function BuildWfDelete(const Secret, From, Name, Why: string): string;
function BuildWfUndo(const Secret, From, Name: string;
  SnapN: Integer = 0): string;
function BuildWfRestore(const Secret, From, Name, Data: string): string;

{ Team management ops (all cmd=team, selected by op). }
function BuildTeamAdd(const Secret, From, Name, Spec, Parent, Host,
  Session, Launch, Prompt: string): string;
function BuildTeamRemove(const Secret, From, Name: string): string;
function BuildTeamSet(const Secret, From, Name, Field, Value: string): string;
function BuildTeamShow(const Secret, From, Name: string): string;

{ Group ops (all cmd=group, selected by op). }
function BuildGroupAdd(const Secret, From, Name, Members: string): string;
function BuildGroupRemove(const Secret, From, Name, Members: string): string;
function BuildGroupProject(const Secret, From, Name, Project: string): string;
function BuildGroupList(const Secret, From: string): string;
function BuildGroupBoss(const Secret, From, Name, Boss: string): string;
function BuildGroupExclude(const Secret, From, Name, Excluded: string): string;
function BuildGroupOnIdle(const Secret, From, Name, Policy: string): string;
function BuildGroupOnIdleMsg(const Secret, From, Name, Msg: string): string;
function BuildGroupOnIdleFrom(const Secret, From, Name, Who: string): string;
function BuildGroupOnIdleReply(const Secret, From, Name, Who: string): string;
function BuildGroupHeader(const Secret, From, Name, Note: string): string;
function BuildGroupOnBlock(const Secret, From, Name, Policy: string): string;

{ Project registry ops (all cmd=project, selected by op). }
function BuildProjectBoss(const Secret, From, Name, Boss: string): string;
function BuildProjectList(const Secret, From: string): string;
{ A project's CARD. It did not exist: 'project' only knew how to set a boss,
  list and remove, so a project's apps had nowhere to live and neither the
  console nor the web could re-read a project after changing it - they relisted
  and extracted. Reading needs no authorisation, same as 'list'. }
function BuildProjectShow(const Secret, From, Name: string): string;
function BuildProjectRemove(const Secret, From, Name: string): string;

{ Runtime delivery-header config (cmd=header). }
function BuildHeaderList(const Secret, From: string): string;
function BuildHeaderSet(const Secret, From, Key, Value: string): string;
function BuildHeaderNote(const Secret, From, Note: string): string;

{ Watch-stream events, one JSON per line. }
function EvMsg(const M: TPzMsg): string;
function EvSys(const Text: string): string;
function EvTask(const Text: string): string;
function EvPing: string;
function EvGap(After: Int64; const Reason: string): string;
{ A high-priority ALARM (a team is blocked on a permission prompt). Its own ev
  type so consoles and external notifiers render it loud (bell / out-of-band) instead of
  letting it blend into the ordinary message feed. }
function EvAlarm(const Team, Text: string): string;

{ Build reply lines for pizarra. }
function ReplyOk: string;
function ReplyOkNote(const Note: string): string;
function ReplyVer(const Ver: string): string;
{ Caller's effective ceiling: the team bound to its credential and the operation
  families in which it may act as console. 'unrestricted' means global access. }
function ReplyCaps(const Bound: string; Unrestricted: Boolean;
  const Families: array of string): string;
function ReplySent(Seq: Int64; Queued: Boolean; const Note: string = ''): string;
function ReplyBroadcast(Sent, Queued: Integer): string;
function ReplyErr(const Msg: string): string;
{ Rejection with an UNKNOWN OUTCOME: the command may have been applied. Its
  dedicated field prevents clients from mistaking it for a definitive hub
  refusal and retrying, which could duplicate the operation. }
function ReplyUnknown(const Msg: string): string;
function ReplyInbox(const Msgs: array of TPzMsg; More: Integer = 0): string;

implementation

function ReadLine(AStream: TStream): string;
var
  c: AnsiChar;
  n: LongInt;
begin
  Result := '';
  repeat
    n := AStream.Read(c, 1);
    if n <= 0 then
      Break;
    if c = #10 then
      Break;
    if c <> #13 then
      Result := Result + c;
    if Length(Result) > MAX_LINE_BYTES then
    begin
      { hostile/buggy client: refuse to buffer more, caller errors out }
      Result := '';
      Exit;
    end;
  until False;
end;

procedure WriteLine(AStream: TStream; const S: string);
var
  Line: string;
begin
  Line := S + #10;
  if Length(Line) > 0 then
    AStream.WriteBuffer(Line[1], Length(Line));
end;

{ FOUR DIFFERENT FAILURES USED TO LOOK LIKE ONE. This returns nil for an empty
  body, for malformed JSON, for a DUPLICATED field, and for valid JSON whose top
  level is not an object - and every caller could only say 'body is not a JSON
  object'. For the duplicate case that sentence is not merely unhelpful, it is
  FALSE: the body IS an object, its problem is a repeated key, and the caller
  goes looking at the wrong thing.

  The duplicate rejection is worth naming for a second reason. It is a guarantee
  the contract makes and NOBODY WROTE: TJSONObject.DoAdd raises
  SErrDuplicateValue = 'Duplicate object member: "%s"'
  (/usr/lib/fpc/src/packages/fcl-json/src/fpjson.pp:822,3731), the parser
  re-raises it unless joIgnoreDuplicates is passed, and we never pass options at
  all - so the promise rests on a library DEFAULT that nobody chose. The day
  someone constructs a parser with different options for an unrelated reason, a
  documented guarantee disappears and nothing goes red. Naming the cause here is
  what lets a test assert it, which is what turns an inherited behaviour into a
  kept promise. }
function ParseObj(const S: string; out Reason: string): TJSONObject;
var
  D: TJSONData;
begin
  Result := nil;
  Reason := '';
  if Trim(S) = '' then
  begin
    Reason := 'empty body';
    Exit;
  end;
  D := nil;
  try
    D := GetJSON(S);
  except
    on E: Exception do
    begin
      if Pos('Duplicate object member', E.Message) > 0 then
        Reason := 'duplicate field in body (' + E.Message + ')'
      else
        Reason := 'body is not valid JSON (' + E.Message + ')';
      Exit;
    end;
  end;
  if (D <> nil) and (D.JSONType = jtObject) then
    Result := TJSONObject(D)
  else
  begin
    Reason := 'body is valid JSON but its top level is not an object';
    D.Free;
  end;
end;

function ParseObj(const S: string): TJSONObject;
var
  Ignorado: string;
begin
  Result := ParseObj(S, Ignorado);
end;

function MsgToJson(const M: TPzMsg): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('seq', M.Seq);
    O.Add('ts', M.Ts);
    O.Add('from', M.From);
    O.Add('to', M.Dest);
    O.Add('text', M.Text);
    O.Add('via', M.Via);
    if M.Ident <> '' then
      O.Add('ident', M.Ident);
    { Emit only for truly minimal headers; keep normal journal records clean. }
    if M.Minimal then
      O.Add('minimal', True);
    if M.ReplyTo <> '' then
      O.Add('reply_to', M.ReplyTo);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function JsonToMsg(Obj: TJSONObject): TPzMsg;
begin
  Result.Seq := Obj.Get('seq', Int64(0));
  Result.Ts := Obj.Get('ts', '');
  Result.From := Obj.Get('from', '');
  Result.Dest := Obj.Get('to', '');
  Result.Text := Obj.Get('text', '');
  Result.Via := Obj.Get('via', '');
  Result.Ident := Obj.Get('ident', '');
  Result.Minimal := Obj.Get('minimal', False);
  Result.ReplyTo := Obj.Get('reply_to', '');
end;

function BuildSend(const Secret, From, Dest, Text: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_SEND);
    O.Add('from', From);
    O.Add('to', Dest);
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildInbox(const Secret, From: string; Peek: Boolean; All: Boolean;
  After: Int64; Limit: Integer): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_INBOX);
    O.Add('from', From);
    if Peek then
      O.Add('peek', True);
    if All then
      O.Add('all', True);
    if After > 0 then
      O.Add('after', After);
    if Limit > 0 then
      O.Add('limit', Limit);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildDeliver(const Secret: string; Seq: Int64;
  const From, Team, Text: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_DELIVER);
    O.Add('seq', Seq);
    O.Add('from', From);
    O.Add('team', Team);
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildPing(const Secret: string; const HubVer: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_PING);
    if HubVer <> '' then
      O.Add('hubver', HubVer);  { lets an autoupdate daemon spot new releases }
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWatch(const Secret, From: string; Since: Int64): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_WATCH);
    O.Add('from', From);
    O.Add('since', Since);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildDial(const Secret, From, Teams: string;
  KeepAlive: Integer; Since: Int64; const Ver: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_DIAL);
    O.Add('from', From);
    O.Add('teams', Teams);
    O.Add('keepalive', KeepAlive);
    O.Add('since', Since);
    if Ver <> '' then
      O.Add('ver', Ver);   { daemon release, shown by cmd=fleet (added 1.0.2) }
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildPut(const Secret, From, Dest, Name, Data: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_PUT);
    O.Add('from', From);
    O.Add('to', Dest);
    O.Add('name', Name);
    O.Add('data', Data);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildPutChunk(const Secret, From, Dest, Name, Id, Data: string;
  Offset: Int64; Last: Boolean; const Sha: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_PUT);
    O.Add('from', From);
    O.Add('to', Dest);
    O.Add('name', Name);
    O.Add('id', Id);
    O.Add('offset', Offset);
    O.Add('data', Data);
    if Last then
    begin
      O.Add('last', True);
      O.Add('sha256', Sha);
    end;
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildGetChunk(const Secret, From, Path: string;
  Offset, Max: Int64): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_GET);
    O.Add('from', From);
    O.Add('path', Path);
    O.Add('offset', Offset);
    O.Add('max', Max);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildGet(const Secret, From, Path: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_GET);
    O.Add('from', From);
    O.Add('path', Path);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildDeliverAck(const Team: string; Seq: Int64; Ok: Boolean): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', Ok);
    O.Add('team', Team);
    O.Add('seq', Seq);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildAck(const Secret, From: string; UpTo: Int64): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_ACK);
    O.Add('from', From);
    O.Add('upto', UpTo);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTeams(const Secret, From: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_TEAMS);
    { Identify WHO is asking: the index hides child teams from everyone except
      their parent and the console. An empty sender previously exposed them. }
    if From <> '' then
      O.Add('from', From);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildRecent(const Secret: string; Since: Int64; Max: Integer;
  const From: string = ''): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_RECENT);
    if From <> '' then
      O.Add('from', From);
    O.Add('since', Since);
    O.Add('max', Max);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;


{ One builder for every app op: add|set|remove|list|show. Empty strings are
  omitted so `set` can clear a field explicitly via value='' with field set. }
function BuildAppOp(const Secret, From, Op, Name, Team, Repo, PathS,
  Purpose, Detail, Field, Value: string; const Text: string = '';
  Snap: Integer = 0; At: Integer = 0;
  const Project_: string = ''; const Role: string = ''): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_APP);
    O.Add('from', From);
    O.Add('op', Op);
    O.Add('name', Name);
    if Team <> '' then O.Add('team', Team);
    if Repo <> '' then O.Add('repo', Repo);
    if PathS <> '' then O.Add('path', PathS);
    if Purpose <> '' then O.Add('purpose', Purpose);
    if Detail <> '' then O.Add('detail', Detail);
    if Field <> '' then
    begin
      O.Add('field', Field);
      O.Add('value', Value);
    end;
    if Text <> '' then
      O.Add('text', Text);   { the app manual (op=setdoc) }
    if Snap > 0 then
      O.Add('snap', Snap);   { History point to restore for op=undo. }
    if At > 0 then
      O.Add('at', At);       { Manual version to view for op=doc. }
      if Project_ <> '' then
    O.Add('project', Project_);
  if Role <> '' then
    O.Add('role', Role);
  Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildVer(const Secret, From: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_VER);
    O.Add('from', From);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildActivity(const Secret, From, State: string; const Note: string = '';
  Hold: Boolean = False): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_ACTIVITY);
    O.Add('from', From);
    O.Add('state', State);
    if Note <> '' then
      O.Add('note', Note);
    if Hold then
      O.Add('hold', True);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildHold(const Secret, From, Team: string; On_: Boolean): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_HOLD);
    O.Add('from', From);
    O.Add('team', Team);
    O.Add('on', On_);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildCaps(const Secret, From: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_CAPS);
    O.Add('from', From);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildBackup(const Secret, From, OutDir: string;
  Force: Boolean): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_BACKUP);
    O.Add('from', From);
    if OutDir <> '' then
      O.Add('out', OutDir);
    if Force then
      O.Add('force', True);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildFleet(const Secret, From: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_FLEET);
    O.Add('from', From);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ From identifies the requester. Sending it empty worked with the master key,
  but the hub rejected daemons presenting their own team secret and fleet
  self-update stopped. State who is asking as well as proving the secret. }
function BuildUpget(const Secret, OsS, CpuS, Kind: string;
  Offset, Max: Int64; const From: string = ''): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_UPGET);
    O.Add('os', OsS);
    O.Add('cpu', CpuS);
    O.Add('kind', Kind);       { 'bin' | 'src' }
    O.Add('offset', Offset);
    O.Add('max', Max);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildUpdate(const Secret, From, Name, Ver: string;
  Force: Boolean): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret);
    O.Add('cmd', CMD_UPDATE);
    O.Add('from', From);       { hub gate: console-only op }
    O.Add('name', Name);       { team | 'all' (console->hub); '' hub->daemon }
    O.Add('ver', Ver);
    if Force then
      O.Add('force', True);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function TaskReq(const Secret, From, Op: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('secret', Secret);
  Result.Add('cmd', CMD_TASK);
  Result.Add('from', From);
  Result.Add('op', Op);
end;

function BuildTaskAdd(const Secret, From, Title, Team, Hito: string;
  Parent: Integer = 0): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'add');
  try
    O.Add('title', Title);
    O.Add('team', Team);
    O.Add('hito', Hito);
    if Parent > 0 then
      O.Add('parent', Parent);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTaskState(const Secret, From: string; Id: Integer;
  const State: string): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'state');
  try
    O.Add('id', Id);
    O.Add('state', State);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTaskAssign(const Secret, From: string; Id: Integer;
  const Team: string): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'assign');
  try
    O.Add('id', Id);
    O.Add('team', Team);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTaskNote(const Secret, From: string; Id: Integer;
  const Text: string): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'note');
  try
    O.Add('id', Id);
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTaskList(const Secret, From, Filter, Team: string): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'list');
  try
    O.Add('filter', Filter);
    O.Add('team', Team);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTaskShow(const Secret, From: string; Id: Integer): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'show');
  try
    O.Add('id', Id);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTaskDelete(const Secret, From: string; Id: Integer): string;
var
  O: TJSONObject;
begin
  O := TaskReq(Secret, From, 'delete');
  try
    O.Add('id', Id);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function WfReq(const Secret, From, Op: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('secret', Secret);
  Result.Add('cmd', CMD_WORKFLOW);
  Result.Add('from', From);
  Result.Add('op', Op);
end;

function BuildWfCreate(const Secret, From, Name, Group: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'create');
  try
    O.Add('name', Name);
    O.Add('group', Group);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfStep(const Secret, From, Name, Team, Hito, After: string;
  const EtaS: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'step');
  try
    O.Add('name', Name);
    O.Add('team', Team);
    O.Add('hito', Hito);
    if After <> '' then
      O.Add('after', After);
    if EtaS <> '' then
      O.Add('eta', EtaS);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfStart(const Secret, From, Name: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'start');
  try
    O.Add('name', Name);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfDone(const Secret, From, Name: string; Step: Integer;
  const Proof: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'done');
  try
    O.Add('name', Name);
    if Step > 0 then
      O.Add('step', Step);
    if Proof <> '' then
      O.Add('text', Proof);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfError(const Secret, From, Name, Why: string;
  Step: Integer): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'error');
  try
    O.Add('name', Name);
    O.Add('text', Why);
    if Step > 0 then
      O.Add('step', Step);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfFixed(const Secret, From, Name, Text: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'fixed');
  try
    O.Add('name', Name);
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfVerify(const Secret, From, Name: string; Pass: Boolean;
  const Note: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'verify');
  try
    O.Add('name', Name);
    if Pass then
      O.Add('result', 'ok')
    else
      O.Add('result', 'fail');
    if Note <> '' then
      O.Add('text', Note);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfAbort(const Secret, From, Name, Why: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'abort');
  try
    O.Add('name', Name);
    O.Add('text', Why);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfList(const Secret, From: string; Mine: Boolean;
  const Team: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'list');
  try
    if Mine then
      O.Add('mine', True);
    if Team <> '' then
      O.Add('team', Team);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfTasks(const Secret, From, Name: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'tasks');
  try
    O.Add('name', Name);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfClone(const Secret, From, Src, NewName: string;
  const Group: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'clone');
  try
    O.Add('name', Src);
    O.Add('newname', NewName);
    if Group <> '' then
      O.Add('group', Group);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfShow(const Secret, From, Name: string; FromN: Integer;
  Depth: Integer; Detail: Boolean): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'show');
  try
    O.Add('name', Name);
    if FromN > 0 then
      O.Add('subtree', FromN);
    if Depth > 0 then
      O.Add('depth', Depth);
    if Detail then
      O.Add('detail', True);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfInsert(const Secret, From, Name, Team, Hito: string;
  AfterN: Integer; const EtaS: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'insert');
  try
    O.Add('name', Name);
    O.Add('team', Team);
    O.Add('hito', Hito);
    { STRING: HandleWorkflow reads 'after' with Obj.Get(...,'') at the hub, so a
      numeric value appears absent. Changing this to a number to mirror the HTTP
      contract broke existing bus behavior. pzweb translates the numeric HTTP
      representation to this string-based bus representation. }
    O.Add('after', IntToStr(AfterN));
    if EtaS <> '' then
      O.Add('eta', EtaS);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfRemove(const Secret, From, Name: string; Step: Integer): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'remove');
  try
    O.Add('name', Name);
    O.Add('step', Step);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfSet(const Secret, From, Name: string; Step: Integer;
  const Field, Value: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'set');
  try
    O.Add('name', Name);
    O.Add('step', Step);
    O.Add('field', Field);
    O.Add('value', Value);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfHistory(const Secret, From, Name: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'history');
  try
    O.Add('name', Name);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfDelete(const Secret, From, Name, Why: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'delete');
  try
    O.Add('name', Name);
    O.Add('text', Why);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfUndo(const Secret, From, Name: string;
  SnapN: Integer = 0): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'undo');
  try
    O.Add('name', Name);
    if SnapN > 0 then
      O.Add('snap', SnapN);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildWfRestore(const Secret, From, Name, Data: string): string;
var
  O: TJSONObject;
begin
  O := WfReq(Secret, From, 'restore');
  try
    O.Add('name', Name);
    O.Add('data', Data);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function EvTask(const Text: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ev', 'task');
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function EvAlarm(const Team, Text: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ev', 'alarm');
    O.Add('team', Team);
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function TeamReq(const Secret, From, Op, Name: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('secret', Secret);
  Result.Add('cmd', CMD_TEAM);
  Result.Add('from', From);
  Result.Add('op', Op);
  Result.Add('name', Name);
end;

function BuildTeamAdd(const Secret, From, Name, Spec, Parent, Host,
  Session, Launch, Prompt: string): string;
var
  O: TJSONObject;
begin
  O := TeamReq(Secret, From, 'add', Name);
  try
    O.Add('speciality', Spec);
    O.Add('parent', Parent);
    O.Add('host', Host);
    O.Add('session', Session);
    O.Add('launch', Launch);
    O.Add('prompt', Prompt);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTeamRemove(const Secret, From, Name: string): string;
var
  O: TJSONObject;
begin
  O := TeamReq(Secret, From, 'remove', Name);
  try
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTeamSet(const Secret, From, Name, Field, Value: string): string;
var
  O: TJSONObject;
begin
  O := TeamReq(Secret, From, 'set', Name);
  try
    O.Add('field', Field);
    O.Add('value', Value);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildTeamShow(const Secret, From, Name: string): string;
var
  O: TJSONObject;
begin
  O := TeamReq(Secret, From, 'show', Name);
  try
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function GroupReq(const Secret, From, Op, Name: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('secret', Secret);
  Result.Add('cmd', CMD_GROUP);
  Result.Add('from', From);
  Result.Add('op', Op);
  Result.Add('name', Name);
end;

function BuildGroupAdd(const Secret, From, Name, Members: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'add', Name);
  try O.Add('members', Members); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupRemove(const Secret, From, Name, Members: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'remove', Name);
  try O.Add('members', Members); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupProject(const Secret, From, Name, Project: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'project', Name);
  try O.Add('project', Project); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupList(const Secret, From: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'list', '');
  try Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupBoss(const Secret, From, Name, Boss: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'boss', Name);
  try O.Add('boss', Boss); Result := O.AsJSON; finally O.Free; end;
end;

{ Excluded is the WHOLE muted set as a CSV (empty clears it): replace semantics,
  like project/boss. }
function BuildGroupExclude(const Secret, From, Name, Excluded: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'exclude', Name);
  try O.Add('excluded', Excluded); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupOnIdle(const Secret, From, Name, Policy: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'onidle', Name);
  try O.Add('onidle', Policy); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupOnIdleMsg(const Secret, From, Name, Msg: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'onidlemsg', Name);
  try O.Add('onidlemsg', Msg); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupHeader(const Secret, From, Name, Note: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'header', Name);
  try O.Add('header', Note); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupOnIdleFrom(const Secret, From, Name, Who: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'onidlefrom', Name);
  try O.Add('onidlefrom', Who); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupOnIdleReply(const Secret, From, Name, Who: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'onidlereply', Name);
  try O.Add('onidlereply', Who); Result := O.AsJSON; finally O.Free; end;
end;

function BuildGroupOnBlock(const Secret, From, Name, Policy: string): string;
var O: TJSONObject;
begin
  O := GroupReq(Secret, From, 'onblock', Name);
  try O.Add('onblock', Policy); Result := O.AsJSON; finally O.Free; end;
end;

function BuildProjectBoss(const Secret, From, Name, Boss: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_PROJECT); O.Add('from', From);
    O.Add('op', 'boss'); O.Add('name', Name); O.Add('boss', Boss);
    Result := O.AsJSON;
  finally O.Free; end;
end;

function BuildProjectList(const Secret, From: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_PROJECT); O.Add('from', From);
    O.Add('op', 'list');
    Result := O.AsJSON;
  finally O.Free; end;
end;

function BuildProjectShow(const Secret, From, Name: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_PROJECT); O.Add('from', From);
    O.Add('op', 'show');     O.Add('name', Name);
    Result := O.AsJSON;
  finally O.Free; end;
end;

function BuildProjectRemove(const Secret, From, Name: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_PROJECT); O.Add('from', From);
    O.Add('op', 'remove');   O.Add('name', Name);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function BuildHeaderList(const Secret, From: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_HEADER); O.Add('from', From);
    O.Add('op', 'list');
    Result := O.AsJSON;
  finally O.Free; end;
end;

function BuildHeaderSet(const Secret, From, Key, Value: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_HEADER); O.Add('from', From);
    O.Add('op', 'set'); O.Add('key', Key); O.Add('value', Value);
    Result := O.AsJSON;
  finally O.Free; end;
end;

function BuildHeaderNote(const Secret, From, Note: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('secret', Secret); O.Add('cmd', CMD_HEADER); O.Add('from', From);
    O.Add('op', 'note'); O.Add('note', Note);
    Result := O.AsJSON;
  finally O.Free; end;
end;

function EvMsg(const M: TPzMsg): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ev', 'msg');
    O.Add('seq', M.Seq);
    O.Add('ts', M.Ts);
    O.Add('from', M.From);
    O.Add('to', M.Dest);
    O.Add('text', M.Text);
    O.Add('via', M.Via);
    if M.Ident <> '' then
      O.Add('ident', M.Ident);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function EvSys(const Text: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ev', 'sys');
    O.Add('text', Text);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function EvPing: string;
begin
  Result := '{"ev":"ping"}';
end;

{ STRUCTURAL GAP: the sole signal that a view cannot be certified complete.
  'after' is the final sequence whose socket write FINISHED, not the last item
  removed from the queue; otherwise it would claim delivery of unsent data. It
  carries no event ID so it cannot advance the client's last known-good cursor.
  Allowed reasons are queue_overflow, replay_overflow, history_unavailable, and
  cursor_ahead. A sequence-number jump is NOT a gap: hiding unrelated traffic
  makes the global sequence skip by design. }
function EvGap(After: Int64; const Reason: string): string;
begin
  Result := Format('{"ev":"gap","after":%d,"reason":"%s","reload":true}',
                   [After, Reason]);
end;

function ReplyOk: string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ A successful result WITH explanation for side effects the operator must know
  even though the operation succeeded. }
function ReplyOkNote(const Note: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('note', Note);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyCaps(const Bound: string; Unrestricted: Boolean;
  const Families: array of string): string;
var
  O: TJSONObject;
  A: TJSONArray;
  i: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    { Team BOUND to the credential; empty for a global credential. }
    O.Add('bound', Bound);
    O.Add('unrestricted', Unrestricted);
    A := TJSONArray.Create;
    for i := 0 to High(Families) do
      A.Add(Families[i]);
    O.Add('families', A);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyVer(const Ver: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('ver', Ver);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplySent(Seq: Int64; Queued: Boolean; const Note: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('seq', Seq);
    O.Add('queued', Queued);
    if Note <> '' then
      O.Add('note', Note);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyBroadcast(Sent, Queued: Integer): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    O.Add('broadcast', Sent);
    O.Add('queued_count', Queued);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyErr(const Msg: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', False);
    O.Add('error', Msg);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ReplyUnknown(const Msg: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', False);
    O.Add('error', Msg);
    O.Add('outcome', 'unknown');
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ 'Below' is the unread count BENEATH this window. It tells an acknowledging
  client that it cannot jump to the highest visible sequence. Zero means none;
  emit the field only when positive to preserve deployed-client behavior. }
function ReplyInbox(const Msgs: array of TPzMsg; More: Integer): string;
var
  O, M: TJSONObject;
  A: TJSONArray;
  i: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('ok', True);
    if More > 0 then
      O.Add('more', More);
    A := TJSONArray.Create;
    for i := 0 to High(Msgs) do
    begin
      M := TJSONObject.Create;
      M.Add('seq', Msgs[i].Seq);
      M.Add('ts', Msgs[i].Ts);
      M.Add('from', Msgs[i].From);
      M.Add('to', Msgs[i].Dest);
      M.Add('text', Msgs[i].Text);
      M.Add('via', Msgs[i].Via);
      A.Add(M);
    end;
    O.Add('messages', A);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

end.
