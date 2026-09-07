{ pzchat - the human console (`tiza chat`).

  One process, one fpSelect loop over two fds:
    - the watch socket: pizarra streams every bus event as one JSON line
    - stdin: a minimal raw-mode line editor (UTF-8 backspace, Ctrl-U/W,
      history with Up/Down, Ctrl-D to quit)

  Feed lines use the classic redraw trick: erase the input line, print the
  event, reprint prompt+buffer. Commands travel on short-lived one-shot
  connections (pznet.RequestLine); only the watch stream is persistent, and
  it reconnects with backoff from the last seen seq.

  Raw mode keeps ISIG (Ctrl-C works via pznet's SIGINT handler -> clean exit,
  termios always restored) and OPOST untouched. --plain skips termios games
  entirely (canonical input; feed and typing may interleave).               }
unit pzchat;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, termio, ssockets, fpjson, base64,
  pzproto, pzconfig, pzlayout, pznet, pzshare, pzansi, pzver, pzbox;

procedure RunChat(const ACfg: TTizaConfig; APlain: Boolean);

implementation

const
  RECENT_CAP = 500;   { local cache backing /full }

type
  TChatTeam = record
    Id: Integer;
    Name, Spec, Parent, Workdir: string;
    OpenTasks: Integer;
    Slave: Boolean;
  end;

  TChat = class
  private
    FCfg: TTizaConfig;
    FPlain: Boolean;
    FOldTios: Termios;
    FRawOn: Boolean;
    FSock: TInetSocket;
    FSockBuf: string;
    FBuf: string;
    FCursor: Integer;    { insert point as a BYTE offset into FBuf, 0..Length }
    FWinStart: Integer;  { first visible character CELL when the line is scrolled }
    FEscState: Integer;
    FEscNum: Integer;    { numeric parameter of a CSI sequence (e.g. 3 in ESC[3~) }
    FHistory: TStringList;
    FHistIdx: Integer;
    FHistFile: string;
    FTeams: array of TChatTeam;
    FGroupNames: array of string;   { for bare-group-name send validation }
    FSharedDir: string;
    FLastSeq: Int64;
    FRecent: TPzMsgArray;
    FRecentN: Integer;
    FCompose: Boolean;
    FComposeTo: string;
    FComposeLines: TStringList;
    FQuit: Boolean;
    FRetryWaitMs: Integer;
    FAckHigh, FAckSent: Int64;   { batched console-cursor acks }
    procedure EnterRaw;
    procedure LeaveRaw;
    function  Prompt: string;
    procedure RedrawInput;
    procedure FeedLine(const S: string);
    function  OneShot(const Req: string; out Reply: string;
      TimeoutMs: Integer = 3000): Boolean;
    procedure ConnectWatch;
    procedure HandleSockData;
    procedure HandleEvent(const Line: string);
    procedure HandleStdin;
    procedure HandleByte(b: Byte);
    procedure CursorLeft;
    procedure CursorRight;
    procedure SubmitLine;
    procedure ExecuteLine(const RawLine: string);
    procedure DoSendTo(const Dest, Text: string);
    procedure StartCompose(const Dest: string);
    procedure RefreshTeams(Quiet: Boolean);
    function  KnownTeam(const Key: string): Boolean;
    function  KnownDest(const Key: string): Boolean;
    procedure CmdHelp(const Arg: string);
    procedure CmdInbox;
    procedure CmdLog(const Arg: string);
    procedure CmdFull(const Arg: string);
    procedure CmdCat(const Arg: string);
    procedure CmdFile(const Rest: string);
    procedure CmdTask(const Rest: string);
    procedure CmdWorkflow(const Rest: string);
    procedure CmdTeam(const Rest: string);
    procedure CmdGroup(const Rest: string);
    procedure CmdProject(const Rest: string);
    procedure CmdHeader(const Rest: string);
    procedure CmdShare(const Rest: string);
    procedure CmdFiles(const Rest: string);
    procedure CmdTree;
    procedure CmdVer;
    procedure CmdFleet;
    procedure CmdUpdate(const Rest: string);
    procedure CmdApp(const Rest: string);
    procedure FeedBlock(const S: string);
    function TeamsTable: string;
    procedure PrintTask(T: TJSONObject; Full: Boolean);
    procedure Remember(const M: TPzMsg);
    procedure HistAdd(const Line: string);
    procedure HistNav(Up: Boolean);
    procedure FlushAck;
  public
    constructor Create(const ACfg: TTizaConfig; APlain: Boolean);
    destructor Destroy; override;
    procedure Run;
  end;

{ ---------------- terminal ---------------- }

procedure TChat.EnterRaw;
var
  T: Termios;
begin
  if FPlain then
    Exit;
  if TCGetAttr(0, FOldTios) <> 0 then
  begin
    FPlain := True;   { no termios? degrade to plain }
    AnsiOff;          { and kill colors with it (single gate, pzansi) }
    Exit;
  end;
  T := FOldTios;
  T.c_lflag := T.c_lflag and (not (ICANON or ECHO));   { keep ISIG }
  T.c_cc[VMIN] := 1;
  T.c_cc[VTIME] := 0;
  if TCSetAttr(0, TCSANOW, T) = 0 then
    FRawOn := True
  else
    FPlain := True;
end;

procedure TChat.LeaveRaw;
begin
  if FRawOn then
  begin
    TCSetAttr(0, TCSANOW, FOldTios);
    FRawOn := False;
  end;
end;

function TChat.Prompt: string;
begin
  if FCompose then
    Result := FComposeTo + '| '
  else
    Result := '> ';
end;

{ terminal width in columns; 80 if it cannot be queried.
  TIOCGWINSZ and TWinSize come from termio, which carries each platform's own
  request number (Linux $5413, Darwin $40087468). A hardcoded Linux value
  used to live here, so on the macOS endpoint the ioctl failed silently and
  the console always fell back to 80 columns. }
function TermWidth: Integer;
var ws: TWinSize;
begin
  if fpIOCtl(1, TIOCGWINSZ, @ws) >= 0 then
    Result := ws.ws_col
  else
    Result := 0;
  if Result <= 0 then
    Result := 80;
end;

{ number of UTF-8 characters (cells) in S[1..BytePos] }
function CellsUpto(const S: string; BytePos: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  if BytePos > Length(S) then BytePos := Length(S);
  for i := 1 to BytePos do
    if (Byte(S[i]) and $C0) <> $80 then   { not a UTF-8 continuation byte }
      Inc(Result);
end;

{ 0-based byte offset where the Cell-th (0-based) character begins;
  Length(S) if Cell is at/past the end }
function ByteAtCell(const S: string; Cell: Integer): Integer;
var i, c: Integer;
begin
  if Cell <= 0 then Exit(0);
  c := 0;
  for i := 1 to Length(S) do
    if (Byte(S[i]) and $C0) <> $80 then
    begin
      if c = Cell then Exit(i - 1);
      Inc(c);
    end;
  Result := Length(S);
end;

{ Draw the input on ONE physical row. If prompt+text is wider than the terminal,
  horizontally scroll a window that keeps the cursor visible, so the line never
  wraps — a wrapped line cannot be cleared by a single CR + ESC[K and would
  cascade/duplicate on every keystroke (the bug this replaces). The visible
  window only scrolls when the cursor leaves it, so the view stays steady. }
procedure TChat.RedrawInput;
var
  W, promptW, avail, curCell, totCell, winEnd, back, sB, eB: Integer;
  vis: string;
begin
  if FPlain then
    Exit;
  W := TermWidth;
  promptW := CellsUpto(Prompt, Length(Prompt));
  avail := W - promptW - 1;    { spare column dodges the last-column wrap glitch }
  if avail < 1 then
    avail := 1;
  curCell := CellsUpto(FBuf, FCursor);
  totCell := CellsUpto(FBuf, Length(FBuf));
  if totCell <= avail then
    FWinStart := 0
  else
  begin
    if curCell < FWinStart then FWinStart := curCell;                  { off the left }
    if curCell > FWinStart + avail then FWinStart := curCell - avail;  { off the right }
    if FWinStart > totCell - avail then FWinStart := totCell - avail;  { text shrank }
    if FWinStart < 0 then FWinStart := 0;
  end;
  winEnd := FWinStart + avail;
  if winEnd > totCell then
    winEnd := totCell;
  sB := ByteAtCell(FBuf, FWinStart);
  eB := ByteAtCell(FBuf, winEnd);
  vis := Copy(FBuf, sB + 1, eB - sB);
  Write(#13#27'[K', Prompt, vis);
  back := winEnd - curCell;    { cells from the cursor to the end of the visible text }
  if back > 0 then
    Write(#27'[', back, 'D');
  Flush(Output);
end;

{ Print one feed line above the input line. }
{ Append a preformatted block (box or table) to the feed one line at a time. }
procedure TChat.FeedBlock(const S: string);
var
  L: TStringList;
  i: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := S;
    for i := 0 to L.Count - 1 do
      if (i < L.Count - 1) or (Trim(L[i]) <> '') then
        FeedLine(L[i]);
  finally
    L.Free;
  end;
end;

procedure TChat.FeedLine(const S: string);
begin
  if FPlain then
    Writeln(S)
  else
  begin
    Write(#13#27'[K');
    Writeln(S);
    RedrawInput;
  end;
  Flush(Output);
end;

{ ---------------- network ---------------- }

function TChat.OneShot(const Req: string; out Reply: string;
  TimeoutMs: Integer): Boolean;
var
  Err: string;
begin
  Result := RequestLine(FCfg.Host, FCfg.Port, TimeoutMs, Req, Reply, Err);
  if not Result then
      FeedLine('(pizarra is not responding: ' + Err + ')');
end;

{ Batched, silent cursor advance — losing an ack only means a message shows
  as unread once more, never worth feed noise or blocking the loop for. }
procedure TChat.FlushAck;
var
  Reply, Err: string;
begin
  if FAckHigh > FAckSent then
  begin
    if RequestLine(FCfg.Host, FCfg.Port, 2000,
      BuildAck(FCfg.Secret, FCfg.SelfId, FAckHigh), Reply, Err) then
      FAckSent := FAckHigh;
  end;
end;

procedure TChat.ConnectWatch;
begin
  FreeAndNil(FSock);
  FSockBuf := '';
  try
    FSock := TInetSocket.Create(FCfg.Host, FCfg.Port, 3000);
    if FLastSeq > 0 then
      { resume exactly after the last rendered event }
      WriteLine(FSock, BuildWatch(FCfg.Secret, FCfg.SelfId, FLastSeq))
    else
      { fresh session: server replays the last 30 }
      WriteLine(FSock, BuildWatch(FCfg.Secret, FCfg.SelfId, -1));
    FRetryWaitMs := 0;
  except
    on E: Exception do
    begin
      FreeAndNil(FSock);
      FRetryWaitMs := 3000;
    end;
  end;
end;

procedure TChat.HandleSockData;
var
  Buf: array[0..4095] of Byte;
  n, p: Integer;
  Line: string;
begin
  n := FSock.Read(Buf, SizeOf(Buf));
  if n <= 0 then
  begin
    FeedLine('(pizarra disconnected - retrying...)');
    FreeAndNil(FSock);
    FRetryWaitMs := 1000;
    Exit;
  end;
  SetLength(Line, n);
  Move(Buf, Line[1], n);
  FSockBuf := FSockBuf + Line;
  repeat
    p := Pos(#10, FSockBuf);
    if p = 0 then
      Break;
    Line := Copy(FSockBuf, 1, p - 1);
    Delete(FSockBuf, 1, p);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if Line <> '' then
      HandleEvent(Line);
  until False;
end;

{ Ring buffer. TPzMsg holds managed strings — never Move() such records
  (refcount corruption); plain assignment into a rotating slot is safe. }
procedure TChat.Remember(const M: TPzMsg);
begin
  if Length(FRecent) < RECENT_CAP then
    SetLength(FRecent, RECENT_CAP);
  FRecent[FRecentN mod RECENT_CAP] := M;
  Inc(FRecentN);
end;

procedure TChat.HandleEvent(const Line: string);
var
  Obj: TJSONObject;
  Ev, First, Extra: string;
  M: TPzMsg;
  nl: Integer;
begin
  Obj := ParseObj(Line);
  if Obj = nil then
    Exit;
  try
    Ev := Obj.Get('ev', '');
    if Ev = 'msg' then
    begin
      M := JsonToMsg(Obj);
      if M.Seq > FLastSeq then
        FLastSeq := M.Seq;
      Remember(M);
      nl := Pos(#10, M.Text);
      if nl = 0 then
      begin
        First := M.Text;
        Extra := '';
      end
      else
      begin
        First := Copy(M.Text, 1, nl - 1);
        Extra := Format('  [+%d lines, /full %d]',
          [Length(M.Text) - Length(StringReplace(M.Text, #10, '', [rfReplaceAll])),
           M.Seq]);
      end;
      if ColorsOn then
      begin
        { identity by tone, metadata dim, body at default intensity; the via
          badge and the styled /full affordance exist only in color mode so
          the plain branch below stays byte-identical (frozen contract) }
        if nl <> 0 then
          Extra := '  ' + Dim(Format('[+%d lines, ',
            [Length(M.Text) - Length(StringReplace(M.Text, #10, '', [rfReplaceAll]))]))
            + Fg(HINT_FG, Format('/full %d', [M.Seq])) + Dim(']');
        FeedLine(Dim(Copy(M.Ts, 12, 5)) + ' ' + Dim(Format('#%d', [M.Seq])) +
          ' ' + Dim(M.Via) + ' ' + TeamName(M.From) + Dim('->') +
          TeamName(M.Dest) + '  ' + First + Extra);
      end
      else
        FeedLine(Format('%s #%d %s%s%s  %s%s',
          [Copy(M.Ts, 12, 5), M.Seq, M.From, '->', M.Dest, First, Extra]));
      { rendered = read; acked in batches from the main loop — one TCP
        round-trip per rendered message would stall the feed on bursts }
      if SameText(M.Dest, FCfg.SelfId) and (M.Seq > FAckHigh) then
        FAckHigh := M.Seq;
    end
    else if Ev = 'sys' then
      FeedLine(Dim('~ ' + Obj.Get('text', '')))

    else if Ev = 'gap' then
      FeedLine(FgBold(ALERT_FG, '~ (gap: events dropped, slow client)'))
    else if Ev = 'task' then
      FeedLine(Fg(TASK_FG, '*') + ' ' + Obj.Get('text', 'task updated'))
    else if Ev = 'alarm' then
    begin
      { loudest thing the console can do: bold-red REVERSE video + the terminal
        bell. #7 is not an SGR sequence — write it raw, never via Sgr, never
        store it (print-time only, C1 purity). }
      FeedLine(FgBold(ALERT_FG, Inverse('!! ' + Obj.Get('text', 'ALARM'))));
      Write(#7);
      Flush(Output);
    end;
    { ping: ignored }
  finally
    Obj.Free;
  end;
end;

{ ---------------- input ---------------- }

procedure TChat.HandleStdin;
var
  Buf: array[0..255] of Byte;
  n, i: Integer;
begin
  n := fpRead(0, Buf, SizeOf(Buf));
  if n <= 0 then
  begin
    FQuit := True;   { stdin closed }
    Exit;
  end;
  for i := 0 to n - 1 do
    HandleByte(Buf[i]);
end;

{ move the insert point left/right by one whole UTF-8 character }
procedure TChat.CursorLeft;
begin
  if FCursor <= 0 then Exit;
  Dec(FCursor);
  while (FCursor > 0) and ((Byte(FBuf[FCursor + 1]) and $C0) = $80) do
    Dec(FCursor);
  RedrawInput;
end;

procedure TChat.CursorRight;
begin
  if FCursor >= Length(FBuf) then Exit;
  Inc(FCursor);
  while (FCursor < Length(FBuf)) and ((Byte(FBuf[FCursor + 1]) and $C0) = $80) do
    Inc(FCursor);
  RedrawInput;
end;

procedure TChat.HandleByte(b: Byte);
var
  st, en: Integer;
begin
  { CSI/SS3 escape decoding: arrows, Home/End, Delete. FEscState 1 = after ESC,
    2 = after ESC[ or ESC O, collecting an optional numeric parameter. }
  if FEscState = 1 then
  begin
    if (b = Ord('[')) or (b = Ord('O')) then
    begin
      FEscState := 2;
      FEscNum := 0;
    end
    else
      FEscState := 0;   { unknown ESC x — drop }
    Exit;
  end
  else if FEscState = 2 then
  begin
    if (b >= Ord('0')) and (b <= Ord('9')) then
    begin
      FEscNum := FEscNum * 10 + (b - Ord('0'));
      Exit;   { keep collecting digits }
    end;
    case Chr(b) of
      'A': HistNav(True);       { up }
      'B': HistNav(False);      { down }
      'C': CursorRight;
      'D': CursorLeft;
      'H': begin FCursor := 0; RedrawInput; end;             { Home }
      'F': begin FCursor := Length(FBuf); RedrawInput; end;  { End }
      '~':
        case FEscNum of
          1, 7: begin FCursor := 0; RedrawInput; end;             { Home }
          4, 8: begin FCursor := Length(FBuf); RedrawInput; end;  { End }
          3:    { Delete: remove the character AT the cursor }
            if FCursor < Length(FBuf) then
            begin
              en := FCursor + 1;
              while (en < Length(FBuf)) and ((Byte(FBuf[en + 1]) and $C0) = $80) do
                Inc(en);
              Delete(FBuf, FCursor + 1, en - FCursor);
              RedrawInput;
            end;
        end;
    end;
    FEscState := 0;
    Exit;
  end;

  case b of
    27: FEscState := 1;
    10, 13: SubmitLine;
    1:    { Ctrl-A = start of line }
      begin FCursor := 0; RedrawInput; end;
    5:    { Ctrl-E = end of line }
      begin FCursor := Length(FBuf); RedrawInput; end;
    2:    CursorLeft;    { Ctrl-B }
    6:    CursorRight;   { Ctrl-F }
    127, 8:
      begin
        { backspace: delete the whole UTF-8 character BEFORE the cursor }
        if FCursor > 0 then
        begin
          st := FCursor;
          while (st > 1) and ((Byte(FBuf[st]) and $C0) = $80) do
            Dec(st);
          Delete(FBuf, st, FCursor - st + 1);
          FCursor := st - 1;
          RedrawInput;
        end;
      end;
    21:   { Ctrl-U: clear the line }
      begin
        FBuf := '';
        FCursor := 0;
        FWinStart := 0;
        RedrawInput;
      end;
    23:   { Ctrl-W: delete the word before the cursor }
      begin
        st := FCursor;
        while (st > 0) and (FBuf[st] = ' ') do Dec(st);
        while (st > 0) and (FBuf[st] <> ' ') do Dec(st);
        Delete(FBuf, st + 1, FCursor - st);
        FCursor := st;
        RedrawInput;
      end;
    4:    { Ctrl-D }
      begin
        if FBuf = '' then
        begin
          if FCompose then
          begin
            FCompose := False;
            FComposeLines.Clear;   { a stale draft must not leak into the next /msg }
            FeedLine('(composition cancelled)');
          end
          else
            FQuit := True;
        end;
      end;
  else
    if (b >= 32) and (Length(FBuf) < 65536) then
    begin
      { insert the byte AT the cursor (multi-byte chars arrive byte-by-byte and
        stay contiguous because the cursor advances one byte at a time). The cap
        keeps a pathological paste from an O(n^2) rebuild — well above any real
        line and below the hub's line limit. }
      Insert(Chr(b), FBuf, FCursor + 1);
      Inc(FCursor);
      RedrawInput;
    end;
  end;
end;

procedure TChat.SubmitLine;
var
  Line: string;
begin
  Line := FBuf;
  FBuf := '';
  FCursor := 0;
  FWinStart := 0;
  FHistIdx := -1;
  if not FPlain then
    Writeln;
  { RAW line: compose mode needs exact '.'-only detection and must keep
    indentation and blank lines; non-compose paths trim for themselves }
  ExecuteLine(Line);
  RedrawInput;
end;

procedure TChat.HistAdd(const Line: string);
begin
  if Line = '' then
    Exit;
  if (FHistory.Count > 0) and (FHistory[FHistory.Count - 1] = Line) then
    Exit;
  FHistory.Add(Line);
  while FHistory.Count > 500 do
    FHistory.Delete(0);
end;

procedure TChat.HistNav(Up: Boolean);
begin
  if FHistory.Count = 0 then
    Exit;
  if Up then
  begin
    if FHistIdx = -1 then
      FHistIdx := FHistory.Count - 1
    else if FHistIdx > 0 then
      Dec(FHistIdx);
  end
  else
  begin
    if FHistIdx = -1 then
      Exit;
    Inc(FHistIdx);
    if FHistIdx >= FHistory.Count then
    begin
      FHistIdx := -1;
      FBuf := '';
      FCursor := 0;
      RedrawInput;
      Exit;
    end;
  end;
  FBuf := FHistory[FHistIdx];
  FCursor := Length(FBuf);
  RedrawInput;
end;

{ ---------------- commands ---------------- }

{ Framed team list. A read-only subordinate is not shown as another peer team;
  it appears in its owner's row, in a separate cell. The cell stays empty when
  a team has no such subordinate. }
function TChat.TeamsTable: string;
var
  Rows: TRows;
  H: TCells;
  i, j, n: Integer;
  Sl: string;
begin
  n := 0;
  for i := 0 to High(FTeams) do
    if not FTeams[i].Slave then
      Inc(n);
  H := TCells.Create('#', 'team', 'speciality', 'slave');
  SetLength(Rows, n);
  n := 0;
  for i := 0 to High(FTeams) do
  begin
    if FTeams[i].Slave then
      Continue;
    { Its child, if any: the attached member explicitly marked as such. }
    Sl := '';
    for j := 0 to High(FTeams) do
      if FTeams[j].Slave and SameText(FTeams[j].Parent, FTeams[i].Name) then
      begin
        if Sl <> '' then
          Sl := Sl + ' | ';
          { INTENTIONALLY compact: a full specialty made this the widest column,
            which then trimmed to an unhelpful fragment. The complete card is
            available through /team <name>. }
        Sl := Sl + Format('%d %s (read-only)',
          [FTeams[j].Id, FTeams[j].Name]);
      end;
    Rows[n] := TCells.Create(IntToStr(FTeams[i].Id), FTeams[i].Name,
      FTeams[i].Spec, Sl);
    Inc(n);
  end;
  { Fit the terminal width rather than a fixed value; a 118-column table wraps
    into an unreadable layout in a narrow pane. }
  Result := Table(H, Rows, TermWidth - 2);
end;

procedure TChat.RefreshTeams(Quiet: Boolean);
var
  Reply: string;
  Obj, T: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  TH: TCells;
  TR: TRows;
  Names: array of string;
begin
  if not OneShot(BuildTeams(FCfg.Secret, FCfg.SelfId), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    FSharedDir := Obj.Get('shared_dir', '');
    Arr := Obj.Get('teams', TJSONArray(nil));
    if Arr = nil then
      Exit;
    SetLength(FTeams, Arr.Count);
    for i := 0 to Arr.Count - 1 do
    begin
      T := TJSONObject(Arr.Items[i]);
      FTeams[i].Id := T.Get('id', 0);
      FTeams[i].Name := T.Get('name', '');
      FTeams[i].Spec := T.Get('speciality', '');
      FTeams[i].Parent := T.Get('parent', '');
      FTeams[i].OpenTasks := T.Get('open_tasks', 0);
      FTeams[i].Slave := T.Get('slave', False);
      FTeams[i].Workdir := T.Get('workdir', '');
    end;
    if not Quiet then
      FeedBlock(TeamsTable);
    { collision-free identity colors over the live roster (deterministic:
      any process with the same roster computes the same assignment) }
    Names := nil;
    SetLength(Names, Length(FTeams));
    for i := 0 to High(FTeams) do
      Names[i] := FTeams[i].Name;
    AssignPalette(Names);
  finally
    Obj.Free;
  end;
  { group names too, so the shorthand accepts 'grp: text' like the hub does
    (a team wins a name clash there; '@grp' always forces the group) }
  FGroupNames := nil;
  if OneShot(BuildGroupList(FCfg.Secret, FCfg.SelfId), Reply) then
  begin
    Obj := ParseObj(Reply);
    if Obj <> nil then
    try
      Arr := Obj.Get('groups', TJSONArray(nil));
      if Arr <> nil then
      begin
        SetLength(FGroupNames, Arr.Count);
        for i := 0 to Arr.Count - 1 do
          FGroupNames[i] :=
            TJSONObject(Arr.Items[i]).Get('name', '');
      end;
    finally
      Obj.Free;
    end;
  end;
end;

function TChat.KnownTeam(const Key: string): Boolean;
var
  i, Id: Integer;
begin
  Id := StrToIntDef(Key, -1);
  for i := 0 to High(FTeams) do
    if SameText(FTeams[i].Name, Key) or (FTeams[i].Id = Id) then
      Exit(True);
  Result := False;
end;

{ Valid send destination: a team, a group (bare name — the hub gives a team
  the win on a clash), an explicit group (@name always means the group), or
  the reserved broadcast name 'all'. }
function TChat.KnownDest(const Key: string): Boolean;
var
  i: Integer;
  GroupName: string;
begin
  Result := SameText(Key, 'all') or KnownTeam(Key);
  if Result then
    Exit;
  GroupName := Key;
  if (GroupName <> '') and (GroupName[1] = '@') then
    Delete(GroupName, 1, 1);
  if GroupName = '' then
    Exit(False);
  for i := 0 to High(FGroupNames) do
    if SameText(FGroupNames[i], GroupName) then
      Exit(True);
end;

procedure TChat.DoSendTo(const Dest, Text: string);
var
  Reply: string;
  Obj: TJSONObject;
begin
  if not OneShot(BuildSend(FCfg.Secret, FCfg.SelfId, Dest, Text), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    if not Obj.Get('ok', False) then
      FeedLine('error: ' + Obj.Get('error', 'unknown'))
    else if Obj.Get('broadcast', 0) > 0 then
      FeedLine(Format('sent to %s (%d teams, %d queued)',
        [Dest, Obj.Get('broadcast', 0), Obj.Get('queued_count', 0)]))
    else if Obj.Get('queued', False) then
      FeedLine(Format('queued for %s (host down, will be delivered)', [Dest]))
    else
      FeedLine(Format('sent to %s', [Dest]));
  finally
    Obj.Free;
  end;
end;

{ Keep every multi-line destination on the same state machine.  In particular,
  an explicit group must get the same exact '.' and /cancel semantics as a
  direct team selected through /msg. }
procedure TChat.StartCompose(const Dest: string);
begin
  FCompose := True;
  FComposeTo := Dest;
  FComposeLines.Clear;
  FeedLine('(composing for ' + Dest + ': a "." line sends, /cancel aborts)');
end;

{ Topic-based help presents the canonical English interface. Legacy aliases
  remain accepted by the parser for compatibility. }
procedure TChat.CmdHelp(const Arg: string);
var
  T: string;
begin
  T := LowerCase(Trim(Arg));

  if T = '' then
  begin
      { The quick reference used to be a wall of separate lines. Group commands
        into framed tables so users can scan columns instead. Frames appear only
        on terminals (pzbox.Pretty); redirected output retains its established
        plain-text representation. }
    FeedBlock(Table(TCells.Create('talk', 'what it does'),
      TRows.Create(
        TCells.Create('team: text', 'send (all: text = everyone)'),
        TCells.Create('group: text', 'send to a group (team wins a name clash)'),
        TCells.Create('@group: text', 'send one line; @ always forces the group'),
        TCells.Create('@group', 'multi-line group ("." sends, /cancel aborts)'),
        TCells.Create('/send', 'send, naming the destination'),
        TCells.Create('/msg team|@group', 'multi-line ("." sends, /cancel aborts)'),
        TCells.Create('/file', 'send a file as the message body'),
        TCells.Create('/inbox', 'my unread messages'),
        TCells.Create('/log [n]', 'bus history'),
        TCells.Create('/full <seq>', 'full text of message #seq')),
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('work', 'what it does'),
      TRows.Create(
        TCells.Create('/task', 'tasks (more in /help tasks)'),
        TCells.Create('/workflow | /wf', 'milestone plans (more in /help workflow)')),
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('who is who', 'what it does'),
      TRows.Create(
        TCells.Create('/teams | /info', 'team index, with each slave'),
        TCells.Create('/tree', 'hierarchy: bosses and subordinates'),
        TCells.Create('/team', 'add, remove, change (persisted)'),
        TCells.Create('/group', 'groups and their members (persisted)'),
        TCells.Create('/app | /apps', 'applications and the team that owns each'),
        TCells.Create('/app doc <name>', 'the app manual (anyone may read it)'),
        TCells.Create('/project | /projects', 'projects and their admin team')),
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('files and fleet', 'what it does'),
      TRows.Create(
        TCells.Create('/share', 'leave a file for a team'),
        TCells.Create('/files', 'list a shared directory'),
        TCells.Create('/cat <path>', 'print a shared file'),
        TCells.Create('/fleet', 'every host: release and ONLINE/OFFLINE'),
        TCells.Create('/update', 'tell the daemons to self-update'),
        TCells.Create('/version', 'release of this console and of the hub'),
        TCells.Create('/header | /headers', 'what each delivery header carries'),
        TCells.Create('/clear', 'clear   /quit  exit')),
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('learn more', 'what it does'),
      TRows.Create(
        TCells.Create('/help', 'this quick reference'),
        TCells.Create('/help <topic>', 'a whole topic in depth — see /help index'),
        TCells.Create('/help tasks', 'how tasks work: create, assign, close, milestones'),
        TCells.Create('/help workflow', 'milestone plans: steps, deps, halt/fix/verify'),
        TCells.Create('/help send', 'ways of sending: shorthand, multi-line, files')),
      TermWidth - 2));
    FeedBlock(Frame('what not to forget',
      'Plurals work too: /apps /workflows /projects /groups /headers.'#10 +
      'Legacy command aliases remain accepted for compatibility.'#10 +
      'If your header shows an ADMIN (group or project boss), wait for their'#10 +
      'instructions before building anything.'#10 +
      'A group name works bare, like a team name; on a clash the team wins.'#10 +
      'Full manual: /help index',
      TermWidth - 2));
    Exit;
  end;

  if (T = 'index') or (T = 'indice') then
  begin
    FeedLine('help topics — /help <topic>:');
    FeedLine('  index             this list');
    FeedLine('  commands          every command');
    FeedLine('  send              sending: shorthand, multi-line, files, broadcast');
    FeedLine('  tasks             create, assign, and close tasks and milestones');
    FeedLine('  workflow          milestone plans with a dependency tree (/wf)');
    FeedLine('  config            pizarra.conf and tiza.conf explained');
    FeedLine('  daemon            remote team hosts (tiza daemon)');
    FeedLine('  feed              reading /log, /full, /inbox, and read marks');
    FeedLine('  shortcuts         keyboard, history, and compose mode');
    FeedLine('  troubleshooting   quick fixes for common problems');
    FeedLine('deep manual on disk: docs/operations.md in the repository');
  end
  else if (T = 'commands') or (T = 'comandos') then
  begin
    { Keep the complete command index scannable.  Table renders a proper box
      on a terminal but deliberately stays parser-friendly when redirected.
      The destination column names the group form explicitly: it must not look
      like /msg accepts only a numeric team id or a single team. }
    FeedBlock(Frame('commands',
      'English command | Spanish alias — both always work.'#10 +
      'A destination may be a team name or ID; @group always addresses the group.',
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('message command', 'use', 'what it does'),
      TRows.Create(
        TCells.Create('/send | /enviar', '<team|@group> text',
          'send one line (all = every team)'),
        TCells.Create('/msg | /mensaje', '<team|@group>',
          'compose multiple lines; . sends, /cancel aborts'),
        TCells.Create('@group', 'no colon',
          'same multi-line group compose shortcut'),
        TCells.Create('@group: text', 'with colon',
          'send one line to that group immediately'),
        TCells.Create('/file | /fichero', '<team|@group> path',
          'send a file as the message body'),
        TCells.Create('/inbox | /buzon', '',
          'my unread messages (marks them read)'),
        TCells.Create('/log | /registro', '[n]',
          'last n events from the whole bus (30)'),
        TCells.Create('/full | /completo', '<seq>',
          'complete text of message #seq')),
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('work and structure', 'use', 'what it does'),
      TRows.Create(
        TCells.Create('/teams | /equipos', '', 'team index with specialities'),
        TCells.Create('/tree | /arbol', '', 'team hierarchy tree'),
        TCells.Create('/task | /tarea', '<subcommand>', 'see /help tasks'),
        TCells.Create('/workflow | /wf | /flujo', '[name|subcommand]',
          'milestone plans; see /help workflow'),
        TCells.Create('/team | /equipo', '<subcommand>',
          'add, remove, set, list, or show teams'),
        TCells.Create('/group | /grupo', '<subcommand>',
          'manage persisted groups and their members'),
        TCells.Create('/project | /proyecto', '<subcommand>',
          'manage projects and their administrator'),
        TCells.Create('/app | /aplicacion', '<subcommand>',
          'manage applications and manuals')),
      TermWidth - 2));
    FeedBlock(Table(TCells.Create('console and files', 'use', 'what it does'),
      TRows.Create(
        TCells.Create('/share | /compartir', '<team|@group> file [note]',
          'shared-directory file exchange'),
        TCells.Create('/files | /ficheros', '[team]', 'list shared files'),
        TCells.Create('/help | /ayuda', '[topic]',
          'this help; /help index lists topics'),
        TCells.Create('/clear | /limpiar', '', 'clear the screen'),
        TCells.Create('/quit | /salir', '', 'exit the console (also Ctrl-D)')),
      TermWidth - 2));
    FeedBlock(Frame('shortcuts',
      'team: text sends to a team; all: text broadcasts to every team.'#10 +
      'group: text sends to a group when no team has that name; use @group to force it.',
      TermWidth - 2));
  end
  else if (T = 'send') or (T = 'enviar') then
  begin
    FeedLine('sending messages:');
    FeedLine('  api: review the plan               -> one line to team api');
    FeedLine('  all: meeting in 5 minutes          -> broadcast to EVERY team');
    FeedLine('  /msg api | /msg @group            -> multi-line: type lines, "." sends');
    FeedLine('  @group                             -> same multi-line group compose');
    FeedLine('  @group: one line                   -> immediate group send');
    FeedLine('  /file api /tmp/spec.txt            -> send a whole file');
    FeedLine('from any shell (as the human): tiza api "text"');
    FeedLine('  tiza all "text"        broadcast   |   tiza <team> --file f  (- = stdin)');
    FeedLine('agents on this host must use a config whose self= names their team');
    FeedLine('  (select it with tiza --config <path> ... or TIZA_CONF=<path>)');
    FeedLine('"queued for X" = destination down; auto-redelivered in order, max 15 s late');
    FeedLine('FILES: /share <team> <path> [note] copies onto the shared NFS dir');
    FeedLine('  configured by the hub and notifies the team with the exact path;');
    FeedLine('  /files [team] lists; every header shows both shared dirs');
  end
  else if (T = 'tasks') or (T = 'tareas') then
  begin
    FeedLine('tasks:');
    FeedLine('  /task add team title [--milestone v1]   create (team "-" = backlog)');
    FeedLine('  /task done id                           close');
    FeedLine('  /task reopen id                         reopen');
    FeedLine('  /task assign id team                    (re)assign, "-" = backlog');
    FeedLine('  /task note id text                      add a note');
    FeedLine('  /task list [open|done|all] [team|@group]  list; bare /task = open');
    FeedLine('  /task show id                           full card with notes');
    FeedLine('tasks are open: ANY team can create a task for ANY team (same or other group):');
    FeedLine('  /task add api users endpoint --parent 3     (--parent makes it a subtask; /tree shows teams)');
    FeedLine('  /task assign <id> <team>   hand a task to another team — but ONLY the current');
    FeedLine('     owner (or the console) may reassign; a team cannot yank another team''s task');
    FeedLine('examples:');
    FeedLine('  /task add portal portal login --milestone v1');
    FeedLine('  /task done 3');
    FeedLine('each team SEES its open tasks in every message header it receives;');
    FeedLine('state persists in the task store and survives restarts');
  end
  else if (T = 'workflow') or (T = 'workflows') or (T = 'flujo') or
          (T = 'flujos') then
  begin
    FeedLine('WORKFLOWS — dependency-tree milestone plans for a group.');
    FeedLine('/workflow and /wf use the same verbs as "tiza wf" in a shell.');
    FeedLine('');
    FeedLine('HOW IT WORKS: a workflow belongs to ONE group. Each milestone step');
    FeedLine('has ONE owner team and depends on other steps. A step ACTIVATES only when');
    FeedLine('ALL its dependencies are done: roots start first, independent branches run');
    FeedLine('in PARALLEL, joins wait for every parent. The hub itself tells each owner');
    FeedLine('the moment its step is ACTIVE (with the linked task id and the finish');
    FeedLine('command); nobody can work ahead. Everything survives hub restarts.');
    FeedLine('');
    FeedLine('BUILD THE PLAN (draft; console or the group admin):');
    FeedLine('  /wf create <name> <group>                      new draft');
    FeedLine('  /wf step   <name> <team> <title...>            add at the end (after the last)');
    FeedLine('  /wf step   ... --after 1        branch (a 2nd step after #1 = parallel)');
    FeedLine('  /wf step   ... --after 2,3      join (waits for #2 AND #3); --after 0 = root');
    FeedLine('  /wf insert <name> <team> <title...> --after K  SPLICE IN: everything that');
    FeedLine('       hung after #K re-hangs on the new step (0 = insert before everything)');
    FeedLine('  /wf remove <name> <step>        splice OUT: its dependents inherit its deps');
    FeedLine('  /wf set    <name> <step> team|milestone|after <value> edit owner/title/deps');
    FeedLine('       (after = comma list of step ids; 0 = root; cycles are refused)');
    FeedLine('  step numbers are STABLE IDS (holes stay after removals - the TREE is the truth)');
    FeedLine('');
    FeedLine('SEE IT (anyone, anytime):');
    FeedLine('  /wf <name>                      the whole tree (also: /wf show <name>)');
    FeedLine('  /wf <name> --from K             only the subtree hanging under #K');
    FeedLine('  /wf <name> --depth N            only N levels below the start');
    FeedLine('  /wf <name> --detail             + per-step facts: deps, task, timestamps');
    FeedLine('  /wf list                        one line per workflow');
    FeedLine('');
    FeedLine('RUN IT:');
    FeedLine('  /wf start <name>       members get the plan + WAIT rule; roots ACTIVATE');
    FeedLine('  a team finishes with "tiza task done <id>" (or /wf done <name> [step|-]) ->');
    FeedLine('  the hub records it and ACTIVATES whatever became ready, automatically');
    FeedLine('');
    FeedLine('ERRORS (the brake):  /wf error <name> <why...> [--step N]   (any member)');
    FeedLine('  the WHOLE workflow HALTS: everyone sees the broken step and its owner;');
    FeedLine('  only the fix moves. Owner: /wf fixed <name> "<what + how tested>".');
    FeedLine('  ANOTHER party verifies: /wf verify <name> ok|fail [why] - the reporter,');
    FeedLine('  the group admin or you; NEVER the fixer itself. ok -> RESUMED for all.');
    FeedLine('');
    FeedLine('AUTOMATION (v2): stalled ACTIVE steps get recurring nudges (owner +');
    FeedLine('  admin) after their eta: --eta 4h per step, /wf set <name> <k> eta 30m');
    FeedLine('  (works on a RUNNING step), /wf set <name> eta <dur>|off (plan default,');
    FeedLine('  factory 24h); a task note resets the clock. /wf set <name> strict on');
    FeedLine('  makes done require a how-tested proof. Steps owned by console are');
    FeedLine('  HUMAN APPROVAL GATES (only you can pass them). /wf clone <src> <new>');
    FeedLine('  copies a plan as a pristine draft. /wf tasks <name> = linked tasks in');
    FeedLine('  dependency order; /wf list --mine = your plans. Cross-plan deps:');
    FeedLine('  --after otherwf#3 (a step waits on ANOTHER plan''s step).');
    FeedLine('  Diagrams: tiza wf export <name> f.mmd|f.dot (Mermaid/Graphviz).');
    FeedLine('');
    FeedLine('TIME-TRAVEL (every change is snapshotted automatically, keep 30):');
    FeedLine('  /wf history <name>     every saved point: snap id, when, before what');
    FeedLine('  /wf undo <name>        one step back (the jump is snapshotted too)');
    FeedLine('  /wf undo <name> <snap> JUMP to any listed point (back OR forward)');
    FeedLine('  /wf save <name> [file] write the full card to a file (manual backup)');
    FeedLine('  /wf restore <name> <file>   load a saved card back');
    FeedLine('  tiza wf export <name> [f.sqlite|f.sql]   read-only SQLite for SQL queries');
    FeedLine('');
    FeedLine('permissions: build/start/abort/undo = console + group admin; error = any');
    FeedLine('member; fixed = the step owner; verify = never the fixer. Structure edits');
    FeedLine('are DRAFT-only; a running plan changes via error/abort (or undo).');
  end
  else if (T = 'config') or (T = 'configuracion') then
  begin
    FeedLine('configuration — canonical files are under /etc/pizarra (0600):');
    FeedLine('pizarra.conf is HUB BOOTSTRAP only:');
    FeedLine('  [server]  listen / port (7010) / secret');
    FeedLine('  [registry] authority=sqlite   [log] path   [store] dir=/var/lib/pizarra');
    FeedLine('  [prompts] global = one-line project prompt   (or global_file = path)');
    FeedLine('teams, groups, projects, apps, manuals and relations live in org.sqlite;');
    FeedLine('  inspect/change them with /team /group /project /app (or tiza).');
    FeedLine('tiza.conf (every endpoint):');
    FeedLine('  [pizarra] host / port / secret / self   (self: console, or the team name)');
    FeedLine('resolution: explicit --config, strict environment path, then /etc/pizarra/;');
    FeedLine('  source-tree conf/ and HOME are never implicit runtime authorities.');
  end
  else if (T = 'daemon') or (T = 'demonio') then
  begin
    FeedLine('remote team hosts (tiza daemon):');
    FeedLine('  1. copy the tiza binary:  scp tiza host:' +
      PZ_INSTALL_BINDIR + '/');
    FeedLine('  2. /etc/pizarra/tiza.conf there: [pizarra] hub ip/port/secret, self=<team>');
    FeedLine('     [daemon] listen/port(7011)/secret + [session:<team>] tmux_session/launch');
    FeedLine('  3. enable systemd/tiza.service (or run: tiza daemon)');
    FeedLine('  4. on the hub, the team is just:  host = <that-ip>:7011');
    FeedLine('the daemon injects into its local tmux, respawns it, dedupes retries;');
    FeedLine('messages sent while the host is down queue and redeliver in order');
  end
  else if (T = 'feed') or (T = 'actividad') then
  begin
    FeedLine('reading the feed:');
    FeedLine('  07:15 #13 api->console  build complete       <- time, seq, from->to, text');
    FeedLine('  [+23 lines, /full 13] = multi-line message; /full 13 shows all of it');
    FeedLine('  * lines = task events;  ~ lines = system notices');
    FeedLine('  /log 50   last 50 events of ALL traffic (also team<->team)');
    FeedLine('  /inbox    your unread; NOTE: this open chat already marks your');
    FeedLine('            messages read as it shows them (tiza inbox elsewhere = empty)');
    FeedLine('  tiza inbox --keep (peek) | --all (history) from any shell');
    FeedLine('  hub restart? the chat reconnects alone and resumes where it was');
  end
  else if (T = 'shortcuts') or (T = 'atajos') then
  begin
    FeedLine('keyboard (in this chat):');
    FeedLine('  Up / Down     history (persists in ~/.local/state/pizarra/chat_history)');
    FeedLine('  Ctrl-U        delete the whole line     Ctrl-W   delete last word');
    FeedLine('  Ctrl-D        quit (empty line) / cancel compose');
    FeedLine('  Enter         send the line');
    FeedLine('compose mode (/msg team, /msg @group, or @group): type lines freely — blank lines and');
    FeedLine('  indentation are kept; a line with only "." sends; /cancel aborts');
    FeedLine('more: docs/cli.md (Human terminal console)');
  end
  else if (T = 'troubleshooting') or (T = 'solucion') then
  begin
    FeedLine('quick fixes:');
    FeedLine('  "queued for X"      destination down; auto-redelivered within 15 s');
    FeedLine('  "unauthorized"      secret mismatch between tiza.conf and pizarra.conf');
    FeedLine('  inbox empty         this chat already marked them read — use /log');
    FeedLine('  feed frozen         hub down; the chat reconnects alone (watch the ~ lines)');
    FeedLine('  message shown twice tiza daemon restarted mid-retry (rare, harmless)');
    FeedLine('  wrong sender id     self= in tiza.conf does not name the intended team');
    FeedLine('full operations guide: docs/operations.md');
  end
  else
  begin
    FeedLine('unknown topic "' + T + '" — available topics:');
    CmdHelp('index');
  end;
end;

procedure TChat.PrintTask(T: TJSONObject; Full: Boolean);
var
  H, Team, Closed: string;
  Notes: TJSONArray;
  N: TJSONObject;
  i: Integer;
  CK, CV: TCells;
begin
  H := T.Get('hito', '');
  if H <> '' then
    H := '[' + H + '] ';
  Team := T.Get('team', '');
  if Team = '' then
    Team := 'backlog';
  H := Format('#%d %s%-6s %-10s %s',
    [T.Get('id', 0), H, T.Get('state', '?'), Team, T.Get('title', '')]);
  if T.Get('parent', 0) > 0 then
    H := H + Format('  (subtask of #%d)', [T.Get('parent', 0)]);
  if not Full then
  begin
    FeedLine(H);
    Exit;
  end;
    { The full card used to be a collection of loose lines, making a task with
      long notes unreadable. Use a card with fields on the left, wrapped values
      on the right, and a separate row for every note. }
  CK := TCells.Create('task', 'state', 'team');
  CV := TCells.Create(
    Format('#%d%s', [T.Get('id', 0),
      BoolToStr(T.Get('parent', 0) > 0,
        Format('  (subtask of #%d)', [T.Get('parent', 0)]), '')]),
    T.Get('state', '?'), Team);
  if T.Get('hito', '') <> '' then
  begin
    CK := Concat(CK, TCells.Create('milestone'));
    CV := Concat(CV, TCells.Create(T.Get('hito', '')));
  end;
  CK := Concat(CK, TCells.Create('title', 'created'));
  CV := Concat(CV, TCells.Create(T.Get('title', ''), T.Get('created', '')));
  Closed := T.Get('closed', '');
  if Closed <> '' then
  begin
    CK := Concat(CK, TCells.Create('closed'));
    CV := Concat(CV, TCells.Create(Closed));
  end;
  Notes := T.Get('notes', TJSONArray(nil));
  if Notes <> nil then
    for i := 0 to Notes.Count - 1 do
    begin
      N := TJSONObject(Notes.Items[i]);
      CK := Concat(CK, TCells.Create(Format('note %s',
        [Copy(N.Get('ts', ''), 1, 16)])));
      CV := Concat(CV, TCells.Create(
        N.Get('by', '?') + ': ' + N.Get('text', '')));
    end;
  FeedBlock(Card(Format('task #%d', [T.Get('id', 0)]), CK, CV, TermWidth - 2));
end;

{ Runtime team management: /team add|remove|set|list|show. Legacy aliases remain
  accepted by the parser. Changes persist through the hub to org.sqlite. }
{ /workflow — dependency-tree milestone plans. Bare /workflow lists;
  '/workflow <name>' draws the tree. Legacy subcommand aliases remain accepted. }
{ Remove ONE enclosing quote pair, as a shell would. Without this, the same
  logical value had two stored forms depending on its entry point: the shell
  passes tiza `tested manually` without quotes, while chat captured
  `"tested manually"` with them. These values reach workflow history, undo, and
  task-show audit columns. Preserve interior quotes and remove only the outer
  pair. }
function DeQuote(const S: string): string;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

procedure TChat.CmdWorkflow(const Rest: string);
var
  R, Sub, Name, TeamName, AfterS, Text, Req, Reply, Line, EtaS, TeamF: string;
  StepN, FromN, DepthN, i, p: Integer;
  Detail, MineF, BadFlag: Boolean;
  Obj, W: TJSONObject;
  Arr: TJSONArray;
  WT: TRows;
  SL: TStringList;
  FS: TFileStream;

  function Word1(var S: string): string;
  var q: Integer;
  begin
    S := Trim(S); q := Pos(' ', S);
    if q = 0 then begin Result := S; S := ''; end
    else begin Result := Copy(S, 1, q - 1); S := Trim(Copy(S, q + 1, Length(S))); end;
  end;

  { pull the option flags out of R; the remainder is free text }
  procedure Collect;
  var Tok: string;
  begin
    Text := '';
    BadFlag := False;
    while R <> '' do
    begin
      Tok := Word1(R);
      if (Tok = '--after') and (R <> '') then
        AfterS := Word1(R)
      else if (Tok = '--step') and (R <> '') then
      begin
          { Same trap as the CLI: a nonnumeric --step used to become 0, which the
            engine interprets as "my only active step". }
        Tok := Word1(R);
        if StrToIntDef(Tok, -1) < 0 then
        begin
          FeedLine('--step must be a number (got: ' + Tok + ')');
            { Collect is a NESTED procedure. Exit here leaves Collect, NOT the
              command, so the request used to continue with StepN=0 ("my only
              active step") and stop the entire plan while claiming rejection.
              That is worse than no guard. Mark the error and let the caller
              abort. }
          BadFlag := True;
          Exit;
        end;
        StepN := StrToIntDef(Tok, 0);
      end
      else if (Tok = '--from') and (R <> '') then
        FromN := StrToIntDef(Word1(R), 0)
      else if (Tok = '--depth') and (R <> '') then
        DepthN := StrToIntDef(Word1(R), 0)
      else if (Tok = '--eta') and (R <> '') then
        EtaS := Word1(R)
      else if ((Tok = '--team') or (Tok = '--equipo')) and (R <> '') then
        TeamF := Word1(R)
      else if (Tok = '--mine') or (Tok = '--mio') then
        MineF := True
      else if Tok = '--detail' then
        Detail := True
      else
      begin
        if Text <> '' then
          Text := Text + ' ';
        Text := Text + Tok;
      end;
    end;
      { Match shell behavior so evidence text has one representation regardless
        of its entry point; see DeQuote. }
    Text := DeQuote(Text);
  end;

begin
  R := Trim(Rest);
  Sub := LowerCase(Word1(R));
  AfterS := '';
  Text := '';
  EtaS := '';
  TeamF := '';
  StepN := 0;
  FromN := 0;
  DepthN := 0;
  Detail := False;
  MineF := False;
  Req := '';
  if (Sub = 'help') or (Sub = 'ayuda') then
  begin
    CmdHelp('workflow');
    Exit;
  end;
  if (Sub = '') or (Sub = 'list') or (Sub = 'lista') or (Sub = 'listar') then
  begin
    Collect;
    if BadFlag then Exit;
    Req := BuildWfList(FCfg.Secret, FCfg.SelfId, MineF, TeamF);
  end
  else if (Sub = 'create') or (Sub = 'crear') then
  begin
    Name := Word1(R);
    TeamName := Word1(R);
    if (Name = '') or (TeamName = '') then
    begin FeedLine('usage: /workflow create <name> <group>'); Exit; end;
    Req := BuildWfCreate(FCfg.Secret, FCfg.SelfId, Name, TeamName);
  end
  else if (Sub = 'step') or (Sub = 'paso') then
  begin
    Name := Word1(R);
    TeamName := Word1(R);
    Collect;
    if BadFlag then Exit;
    if (Name = '') or (TeamName = '') or (Text = '') then
    begin
      FeedLine('usage: /workflow step <name> <team> <milestone...> [--after K[,K...]]');
      Exit;
    end;
    Req := BuildWfStep(FCfg.Secret, FCfg.SelfId, Name, TeamName, Text,
      AfterS, EtaS);
  end
  else if (Sub = 'start') or (Sub = 'iniciar') or (Sub = 'arrancar') then
  begin
    Name := Word1(R);
    if Name = '' then begin FeedLine('usage: /workflow start <name>'); Exit; end;
    Req := BuildWfStart(FCfg.Secret, FCfg.SelfId, Name);
  end
  else if (Sub = 'done') or (Sub = 'hecho') or (Sub = 'hecha') then
  begin
    Name := Word1(R);
    if Name = '' then
    begin
      FeedLine('usage: /workflow done <name> [step|-] ["how tested..."]');
      FeedLine('  step must be a NUMBER; use - for "my only active step" when ' +
        'providing evidence without naming the step');
      Exit;
    end;
    TeamName := Word1(R);
    if StrToIntDef(TeamName, -1) >= 0 then
      StepN := StrToIntDef(TeamName, 0)
    else if TeamName = '-' then
      { '-' explicitly means my only active step. }
    else if TeamName <> '' then
    begin
        { Same trap as the CLI: a nonnumeric token was swallowed as evidence and
          StepN=0 closed "my only active step", so a typo silently closed the
          wrong step. }
      FeedLine('the step must be a number: /wf done ' + Name +
        ' <step> ["how tested"]');
      FeedLine('to close your ONLY active step and give proof, use a dash: ' +
        '/wf done ' + Name + ' - "how tested"');
      Exit;
    end;
    Req := BuildWfDone(FCfg.Secret, FCfg.SelfId, Name, StepN, Trim(R));
  end
  else if Sub = 'error' then
  begin
    Name := Word1(R);
    Collect;
    if BadFlag then Exit;
    if (Name = '') or (Text = '') then
    begin
      FeedLine('usage: /workflow error <name> <why...> [--step N]');
      Exit;
    end;
    Req := BuildWfError(FCfg.Secret, FCfg.SelfId, Name, Text, StepN);
  end
  else if (Sub = 'fixed') or (Sub = 'arreglado') or (Sub = 'corregido') then
  begin
    Name := Word1(R);
    Collect;
    if BadFlag then Exit;
    if (Name = '') or (Text = '') then
    begin
      FeedLine('usage: /workflow fixed <name> <what fixed + how tested...>');
      Exit;
    end;
    Req := BuildWfFixed(FCfg.Secret, FCfg.SelfId, Name, Text);
  end
  else if (Sub = 'verify') or (Sub = 'verificar') then
  begin
    Name := Word1(R);
    TeamName := LowerCase(Word1(R));
    Collect;
    if BadFlag then Exit;
    if (Name = '') or ((TeamName <> 'ok') and (TeamName <> 'fail')) then
    begin
      FeedLine('usage: /workflow verify <name> ok|fail [why...]');
      Exit;
    end;
    Req := BuildWfVerify(FCfg.Secret, FCfg.SelfId, Name, TeamName = 'ok', Text);
  end
  else if (Sub = 'abort') or (Sub = 'abortar') or (Sub = 'cancelar') then
  begin
    Name := Word1(R);
    Collect;
    if BadFlag then Exit;
    if Name = '' then
    begin FeedLine('usage: /workflow abort <name> [why...]'); Exit; end;
    Req := BuildWfAbort(FCfg.Secret, FCfg.SelfId, Name, Text);
  end
  else if (Sub = 'insert') or (Sub = 'insertar') then
  begin
    Name := Word1(R);
    TeamName := Word1(R);
    Collect;
    if BadFlag then Exit;
    if (Name = '') or (TeamName = '') or (Text = '') or (AfterS = '') then
    begin
      FeedLine('usage: /workflow insert <name> <team> <milestone...> ' +
        '--after K   (K''s dependents re-hang on the new step; 0 = front)');
      Exit;
    end;
    Req := BuildWfInsert(FCfg.Secret, FCfg.SelfId, Name, TeamName, Text,
      StrToIntDef(AfterS, -1), EtaS);
  end
  else if (Sub = 'remove') or (Sub = 'quitar') or (Sub = 'borrar') or
          (Sub = 'eliminar') then
  begin
    Name := Word1(R);
    StepN := StrToIntDef(Trim(R), 0);
    if (Name = '') or (StepN = 0) then
    begin FeedLine('usage: /workflow remove <name> <step>'); Exit; end;
    Req := BuildWfRemove(FCfg.Secret, FCfg.SelfId, Name, StepN);
  end
  else if (Sub = 'set') or (Sub = 'definir') then
  begin
    Name := Word1(R);
    TeamName := Word1(R);
    StepN := StrToIntDef(TeamName, 0);
    if StepN > 0 then
      TeamName := LowerCase(Word1(R))
    else
      TeamName := LowerCase(TeamName);   { wf-level: eta | strict }
    { Present the English field publicly while retaining the established hub
      wire name. }
    if TeamName = 'milestone' then
      TeamName := 'hito';
    if (Name = '') or (TeamName = '') or (Trim(R) = '') then
    begin
      FeedLine('usage: /workflow set <name> <step> team|milestone|after|eta <v>' +
        '  |  /workflow set <name> eta|strict <v>');
      Exit;
    end;
    Req := BuildWfSet(FCfg.Secret, FCfg.SelfId, Name, StepN, TeamName,
      Trim(R));
  end
  else if (Sub = 'tasks') or (Sub = 'tareas') then
  begin
    Name := Word1(R);
    if Name = '' then
    begin FeedLine('usage: /workflow tasks <name>'); Exit; end;
    Req := BuildWfTasks(FCfg.Secret, FCfg.SelfId, Name);
  end
  else if (Sub = 'clone') or (Sub = 'clonar') then
  begin
    Name := Word1(R);
    TeamName := Word1(R);
    if (Name = '') or (TeamName = '') then
    begin FeedLine('usage: /workflow clone <src> <new> [group]'); Exit; end;
    Req := BuildWfClone(FCfg.Secret, FCfg.SelfId, Name, TeamName, Trim(R));
  end
  else if (Sub = 'history') or (Sub = 'historial') or (Sub = 'historia') then
  begin
    Name := Word1(R);
    if Name = '' then
    begin FeedLine('usage: /workflow history <name>'); Exit; end;
    Req := BuildWfHistory(FCfg.Secret, FCfg.SelfId, Name);
  end
  else if (Sub = 'undo') or (Sub = 'deshacer') then
  begin
    Name := Word1(R);
    if Name = '' then
    begin
      FeedLine('usage: /workflow undo <name> [snap]  (no snap = one step ' +
        'back; a number from /workflow history = jump to that point)');
      Exit;
    end;
    Req := BuildWfUndo(FCfg.Secret, FCfg.SelfId, Name,
      StrToIntDef(Trim(R), 0));
  end
  else if (Sub = 'export') or (Sub = 'exportar') then
  begin
    FeedLine('export runs from a shell (it writes files): ' +
      'tiza wf export <name> [f.sqlite|f.sql|f.mmd|f.dot]');
    Exit;
  end
  else if (Sub = 'save') or (Sub = 'guardar') then
  begin
    Name := Word1(R);
    if Name = '' then
    begin FeedLine('usage: /workflow save <name> [file]'); Exit; end;
    if not OneShot(BuildWfShow(FCfg.Secret, FCfg.SelfId, Name), Reply) then
      Exit;
    Obj := ParseObj(Reply);
    if Obj = nil then Exit;
    try
      if not Obj.Get('ok', False) then
      begin FeedLine('error: ' + Obj.Get('error', 'unknown')); Exit; end;
      W := Obj.Get('workflow', TJSONObject(nil));
      if W = nil then Exit;
      Text := Trim(R);
      if Text = '' then
        Text := Name + '.wf.json';
      try
        FS := TFileStream.Create(Text, fmCreate);
        try
          Line := W.FormatJSON();
          FS.WriteBuffer(Line[1], Length(Line));
        finally
          FS.Free;
        end;
        FeedLine('saved workflow card: ' + Text +
          '  (restore: /workflow restore ' + Name + ' ' + Text + ')');
      except
        on E: Exception do
          FeedLine('cannot write ' + Text + ': ' + E.Message);
      end;
    finally
      Obj.Free;
    end;
    Exit;
  end
  else if (Sub = 'restore') or (Sub = 'restaurar') then
  begin
    Name := Word1(R);
    Text := Trim(R);
    if (Name = '') or (Text = '') then
    begin FeedLine('usage: /workflow restore <name> <file>'); Exit; end;
    if not FileExists(Text) then
    begin FeedLine('file not found: ' + Text); Exit; end;
    SL := TStringList.Create;
    try
      SL.LoadFromFile(Text);
      Req := BuildWfRestore(FCfg.Secret, FCfg.SelfId, Name, SL.Text);
    finally
      SL.Free;
    end;
  end
  else if (Sub = 'show') or (Sub = 'ver') or (Sub = 'mostrar') then
  begin
    Name := Word1(R);
    if Name = '' then begin FeedLine('usage: /workflow show <name> ' +
      '[--from K] [--depth N] [--detail]'); Exit; end;
    Collect;
    if BadFlag then Exit;
    Req := BuildWfShow(FCfg.Secret, FCfg.SelfId, Name, FromN, DepthN, Detail);
  end
  else if Sub <> '' then
  begin
    { anything else is a workflow name: '/workflow relv2 [--detail]' }
    Name := Sub;
    Collect;
    if BadFlag then Exit;
    if Text <> '' then
    begin
      FeedLine('usage: /workflow [name] | create|step|insert|remove|set|' +
        'start|done|error|fixed|verify|abort|history|undo|save|restore|' +
        'list|show|export ... (/help workflow explains everything)');
      Exit;
    end;
    Req := BuildWfShow(FCfg.Secret, FCfg.SelfId, Name, FromN, DepthN, Detail);
  end
  else
  begin
    FeedLine('usage: /workflow [name] | create|step|insert|remove|set|start|' +
      'done|error|fixed|verify|abort|history|undo|save|restore|list|show ' +
      '- /help workflow explains everything');
    Exit;
  end;

  if not OneShot(Req, Reply) then Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then Exit;
  try
    if not Obj.Get('ok', False) then
    begin FeedLine('error: ' + Obj.Get('error', 'unknown')); Exit; end;
      { FRAME THE TREE. It previously appeared as loose lines inside the feed and
        was indistinguishable from messages, unlike other framed commands. Render
        the tree UNCHANGED inside the block because indentation is information,
        not decoration. }
    Text := Obj.Get('tree', '');
    if Text <> '' then
      FeedBlock(FrameWrap('workflow ' + Name, Text, TermWidth - 2))
    else if Obj.Get('text', '') <> '' then
      FeedBlock(FrameWrap('workflow', Obj.Get('text', ''), TermWidth - 2));
    Arr := Obj.Get('workflows', TJSONArray(nil));
    if Arr <> nil then
    begin
      if Arr.Count = 0 then
        FeedLine('(no workflows)')
      else
      begin
          { Use a TABLE, not raw lines. The hub provides separate fields; parsing
            its presentation-oriented summary line here would be guesswork. }
        SetLength(WT, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          W := TJSONObject(Arr.Items[i]);
          SetLength(WT[i], 5);
          WT[i][0] := W.Get('name', '?');
          WT[i][1] := '@' + W.Get('group', '');
          WT[i][2] := W.Get('state', '');
          WT[i][3] := Format('%d/%d', [W.Get('done', 0), W.Get('steps', 0)]);
          WT[i][4] := W.Get('note', '');
        end;
        FeedBlock(Table(TCells.Create('plan', 'group', 'state', 'done',
          'what is live now'), WT, TermWidth - 2));
      end;
    end;
    Arr := Obj.Get('history', TJSONArray(nil));
    if Arr <> nil then
    begin
      if Arr.Count = 0 then
        FeedLine('(no snapshots yet - one is taken before every change)')
      else
      begin
        Text := '';
        for i := 0 to Arr.Count - 1 do
          Text := Text + Arr.Items[i].AsString + #10;
        Text := Text + #10'jump to any point: /workflow undo <name> <snap>';
        FeedBlock(FrameWrap('history ' + Name, Text, TermWidth - 2));
      end;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TChat.CmdTeam(const Rest: string);
var
  Sub, R, Name, Spec, Parent, Host, Session, Launch, PromptV: string;
  Field, Value, Reply, W: string;
  Obj, T: TJSONObject;

  function NextWordOf(var S: string): string;
  var
    q: Integer;
  begin
    S := Trim(S);
    q := Pos(' ', S);
    if q = 0 then
    begin
      Result := S;
      S := '';
    end
    else
    begin
      Result := Copy(S, 1, q - 1);
      S := Trim(Copy(S, q + 1, Length(S)));
    end;
  end;

  procedure ShowCard;
  var
    Kind: string;
    CK, CV: TCells;
  begin
    Obj := ParseObj(Reply);
    if Obj = nil then
      Exit;
    try
      if not Obj.Get('ok', False) then
      begin
        FeedLine('error: ' + Obj.Get('error', 'unknown'));
        Exit;
      end;
      T := Obj.Get('team', TJSONObject(nil));
      if T = nil then
      begin
        FeedLine('ok');
        Exit;
      end;
      Kind := T.Get('kind', '');
      if Kind = '' then   { pre-1.0.4 hub }
        if T.Get('host', '') <> '' then Kind := 'push' else Kind := 'local';
      if Kind = 'push' then
        Kind := 'remote push to ' + T.Get('host', '')
      else if Kind = 'dial' then
        Kind := 'dial-in (the host dials the hub and the hub delivers over ' +
          'that held connection)'
      else if Kind = 'inbox' then
        Kind := 'inbox-only (pull with this team''s self= config: tiza inbox)'
      else
        Kind := Format('local (tmux %s, launch: %s)',
          [T.Get('session', ''), T.Get('launch', '(none)')]);
        { Use a card rather than loose lines; a long specialty or prompt
          otherwise created a wall of text. }
      CK := TCells.Create('speciality');
      CV := TCells.Create(T.Get('speciality', ''));
      if T.Get('apps', '') <> '' then
      begin
        CK := Concat(CK, TCells.Create('apps'));
        CV := Concat(CV, TCells.Create(T.Get('apps', '') +
          '   (/app show <name>)'));
      end;
      if T.Get('workdir', '') <> '' then
      begin
        CK := Concat(CK, TCells.Create('works in'));
        CV := Concat(CV, TCells.Create(T.Get('workdir', '')));
      end;
      if T.Get('parent', '') <> '' then
      begin
        CK := Concat(CK, TCells.Create('boss'));
        CV := Concat(CV, TCells.Create(T.Get('parent', '')));
      end;
      if T.Get('slave', False) then
      begin
        CK := Concat(CK, TCells.Create('slave'));
        CV := Concat(CV, TCells.Create('on - READ-ONLY, reports only to ' +
          T.Get('parent', '(no boss)')));
      end;
      CK := Concat(CK, TCells.Create('delivery'));
      CV := Concat(CV, TCells.Create(Kind));
      if T.Get('other_sessions', '') <> '' then
      begin
        CK := Concat(CK, TCells.Create('AMBIGUOUS'));
        CV := Concat(CV, TCells.Create('other tmux session(s) could be this ' +
          'team: ' + T.Get('other_sessions', '') +
          ' - pizarra delivers ONLY to the one above'));
      end;
      if T.Get('prompt', '') <> '' then
      begin
        CK := Concat(CK, TCells.Create('prompt'));
        CV := Concat(CV, TCells.Create(T.Get('prompt', '')));
      end;
      FeedBlock(Card(Format('#%d %s', [T.Get('id', 0), T.Get('name', '')]),
        CK, CV, TermWidth - 2));
    finally
      Obj.Free;
    end;
  end;

begin
  R := Trim(Rest);
  Sub := LowerCase(NextWordOf(R));
  if Sub = 'agregar' then Sub := 'add'
  else if Sub = 'eliminar' then Sub := 'remove'
  else if Sub = 'definir' then Sub := 'set'
  else if Sub = 'listar' then Sub := 'list'
  else if (Sub = 'ver') or (Sub = 'mostrar') then Sub := 'show';

  if Sub = 'add' then
  begin
    Name := NextWordOf(R);
    if Name = '' then
    begin
      FeedLine('usage: /team add <name> <speciality...> [--parent X] [--remote ip[:port]]');
      FeedLine('       [--session S] [--launch CMD] [--prompt text...]');
      Exit;
    end;
    Spec := '';
    Parent := '';
    Host := '';
    Session := '';
    Launch := '';
    PromptV := '';
    while R <> '' do
    begin
      W := NextWordOf(R);
      if W = '--parent' then
        Parent := NextWordOf(R)
      else if W = '--remote' then
        Host := NextWordOf(R)
      else if W = '--local' then
        { default }
      else if W = '--session' then
        Session := NextWordOf(R)
      else if W = '--launch' then
        Launch := NextWordOf(R)
      else if W = '--prompt' then
      begin
        PromptV := R;   { everything after --prompt }
        R := '';
      end
      else
      begin
        if Spec <> '' then
          Spec := Spec + ' ';
        Spec := Spec + W;
      end;
    end;
    if OneShot(BuildTeamAdd(FCfg.Secret, FCfg.SelfId, Name, Spec, Parent,
      Host, Session, Launch, PromptV), Reply) then
      ShowCard;
    RefreshTeams(True);
  end
  else if Sub = 'remove' then
  begin
    Name := NextWordOf(R);
    if Name = '' then
    begin
      FeedLine('usage: /team remove <name>   (config only; sessions are never killed)');
      Exit;
    end;
    if OneShot(BuildTeamRemove(FCfg.Secret, FCfg.SelfId, Name), Reply) then
      ShowCard;
    RefreshTeams(True);
  end
  else if Sub = 'set' then
  begin
    Name := NextWordOf(R);
    Field := LowerCase(NextWordOf(R));
    Value := R;
    if (Name = '') or (Field = '') then
    begin
      FeedLine('usage: /team set <name> prompt|speciality|parent|launch|session|user|');
      FeedLine('       project|slave|workdir|hold_when_blocked|host|dial|delegate|secret <value>');
      Exit;
    end;
    if OneShot(BuildTeamSet(FCfg.Secret, FCfg.SelfId, Name, Field, Value), Reply) then
      ShowCard;
    RefreshTeams(True);
  end
  else if (Sub = '') or (Sub = 'list') then
    RefreshTeams(False)
  else if Sub = 'show' then
  begin
    Name := NextWordOf(R);
    if Name = '' then
    begin
      FeedLine('usage: /team show <name>');
      Exit;
    end;
    if OneShot(BuildTeamShow(FCfg.Secret, FCfg.SelfId, Name), Reply) then
      ShowCard;
  end
  else
    FeedLine('usage: /team add|remove|set|list|show');
end;

{ /group [add|remove|project] — manage groups; bare /group lists them,
  '/group <name>' (or '/group show <name>') shows only that group. }
procedure TChat.CmdGroup(const Rest: string);
var
  R, Sub, Name, Members, Reply, Req, Want, Cell, Hdr, OnIdleP,
    OnBlockP: string;
  Obj, G: TJSONObject;
  Arr, M, MI, EX: TJSONArray;
  i, j, p, mid: Integer;
  Found, AnyMuted, AllIdle, AnyBlocked: Boolean;
  Cells: array of string;

  { is team NAME in the group's muted (excluded) list? }
  function EsMuted(Ex: TJSONArray; const Nm: string): Boolean;
  var k: Integer;
  begin
    Result := False;
    if Ex = nil then Exit;
    for k := 0 to Ex.Count - 1 do
      if SameText(Ex.Items[k].AsString, Nm) then
      begin Result := True; Exit; end;
  end;

  { print the member cells wrapped to the terminal width, indented — so EVERY
    member is always visible even on a narrow terminal (no truncated column).
    ANSI-aware width (a muted member is reverse-video). }
  procedure WrapMembers(const Cs: array of string);
  var
    k, w, wln: Integer;
    ln: string;
  begin
    ln := '';
    wln := 0;
    for k := 0 to High(Cs) do
    begin
      w := VisCells(Cs[k]);
      if (ln <> '') and (wln + 2 + w > TermWidth - 4) then
      begin
        FeedLine('  ' + ln);
        ln := '';
        wln := 0;
      end;
      if ln <> '' then
      begin
        ln := ln + '  ';
        wln := wln + 2;
      end;
      ln := ln + Cs[k];
      wln := wln + w;
    end;
    if ln <> '' then
      FeedLine('  ' + ln);
  end;

  { human sentence for the on_idle policy }
  function OnIdleText(const P: string): string;
  begin
    if (P = '') or (P = 'off') then
      Result := Dim('on idle: off')
    else if P = 'boss' then
      Result := Dim('on idle: ') + 'wake the boss'
    else if P = 'all' then
      Result := Dim('on idle: ') + 'wake all members'
    else
      Result := Dim('on idle: ') + 'wake ' + P;
  end;

  function Word1(var S: string): string;
  var q: Integer;
  begin
    S := Trim(S); q := Pos(' ', S);
    if q = 0 then begin Result := S; S := ''; end
    else begin Result := Copy(S, 1, q - 1); S := Trim(Copy(S, q + 1, Length(S))); end;
  end;

begin
  R := Trim(Rest);
  Sub := LowerCase(Word1(R));
  Req := '';
  Want := '';
  if (Sub = '') or (Sub = 'list') or (Sub = 'lista') then
  begin
    Want := Word1(R);                   { '/group list <name>' filters }
    Req := BuildGroupList(FCfg.Secret, FCfg.SelfId);
  end
  else if (Sub = 'show') or (Sub = 'ver') then
  begin
    Want := Word1(R);
    if Want = '' then begin FeedLine('usage: /group show <name>'); Exit; end;
    Req := BuildGroupList(FCfg.Secret, FCfg.SelfId);
  end
  else if Sub = 'add' then
  begin
    Name := Word1(R);
    Members := StringReplace(Trim(R), ' ', ',', [rfReplaceAll]);
    if (Name = '') or (Members = '') then
    begin
      FeedLine('usage: /group add <name> <team...>');
      Exit;
    end;
    Req := BuildGroupAdd(FCfg.Secret, FCfg.SelfId, Name, Members);
  end
  else if Sub = 'remove' then
  begin
    Name := Word1(R);
    Members := StringReplace(Trim(R), ' ', ',', [rfReplaceAll]);
    if Name = '' then begin FeedLine('usage: /group remove <name> [team...]'); Exit; end;
    Req := BuildGroupRemove(FCfg.Secret, FCfg.SelfId, Name, Members);
  end
  else if (Sub = 'exclude') or (Sub = 'mute') or (Sub = 'silenciar') then
  begin
    { the teams are the WHOLE muted set; naming none clears it. Muted members
      stay in the group, they just do not receive @group broadcasts. }
    Name := Word1(R);
    Members := StringReplace(Trim(R), ' ', ',', [rfReplaceAll]);
    if Name = '' then begin FeedLine('usage: /group exclude <name> [team...]  (none = clear)'); Exit; end;
    Req := BuildGroupExclude(FCfg.Secret, FCfg.SelfId, Name, Members);
  end
  else if Sub = 'project' then
  begin
    Name := Word1(R);
    if (Name = '') or (Trim(R) = '') then
    begin FeedLine('usage: /group project <name> <project>'); Exit; end;
    Req := BuildGroupProject(FCfg.Secret, FCfg.SelfId, Name, Trim(R));
  end
  else if (Sub = 'boss') or (Sub = 'admin') then
  begin
    Name := Word1(R);
    if (Name = '') or (Trim(R) = '') then
    begin FeedLine('usage: /group boss <name> <team>'); Exit; end;
    Req := BuildGroupBoss(FCfg.Secret, FCfg.SelfId, Name, Word1(R));
  end
  else if (Sub = 'onblock') or (Sub = 'block') then
  begin
    Name := Word1(R);
    Members := LowerCase(Word1(R));
    if (Name = '') or
       ((Members <> 'alarm') and (Members <> 'log') and
        (Members <> 'default')) then
    begin
      FeedLine('usage: /group onblock <name> alarm|log|default');
      Exit;
    end;
    Req := BuildGroupOnBlock(FCfg.Secret, FCfg.SelfId, Name, Members);
  end
  else
  begin
    { anything else is a group name: '/group softphone' shows only it }
    Want := Sub;
    Req := BuildGroupList(FCfg.Secret, FCfg.SelfId);
  end;
  if (Want <> '') and (Want[1] = '@') then
    Delete(Want, 1, 1);

  if not OneShot(Req, Reply) then Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then Exit;
  try
    if not Obj.Get('ok', False) then
    begin FeedLine('error: ' + Obj.Get('error', 'unknown')); Exit; end;
    Arr := Obj.Get('groups', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then begin FeedLine('(no groups)'); Exit; end;
    { ONE BLOCK per group: a header line (name, admin, project, on-idle policy and
      the live "all stopped" indicator) then the members WRAPPED to the terminal
      width — so every member is always visible, never a truncated column. }
    Found := False;
    AnyMuted := False;
    for i := 0 to Arr.Count - 1 do
    begin
      G := TJSONObject(Arr.Items[i]);
      if (Want <> '') and not SameText(G.Get('name', ''), Want) then
        Continue;
      Found := True;
      M := G.Get('members', TJSONArray(nil));
      MI := G.Get('member_ids', TJSONArray(nil));
      EX := G.Get('excluded', TJSONArray(nil));
      OnIdleP := LowerCase(Trim(G.Get('on_idle', '')));
      OnBlockP := LowerCase(Trim(G.Get('on_block', '')));
      AllIdle := G.Get('all_idle', False);
      AnyBlocked := G.Get('any_blocked', False);

      { header: @name   admin X   project Y }
      Hdr := Bold('@' + G.Get('name', ''));
      if G.Get('boss', '') <> '' then
        Hdr := Hdr + '   ' + Dim('admin ') + G.Get('boss', '');
      if G.Get('project', '') <> '' then
        Hdr := Hdr + '   ' + Dim('project ') + G.Get('project', '');
      FeedLine(Hdr);

      { members wrapped }
      SetLength(Cells, 0);
      if M <> nil then
        for j := 0 to M.Count - 1 do
        begin
          mid := 0;
          if (MI <> nil) and (j < MI.Count) then
            mid := MI.Items[j].AsInteger;
          if mid > 0 then
            Cell := Format('#%d %s', [mid, M.Items[j].AsString])
          else
            Cell := M.Items[j].AsString;
          { a MUTED member (excluded from @group sends) shows in reverse video;
            a text tag when colors are off (--plain) so it stays visible }
          if EsMuted(EX, M.Items[j].AsString) then
          begin
            if ColorsOn then Cell := Inverse(Cell) else Cell := Cell + ' (muted)';
            AnyMuted := True;
          end;
          SetLength(Cells, Length(Cells) + 1);
          Cells[High(Cells)] := Cell;
        end;
      if Length(Cells) = 0 then
        FeedLine('  ' + Dim('(no members)'))
      else
        WrapMembers(Cells);

      { the on-idle policy line + the live "all teams stopped" alarm indicator }
      Cell := '  ' + OnIdleText(OnIdleP);
      if AllIdle then
      begin
        if (OnIdleP <> '') and (OnIdleP <> 'off') then
          Cell := Cell + '   ' + FgBold(ALERT_FG, Inverse(' ALL STOPPED — signal armed '))
        else
          Cell := Cell + '   ' + FgBold(ALERT_FG, ' ALL STOPPED ');
      end
      else if AnyBlocked then
        Cell := Cell + '   ' + Fg(ALERT_FG, '(a member is BLOCKED on a prompt)');
      FeedLine(Cell);
      if OnBlockP = 'log' then
        FeedLine('  on block: log only (operator alarm suppressed)')
      else
        FeedLine('  on block: alarm');
    end;
    if (Want <> '') and not Found then
      FeedLine('(no such group: ' + Want + ')')
    else if AnyMuted then
      FeedLine(Dim('  ') + Inverse(' reverse video ') +
        Dim(' = muted in the @group (still a member, receives no broadcasts)'));
  finally
    Obj.Free;
  end;
end;

{ /project [list] | boss <name> <team> — the project registry. }
procedure TChat.CmdProject(const Rest: string);
var
  R, Sub, Name, Reply, Req: string;
  Obj, P: TJSONObject;
  Arr: TJSONArray;
  i, q: Integer;

  function W1(var S: string): string;
  var p: Integer;
  begin
    S := Trim(S); p := Pos(' ', S);
    if p = 0 then begin Result := S; S := ''; end
    else begin Result := Copy(S, 1, p - 1); S := Trim(Copy(S, p + 1, Length(S))); end;
  end;

begin
  R := Trim(Rest);
  Sub := LowerCase(W1(R));
  if (Sub = '') or (Sub = 'list') then
    Req := BuildProjectList(FCfg.Secret, FCfg.SelfId)
  else if (Sub = 'boss') or (Sub = 'admin') then
  begin
    Name := W1(R);
    if (Name = '') or (Trim(R) = '') then
    begin FeedLine('usage: /project boss <name> <team>'); Exit; end;
    Req := BuildProjectBoss(FCfg.Secret, FCfg.SelfId, Name, W1(R));
  end
  else
  begin FeedLine('usage: /project [list] | boss <name> <team>'); Exit; end;

  if not OneShot(Req, Reply) then Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then Exit;
  try
    if not Obj.Get('ok', False) then begin FeedLine('error: ' + Obj.Get('error', 'unknown')); Exit; end;
    Arr := Obj.Get('projects', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then begin FeedLine('(no projects)'); Exit; end;
    for i := 0 to Arr.Count - 1 do
    begin
      P := TJSONObject(Arr.Items[i]);
      Name := P.Get('name', '');
      if P.Get('boss', '') <> '' then Name := Name + '  (admin: ' + P.Get('boss', '') + ')';
      FeedLine(Name);
    end;
  finally Obj.Free; end;
end;

{ /header [show] | short | full | set <key> <value> — delivery-header config. }
procedure TChat.CmdHeader(const Rest: string);
var
  R, Sub, Key, Val, Reply, Req: string;
  Obj, H: TJSONObject;

  function W1(var S: string): string;
  var p: Integer;
  begin
    S := Trim(S); p := Pos(' ', S);
    if p = 0 then begin Result := S; S := ''; end
    else begin Result := Copy(S, 1, p - 1); S := Trim(Copy(S, p + 1, Length(S))); end;
  end;

  function OnOff(const K: string): string;
  begin if H.Get(K, False) then Result := 'on' else Result := 'off'; end;

begin
  R := Trim(Rest);
  Sub := LowerCase(W1(R));
  if (Sub = '') or (Sub = 'show') or (Sub = 'list') then
    Req := BuildHeaderList(FCfg.Secret, FCfg.SelfId)
  else if (Sub = 'short') or (Sub = 'full') then
    Req := BuildHeaderSet(FCfg.Secret, FCfg.SelfId, 'mode', Sub)
  else if Sub = 'set' then
  begin
    Key := LowerCase(W1(R));
    Val := LowerCase(W1(R));
    if (Key = '') or (Val = '') then
    begin FeedLine('usage: /header set <key> <value>'); Exit; end;
    Req := BuildHeaderSet(FCfg.Secret, FCfg.SelfId, Key, Val);
  end
  else
  begin
    FeedLine('usage: /header [show] | short | full | set <key> <value>');
    FeedLine('  keys: mode(short|full) style orders tasks teams group(own|off) project subs shared workflow manual(first|off|always)');
    Exit;
  end;

  if not OneShot(Req, Reply) then Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then Exit;
  try
    if not Obj.Get('ok', False) then
    begin FeedLine('error: ' + Obj.Get('error', 'unknown')); Exit; end;
    H := Obj.Get('header', TJSONObject(nil));
    if H = nil then Exit;
    FeedLine('delivery header: ' + H.Get('mode', '?') + '   (short = compact | full = legacy long)');
    FeedLine(Format('  style=%s orders=%s tasks=%s teams=%s group=%s',
      [OnOff('style'), OnOff('orders'), OnOff('tasks'), OnOff('teams'), H.Get('group', '?')]));
    FeedLine(Format('  project=%s subs=%s shared=%s workflow=%s manual=%s',
      [OnOff('project'), OnOff('subs'), OnOff('shared'), OnOff('workflow'),
       H.Get('manual', '?')]));
  finally
    Obj.Free;
  end;
end;

{ /share <team|console> <file> [note...] — copy into the shared dir + notify. }
procedure TChat.CmdShare(const Rest: string);
var
  R, Dest, PathV, Note, FinalPath, Err, Msg: string;
  p: Integer;
begin
  if FSharedDir = '' then
  begin
    FeedLine('shared exchange not configured on the hub ([shared] dir)');
    Exit;
  end;
  R := Trim(Rest);
  p := Pos(' ', R);
  if p = 0 then
  begin
    FeedLine('usage: /share <team|console> <file> [note...]');
    Exit;
  end;
  Dest := Copy(R, 1, p - 1);
  R := Trim(Copy(R, p + 1, Length(R)));
  p := Pos(' ', R);
  if p = 0 then
  begin
    PathV := R;
    Note := '';
  end
  else
  begin
    PathV := Copy(R, 1, p - 1);
    Note := Trim(Copy(R, p + 1, Length(R)));
  end;
  if (not SameText(Dest, 'console')) and (not KnownTeam(Dest)) then
  begin
    FeedLine('error: unknown team ''' + Dest + '''');
    Exit;
  end;
  if not ShareCopy(PathV, FSharedDir + '/' + LowerCase(Dest), FinalPath, Err) then
  begin
    FeedLine('error: ' + Err);
    Exit;
  end;
  Msg := 'FILE SHARED: ' + FinalPath;
  if Note <> '' then
    Msg := Msg + ' - ' + Note;
  DoSendTo(Dest, Msg);
  FeedLine('file placed at ' + FinalPath);
end;

{ /files [team|console] — list a shared directory. }
procedure TChat.CmdFiles(const Rest: string);
var
  Dest, Dir: string;
  Info: TSearchRec;
  n: Integer;
  Total: Int64;
begin
  if FSharedDir = '' then
  begin
    FeedLine('shared exchange not configured on the hub ([shared] dir)');
    Exit;
  end;
  Dest := Trim(Rest);
  if Dest = '' then
    Dest := FCfg.SelfId;
  if (not SameText(Dest, 'console')) and (not KnownTeam(Dest)) then
  begin
    FeedLine('error: unknown team ''' + Dest + '''');
    Exit;
  end;
  Dir := FSharedDir + '/' + LowerCase(Dest);
  if not DirectoryExists(Dir) then
  begin
    FeedLine('(directory does not exist yet: ' + Dir + ')');
    Exit;
  end;
  n := 0;
  Total := 0;
  if FindFirst(Dir + '/*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Attr and faDirectory) = 0 then
      begin
        Inc(n);
        Inc(Total, Info.Size);
        FeedLine(Format('%10d  %s  %s',
          [Info.Size, FormatDateTime('yyyy-mm-dd hh:nn', Info.TimeStamp),
           Info.Name]));
      end;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  FeedLine(Format('shared/%s: %d file(s), %.1f MB', [LowerCase(Dest), n,
    Total / 1048576.0]));
end;

{ Indented view of the team hierarchy (parent = links). }
procedure TChat.CmdTree;

  procedure PrintNode(const Name: string; Depth: Integer);
  var
    j: Integer;
  begin
    for j := 0 to High(FTeams) do
      if SameText(FTeams[j].Name, Name) then
        FeedLine(Format('%s%s (id=%d) - %s  [%d open]',
          [StringOfChar(' ', Depth * 2), FTeams[j].Name, FTeams[j].Id,
           FTeams[j].Spec, FTeams[j].OpenTasks]));
    for j := 0 to High(FTeams) do
      if SameText(FTeams[j].Parent, Name) then
        PrintNode(FTeams[j].Name, Depth + 1);
  end;

var
  i: Integer;
begin
  RefreshTeams(True);   { fresh parents + open counts }
  if Length(FTeams) = 0 then
  begin
    FeedLine('(no teams)');
    Exit;
  end;
  FeedLine('team hierarchy:');
  for i := 0 to High(FTeams) do
    if FTeams[i].Parent = '' then
      PrintNode(FTeams[i].Name, 1);
end;

procedure TChat.CmdFleet;
var
  Reply: string;
  Obj, FO: TJSONObject;
  FR: TJSONArray;
  FT: TRows;
  i: Integer;
begin
  if not OneShot(BuildFleet(FCfg.Secret, FCfg.SelfId), Reply) then
  begin
    FeedLine('pizarra hub: unreachable');
    Exit;
  end;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    if not Obj.Get('ok', False) then
    begin
      FeedLine('error: ' + Obj.Get('error', 'unknown'));
      Exit;
    end;
    FR := Obj.Get('rows', TJSONArray(nil));
    if FR <> nil then
    begin
      SetLength(FT, FR.Count);
      for i := 0 to FR.Count - 1 do
      begin
        FO := TJSONObject(FR.Items[i]);
        SetLength(FT[i], 5);
        FT[i][0] := FO.Get('kind', '');
        FT[i][1] := FO.Get('host', '');
        FT[i][2] := FO.Get('state', '');
        FT[i][3] := FO.Get('ver', '');
        FT[i][4] := FO.Get('teams', '');
      end;
      FeedBlock(Table(TCells.Create('TYPE', 'HOST', 'STATE',
        'RELEASE', 'TEAMS'), FT, TermWidth - 1));
    end
    else
      FeedBlock(Obj.Get('tree', ''));
  finally
    Obj.Free;
  end;
end;

procedure TChat.CmdUpdate(const Rest: string);
var
  Name, Reply: string;
  Force: Boolean;
  Obj: TJSONObject;
  Lines: TStringList;
  i, p: Integer;
begin
  Name := Trim(Rest);
  Force := False;
  p := Pos('--force', Name);
  if p = 0 then
    p := Pos('--forzar', Name);
  if p > 0 then
  begin
    Force := True;
    Name := Trim(StringReplace(StringReplace(Name, '--force', '',
      [rfReplaceAll]), '--forzar', '', [rfReplaceAll]));
  end;
  if Name = '' then
  begin
    FeedLine('usage: /update <team|all> [--force]   (daemons self-update to' +
      ' the hub release)');
    Exit;
  end;
  { the hub probes every push host in turn (1 s each when one is down) before
    it answers, so this one needs a wider budget than the usual 3 s }
  if not OneShot(BuildUpdate(FCfg.Secret, FCfg.SelfId, Name, '', Force),
    Reply, 15000) then
  begin
    FeedLine('pizarra hub: unreachable');
    Exit;
  end;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    if not Obj.Get('ok', False) then
    begin
      FeedLine('error: ' + Obj.Get('error', 'unknown'));
      Exit;
    end;
    Lines := TStringList.Create;
    try
      Lines.Text := Obj.Get('tree', '');
      for i := 0 to Lines.Count - 1 do
        FeedLine(Lines[i]);
    finally
      Lines.Free;
    end;
  finally
    Obj.Free;
  end;
end;


{ /app — application registry from the console. It uses the CLI verbs and keeps
  legacy aliases; the card is printed exactly like `tiza app show`. }
procedure TChat.CmdApp(const Rest: string);
var
  R, Sub, Name, Reply, Field, Value, Team, Repo, PathS, Purpose, Detail: string;
  DocText, Leftover: string;
  Obj, A, AO: TJSONObject;
  Rws: TJSONArray;
  TRs: TRows;
  CK, CV: TCells;
  Lines: TStringList;
  i: Integer;

  function NextTok(var S: string): string;
  var
    q: Integer;
  begin
    S := Trim(S);
    q := Pos(' ', S);
    if q = 0 then
    begin
      Result := S;
      S := '';
    end
    else
    begin
      Result := Copy(S, 1, q - 1);
      S := Trim(Copy(S, q + 1, Length(S)));
    end;
  end;

  { Parse "--flag value words --flag2 value" in ANY order: a flag's value
    runs to the next --flag, not to end of line. Surrounding quotes are
    stripped here because TIniFile strips them on reload — keeping them would
    silently change the value at the next hub restart. }
  procedure ParseFlags(const S: string; out FTeam, FRepo, FPath, FPurpose,
    FDetail, Leftover: string);
  var
    Toks: TStringList;
    i: Integer;
    Cur, Val: string;

    procedure Flush;
    begin
      Val := Trim(Val);
      if (Length(Val) >= 2) and (Val[1] = Val[Length(Val)]) and
         ((Val[1] = '"') or (Val[1] = '''')) then
        Val := Copy(Val, 2, Length(Val) - 2);
      if (Cur = '--team') or (Cur = '--equipo') then FTeam := Val
      else if Cur = '--repo' then FRepo := Val
      else if (Cur = '--path') or (Cur = '--ruta') then FPath := Val
      else if (Cur = '--purpose') or (Cur = '--utilidad') then FPurpose := Val
      else if (Cur = '--detail') or (Cur = '--detalle') then FDetail := Val
      else if Cur = '' then Leftover := Val;
      Val := '';
    end;

  begin
    FTeam := ''; FRepo := ''; FPath := ''; FPurpose := '';
    FDetail := ''; Leftover := '';
    Cur := '';
    Val := '';
    Toks := TStringList.Create;
    try
      Toks.Delimiter := ' ';
      Toks.StrictDelimiter := True;
      { Disable QUOTING too. StrictDelimiter does NOT disable it: CheckQuoted
        never consults that property (rtl/objpas/classes/stringl.inc:549-573),
        and QuoteChar defaults to '"' (stringl.inc:74). A field STARTING with a
        double quote was split internally, silently shifting EVERY following
        column. With #0, CheckQuoted always returns False (stringl.inc:556,
        aQuoteChar<>#0). }
      Toks.QuoteChar := #0;
      Toks.DelimitedText := S;
      for i := 0 to Toks.Count - 1 do
        if Copy(Toks[i], 1, 2) = '--' then
        begin
          Flush;
          Cur := LowerCase(Toks[i]);
        end
        else
        begin
          if Val <> '' then
            Val := Val + ' ';
          Val := Val + Toks[i];
        end;
      Flush;
    finally
      Toks.Free;
    end;
  end;

begin
  R := Trim(Rest);
  Sub := LowerCase(NextTok(R));
  if (Sub = 'alta') or (Sub = 'crear') then Sub := 'add'
  else if (Sub = 'quitar') or (Sub = 'borrar') then Sub := 'remove'
  else if (Sub = 'definir') or (Sub = 'cambiar') then Sub := 'set'
  else if (Sub = 'lista') or (Sub = 'listar') then Sub := 'list'
  else if (Sub = 'ver') or (Sub = 'ficha') then Sub := 'show'
  else if (Sub = 'doc') or (Sub = 'manual') then Sub := 'doc'
  else if (Sub = 'historial') or (Sub = 'hist') then Sub := 'history'
  else if (Sub = 'deshacer') then Sub := 'undo';
  if Sub = '' then
    Sub := 'list';
  if (Sub <> 'list') and (Sub <> 'add') and (Sub <> 'set') and
     (Sub <> 'remove') and (Sub <> 'show') and (Sub <> 'doc') and
     (Sub <> 'history') and (Sub <> 'undo') then
  begin
    { bare "/app <name>" = show that app }
    Name := Sub;
    Sub := 'show';
  end
  else
    Name := NextTok(R);

  Field := '';
  Value := '';
  Team := ''; Repo := ''; PathS := ''; Purpose := ''; Detail := '';
  if Sub = 'set' then
  begin
    Field := LowerCase(NextTok(R));
    Value := Trim(R);
    if (Field = '') or (Name = '') then
    begin
      FeedLine('usage: /app set <name> team|repo|path|purpose|detail <value>');
      Exit;
    end;
  end
  else if Sub = 'add' then
  begin
    ParseFlags(R, Team, Repo, PathS, Purpose, Detail, Leftover);
    R := Leftover;
    if Name = '' then
    begin
      FeedLine('usage: /app add <name> --team <team> [--repo U] [--path P]' +
        ' [--purpose "..."] [--detail "..."]');
      Exit;
    end;
  end;

  DocText := '';
  if Sub = 'doc' then
  begin
    DocText := Trim(R);          { anything after the name replaces the manual }
    if DocText <> '' then
      Sub := 'setdoc';
  end;
  if not OneShot(BuildAppOp(FCfg.Secret, FCfg.SelfId, Sub, Name, Team, Repo,
    PathS, Purpose, Detail, Field, Value, DocText), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    if not Obj.Get('ok', False) then
    begin
      FeedLine('error: ' + Obj.Get('error', 'unknown'));
      Exit;
    end;
    Rws := Obj.Get('rows', TJSONArray(nil));
    if Rws <> nil then
    begin
      if Rws.Count = 0 then
      begin
        FeedLine('(no applications registered yet - /app add <name> --team <team>)');
        Exit;
      end;
      SetLength(TRs, Rws.Count);
      for i := 0 to Rws.Count - 1 do
      begin
        AO := TJSONObject(Rws.Items[i]);
        SetLength(TRs[i], 4);
        TRs[i][0] := AO.Get('name', '');
        TRs[i][1] := AO.Get('team', '');
        TRs[i][2] := BoolToStr(AO.Get('hasdoc', False), 'yes', '-');
        TRs[i][3] := AO.Get('purpose', '');
      end;
      FeedBlock(Table(TCells.Create('APP', 'OWNER', 'MANUAL',
        'PURPOSE'), TRs, TermWidth - 1));
      Exit;
    end;
    if Obj.Get('tree', '') <> '' then
    begin
      FeedBlock(Frame('', Obj.Get('tree', ''), TermWidth - 1));
      Exit;
    end;
    A := Obj.Get('app', TJSONObject(nil));
    if A = nil then
    begin
      FeedLine('ok');
      Exit;
    end;
    CK := TCells.Create('team', 'purpose', 'repo', 'path',
      'detail', 'manual');
    SetLength(CV, 6);
    CV[0] := BoolToStr(A.Get('team', '') = '', '(unassigned)',
      A.Get('team', ''));
    CV[1] := A.Get('purpose', '');
    CV[2] := A.Get('repo', '');
    CV[3] := A.Get('path', '');
    CV[4] := A.Get('detail', '');
    if A.Get('hasdoc', False) then
      CV[5] := '/app doc ' + A.Get('name', '')
    else
      CV[5] := '(none yet - /app doc ' + A.Get('name', '') + ' <text>)';
    FeedBlock(Card('app ' + A.Get('name', ''), CK, CV, TermWidth - 1));
  finally
    Obj.Free;
  end;
end;

procedure TChat.CmdVer;
var
  Reply: string;
  Obj: TJSONObject;
begin
  FeedLine('tiza console ' + PizarraVersion);
  if not OneShot(BuildVer(FCfg.Secret, FCfg.SelfId), Reply) then
  begin
    FeedLine('pizarra hub: unreachable');
    Exit;
  end;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    if Obj.Get('ok', False) then
      FeedLine('pizarra hub ' + Obj.Get('ver', '?'))
    else
      FeedLine('pizarra hub: ' + Obj.Get('error', 'unknown'));
  finally
    Obj.Free;
  end;
end;

procedure TChat.CmdTask(const Rest: string);
var
  Sub, R, TeamName, Title, Milestone, Reply, Filter: string;
  p, Id, ParentId: Integer;
  Obj, T: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  TH: TCells;
  TR: TRows;

  function NextWord(var S: string): string;
  var
    q: Integer;
  begin
    S := Trim(S);
    q := Pos(' ', S);
    if q = 0 then
    begin
      Result := S;
      S := '';
    end
    else
    begin
      Result := Copy(S, 1, q - 1);
      S := Trim(Copy(S, q + 1, Length(S)));
    end;
  end;

  function ShowReply(const Req: string): Boolean;
  begin
    Result := False;
    if not OneShot(Req, Reply) then
      Exit;
    Obj := ParseObj(Reply);
    if Obj = nil then
      Exit;
    try
      if not Obj.Get('ok', False) then
      begin
        FeedLine('error: ' + Obj.Get('error', 'unknown'));
        Exit;
      end;
      T := Obj.Get('task', TJSONObject(nil));
      if T <> nil then
        PrintTask(T, False);
      Result := True;
    finally
      Obj.Free;
    end;
  end;

begin
  R := Trim(Rest);
  Sub := LowerCase(NextWord(R));
  { Legacy aliases for subcommands. }
  if Sub = 'crear' then Sub := 'add'
  else if (Sub = 'hecha') or (Sub = 'hecho') then Sub := 'done'
  else if Sub = 'reabrir' then Sub := 'reopen'
  else if Sub = 'asignar' then Sub := 'assign'
  else if Sub = 'nota' then Sub := 'note'
  else if (Sub = 'lista') or (Sub = 'listar') then Sub := 'list'
  else if (Sub = 'ver') or (Sub = 'mostrar') then Sub := 'show';

  if (Sub = '') or (Sub = 'list') then
  begin
    Filter := 'open';
    TeamName := '';
    if Sub = 'list' then
    begin
      Title := LowerCase(NextWord(R));
      if (Title = 'open') or (Title = 'done') or (Title = 'all') then
      begin
        Filter := Title;
        TeamName := NextWord(R);
      end
      else
        TeamName := Title;
    end;
    if not OneShot(BuildTaskList(FCfg.Secret, FCfg.SelfId, Filter, TeamName), Reply) then
      Exit;
    Obj := ParseObj(Reply);
    if Obj = nil then
      Exit;
    try
      if not Obj.Get('ok', False) then
      begin
        FeedLine('error: ' + Obj.Get('error', 'unknown'));
        Exit;
      end;
      Arr := Obj.Get('tasks', TJSONArray(nil));
      if (Arr = nil) or (Arr.Count = 0) then
      begin
        FeedLine('(no tasks)');
        Exit;
      end;
        { The list used loose lines and most long titles wrapped wherever the
          terminal chose. A table trims the title within its column, while the
          complete card remains available through /task show <id>. }
      TH := TCells.Create('#', 'milestone', 'state', 'team', 'title');
      SetLength(TR, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        T := TJSONObject(Arr.Items[i]);
        TeamName := T.Get('team', '');
        if TeamName = '' then
          TeamName := 'backlog';
        Title := T.Get('title', '');
        if T.Get('parent', 0) > 0 then
          Title := Title + Format('  (sub of #%d)', [T.Get('parent', 0)]);
        TR[i] := TCells.Create(
          IntToStr(T.Get('id', 0)), T.Get('hito', ''),
          T.Get('state', '?'), TeamName, Title);
      end;
      FeedBlock(Table(TH, TR, TermWidth - 2));
    finally
      Obj.Free;
    end;
  end
  else if Sub = 'add' then
  begin
    TeamName := NextWord(R);
    if (TeamName = '') or (R = '') then
    begin
      FeedLine('usage: /task add <team|-> <title> [--milestone v1]');
      Exit;
    end;
    if (TeamName <> '-') and (not KnownTeam(TeamName)) then
    begin
      FeedLine('error: unknown team ''' + TeamName + ''' (use - for backlog)');
      Exit;
    end;
    { Parse the canonical --milestone flag, its legacy alias, and --parent as
      TOKENS anywhere. Keep the rest as the title; the old trailing-substring
      parse dropped words after a flag. }
    ParentId := 0;
    Milestone := '';
    Title := '';
    while R <> '' do
    begin
      Filter := NextWord(R);   { reuse Filter as a scratch word var }
      if Filter = '--parent' then
      begin
          { As in the CLI, a nonnumeric --parent used to become 0 (no parent), so
            a typo silently created a ROOT task instead of the intended subtask. }
        Filter := NextWord(R);
        if StrToIntDef(Filter, -1) < 0 then
        begin
          FeedLine('--parent needs a task id (a number); omit it ' +
            'for a root task');
          Exit;
        end;
        ParentId := StrToIntDef(Filter, 0);
      end
      else if (Filter = '--milestone') or (Filter = '--hito') then
        Milestone := NextWord(R)
      else
      begin
        if Title <> '' then Title := Title + ' ';
        Title := Title + Filter;
      end;
    end;
    { strip optional surrounding quotes }
    if (Length(Title) >= 2) and (Title[1] = '"') and (Title[Length(Title)] = '"') then
      Title := Copy(Title, 2, Length(Title) - 2);
    ShowReply(BuildTaskAdd(FCfg.Secret, FCfg.SelfId, Title, TeamName,
      Milestone, ParentId));
  end
  else if (Sub = 'done') or (Sub = 'reopen') then
  begin
    Id := StrToIntDef(NextWord(R), -1);
    if Id < 0 then
    begin
      FeedLine('usage: /task ' + Sub + ' <id>');
      Exit;
    end;
    if Sub = 'done' then
      ShowReply(BuildTaskState(FCfg.Secret, FCfg.SelfId, Id, 'done'))
    else
      ShowReply(BuildTaskState(FCfg.Secret, FCfg.SelfId, Id, 'open'));
  end
  else if Sub = 'assign' then
  begin
    Id := StrToIntDef(NextWord(R), -1);
    TeamName := NextWord(R);
    if (Id < 0) or (TeamName = '') then
    begin
      FeedLine('usage: /task assign <id> <team|->');
      Exit;
    end;
    ShowReply(BuildTaskAssign(FCfg.Secret, FCfg.SelfId, Id, TeamName));
  end
  else if Sub = 'note' then
  begin
    Id := StrToIntDef(NextWord(R), -1);
    if (Id < 0) or (R = '') then
    begin
      FeedLine('usage: /task note <id> <text>');
      Exit;
    end;
    ShowReply(BuildTaskNote(FCfg.Secret, FCfg.SelfId, Id, R));
  end
  else if Sub = 'show' then
  begin
    Id := StrToIntDef(NextWord(R), -1);
    if Id < 0 then
    begin
      FeedLine('usage: /task show <id>');
      Exit;
    end;
    if not OneShot(BuildTaskShow(FCfg.Secret, FCfg.SelfId, Id), Reply) then
      Exit;
    Obj := ParseObj(Reply);
    if Obj = nil then
      Exit;
    try
      if not Obj.Get('ok', False) then
        FeedLine('error: ' + Obj.Get('error', 'unknown'))
      else
      begin
        T := Obj.Get('task', TJSONObject(nil));
        if T <> nil then
          PrintTask(T, True);
        Arr := Obj.Get('subtasks', TJSONArray(nil));
        if (Arr <> nil) and (Arr.Count > 0) then
        begin
          Title := '';
          for i := 0 to Arr.Count - 1 do
          begin
            if Title <> '' then
              Title := Title + ' ';
            Title := Title + '#' + IntToStr(Arr.Items[i].AsInteger);
          end;
          FeedLine('  subtasks: ' + Title);
        end;
      end;
    finally
      Obj.Free;
    end;
  end
  else
    FeedLine('usage: /task add|done|reopen|assign|note|list|show (see /help)');
end;

procedure TChat.CmdInbox;
var
  Reply: string;
  Obj, M: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  if not OneShot(BuildInbox(FCfg.Secret, FCfg.SelfId), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    Arr := Obj.Get('messages', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      FeedLine('(inbox empty)');
      Exit;
    end;
    for i := 0 to Arr.Count - 1 do
    begin
      M := TJSONObject(Arr.Items[i]);
      if ColorsOn then
        { headers styled, flattened body untouched (frozen shape) }
        FeedLine(Dim(Format('#%d', [M.Get('seq', Int64(0))])) + ' ' +
          Dim('[' + M.Get('ts', '') + ']') + ' ' +
          TeamName(M.Get('from', '?')) + ': ' +
          StringReplace(M.Get('text', ''), #10, ' / ', [rfReplaceAll]))
      else
        FeedLine(Format('#%d [%s] %s: %s',
          [M.Get('seq', Int64(0)), M.Get('ts', ''), M.Get('from', '?'),
           StringReplace(M.Get('text', ''), #10, ' / ', [rfReplaceAll])]));
    end;
  finally
    Obj.Free;
  end;
end;

procedure TChat.CmdLog(const Arg: string);
var
  Reply, txt: string;
  Obj, M: TJSONObject;
  Arr: TJSONArray;
  i, n: Integer;
begin
  n := StrToIntDef(Arg, 30);
  if not OneShot(BuildRecent(FCfg.Secret, -1, n), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
    Exit;
  try
    Arr := Obj.Get('messages', TJSONArray(nil));
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      FeedLine('(no traffic)');
      Exit;
    end;
    for i := 0 to Arr.Count - 1 do
    begin
      M := TJSONObject(Arr.Items[i]);
      if ColorsOn then
      begin
        txt := StringReplace(M.Get('text', ''), #10, ' / ', [rfReplaceAll]);
        { hub-LAUNCHED messages (from 'pizarra': the group-idle nudge, workflow
          notices) get a distinct colour so you can spot when they fired in the
          log, apart from team-to-team traffic. }
        if SameText(M.Get('from', '?'), 'pizarra') then
          txt := FgBold(HINT_FG, txt);
        FeedLine(Dim(Format('#%d', [M.Get('seq', Int64(0))])) + ' ' +
          Dim(Copy(M.Get('ts', ''), 12, 5)) + ' ' +
          TeamName(M.Get('from', '?')) + Dim('->') +
          TeamName(M.Get('to', '?')) + '  ' + txt);
      end
      else
        FeedLine(Format('#%d %s %s->%s  %s',
          [M.Get('seq', Int64(0)), Copy(M.Get('ts', ''), 12, 5),
           M.Get('from', '?'), M.Get('to', '?'),
           StringReplace(M.Get('text', ''), #10, ' / ', [rfReplaceAll])]));
    end;
  finally
    Obj.Free;
  end;
end;

procedure TChat.CmdFull(const Arg: string);
var
  Seq: Int64;
  i, n: Integer;
begin
  Seq := StrToInt64Def(Arg, -1);
  if Seq < 0 then
  begin
    FeedLine('usage: /full <seq>');
    Exit;
  end;
  n := FRecentN;
  if n > RECENT_CAP then
    n := RECENT_CAP;
  for i := 0 to n - 1 do
    if FRecent[i].Seq = Seq then
    begin
      FeedLine(Format('---- #%d %s %s->%s ----',
        [FRecent[i].Seq, FRecent[i].Ts, FRecent[i].From, FRecent[i].Dest]));
      FeedLine(FRecent[i].Text);
      FeedLine('----');
      Exit;
    end;
  FeedLine('(message not seen this session; try /log)');
end;

{ /cat <shared-path> - read a shared-dir file's content inline in the feed,
  over the bus (same request as `tiza cat` / `tiza get`). Header styled,
  body printed line by line. }
procedure TChat.CmdCat(const Arg: string);
var
  Reply, Data, Bytes, Path: string;
  Obj: TJSONObject;
  SL: TStringList;
  i: Integer;
begin
  Path := Trim(Arg);
  if Path = '' then
  begin
    FeedLine('usage: /cat <shared-path>');
    Exit;
  end;
  if not OneShot(BuildGet(FCfg.Secret, FCfg.SelfId, Path), Reply) then
    Exit;
  Obj := ParseObj(Reply);
  if Obj = nil then
  begin
    FeedLine('cat: bad reply');
    Exit;
  end;
  try
    if not Obj.Get('ok', False) then
    begin
      FeedLine('cat: ' + Obj.Get('error', 'failed'));
      Exit;
    end;
    Data := Obj.Get('data', '');
  finally
    Obj.Free;
  end;
  Bytes := DecodeStringBase64(Data);
  if ColorsOn then
    FeedLine(Fg(HINT_FG, Format('---- %s (%d bytes) ----',
      [ExtractFileName(Path), Length(Bytes)])))
  else
    FeedLine(Format('---- %s (%d bytes) ----',
      [ExtractFileName(Path), Length(Bytes)]));
  SL := TStringList.Create;
  try
    SL.Text := Bytes;
    for i := 0 to SL.Count - 1 do
      FeedLine(SL[i]);
  finally
    SL.Free;
  end;
  if ColorsOn then
    FeedLine(Fg(HINT_FG, '----'))
  else
    FeedLine('----');
end;

procedure TChat.CmdFile(const Rest: string);
var
  Dest, PathV, Body: string;
  p: Integer;
  SL: TStringList;
begin
  p := Pos(' ', Rest);
  if p = 0 then
  begin
    FeedLine('usage: /file team path');
    Exit;
  end;
  Dest := Copy(Rest, 1, p - 1);
  PathV := Trim(Copy(Rest, p + 1, Length(Rest)));
  if not KnownDest(Dest) then
  begin
    FeedLine('error: unknown team ''' + Dest + '''');
    Exit;
  end;
  if not FileExists(PathV) then
  begin
    FeedLine('error: file not found: ' + PathV);
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(PathV);
    Body := TrimRight(SL.Text);
  finally
    SL.Free;
  end;
  if Body = '' then
    FeedLine('error: file empty')
  else
    DoSendTo(Dest, Body);
end;

procedure TChat.ExecuteLine(const RawLine: string);
var
  Line, Cmd, Rest, Dest: string;
  p: Integer;
begin
  { multi-line compose mode works on the RAW line: blank lines and
    indentation belong to the body; only an exactly-'.' line sends }
  if FCompose then
  begin
    if RawLine = '.' then
    begin
      FCompose := False;
      if FComposeLines.Count = 0 then
        FeedLine('(nothing to send)')
      else
        DoSendTo(FComposeTo, TrimRight(FComposeLines.Text));
      FComposeLines.Clear;
    end
    else if SameText(Trim(RawLine), '/cancel') then
    begin
      FCompose := False;
      FComposeLines.Clear;
      FeedLine('(composition cancelled)');
    end
    else
      FComposeLines.Add(RawLine);
    Exit;
  end;

  Line := Trim(RawLine);
  if Line = '' then
    Exit;

  HistAdd(Line);

  if Line[1] = '/' then
  begin
    p := Pos(' ', Line);
    if p = 0 then
    begin
      Cmd := Line;
      Rest := '';
    end
    else
    begin
      Cmd := Copy(Line, 1, p - 1);
      Rest := Trim(Copy(Line, p + 1, Length(Line)));
    end;
    Cmd := LowerCase(Cmd);

    if (Cmd = '/quit') or (Cmd = '/salir') or (Cmd = '/q') then
      FQuit := True
    else if (Cmd = '/help') or (Cmd = '/ayuda') or (Cmd = '/?') then
      CmdHelp(Rest)
    else if (Cmd = '/teams') or (Cmd = '/equipos') or
            (Cmd = '/e') or (Cmd = '/info') then
      RefreshTeams(False)
    else if (Cmd = '/team') or (Cmd = '/equipo') then
      CmdTeam(Rest)
    else if (Cmd = '/inbox') or (Cmd = '/i') or (Cmd = '/buzon') then
      CmdInbox
    else if (Cmd = '/log') or (Cmd = '/l') or (Cmd = '/registro') then
      CmdLog(Rest)
    else if (Cmd = '/full') or (Cmd = '/completo') then
      CmdFull(Rest)
    else if (Cmd = '/ver') or (Cmd = '/version') then
      CmdVer
    else if (Cmd = '/fleet') or (Cmd = '/flota') then
      CmdFleet
    else if (Cmd = '/update') or (Cmd = '/actualizar') then
      CmdUpdate(Rest)
    else if (Cmd = '/app') or (Cmd = '/apps') or (Cmd = '/aplicacion') or
            (Cmd = '/aplicaciones') then
      CmdApp(Rest)
    else if (Cmd = '/cat') or (Cmd = '/leer') then
      CmdCat(Rest)
    else if (Cmd = '/send') or (Cmd = '/s') or (Cmd = '/enviar') then
    begin
      p := Pos(' ', Rest);
      if p = 0 then
        FeedLine('usage: /send team text')
      else
      begin
        Dest := Copy(Rest, 1, p - 1);
        if KnownDest(Dest) then
          DoSendTo(Dest, Trim(Copy(Rest, p + 1, Length(Rest))))
        else
          FeedLine('error: unknown team ''' + Dest + '''');
      end;
    end
    else if (Cmd = '/msg') or (Cmd = '/m') or (Cmd = '/mensaje') then
    begin
      if KnownDest(Rest) then
        StartCompose(Rest)
      else
        FeedLine('usage: /msg team|@group   (known destination)');
    end
    else if (Cmd = '/file') or (Cmd = '/f') or (Cmd = '/fichero') then
      CmdFile(Rest)
    else if (Cmd = '/clear') or (Cmd = '/limpiar') then
    begin
      Write(#27'[2J'#27'[H');
      if ColorsOn then
        FeedLine(Bold('=== PIZARRA console ===') +
          Format(' %d teams ===', [Length(FTeams)]))
      else
        FeedLine(Format('=== PIZARRA console === %d teams ===', [Length(FTeams)]));
    end
    else if (Cmd = '/task') or (Cmd = '/t') or (Cmd = '/tarea') or (Cmd = '/tareas') then
      CmdTask(Rest)
    else if (Cmd = '/workflow') or (Cmd = '/wf') or (Cmd = '/flujo') or
            (Cmd = '/workflows') or (Cmd = '/flujos') then
      CmdWorkflow(Rest)
    else if (Cmd = '/tree') or (Cmd = '/arbol') then
      CmdTree
    else if (Cmd = '/group') or (Cmd = '/grupo') or
            (Cmd = '/groups') or (Cmd = '/grupos') then
      CmdGroup(Rest)
    else if (Cmd = '/project') or (Cmd = '/proyecto') or
            (Cmd = '/projects') or (Cmd = '/proyectos') then
      CmdProject(Rest)
    else if (Cmd = '/header') or (Cmd = '/headers') or (Cmd = '/cabecera') then
      CmdHeader(Rest)
    else if (Cmd = '/share') or (Cmd = '/compartir') then
      CmdShare(Rest)
    else if (Cmd = '/files') or (Cmd = '/ficheros') then
      CmdFiles(Rest)
    else
      FeedLine('unknown command (see /help)');
    Exit;
  end;

  { Bare @group enters the same compose mode as /msg.  A colon remains the
    unambiguous one-line shorthand, so existing '@group: text' input is kept
    as an immediate send. }
  if (Length(Line) > 1) and (Line[1] = '@') and (Pos(':', Line) = 0) then
  begin
    if KnownDest(Line) then
      StartCompose(Line)
    else
      FeedLine('error: unknown group ''' + Line + '''');
    Exit;
  end;

  { shorthand: 'team: text' (team, 'all', or '@group') }
  p := Pos(':', Line);
  if p > 1 then
  begin
    Dest := Trim(Copy(Line, 1, p - 1));
    if (Length(Dest) > 0) and (Dest[1] = '@') then
    begin
      DoSendTo(Dest, Trim(Copy(Line, p + 1, Length(Line))));   { hub validates the group }
      Exit;
    end;
    if KnownDest(Dest) then
    begin
      DoSendTo(Dest, Trim(Copy(Line, p + 1, Length(Line))));
      Exit;
    end;
  end;
  FeedLine('error: unknown destination (use "team: text" or /help)');
end;

{ ---------------- main loop ---------------- }

constructor TChat.Create(const ACfg: TTizaConfig; APlain: Boolean);
var
  StateDir: string;
begin
  inherited Create;
  FCfg := ACfg;
  FPlain := APlain;
  FHistory := TStringList.Create;
  FComposeLines := TStringList.Create;
  FHistIdx := -1;
  FLastSeq := 0;
  FRecentN := 0;
  StateDir := GetEnvironmentVariable('HOME') + '/.local/state/pizarra';
  ForceDirectories(StateDir);
  FHistFile := StateDir + '/chat_history';
  if FileExists(FHistFile) then
    try
      FHistory.LoadFromFile(FHistFile);
    except
    end;
end;

destructor TChat.Destroy;
begin
  FSock.Free;
  FComposeLines.Free;
  FHistory.Free;
  inherited Destroy;
end;

procedure TChat.Run;
var
  FDS: TFDSet;
  TV: TTimeVal;
  MaxFd, r, i: Integer;
  Legend: string;
begin
  if (not FPlain) and (IsATTY(0) = 0) then
  begin
    Writeln(StdErr, 'tiza chat requires a terminal (or use --plain)');
    Exit;
  end;

  InstallShutdownHandler;   { Ctrl-C / SIGTERM -> clean exit, termios restored }
  { single color gate for the whole surface; --plain stays byte-identical }
  if FPlain then
    AnsiInit(cmNever)
  else
    AnsiInit(cmAuto);
  RefreshTeams(True);
  if ColorsOn then
  begin
    Writeln(Bold('=== PIZARRA console ===') +
      Format(' %d teams === (%s@%s:%d, ', [Length(FTeams), FCfg.SelfId,
        FCfg.Host, FCfg.Port]) + Fg(HINT_FG, '/help') + ')');
    { self-teaching legend: each team in its identity color }
    Legend := '';
    for i := 0 to High(FTeams) do
      Legend := Legend + ' ' + TeamName(FTeams[i].Name);
    if Legend <> '' then
      Writeln(Dim('teams:') + Legend);
  end
  else
    Writeln(Format('=== PIZARRA console === %d teams === (%s@%s:%d, /help)',
      [Length(FTeams), FCfg.SelfId, FCfg.Host, FCfg.Port]));
  Flush(Output);
  ConnectWatch;
  EnterRaw;
  try
    RedrawInput;
    while not (FQuit or ShutdownRequested) do
    begin
      fpFD_ZERO(FDS);
      fpFD_SET(0, FDS);
      MaxFd := 0;
      if FSock <> nil then
      begin
        fpFD_SET(FSock.Handle, FDS);
        if FSock.Handle > MaxFd then
          MaxFd := FSock.Handle;
      end;
      TV.tv_sec := 0;
      TV.tv_usec := 500000;
      r := fpSelect(MaxFd + 1, @FDS, nil, nil, @TV);
      if r > 0 then
      begin
        if (FSock <> nil) and (fpFD_ISSET(FSock.Handle, FDS) > 0) then
          HandleSockData;
        if fpFD_ISSET(0, FDS) > 0 then
          HandleStdin;
        FlushAck;   { once per burst, not once per message }
      end
      else if r < 0 then
      begin
        if fpGetErrno <> ESysEINTR then
          Break;   { EINTR (Ctrl-C) is handled via ShutdownRequested }
      end
      else if FSock = nil then
      begin
        { disconnected: retry with backoff on the select cadence }
        Dec(FRetryWaitMs, 500);
        if FRetryWaitMs <= 0 then
        begin
          ConnectWatch;
          if FSock <> nil then
            FeedLine('(reconnected)')
          else if FRetryWaitMs < 30000 then
            FRetryWaitMs := FRetryWaitMs + 3000;
        end;
      end;
    end;
  finally
    FlushAck;
    LeaveRaw;
    Writeln;
    try
      FHistory.SaveToFile(FHistFile);
    except
    end;
  end;
end;

procedure RunChat(const ACfg: TTizaConfig; APlain: Boolean);
var
  C: TChat;
begin
  { The console always writes to a terminal, so draw frames unless the operator
    requests --plain or the terminal lacks the required capabilities. }
  SetPretty(not APlain);
  C := TChat.Create(ACfg, APlain);
  try
    C.Run;
  finally
    C.Free;
  end;
end;

end.
