{ pzweb - the pizarra web console.

  This daemon runs alongside pizarra and tiza. It does NOT read hub files; it
  communicates over the bus with its own team credential.

  The live contract is docs/web-api.md. Do not pin this header to a commit hash
  because the document evolves and a fixed hash would point to an obsolete
  schema.

  pzweb serves the management application, its authenticated read/write API,
  and the live SSE feed. Milestone numbers and plan state do not belong in this
  header because they expire quickly. }
program pzweb;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, StrUtils, Sockets, BaseUnix, ssockets,
  fphttpserver, httpdefs, httpprotocol, fpjson, jsonparser, base64,
  pzconfig, pzlayout, pzproto, pznet, pzver, pzsha256;

const
  { A browser loads the page and several assets over keep-alive connections
    while holding an SSE feed open. Limits must accommodate real tab refreshes
    without allowing one source address to consume the global pool. }
  MAX_CONN_TOTAL = 256;  { total simultaneous connections }
  MAX_CONN_PEER  = 64;   { per source address }
  MAX_FEED_PEER  = 16;   { open SSE feeds per source address; a refreshed feed
                           may overlap the old tab until the browser releases it }
  MAX_BODY       = 64 * 1024;
  IO_TIMEOUT_MS  = 10000;
  { Per-hub-request budget. HUB_TRY_MS caps one read; HUB_BUDGET_MS caps the
    whole request including connection retries. A bounded lifetime prevents
    stalled upstream calls from exhausting the thread-per-request server. }
  HUB_TRY_MS     = 5000;
  HUB_BUDGET_MS  = 12000;
  { Probe interval for an open browser feed. This bounds detection time for a
    closed tab; it is not a general network timeout. See ServeFeed. }
  FEED_PROBE_MS  = 1000;
  MAX_ASSET      = 2 * 1024 * 1024;
  MAX_ASSETS_ALL = 32 * 1024 * 1024;

type
  TAsset = record
    Url:   string;
    Mime:  string;
    Bytes: string;
    { Content digest computed at load time. It supports zero-body 304 responses
      and changes automatically with every deployment. }
    ETag:  string;
  end;

  TWebCfg = record
    { bus }
    Host:   string;
    Port:   Integer;
    Secret: string;
    Self_:  string;
    { web }
    Listen:    string;
    WebPort:   Integer;
    AllowFrom: TStringArray;
    HostExp:   string;
    Origin:    string;
    User:      string;   { login name }
    PassHash:  string;   { SHA-256 credential digest, never the credential }
    AppsDir:   string;
    SharedDir: string;   { optional file exchange }
  end;

var
  Cfg: TWebCfg;
  Assets: array of TAsset;
  ConnTotal: Integer = 0;
  ConnPeer: TStringList = nil;
  FeedPeer: TStringList = nil;
  ConnLock: TRTLCriticalSection;

{ ---------------------------------------------------------------- utilities }

procedure Fail(const Msg: string);
begin
  Writeln(StdErr, 'pzweb: ', Msg);
  Halt(1);
end;

{ Exact MIME map required by contract section 8.1. With nosniff enabled, an
  unknown extension must not be loaded or served as a guessed octet stream. }
function MimeFor(const Ext: string): string;
begin
  case LowerCase(Ext) of
    '.html':  Result := 'text/html; charset=utf-8';
    '.js':    Result := 'text/javascript; charset=utf-8';
    '.css':   Result := 'text/css; charset=utf-8';
    '.json':  Result := 'application/json; charset=utf-8';
    '.svg':   Result := 'image/svg+xml';
    '.png':   Result := 'image/png';
    '.ico':   Result := 'image/x-icon';
    '.woff2': Result := 'font/woff2';
  else
    Result := '';
  end;
end;

function JsonStr(const S: string): string;
var
  V: TJSONString;
begin
  V := TJSONString.Create(S);
  try
    Result := V.AsJSON;
  finally
    V.Free;
  end;
end;

{ ------------------------------------------------------------------- bus }

threadvar
  BusTimedOut: Boolean;

{ One hub request. Retry only connection establishment: once a request is sent,
  repeating it could duplicate its effect. A single total budget includes every
  retry, while each attempt receives only the remaining time. }
function Bus(const Req: string; out Reply: string; out Sent: Boolean;
  out TimedOut: Boolean): Boolean; overload;
{ The dispatcher reads timeout state from a thread variable because every HTTP
  request has its own thread and dozens of Bus call sites converge on one error
  exit. }
var
  Err: string;
  attempt: Integer;
  Deadline, CurrentTick: QWord;
  RemainingMs: Integer;
begin
  Result := False;
  Sent := False;
  TimedOut := False;
  Deadline := GetTickCount64 + QWord(HUB_BUDGET_MS);
  for attempt := 1 to 3 do
  begin
    CurrentTick := GetTickCount64;
    if CurrentTick >= Deadline then
    begin
      TimedOut := True;
      Break;
    end;
    RemainingMs := Integer(Deadline - CurrentTick);
    Result := RequestLine(Cfg.Host, Cfg.Port, HUB_TRY_MS, RemainingMs,
                Req, Reply, Err, Sent);
    if Result or Sent then
      Break;
    { Never sleep past the remaining request budget. }
    if GetTickCount64 + 200 < Deadline then
      Sleep(200);
  end;
  if (not Result) and (GetTickCount64 >= Deadline) then
    TimedOut := True;
  BusTimedOut := TimedOut;
end;

{ Compatibility overload; preserve timeout state in BusTimedOut for the shared
  dispatcher error path. }
function Bus(const Req: string; out Reply: string; out Sent: Boolean): Boolean;
var
  TimedOut: Boolean;
begin
  Result := Bus(Req, Reply, Sent, TimedOut);
end;

{ ------------------------------------------- credential-binding proof }

{ A nonempty secret alone proves no binding: a global secret also works as the
  web identity and can claim the console. Issue the same command twice with only
  `from` changed; acceptance of the negative probe proves the credential is
  unbound and startup must stop before opening a socket. }
{ Binding proves identity, not capability. Query the hub for the credential's
  actual family ceiling and require every declared management family before
  listening. The hub derives this from the credential, never from `from`. }
procedure ProveFamilies;
var
  Reply, Missing: string;
  Obj: TJSONObject;
  Arr, D: TJSONData;
  Sent, Found: Boolean;
  i, j: Integer;
begin
  if not Bus(BuildCaps(Cfg.Secret, Cfg.Self_), Reply, Sent) then
    Fail('the hub does not answer the capability query: refusing to start');
  Obj := ParseObj(Reply);
  if Obj = nil then
    Fail('unreadable hub reply to the capability query');
  try
    { Fail closed: require every field with its declared type. A defaulted read
      would incorrectly treat missing or mistyped fields as safe values. }
    D := Obj.Find('ok');
    if (D = nil) or (D.JSONType <> jtBoolean) or (not D.AsBoolean) then
      Fail('the hub refused the capability query, or answered without a ' +
           'boolean ok: refusing to start');
    { The capability card must name this service; never administer with another
      team's permission ceiling. }
    D := Obj.Find('bound');
    if (D = nil) or (D.JSONType <> jtString) then
      Fail('the hub answered no bound team: refusing to start');
    if not SameText(D.AsString, Cfg.Self_) then
      Fail('the hub says this credential is bound to "' + D.AsString +
           '", not to ' + Cfg.Self_ + ': refusing to start');
    { An `unrestricted` result contradicts the preceding binding proof and must
      stop startup. }
    D := Obj.Find('unrestricted');
    if (D = nil) or (D.JSONType <> jtBoolean) then
      Fail('the hub answered no boolean unrestricted flag: refusing to start');
    if D.AsBoolean then
      Fail('the hub reports this credential as UNRESTRICTED, which contradicts ' +
           'the binding proof: refusing to start');
    Arr := Obj.Find('families');
    if (Arr = nil) or (Arr.JSONType <> jtArray) then
      Fail('the hub answered no family list: refusing to start');
    for j := 0 to TJSONArray(Arr).Count - 1 do
      if TJSONArray(Arr).Items[j].JSONType <> jtString then
        Fail('the hub family list carries something that is not a name: ' +
             'refusing to start');
    Missing := '';
    { Use the single family list exported by pzconfig. A local duplicate would
      silently become incomplete when the hub adds a family. }
    for i := 0 to High(DELEGATE_FAMILIES) do
    begin
      Found := False;
      for j := 0 to TJSONArray(Arr).Count - 1 do
        if SameText(TJSONArray(Arr).Items[j].AsString, DELEGATE_FAMILIES[i]) then
          Found := True;
      if not Found then
      begin
        if Missing <> '' then
          Missing := Missing + ', ';
        Missing := Missing + DELEGATE_FAMILIES[i];
      end;
    end;
    if Missing <> '' then
      Fail('the hub does not delegate these families to ' + Cfg.Self_ + ': ' +
           Missing + '. This console administers everything or it does not ' +
           'open: use `tiza team set ' + Cfg.Self_ +
           ' delegate ...` from the real console. ' +
           'No socket was opened.');
    Writeln('pzweb: the hub delegates all ', Length(DELEGATE_FAMILIES),
            ' families to ', Cfg.Self_);
  finally
    Obj.Free;
  end;
end;

procedure ProveBinding;
var
  Reply: string;
  Obj: TJSONObject;
  OkSelf, OkConsole, Sent: Boolean;
  ConsoleWhy, LastWhy: string;

  function AskOk(const FromWho: string): Boolean;
  var
    D: TJSONData;
  begin
    Result := False;
    if not Bus(BuildTeams(Cfg.Secret, FromWho), Reply, Sent) then
      Fail('the hub does not answer: refusing to start (no socket opened)');
    Obj := ParseObj(Reply);
    if Obj = nil then
      Fail('unreadable hub reply during the startup binding proof');
    try
      { Require an explicit Boolean `ok`. The negative probe must not interpret
        a malformed or missing field as proof of binding. }
      D := Obj.Find('ok');
      if (D = nil) or (D.JSONType <> jtBoolean) then
        Fail('the hub answered the binding proof (from=' + FromWho +
             ') without a boolean ok: refusing to start');
      Result := D.AsBoolean;
      LastWhy := '';
      D := Obj.Find('error');
      if (D <> nil) and (D.JSONType = jtString) then
        LastWhy := Trim(D.AsString);
    finally
      Obj.Free;
    end;
  end;

begin
  LastWhy := '';
  ConsoleWhy := '';
  OkSelf    := AskOk(Cfg.Self_);
  OkConsole := AskOk('console');
  ConsoleWhy := LastWhy;

  if not OkSelf then
    Fail(Format('the configured credential is not accepted as %s: refusing to start',
      [Cfg.Self_]));

  { The negative response must be the expected identity-guard rejection. Any
    other error would prove a different condition and cannot establish binding. }
  if (not OkConsole) and (Copy(LowerCase(ConsoleWhy), 1, 9) <> 'identity:') then
    Fail('the hub refused from=console for another reason ("' + ConsoleWhy +
         '"), not with its identity guard: that proves something else. ' +
         'Refusing to start.');

  if OkConsole then
    Fail('the configured credential was ACCEPTED as from=console, so it is NOT ' +
         'bound to this team (it looks like the GLOBAL secret). Refusing to ' +
         'start: no socket is opened. Rotate it with `tiza team set ' +
         Cfg.Self_ + ' secret --file PATH` from the real console.');

  Writeln('pzweb: credential proved bound to team ', Cfg.Self_,
          ' (accepted as itself, refused as console)');
  ProveFamilies;
end;

{ Reject symlinks in every path component, not only the final one. Otherwise an
  ancestor can be retargeted after a shallow validation. }
function NoSymlinkInPath(const Path: string; out Bad: string): Boolean;
var
  Full, Acc: string;
  Parts: TStringArray;
  i: Integer;
  St: Stat;
begin
  Result := False;
  Bad := '';
  { Reject `..` before normalization. FPC removes it lexically while the system
    resolves symlinks first, so validation and open could otherwise address
    different objects. }
  if (Pos('/../', Path) > 0) or (Pos('/./', Path) > 0) or
     (Copy(Path, 1, 3) = '../') or (Copy(Path, 1, 2) = './') or
     (Copy(Path, Length(Path) - 2, 3) = '/..') then
  begin
    Bad := Path + ' contains a dot component: give a path without . or ..';
    Exit;
  end;
  Full := ExpandFileName(ExcludeTrailingPathDelimiter(Path));
  Parts := SplitString(Full, '/');
  Acc := '';
  for i := 0 to High(Parts) do
  begin
    if Parts[i] = '' then
      Continue;
    Acc := Acc + '/' + Parts[i];
    St := Default(Stat);
    if fpLStat(Acc, St) <> 0 then
    begin
      Bad := Acc + ' (cannot stat)';
      Exit;
    end;
    if fpS_ISLNK(St.st_mode) then
    begin
      Bad := Acc + ' is a symlink';
      Exit;
    end;
  end;
  Result := True;
end;

{ --------------------------------------------------------------- static assets }

procedure LoadAssets;
var
  Total: Int64;

  procedure Walk(const Dir, Prefix: string);
  var
    Info: TSearchRec;
    Full, Rel, Ext, Mime: string;
    FS: TFileStream;
    Data: string;
    St: Stat;
  begin
    if FindFirst(Dir + '/*', faAnyFile, Info) <> 0 then
      Exit;
    try
      repeat
        if (Info.Name = '.') or (Info.Name = '..') then
          Continue;
        Full := Dir + '/' + Info.Name;
        Rel  := Prefix + Info.Name;
        { Reject a symlink in any component so an asset validated at startup
          cannot point elsewhere. }
        if fpLStat(Full, St) <> 0 then
          Continue;
        if fpS_ISLNK(St.st_mode) then
        begin
          Writeln(StdErr, 'pzweb: skipping symlink: ', Full);
          Continue;
        end;
        if fpS_ISDIR(St.st_mode) then
        begin
          Walk(Full, Rel + '/');
          Continue;
        end;
        if not fpS_ISREG(St.st_mode) then
          Continue;
        Ext  := ExtractFileExt(Info.Name);
        Mime := MimeFor(Ext);
        if Mime = '' then
        begin
          Writeln(StdErr, 'pzweb: skipping unlisted extension: ', Rel);
          Continue;
        end;
        if St.st_size > MAX_ASSET then
        begin
          Writeln(StdErr, 'pzweb: skipping oversized asset: ', Rel);
          Continue;
        end;
        Inc(Total, St.st_size);
        if Total > MAX_ASSETS_ALL then
          Fail('static assets exceed the total budget');
        FS := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
        try
          SetLength(Data, FS.Size);
          if FS.Size > 0 then
            FS.ReadBuffer(Data[1], FS.Size);
        finally
          FS.Free;
        end;
        SetLength(Assets, Length(Assets) + 1);
        Assets[High(Assets)].Url   := '/' + Rel;
        Assets[High(Assets)].Mime  := Mime;
        Assets[High(Assets)].Bytes := Data;
        Assets[High(Assets)].ETag  := '"' + Copy(Sha256OfString(Data), 1, 32) + '"';
      until FindNext(Info) <> 0;
    finally
      FindClose(Info);
    end;
  end;

var
  i: Integer;
  HasIndex: Boolean;
  BadComp: string;
begin
  Total := 0;
  SetLength(Assets, 0);
  { Validate path safety before existence so diagnostics expose the actual
    unsafe configuration instead of masking it as a missing directory. }
  if not NoSymlinkInPath(Cfg.AppsDir, BadComp) then
    Fail('static dir path is unsafe: ' + BadComp + ' — refusing to start');
  if not DirectoryExists(Cfg.AppsDir) then
    Fail(Format('static dir %s does not exist: refusing to start', [Cfg.AppsDir]));
  { Traverse exactly the normalized path that was validated. }
  Cfg.AppsDir := ExpandFileName(ExcludeTrailingPathDelimiter(Cfg.AppsDir));
  Walk(ExcludeTrailingPathDelimiter(Cfg.AppsDir), '');

  { Contract section 8.1: a root that returns 404 is a broken deployment. }
  HasIndex := False;
  for i := 0 to High(Assets) do
    if Assets[i].Url = '/index.html' then
      HasIndex := True;
  if not HasIndex then
    Fail(Format('%s/index.html is missing: refusing to start (a 404 root is a ' +
      'broken deployment)', [Cfg.AppsDir]));

  Writeln('pzweb: ', Length(Assets), ' static asset(s), ', Total, ' bytes');
end;

function FindAsset(const Url: string; out A: TAsset): Boolean;
var
  i: Integer;
  Want: string;
begin
  Result := False;
  Want := Url;
  if Want = '/' then
    Want := '/index.html';
  { Match URLs byte-for-byte with no case folding or trailing-slash redirects. }
  for i := 0 to High(Assets) do
    if Assets[i].Url = Want then
    begin
      A := Assets[i];
      Exit(True);
    end;
end;

{ ------------------------------------------------------- network admission }

{ Read the actual peer from the socket descriptor. Without a trusted proxy,
  client-controlled forwarding headers must never determine admission. }
function PeerOf(ASocket: Longint): string;
var
  SA: TSockAddr;
  Len: TSockLen;
begin
  Result := '';
  Len := SizeOf(SA);
  if fpGetPeerName(ASocket, @SA, @Len) <> 0 then
    Exit;
  Result := NetAddrToStr(SA.sin_addr);
end;

{ Convert dotted IPv4 text to a 32-bit value, or return False. }
function Ip4(const S: string; out V: LongWord): Boolean;
var
  Parts: TStringArray;
  i, n: Integer;
begin
  Result := False;
  V := 0;
  Parts := SplitString(S, '.');
  if Length(Parts) <> 4 then
    Exit;
  for i := 0 to 3 do
  begin
    n := StrToIntDef(Parts[i], -1);
    if (n < 0) or (n > 255) then
      Exit;
    V := (V shl 8) or LongWord(n);
  end;
  Result := True;
end;

{ allow_from accepts an exact IPv4 address or CIDR such as the documentation
  range 192.0.2.0/24. }
function PeerAllowed(const Peer: string): Boolean;
var
  i, slash, Bits: Integer;
  PeerV, NetV, Mask: LongWord;
  Rule, Net: string;
begin
  Result := False;
  if (Peer = '') or (not Ip4(Peer, PeerV)) then
    Exit;
  for i := 0 to High(Cfg.AllowFrom) do
  begin
    Rule := Trim(Cfg.AllowFrom[i]);
    if Rule = '' then
      Continue;
    slash := Pos('/', Rule);
    if slash = 0 then
    begin
      { Compare normalized numeric addresses, not alternate textual forms. }
      if Ip4(Rule, NetV) and (NetV = PeerV) then
        Exit(True);
      Continue;
    end;
    Net  := Copy(Rule, 1, slash - 1);
    Bits := StrToIntDef(Copy(Rule, slash + 1, Length(Rule)), -1);
    if (Bits < 0) or (Bits > 32) or (not Ip4(Net, NetV)) then
      Continue;   { startup already rejects this; retain defense in depth }
    if Bits = 0 then
      Mask := 0
    else
      Mask := LongWord($FFFFFFFF) shl (32 - Bits);
    if (PeerV and Mask) = (NetV and Mask) then
      Exit(True);
  end;
end;

{ An allow_from rule is valid only as exact IPv4 or CIDR. }
function RuleWellFormed(const Rule: string): Boolean;
var
  slash, Bits: Integer;
  V: LongWord;
  R: string;
begin
  R := Trim(Rule);
  slash := Pos('/', R);
  if slash = 0 then
    Exit(Ip4(R, V));
  Bits := StrToIntDef(Copy(R, slash + 1, Length(R)), -1);
  Result := (Bits >= 0) and (Bits <= 32) and Ip4(Copy(R, 1, slash - 1), V);
end;

{ Count feeds separately because normal requests last milliseconds while SSE
  channels can remain open for hours. }
function TakeFeedSlot(const Peer: string): Boolean;
var
  idx, n: Integer;
begin
  EnterCriticalSection(ConnLock);
  try
    idx := FeedPeer.IndexOfName(Peer);
    n := 0;
    if idx >= 0 then
      n := StrToIntDef(FeedPeer.ValueFromIndex[idx], 0);
    Result := n < MAX_FEED_PEER;
    if Result then
    begin
      if idx >= 0 then
        FeedPeer.ValueFromIndex[idx] := IntToStr(n + 1)
      else
        FeedPeer.Add(Peer + '=1');
    end;
  finally
    LeaveCriticalSection(ConnLock);
  end;
end;

{ Number of channels this address currently has OPEN. Track every open and close
  because multiple long-lived browser channels can exhaust the per-server
  connection pool and leave requests queued locally. One number per log line
  turns "it is slow" into observable state. }
function FeedCount(const Peer: string): Integer;
var
  idx: Integer;
begin
  EnterCriticalSection(ConnLock);
  try
    idx := FeedPeer.IndexOfName(Peer);
    if idx >= 0 then
      Result := StrToIntDef(FeedPeer.ValueFromIndex[idx], 0)
    else
      Result := 0;
  finally
    LeaveCriticalSection(ConnLock);
  end;
end;

procedure DropFeedSlot(const Peer: string);
var
  idx, n: Integer;
begin
  EnterCriticalSection(ConnLock);
  try
    idx := FeedPeer.IndexOfName(Peer);
    if idx >= 0 then
    begin
      n := StrToIntDef(FeedPeer.ValueFromIndex[idx], 0) - 1;
      if n > 0 then
        FeedPeer.ValueFromIndex[idx] := IntToStr(n)
      else
        FeedPeer.Delete(idx);
    end;
  finally
    LeaveCriticalSection(ConnLock);
  end;
end;

{ Release one peer slot exactly once for each admitted connection. }
procedure ReleasePeer(const Peer: string);
var
  idx, n: Integer;
begin
  if Peer = '' then
    Exit;
  EnterCriticalSection(ConnLock);
  try
    if ConnTotal > 0 then
      Dec(ConnTotal);
    idx := ConnPeer.IndexOfName(Peer);
    if idx >= 0 then
    begin
      n := StrToIntDef(ConnPeer.ValueFromIndex[idx], 0) - 1;
      if n > 0 then
        ConnPeer.ValueFromIndex[idx] := IntToStr(n)
      else
        ConnPeer.Delete(idx);
    end;
  finally
    LeaveCriticalSection(ConnLock);
  end;
end;

type
  TAdmit = class
    procedure Allow(Sender: TObject; ASocket: Longint; var Allowed: Boolean);
  end;

var
  Admit: TAdmit;

{ Decide admission in accept before reading any bytes. Request.RemoteAddress is
  populated only after unbounded request-line and header reads, which is too
  late for a perimeter intended to contain that resource risk. }
procedure TAdmit.Allow(Sender: TObject; ASocket: Longint; var Allowed: Boolean);
var
  Peer: string;
  n: Integer;
  idx: Integer;
begin
  Peer := PeerOf(ASocket);
  Allowed := PeerAllowed(Peer);
  if not Allowed then
  begin
    Writeln(StdErr, 'pzweb: refused at accept (not in allow_from): ', Peer);
    Exit;
  end;
  EnterCriticalSection(ConnLock);
  try
    if ConnTotal >= MAX_CONN_TOTAL then
    begin
      Allowed := False;
      Writeln(StdErr, 'pzweb: refused at accept (total connections)');
      Exit;
    end;
    idx := ConnPeer.IndexOfName(Peer);
    n := 0;
    if idx >= 0 then
      n := StrToIntDef(ConnPeer.ValueFromIndex[idx], 0);
    if n >= MAX_CONN_PEER then
    begin
      Allowed := False;
      Writeln(StdErr, 'pzweb: refused at accept (per-peer connections): ', Peer);
      Exit;
    end;
    { Reserve here, not in the handler, so a connection that never sends data
      still consumes its bounded slot. }
    Inc(ConnTotal);
    if idx >= 0 then
      ConnPeer.ValueFromIndex[idx] := IntToStr(n + 1)
    else
      ConnPeer.Add(Peer + '=1');
  finally
    LeaveCriticalSection(ConnLock);
  end;
end;

{ ------------------------------------------------------------- responses }

{ Centralize mandatory headers so every response path applies the same policy. }
{ Write the exact body bytes. TResponse.SetContent assigns through Text and adds
  a trailing newline, which silently corrupts binary assets. }
procedure SendExact(AResp: TFPHTTPConnectionResponse; const Bytes: string);
var
  St: TMemoryStream;
begin
  St := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    St.WriteBuffer(Bytes[1], Length(Bytes));
  St.Position := 0;
  AResp.ContentLength := St.Size;
  AResp.FreeContentStream := True;   { response takes ownership of the stream }
  AResp.ContentStream := St;
  AResp.SendContent;
end;

{ Match If-None-Match according to its list syntax, wildcard, and optional weak
  ETag prefix instead of comparing the complete header as one string. }
function ETagMatches(const HeaderValue, ETag: string): Boolean;
var
  Parts: TStringArray;
  i: Integer;
  Item, Expected: string;
begin
  Result := False;
  Expected := ETag;
  if Copy(Expected, 1, 2) = 'W/' then
    Expected := Copy(Expected, 3, Length(Expected));
  Parts := SplitString(HeaderValue, ',');
  for i := 0 to High(Parts) do
  begin
    Item := Trim(Parts[i]);
    if Item = '*' then
      Exit(True);
    if Copy(Item, 1, 2) = 'W/' then
      Item := Copy(Item, 3, Length(Item));
    if Item = Expected then
      Exit(True);
  end;
end;

procedure CommonHeaders(AResp: TFPHTTPConnectionResponse);
begin
  { THE SERVER HAS NO KEEP-ALIVE, SO SAY SO. fcl-web 3.2.2 serves one request per
    connection and closes it (fphttpserver.pp:662-675), while HTTP/1.1 otherwise
    implies reuse. Explicit Connection: close keeps browsers from caching dead
    sockets and retrying each request. }
  AResp.SetCustomHeader('Connection', 'close');
  AResp.SetCustomHeader('X-Content-Type-Options', 'nosniff');
  AResp.SetCustomHeader('Cache-Control', 'no-store');
  AResp.SetCustomHeader('Referrer-Policy', 'no-referrer');
  { No inline scripts or styles and no third-party requests, limiting the impact
    of any future untrusted page text. }
  { Exact Content Security Policy from contract section 9; omitted directives
    otherwise fall back to broader defaults. }
  AResp.SetCustomHeader('Content-Security-Policy',
    'default-src ''self''; script-src ''self''; style-src ''self''; ' +
    'img-src ''self'' data:; connect-src ''self''; object-src ''none''; ' +
    'base-uri ''none''; frame-ancestors ''none''; form-action ''self''');
end;

procedure SendJson(AResp: TFPHTTPConnectionResponse; Code: Integer;
  const Body: string);
begin
  AResp.Code := Code;
  AResp.ContentType := 'application/json; charset=utf-8';
  CommonHeaders(AResp);
  SendExact(AResp, Body);
end;

procedure SendOk(AResp: TFPHTTPConnectionResponse; const DataJson: string);
begin
  SendJson(AResp, 200, '{"ok":true,"data":' + DataJson + '}');
end;

{ Record who requested what when a request is rejected. }
threadvar
  CurPeer: string;
  CurWhat: string;

procedure SendErr(AResp: TFPHTTPConnectionResponse; Code: Integer;
  const Err, Fix: string);
var
  Who: string;
begin
  { Log every rejection with peer and operation. Successful requests remain
    quiet so the diagnostic stream stays readable. }
  if Code >= 400 then
  begin
    Who := CurPeer;
    if Who = '' then
      Who := '?';
    { For a 500, include the exception detail needed to diagnose the failure. }
    if Code >= 500 then
      Writeln(StdErr, Format('pzweb: %d a %s (%s) -> %s :: %s',
        [Code, Who, CurWhat, Err, Fix]))
    else
      Writeln(StdErr, Format('pzweb: %d a %s (%s) -> %s',
        [Code, Who, CurWhat, Err]));
    Flush(StdErr);
  end;
  SendJson(AResp, Code, '{"ok":false,"error":' + JsonStr(Err) +
    ',"fix":' + JsonStr(Fix) + '}');
end;

{ Reject wrong methods instead of silently treating a POST as a successful read.
  RFC 9110 section 15.5.6 requires Allow on a 405 response. }
{ A serialized origin has exactly scheme, `://`, and authority: no path, query,
  or fragment. }
function OriginCoherent(const Origin, HostExp: string;
  out Why: string): Boolean;
var
  Auth: string;
begin
  Result := False;
  Why := '';
  { Accept only http:// because this topology is clear HTTP with no proxy. Proxy
    support must change topology, configuration, and this check together. }
  if Copy(Origin, 1, 7) = 'http://' then
    Auth := Copy(Origin, 8, Length(Origin))
  else
  begin
    Why := 'this server speaks clear HTTP with no proxy, so it must be http://';
    Exit;
  end;
  if Auth = '' then
  begin
    Why := 'it names no authority';
    Exit;
  end;
  if (Pos('/', Auth) > 0) or (Pos('?', Auth) > 0) or (Pos('#', Auth) > 0) then
  begin
    Why := 'an origin carries no path, query or fragment';
    Exit;
  end;
  if Auth <> HostExp then
  begin
    Why := 'its authority is ' + Auth + ', not ' + HostExp;
    Exit;
  end;
  Result := True;
end;

{ URLs with a read representation. Keep one route table so POST to an existing
  read-only URL yields 405 rather than 404. The read dispatcher cross-checks
  this table and reports an internal inconsistency loudly. }
function ReadRouteKnown(const Rest: string;
  const Segs: array of string; NSeg: Integer): Boolean;
begin
  Result :=
    (Rest = 'teams') or (Rest = 'groups') or (Rest = 'projects') or
    (Rest = 'apps') or (Rest = 'tasks') or (Rest = 'workflows') or
    (Rest = 'fleet') or (Rest = 'version') or (Rest = 'header') or
    (Rest = 'messages') or (Rest = 'files') or (Rest = 'inbox') or
    (Rest = 'download');
  if Result then
    Exit;
  if NSeg = 2 then
    Result := (Segs[0] = 'message') or (Segs[0] = 'files');
  if Result then
    Exit;
  if NSeg = 2 then
    { 'project' was missing here, so /api/project/<n> answered 404 and there was
      no way to read ONE project from the web at all - not even to re-read it
      after changing its boss. }
    Result := (Segs[0] = 'team') or (Segs[0] = 'app') or
              (Segs[0] = 'project') or
              (Segs[0] = 'task') or (Segs[0] = 'workflow')
  else if NSeg = 3 then
    Result := ((Segs[0] = 'app') and
               ((Segs[2] = 'history') or (Segs[2] = 'doc'))) or
              ((Segs[0] = 'workflow') and (Segs[2] = 'history'));
end;

{ Read URLs that do not also accept writes. Application manuals share one URL
  for GET and POST; future overlaps must be declared beside this table. }
function ReadOnlyRoute(const Rest: string;
  const Segs: array of string; NSeg: Integer): Boolean;
begin
  Result := ReadRouteKnown(Rest, Segs, NSeg) and
            not ((NSeg = 3) and (Segs[0] = 'app') and (Segs[2] = 'doc')) and
            not (Rest = 'header');
end;

procedure Send405(AResp: TFPHTTPConnectionResponse; const Allow: string);
begin
  AResp.SetCustomHeader('Allow', Allow);
  SendErr(AResp, 405, 'method not allowed',
    'this URL only answers to ' + Allow);
end;

{ Forward hub rejections without inventing a remedy from free-form text. }
{ If the hub accepted and replied but projection fails, report a distinct 502
  protocol error rather than misrepresenting it as a deliberate hub rejection. }
procedure SendProtoErr(AResp: TFPHTTPConnectionResponse; const Err: string);
begin
  SendJson(AResp, 502, '{"ok":false,"error":' + JsonStr(Err) +
    ',"outcome":"upstream_malformed"' +
    { These routes are currently reads, so malformed upstream data changed no
      state. A future post-confirmation mutation needs an unknown-outcome form. }
    ',"fix":"the hub answered something this server cannot project; ' +
    'nothing was written"}');
end;

procedure SendHubErr(AResp: TFPHTTPConnectionResponse; const Err: string);
begin
  SendJson(AResp, 200, '{"ok":false,"error":' + JsonStr(Err) + '}');
end;

{ Central upstream-failure mapping. Use 502 for reachability/failure and 504
  with Retry-After for an exhausted deadline. If the request was already sent,
  its outcome is unknown; never invite an unsafe retry. Include CurWhat so the
  failed operation is identifiable. }
procedure SendBusFail(AResp: TFPHTTPConnectionResponse; Sent: Boolean);
var
  Operation: string;
begin
  Operation := CurWhat;
  if Operation = '' then
    Operation := 'this request';
  if BusTimedOut then
  begin
    AResp.SetCustomHeader('Retry-After', '5');
    if Sent then
      SendJson(AResp, 504, '{"ok":false,"error":' +
        JsonStr('the hub did not answer in time to ' + Operation) +
        ',"outcome":"unknown","fix":"do NOT resend: reload and compare ' +
        'before trying again"}')
    else
      SendJson(AResp, 504, '{"ok":false,"error":' +
        JsonStr('the hub did not accept the connection in time to ' + Operation) +
        ',"outcome":"not_sent","fix":"retry: nothing was sent"}');
    Exit;
  end;
  if Sent then
    SendJson(AResp, 502, '{"ok":false,"error":' +
      JsonStr('the hub did not answer to ' + Operation) + ',"outcome":"unknown"}')
  else
    SendJson(AResp, 502, '{"ok":false,"error":' +
      JsonStr('cannot reach the hub to ' + Operation) +
      ',"outcome":"not_sent","fix":"retry: nothing was sent"}');
end;

{ ------------------------------------------------------------- endpoints }

{ Project only explicitly named fields from upstream objects. Cloning whole
  objects would leak undocumented internal fields and make future additions
  public automatically. Required fields and their types are checked separately
  so malformed responses cannot become plausible empty cards. }
threadvar
  ShapeErr: string;

procedure Missing(const What: string);
begin
  if ShapeErr = '' then
    ShapeErr := What;
end;

{ Every projected field declares a type, not only a name. Codes: `s` string,
  `n` number, `b` Boolean, `[s]` string array, `[n]` number array; a trailing
  `?` marks an optional contract field. }
{ A cursor must be an integer, nonnegative, and within the browser-safe range
  before conversion; floating JSON values must never be rounded into IDs. }
function CursorOk(V: TJSONData): Boolean;
var
  D: Double;
begin
  Result := False;
  if (V = nil) or (V.JSONType <> jtNumber) then
    Exit;
  D := V.AsFloat;
  if (D < 0) or (D > 9.007199254740991E15) then
    Exit;
  Result := Frac(D) = 0;
end;

{ Projected numbers are identifiers, counts, steps, or dependencies and must be
  safe integers in the same domain as browser Number.isSafeInteger. }
function SafeInt(V: TJSONData): Boolean;
begin
  Result := (V <> nil) and (V.JSONType = jtNumber) and
            (Frac(V.AsFloat) = 0) and (Abs(V.AsFloat) <= 9007199254740991.0);
end;

{ Media type is the trimmed value before the first semicolon. }
function MediaTypeOf(const CT: string): string;
var
  p: Integer;
begin
  Result := CT;
  p := Pos(';', Result);
  if p > 0 then
    Result := Copy(Result, 1, p - 1);
  Result := Trim(Result);
end;

function TypeOk(V: TJSONData; const Code: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if V = nil then
    Exit;
  if Code = 's' then
    Result := V.JSONType = jtString
  else if Code = 'n' then
    Result := SafeInt(V)
  else if Code = 'b' then
    Result := V.JSONType = jtBoolean
  else if (Code = '[s]') or (Code = '[n]') then
  begin
    if V.JSONType <> jtArray then
      Exit;
    for i := 0 to TJSONArray(V).Count - 1 do
      if Code = '[s]' then
      begin
        if TJSONArray(V).Items[i].JSONType <> jtString then
          Exit;
      end
      else
        if not SafeInt(TJSONArray(V).Items[i]) then
          Exit;
    Result := True;
  end;
end;

function Pick(Src: TJSONObject; const Spec: array of string): TJSONObject;
var
  i, idx, colon: Integer;
  Name_, Code: string;
  Opt: Boolean;
begin
  Result := TJSONObject.Create;
  if Src = nil then
  begin
    Missing('expected an object');
    Exit;
  end;
  for i := 0 to High(Spec) do
  begin
    colon := Pos(':', Spec[i]);
    Name_ := Copy(Spec[i], 1, colon - 1);
    Code  := Copy(Spec[i], colon + 1, Length(Spec[i]));
    Opt := (Code <> '') and (Code[Length(Code)] = '?');
    if Opt then
      Code := Copy(Code, 1, Length(Code) - 1);
    idx := Src.IndexOfName(Name_);
    if idx < 0 then
    begin
      if not Opt then
        Missing('hub reply is missing the required field: ' + Name_);
      Continue;
    end;
    if not TypeOk(Src.Items[idx], Code) then
    begin
      Missing(Format('hub field %s is not of type %s', [Name_, Code]));
      Continue;
    end;
    Result.Add(Name_, Src.Items[idx].Clone);
  end;
end;

{ Return a required array member or nil while recording the shape failure. }
function ReqArray(Src: TJSONObject; const Name_: string): TJSONArray;
var
  idx: Integer;
begin
  Result := nil;
  idx := Src.IndexOfName(Name_);
  if idx < 0 then
    Missing('hub reply is missing the required field: ' + Name_)
  else if not (Src.Items[idx] is TJSONArray) then
    Missing('hub field ' + Name_ + ' is not an array')
  else
    Result := TJSONArray(Src.Items[idx]);
end;

{ Adapt one workflow step to the public contract. Hub field `hito` becomes
  `title`; absent normalized fields receive their declared defaults. }
function ShapeStep(Src: TJSONObject): TJSONObject;
var
  idxH, idxX, iX, idxT: Integer;
  XArr, XSrc: TJSONArray;
begin
  Result := Pick(Src, ['n:n', 'uid:n', 'team:s', 'state:s', 'deps:[n]', 'task:n']);
  { Step `eta` is editable from both CLI and web. The hub omits zero, which is
    normalized to inheritance from the plan default. }
  idxT := Src.IndexOfName('eta');
  if idxT < 0 then
    Result.Add('eta', 0)
  else if not TypeOk(Src.Items[idxT], 'n') then
    Missing('hub field eta is not of type n')
  else
    Result.Add('eta', Src.Get('eta', 0));
  { xdeps are cross-plan dependencies emitted only when present. Preserve them
    because the editor submits the complete dependency value and would
    otherwise delete hidden cross-plan edges. }
  idxX := Src.IndexOfName('xdeps');
  if idxX >= 0 then
  begin
    if not (Src.Items[idxX] is TJSONArray) then
      Missing('hub field xdeps is not an array')
    else
    begin
      XArr := TJSONArray.Create;
      XSrc := TJSONArray(Src.Items[idxX]);
      for iX := 0 to XSrc.Count - 1 do
        if XSrc.Items[iX] is TJSONObject then
          XArr.Add(Pick(TJSONObject(XSrc.Items[iX]), ['wf:s', 'n:n']))
        else
          Missing('an xdeps entry is not an object');
      Result.Add('xdeps', XArr);
    end;
  end;
  { Validate `hito` before renaming it to `title`; a defaulted Get could invent
    a title for a malformed field. }
  idxH := Src.IndexOfName('hito');
  if idxH < 0 then
    Missing('workflow step is missing the required field: hito')
  else if not TypeOk(Src.Items[idxH], 's') then
    Missing('hub field hito is not of type s')
  else
    Result.Add('title', Src.Get('hito', ''));
end;

function ShapeWorkflow(Src: TJSONObject): TJSONObject;
var
  Steps, Out_: TJSONArray;
  i, idxS, idxE: Integer;
begin
  Result := Pick(Src, ['name:s', 'group:s', 'state:s']);
  { `etadef` is the plan's default deadline. Normalize an omitted zero so the
    editor can both display and change the value. }
  idxE := Src.IndexOfName('etadef');
  if idxE < 0 then
    Result.Add('etadef', 0)
  else if not TypeOk(Src.Items[idxE], 'n') then
    Missing('hub field etadef is not of type n')
  else
    Result.Add('etadef', Src.Get('etadef', 0));

  { `strict` defaults to False only when absent; a present value must still be
    Boolean. }
  idxS := Src.IndexOfName('strict');
  if idxS < 0 then
    Result.Add('strict', False)
  else if not TypeOk(Src.Items[idxS], 'b') then
    Missing('hub field strict is not of type b')
  else
    Result.Add('strict', Src.Get('strict', False));
  Out_ := TJSONArray.Create;
  Steps := ReqArray(Src, 'steps');
  if Steps <> nil then
    for i := 0 to Steps.Count - 1 do
      if Steps.Items[i] is TJSONObject then
        Out_.Add(ShapeStep(TJSONObject(Steps.Items[i])))
      else
        Missing('a workflow step is not an object');
  Result.Add('steps', Out_);
end;

{ Count text units rather than UTF-8 bytes so field limits match browser form
  semantics. The separate whole-body byte limit still applies. }
function TextUnits(const S: string): Integer;
begin
  Result := Length(UTF8Decode(S));
end;

{ Read one exchange directory into JSON without following links or descending.
  Report links and special entries explicitly so the operator can understand
  why they are not downloadable. }
{ Root=True marks the startup manual as managed because the hub recreates it
  when absent; this server-side fact must not be hard-coded in the UI. }
function ListShared(const Dir: string; out Err: string;
  IsRoot: Boolean = False): TJSONArray;
var
  SR: TSearchRec;
  Full: string;
  St: Stat;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  Err := '';
  St := Default(Stat);
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      { Partial-upload temporaries are not team files and must never be listed. }
      if (Copy(SR.Name, 1, 7) = '.pzput-') or
         (Copy(SR.Name, 1, 9) = '.pzshare-') then
        Continue;
      Full := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if fpLStat(Full, St) <> 0 then
        Continue;
      O := TJSONObject.Create;
      O.Add('name', SR.Name);
      if fpS_ISLNK(St.st_mode) then
      begin
        O.Add('kind', 'link');
        O.Add('bytes', Int64(0));
      end
      else if fpS_ISDIR(St.st_mode) then
      begin
        O.Add('kind', 'dir');
        O.Add('bytes', Int64(0));
      end
      else if fpS_ISREG(St.st_mode) then
      begin
        O.Add('kind', 'file');
        O.Add('bytes', Int64(St.st_size));
      end
      else
      begin
        { A FIFO or other special entry is not a file. Label it accurately and
          never offer a download that could block the hub. }
        O.Add('kind', 'special');
        O.Add('bytes', Int64(0));
      end;
      O.Add('ts', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss',
        FileDateToDateTime(SR.Time)));
      if IsRoot and SameText(SR.Name, SHARED_MANUAL) then
        { The hub recreates this file; let the UI warn about that behavior. }
        O.Add('managed', True);
      Result.Add(O);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Count actual directory entries for actionable nonempty-directory errors. }
function CountEntries(const Path: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Validate a single entry name: no separators, dot segments, or NUL. The server
  constructs the anchored path. }
function ValidEntryName(const S: string): Boolean;
begin
  Result := (S <> '') and (S <> '.') and (S <> '..') and
            (Pos('/', S) = 0) and (Pos('\', S) = 0) and (Pos(#0, S) = 0);
end;

{ Empty an already opened directory before removing it. Recursive deletion is
  available only through an explicit request. Never follow links: open each
  level with O_NOFOLLOW+O_DIRECTORY and traverse through the stable descriptor,
  unlinking links themselves. A deliberate depth cap bounds destructive work. }
function EmptyDirectory(const Path: string; Depth: Integer;
  out Reason: string): Boolean;
const
  MAX_DEPTH = 24;
var
  SR: TSearchRec;
  Fd: LongInt;
  St: Stat;
  ChildPath, DescriptorPath: string;
  Names: array of string;
  i: Integer;
begin
  Result := False;
  Reason := '';
  if Depth > MAX_DEPTH then
  begin
    Reason := Format('the tree is deeper than %d levels', [MAX_DEPTH]);
    Exit;
  end;
  Fd := FpOpen(Path, O_RDONLY or O_DIRECTORY or O_NOFOLLOW);
  if Fd < 0 then
  begin
    Reason := 'could not open a directory inside it';
    Exit;
  end;
  try
    DescriptorPath := '/proc/self/fd/' + IntToStr(Fd);
    { Collect names first, then delete; mutating during enumeration makes the
      traversal depend on entries just removed. }
    Names := nil;
    if FindFirst(IncludeTrailingPathDelimiter(DescriptorPath) + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          SetLength(Names, Length(Names) + 1);
          Names[High(Names)] := SR.Name;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    for i := 0 to High(Names) do
    begin
      ChildPath := DescriptorPath + '/' + Names[i];
      St := Default(Stat);
      if fpLStat(ChildPath, St) <> 0 then
        Continue;   { disappeared concurrently; not an error }
      if fpS_ISDIR(St.st_mode) and (not fpS_ISLNK(St.st_mode)) then
      begin
        if not EmptyDirectory(ChildPath, Depth + 1, Reason) then
          Exit;
        if fpRmDir(ChildPath) <> 0 then
        begin
          Reason := Format('could not remove %s (errno %d)',
            [Names[i], fpgeterrno]);
          Exit;
        end;
      end
      else if fpUnlink(ChildPath) <> 0 then
      begin
        Reason := Format('could not remove %s (errno %d)',
          [Names[i], fpgeterrno]);
        Exit;
      end;
    end;
    Result := True;
  finally
    FpClose(Fd);
  end;
end;

{ Delete one exchange entry. See PostRest for the request contract. }
procedure PostFileDelete(const DirectoryName, EntryName: string; Recursive: Boolean;
  AResp: TFPHTTPConnectionResponse);
var
  Base, DescriptorPath, TargetPath: string;
  Fd: LongInt;
  St: Stat;
  IsDirectory, IsLink: Boolean;
  EntryCount, Err: Integer;
  Kind, Reason: string;
begin
  if Cfg.SharedDir = '' then
  begin
    SendErr(AResp, 501, 'file exchange is not configured',
      'set [web] shared = <dir> to the hub shared directory');
    Exit;
  end;
  if not ValidEntryName(EntryName) then
  begin
    SendErr(AResp, 400, 'name must be one entry inside the directory',
      'no slashes, no dot segments: the server anchors the path');
    Exit;
  end;
  { `.` names the exchange root for unassigned files. Any other value is one
    validated directory segment, never a path. }
  if DirectoryName = '.' then
    Base := Cfg.SharedDir
  else
  begin
    if not ValidEntryName(DirectoryName) then
    begin
      SendErr(AResp, 400, 'the directory must be one name, or "." for the root',
        'the exchange has one level per team');
      Exit;
    end;
    Base := IncludeTrailingPathDelimiter(Cfg.SharedDir) + DirectoryName;
  end;

  { Pin the directory and delete through its descriptor. O_NOFOLLOW rejects
    links and O_DIRECTORY rejects non-directories; once open, the inode remains
    stable even if the external name changes. }
  Fd := FpOpen(Base, O_RDONLY or O_DIRECTORY or O_NOFOLLOW);
  if Fd < 0 then
  begin
    St := Default(Stat);
    if (fpLStat(Base, St) = 0) and fpS_ISLNK(St.st_mode) then
      SendErr(AResp, 403, DirectoryName + ' is a symlink: it would leave the shared ' +
        'directory', 'the exchange has one level per team and follows no links')
    else if fpLStat(Base, St) = 0 then
      SendErr(AResp, 404, DirectoryName + ' is not a directory of the exchange',
        'the exchange has one level per team')
    else
      SendErr(AResp, 404, 'no shared directory for ' + DirectoryName,
        'it appears once that team has received a file');
    Exit;
  end;
  try
    DescriptorPath := '/proc/self/fd/' + IntToStr(Fd);
    TargetPath := DescriptorPath + '/' + EntryName;
    St := Default(Stat);
    if fpLStat(TargetPath, St) <> 0 then
    begin
      SendErr(AResp, 404, EntryName + ' is not there', 'nothing was deleted');
      Exit;
    end;
    IsDirectory := fpS_ISDIR(St.st_mode);
    IsLink := fpS_ISLNK(St.st_mode);
    if IsLink then
      Kind := 'link'
    else if IsDirectory then
      Kind := 'dir'
    else if fpS_ISREG(St.st_mode) then
      Kind := 'file'
    else
      Kind := 'special';

    { Remove a directory only when empty unless recursion was explicit. Count
      entries for an actionable message; rmdir remains the atomic authority. }
    if IsDirectory and (not IsLink) then
    begin
      EntryCount := CountEntries(TargetPath);
      if (EntryCount > 0) and (not Recursive) then
      begin
        { Include the entry count in 409 so the operator can judge recursive
          deletion before requesting it. }
        SendErr(AResp, 409, Format('%s is not empty: it holds %d entr%s',
          [EntryName, EntryCount, BoolToStr(EntryCount = 1, 'y', 'ies')]),
          'delete what is inside first, or ask again with recursive:true');
        Exit;
      end;
      if (EntryCount > 0) and Recursive then
      begin
        if not EmptyDirectory(TargetPath, 1, Reason) then
        begin
          { Report partial recursive deletion explicitly because state has
            already changed and must be inspected before retrying. }
          SendErr(AResp, 409, Format('%s was only partly emptied: %s',
            [EntryName, Reason]),
            'some entries were already removed: look at what is left before ' +
            'trying again');
          Exit;
        end;
        Kind := 'dir';
      end;
      if fpRmDir(TargetPath) <> 0 then
      begin
        Err := fpgeterrno;
        if Err = ESysENOTEMPTY then
          SendErr(AResp, 409, EntryName + ' filled up while being deleted',
            'try again: nothing was deleted')
        else
          SendErr(AResp, 403, Format('%s could not be deleted (errno %d)',
            [EntryName, Err]), 'check the permissions of the shared directory');
        Exit;
      end;
    end
    else
    begin
      { unlink removes a link itself without touching an external target. }
      if fpUnlink(TargetPath) <> 0 then
      begin
        Err := fpgeterrno;
        SendErr(AResp, 403, Format('%s could not be deleted (errno %d)',
          [EntryName, Err]), 'check the permissions of the shared directory');
        Exit;
      end;
    end;
  finally
    FpClose(Fd);
  end;

  { Successful destructive operations are the exception to rejection-only
    logging. Include a timestamp because deletion cannot be undone. }
  Writeln(StdErr, Format('pzweb: %s DELETED %s "%s/%s" at the request of %s',
    [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now), Kind, DirectoryName, EntryName, CurPeer]));
  Flush(StdErr);
  SendOk(AResp, '{"removed":' + JsonStr(EntryName) + ',"kind":' + JsonStr(Kind) +
    ',"dir":' + JsonStr(DirectoryName) + '}');
end;

{ A list entry contains a message excerpt and its full text-unit length, not the
  entire body. Server-side truncation avoids transferring full history merely
  to render a summary list. }
function ShapeMsgHead(Src: TJSONObject): TJSONObject;
const
  HEAD_MAX = 240;
var
  Full, Head: string;
  D: TJSONData;
begin
  Result := Pick(Src, ['seq:n', 'ts:s', 'from:s', 'to:s', 'via:s?']);
  Full := '';
  D := Src.Find('text');
  if (D <> nil) and (D.JSONType = jtString) then
    Full := D.AsString
  else
    Missing('a message has no text');
  Head := Full;
  if TextUnits(Full) > HEAD_MAX then
    Head := UTF8Encode(Copy(UTF8Decode(Full), 1, HEAD_MAX));
  Result.Add('head', Head);
  Result.Add('len', TextUnits(Full));
  { State truncation explicitly so the browser need not infer it across Unicode
    length semantics. }
  Result.Add('cut', TextUnits(Full) > HEAD_MAX);
end;

function ShapeMsgArray(Src: TJSONArray): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to Src.Count - 1 do
    if Src.Items[i] is TJSONObject then
      Result.Add(ShapeMsgHead(TJSONObject(Src.Items[i])))
    else
      Missing('a message is not an object');
end;

{ Shape one task according to the contract, including its notes. }
{ Keep one shared field list for cards and summaries so schema additions cannot
  diverge between the two. }
const
  TASK_FIELDS: array[0..10] of string = (
    'id:n', 'title:s', 'team:s', 'state:s', 'hito:s', 'parent:n',
    'wf_name:s', 'wf_step_uid:n', 'created:s', 'closed:s', 'depends:[n]');

{ Full task card with complete notes. }
function ShapeTask(Src: TJSONObject): TJSONObject;
var
  Notes, Out_: TJSONArray;
  i: Integer;
begin
  Result := Pick(Src, TASK_FIELDS);
  Out_ := TJSONArray.Create;
  Notes := ReqArray(Src, 'notes');
  if Notes <> nil then
    for i := 0 to Notes.Count - 1 do
      if Notes.Items[i] is TJSONObject then
        Out_.Add(Pick(TJSONObject(Notes.Items[i]), ['ts:s', 'by:s', 'text:s']))
      else
        Missing('a task note is not an object');
  Result.Add('notes', Out_);
end;

{ Lightweight list item with required note count but no note bodies. }
function ShapeTaskLight(Src: TJSONObject): TJSONObject;
var
  Spec: array of string;
  i: Integer;
begin
  SetLength(Spec, Length(TASK_FIELDS) + 1);
  for i := 0 to High(TASK_FIELDS) do
    Spec[i] := TASK_FIELDS[i];
  Spec[High(Spec)] := 'notes_count:n';
  Result := Pick(Src, Spec);
end;

function ShapeTeamCard(Src: TJSONObject): TJSONObject;
var
  Apps, Out_: TJSONArray;
  i: Integer;
begin
  Result := Pick(Src, ['id:n', 'name:s', 'speciality:s', 'prompt:s', 'parent:s', 'kind:s',
    'session:s', 'launch:s', 'user:s', 'apps:s', 'project:s', 'slave:b',
    'workdir:s', 'groups:s', 'host:s?']);
  Out_ := TJSONArray.Create;
  Apps := ReqArray(Src, 'appsdetail');
  if Apps <> nil then
    for i := 0 to Apps.Count - 1 do
      if Apps.Items[i] is TJSONObject then
        Out_.Add(Pick(TJSONObject(Apps.Items[i]), ['name:s', 'purpose:s']))
      else
        Missing('an appsdetail entry is not an object');
  Result.Add('appsdetail', Out_);
end;

{ APP <-> PROJECT PAIRS. The projector's type codes are s n b [s] [n]: there is
  no code for an array of OBJECTS, so this shape is written by hand, exactly as
  ShapeTeamCard and ShapeMsgArray are. The pair carries 'role' -what that app
  does in THAT project- because the functionality belongs to neither side. }
function ShapePairs(Src: TJSONArray; const What: string): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to Src.Count - 1 do
    if Src.Items[i] is TJSONObject then
      Result.Add(Pick(TJSONObject(Src.Items[i]), ['name:s', 'role:s']))
    else
      { a stray scalar is NOT dropped in silence: the reply would go out as a
        success with one assignment missing }
      Missing('a ' + What + ' entry is not an object');
end;

{ An app's card, with the projects it takes part in. }
function ShapeAppCard(Src: TJSONObject): TJSONObject;
var
  A: TJSONArray;
begin
  Result := Pick(Src, ['name:s', 'team:s', 'purpose:s', 'repo:s', 'path:s',
    'detail:s', 'hasdoc:b']);
  A := ReqArray(Src, 'projects');
  if A <> nil then
    Result.Add('projects', ShapePairs(A, 'app project'))
  else
    Result.Add('projects', TJSONArray.Create);
end;

{ A project's card: its boss, who has it assigned, and the apps that build it. }
function ShapeProjectCard(Src: TJSONObject): TJSONObject;
var
  A: TJSONArray;
begin
  Result := Pick(Src, ['name:s', 'boss:s', 'teams:[s]', 'groups:[s]']);
  A := ReqArray(Src, 'apps');
  if A <> nil then
    Result.Add('apps', ShapePairs(A, 'project app'))
  else
    Result.Add('apps', TJSONArray.Create);
end;

{ Apply one declared shape to each object in an array. }
function ShapeArray(Src: TJSONArray; const Spec: array of string): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to Src.Count - 1 do
    if Src.Items[i] is TJSONObject then
      Result.Add(Pick(TJSONObject(Src.Items[i]), Spec))
    else
      Missing('a list entry is not an object');
end;

{ Project comma-declared members. `hub>web` explicitly renames a field; no
  undeclared name is translated silently. }
function ProjectNamed(const Reply, Spec: string; out DataJson, HubErr: string;
  out Malformed: Boolean): Boolean;
var
  Obj, Out_: TJSONObject;
  Names: TStringArray;
  i, idx, gt, k, colon: Integer;
  Src, Dst, TypeCode: string;
  Arr, Src_: TJSONArray;
  IsObj, IsArr, Opt: Boolean;
begin
  Result := False;
  DataJson := '';
  HubErr := '';
  Malformed := False;
  Obj := ParseObj(Reply);
  if Obj = nil then
  begin
    HubErr := 'unreadable hub reply';
    Malformed := True;
    Exit;
  end;
  try
    { Require Boolean `ok`; a missing or mistyped value is malformed upstream
      data, not a deliberate rejection. A rejection reason must be a string. }
    if not TypeOk(Obj.Find('ok'), 'b') then
    begin
      HubErr := 'hub reply has no boolean ok';
      Malformed := True;
      Exit;
    end;
    if not Obj.Get('ok', False) then
    begin
      if not TypeOk(Obj.Find('error'), 's') then
      begin
        HubErr := 'hub said ok:false without a string error';
        Malformed := True;
        Exit;
      end;
      HubErr := Obj.Get('error', '');
      Exit;
    end;
    ShapeErr := '';
    Names := SplitString(Spec, ',');
    Out_ := TJSONObject.Create;
    try
      for i := 0 to High(Names) do
      begin
        Src := Trim(Names[i]);
        TypeCode := '';
        colon := Pos(':', Src);
        if colon > 0 then
        begin
          TypeCode := Copy(Src, colon + 1, Length(Src));
          Src := Copy(Src, 1, colon - 1);
        end;
        Dst := Src;
        gt := Pos('>', Src);
        if gt > 0 then
        begin
          Dst := Copy(Src, gt + 1, Length(Src));
          Src := Copy(Src, 1, gt - 1);
        end;
        { A trailing `?` marks an optional member for endpoints whose valid shape
          depends on destination type. }
        Opt := (TypeCode <> '') and (TypeCode[Length(TypeCode)] = '?');
        if Opt then
          TypeCode := Copy(TypeCode, 1, Length(TypeCode) - 1);
        idx := Obj.IndexOfName(Src);
        if idx < 0 then
        begin
          if not Opt then
            Missing('hub reply is missing the required member: ' + Src);
          Continue;
        end;
        { Apply the exact contract shape for every structured route. Only scalar
          arrays may be cloned directly; cloning arbitrary objects would publish
          future upstream fields automatically. }
        IsObj := Obj.Items[idx] is TJSONObject;
        IsArr := Obj.Items[idx] is TJSONArray;
        if (Dst = 'workflow') and IsObj then
          Out_.Add(Dst, ShapeWorkflow(TJSONObject(Obj.Items[idx])))
        else if (Dst = 'workflows') and IsArr then
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]),
            ['name:s', 'group:s', 'state:s', 'done:n', 'steps:n', 'note:s']))
        else if (Dst = 'teams') and IsArr then
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]),
            ['id:n', 'name:s', 'speciality:s', 'parent:s', 'open_tasks:n',
             'slave:b', 'workdir:s', 'host:s?']))
        else if (Dst = 'team') and IsObj then
          Out_.Add(Dst, ShapeTeamCard(TJSONObject(Obj.Items[idx])))
        else if (Dst = 'groups') and IsArr then
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]),
            ['name:s', 'project:s', 'boss:s', 'members:[s]', 'member_ids:[n]',
             'excluded:[s]', 'excluded_ids:[n]', 'on_idle:s', 'all_idle:b',
             'any_blocked:b']))
        else if (Dst = 'header') and IsObj then
          Out_.Add(Dst, Pick(TJSONObject(Obj.Items[idx]),
            { `manual` is first|off|always and `group` is own|off; neither is a
              Boolean. }
            ['tasks:b', 'teams:b', 'group:s', 'project:b', 'subs:b',
             'shared:b', 'workflow:b', 'manual:s']))
        else if (Dst = 'messages') and IsArr then
          Out_.Add(Dst, ShapeMsgArray(TJSONArray(Obj.Items[idx])))
        else if (Dst = 'full') and IsArr then
          { Full text is requested one message at a time. }
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]),
            ['seq:n', 'ts:s', 'from:s', 'to:s', 'text:s', 'via:s?']))
        else if (Dst = 'fleet') and IsArr then
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]),
            ['kind:s', 'host:s', 'state:s', 'ver:s', 'teams:s']))
        else if (Dst = 'projects') and IsArr then
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]), ['name:s', 'boss:s']))
        else if (Dst = 'apps') and IsArr then
          Out_.Add(Dst, ShapeArray(TJSONArray(Obj.Items[idx]),
            ['name:s', 'team:s', 'purpose:s', 'hasdoc:b']))
        else if (Dst = 'app') and IsObj then
          Out_.Add(Dst, ShapeAppCard(TJSONObject(Obj.Items[idx])))
        else if (Dst = 'project') and IsObj then
          Out_.Add(Dst, ShapeProjectCard(TJSONObject(Obj.Items[idx])))
        else if (Dst = 'tasks') and IsArr then
        begin
          Arr := TJSONArray.Create;
          Src_ := TJSONArray(Obj.Items[idx]);
          for k := 0 to Src_.Count - 1 do
            if Src_.Items[k] is TJSONObject then
              { Summary carries note count; bodies live at /api/task/<id>. }
              Arr.Add(ShapeTaskLight(TJSONObject(Src_.Items[k])))
            else
              { Reject stray scalar entries instead of silently dropping a task. }
              Missing('a task list entry is not an object');
          Out_.Add(Dst, Arr);
        end
        else if (Dst = 'task') and IsObj then
          Out_.Add(Dst, ShapeTask(TJSONObject(Obj.Items[idx])))
        else if (TypeCode = '') and (IsObj or IsArr) then
        begin
          { A structured member with an unexpected object/array type is malformed
            and must not become an empty successful response. Typed scalar arrays
            are handled by the following branch. }
          Missing('hub field ' + Src + ' has an unexpected type');
          Continue;
        end
        else
        begin
          { Scalars and scalar arrays also require declared types. }
          if TypeCode = '' then
            Missing('no declared type for member ' + Src)
          else if not TypeOk(Obj.Items[idx], TypeCode) then
            Missing(Format('hub field %s is not of type %s', [Src, TypeCode]))
          else
            Out_.Add(Dst, Obj.Items[idx].Clone);
        end;
      end;
      { Missing required fields or wrong types are protocol errors, never partial
        success objects. }
      if ShapeErr <> '' then
      begin
        HubErr := ShapeErr;
        Malformed := True;
        Exit;
      end;
      DataJson := Out_.AsJSON;
      Result := True;
    finally
      Out_.Free;
    end;
  finally
    Obj.Free;
  end;
end;

type
  { Release the accept-time slot in the connection destructor. An admitted peer
    that never sends data must still count until the connection itself closes. }
  TPzWebConn = class(TFPHTTPConnection)
  private
    FPeer: string;
    FReleased: Boolean;
  protected
    procedure SetupSocket; override;
    procedure ReadRequestContent(ARequest: TFPHTTPConnectionRequest); override;
  public
    procedure HandleRequest; override;
    destructor Destroy; override;
    property Peer: string read FPeer write FPeer;
  end;

{ Current connection per thread. AResponse.Connection conflicts with the HTTP
  header property, while the server's one-thread-per-connection model makes this
  thread variable exact. }
threadvar
  CurConn: TPzWebConn;

{ ------------------------------------------------------------------- feed }

{ SSE scope is enforced by the hub from the bound credential. This layer forwards
  received events and does not reimplement authorization. }
procedure ServeFeed(AResp: TFPHTTPConnectionResponse; Since: Int64);
var
  Sock: TInetSocket;
  Out_: TSocketStream;
  Line, Ev, Data, Dir, Reason: string;
  Obj: TJSONObject;
  Seq: Int64;
  FDS: TFDSet;
  TV: TimeVal;
  MaxFd, Sel: LongInt;

  procedure Emit(const S: string);
  begin
    if Length(S) > 0 then
      Out_.WriteBuffer(S[1], Length(S));
  end;

begin
  if CurConn = nil then
    Exit;
  Out_ := CurConn.Socket;
  Sock := nil;
  try
    try
      { Connection establishment may use a short timeout, but an established
        stream handles idle periods separately from closure. }
      Sock := TInetSocket.Create(Cfg.Host, Cfg.Port, 5000);
      { Use a short probe interval because upstream silence is not closure. Each
        interval emits an SSE comment, promptly detecting a departed browser and
        freeing its feed slot. }
      Sock.IOTimeout := FEED_PROBE_MS;
    except
      SendJson(AResp, 502, '{"ok":false,"error":"cannot reach the hub",' +
        '"outcome":"not_sent","fix":"retry: nothing was sent"}');
      Exit;
    end;

    WriteLine(Sock, BuildWatch(Cfg.Secret, Cfg.Self_, Since));
    { Distinguish no upstream answer, malformed response, and explicit watch
      rejection. }
    Line := ReadLine(Sock);
    if Trim(Line) = '' then
    begin
      SendJson(AResp, 502, '{"ok":false,"error":"the hub gave no answer",' +
        '"outcome":"unknown"}');
      Exit;
    end;
    Obj := ParseObj(Line);
    if Obj = nil then
    begin
      SendProtoErr(AResp, 'unreadable hub reply to watch');
      Exit;
    end;
    try
      if not TypeOk(Obj.Find('ok'), 'b') then
      begin
        SendProtoErr(AResp, 'hub watch reply has no boolean ok');
        Exit;
      end;
      if not Obj.Get('ok', False) then
      begin
        { As with reads, an explicit rejection requires a string reason. }
        if not TypeOk(Obj.Find('error'), 's') then
        begin
          SendProtoErr(AResp, 'hub said ok:false without a string error');
          Exit;
        end;
        SendHubErr(AResp, Obj.Get('error', ''));
        Exit;
      end;
    finally
      Obj.Free;
    end;

    { Send headers manually; the streaming body belongs to this routine. }
    AResp.Code := 200;
    AResp.ContentType := 'text/event-stream; charset=utf-8';
    CommonHeaders(AResp);
    AResp.SendHeaders;
    { Log an open channel only after upstream negotiation succeeds. The peer
      comes from the current connection; FeedPeer is the slot table, not text. }
    if CurConn <> nil then
      Writeln(StdErr, Format('pzweb: feed OPEN for %s (cursor %d)',
        [CurConn.Peer, Since]))
    else
      Writeln(StdErr, Format('pzweb: feed OPEN (cursor %d)', [Since]));
    Flush(StdErr);

    { Send an explicit WHATWG event-stream reconnection time instead of relying
      on browser-specific defaults. }
    Emit('retry: 5000' + #10 + #10);

    while not ShutdownRequested do
    begin
      { Wait on upstream and browser descriptors together. An SSE client never
        sends data, so a readable browser socket means it closed; release its
        slot immediately instead of waiting for a later probe write. }
      fpFD_ZERO(FDS);
      fpFD_SET(Sock.Handle, FDS);
      MaxFd := Sock.Handle;
      if Out_ <> nil then
      begin
        fpFD_SET(Out_.Handle, FDS);
        if Out_.Handle > MaxFd then
          MaxFd := Out_.Handle;
      end;
      TV.tv_sec := FEED_PROBE_MS div 1000;
      TV.tv_usec := (FEED_PROBE_MS mod 1000) * 1000;
      Sel := fpSelect(MaxFd + 1, @FDS, nil, nil, @TV);
      if Sel < 0 then
      begin
        { An interrupted select is not closure; wait again. }
        if fpGetErrno = ESysEINTR then
          Continue;
        Break;
      end;
      if (Sel > 0) and (Out_ <> nil) and (fpFD_ISSET(Out_.Handle, FDS) > 0) then
      begin
        { Log immediate browser closure separately from a later write failure. }
        Writeln(StdErr, Format('pzweb: feed CLOSED by %s (browser disconnected)',
          [CurPeer]));
        Flush(StdErr);
        Break;
      end;
      if Sel = 0 then
      begin
        { Both ends are quiet; send a keepalive comment. }
        Emit(': ping' + #10 + #10);
        Continue;
      end;
      Line := ReadLine(Sock);
      if Line = '' then
      begin
        { Empty read with EAGAIN/EWOULDBLOCK means idle, not closed. Any other
          empty result means the hub ended the stream. }
        if (Sock.LastError = ESysEAGAIN) or (Sock.LastError = ESysEWOULDBLOCK) then
        begin
          { A local keepalive also detects browser departure through write error. }
          Emit(': ping' + #10 + #10);
          Continue;
        end;
        Break;                        { the hub actually closed }
      end;
      Obj := ParseObj(Line);
      if Obj = nil then
      begin
        { Never skip an unreadable line: it might be a visible durable message.
          Terminate with a protocol event rather than create silent loss. }
        Emit('event: bye' + #10 +
             'data: {"ev":"bye","reason":"protocol"}' + #10 + #10);
        Exit;
      end;
      try
        Ev := Obj.Get('ev', '');
        if Ev = 'ping' then
        begin
          { SSE comment keeps the connection alive without advancing a cursor. }
          Emit(': ping' + #10 + #10);
          Continue;
        end;
        if Ev = 'gap' then
        begin
          { Rebuild gap events from contract fields. Validate `after` and bound
            `reason` to known values instead of forwarding internal fields or a
            fabricated default cursor. }
          if not CursorOk(Obj.Find('after')) then
          begin
            Emit('event: bye' + #10 +
                 'data: {"ev":"bye","reason":"protocol"}' + #10 + #10);
            Exit;
          end;
          Reason := Obj.Get('reason', '');
          if Pos('|' + Reason + '|',
                 '|queue_overflow|replay_overflow|history_unavailable|cursor_ahead|') = 0 then
          begin
            Emit('event: bye' + #10 +
                 'data: {"ev":"bye","reason":"protocol"}' + #10 + #10);
            Exit;
          end;
          { Emit exactly ev/after/reason and no undeclared convenience fields. }
          Emit('event: gap' + #10 + 'data: {"ev":"gap","after":' +
               IntToStr(Obj.Get('after', Int64(0))) + ',"reason":"' + Reason +
               '"}' + #10 + #10);
          { The gap is terminal; do not follow it with an ordinary closing event. }
          Exit;
        end;
        { Omit only known sys/task events; an unknown event may be durable
          protocol drift and must terminate the feed. }
        if (Ev = 'sys') or (Ev = 'task') then
          Continue;
        if Ev <> 'msg' then
        begin
          Emit('event: bye' + #10 +
               'data: {"ev":"bye","reason":"protocol"}' + #10 + #10);
          Exit;
        end;
        { Rebuild message events from contract fields only. Omit internal `via`
          and derive `dir` locally. Validate all required fields before composing
          so missing data cannot become plausible defaults. }
        if (not CursorOk(Obj.Find('seq'))) or
           (not TypeOk(Obj.Find('ts'), 's')) or
           (not TypeOk(Obj.Find('from'), 's')) or
           (not TypeOk(Obj.Find('to'), 's')) or
           (not TypeOk(Obj.Find('text'), 's')) then
        begin
          Emit('event: bye' + #10 +
               'data: {"ev":"bye","reason":"protocol"}' + #10 + #10);
          Exit;
        end;
        Seq := Obj.Get('seq', Int64(0));
        { Direction has three values: delegated watch may observe third-party
          traffic, which is neither inbound nor outbound for this service. }
        if SameText(Obj.Get('from', ''), Cfg.Self_) then
          Dir := 'out'
        else if SameText(Obj.Get('to', ''), Cfg.Self_) then
          Dir := 'in'
        else
          Dir := 'other';
        Data := '{"ev":"msg","seq":' + IntToStr(Seq) +
                ',"ts":' + JsonStr(Obj.Get('ts', '')) +
                ',"from":' + JsonStr(Obj.Get('from', '')) +
                ',"to":' + JsonStr(Obj.Get('to', '')) +
                ',"text":' + JsonStr(Obj.Get('text', '')) +
                ',"dir":"' + Dir + '"}';
        Emit('id: ' + IntToStr(Seq) + #10 +
             'event: message' + #10 +
             'data: ' + Data + #10 + #10);
      finally
        Obj.Free;
      end;
    end;
    Emit('event: bye' + #10 +
         'data: {"ev":"bye","reason":"closing"}' + #10 + #10);
  finally
    if Sock <> nil then
      Sock.Free;
  end;
end;

{ Decode exactly once, then validate. Double decoding enables encoded traversal;
  no decoding would treat equivalent URLs inconsistently. }
function DecodeOnce(const S: string; out Bad: Boolean): string;
var
  i: Integer;
  Hex: string;
  C: Integer;
begin
  Result := '';
  Bad := False;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '%' then
    begin
      if i + 2 > Length(S) then
      begin
        Bad := True;
        Exit;
      end;
      Hex := Copy(S, i + 1, 2);
      C := StrToIntDef('$' + Hex, -1);
      if C < 0 then
      begin
        Bad := True;
        Exit;
      end;
      { Reject encoded NUL and separators so validation and filesystem parsing
        cannot see different paths. }
      if (C = 0) or (C = Ord('/')) or (C = Ord('\')) then
      begin
        Bad := True;
        Exit;
      end;
      Result := Result + Chr(C);
      Inc(i, 3);
    end
    else
    begin
      { Reject literal backslash and NUL as well as their encoded forms. }
      if (S[i] = '\') or (S[i] = #0) then
      begin
        Bad := True;
        Exit;
      end;
      Result := Result + S[i];
      Inc(i);
    end;
  end;
  { Reject dot segments after decoding. }
  if (Pos('/./', Result) > 0) or (Pos('/../', Result) > 0) or
     (Copy(Result, Length(Result) - 1, 2) = '/.') or
     (Copy(Result, Length(Result) - 2, 3) = '/..') then
    Bad := True;
end;

{ Require one or more ASCII digits. }
function AllDigits(const S: string): Boolean;
var
  i: Integer;
begin
  Result := Length(S) > 0;
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then
      Exit(False);
end;

{ Allow each declared query parameter at most once and reject unknown names so
  callers never believe an ignored filter was applied. }
function QueryOk(AReq: TFPHTTPConnectionRequest; const Allowed: array of string;
  out Bad: string): Boolean;
var
  i, j: Integer;
  Name_: string;
  Known: Boolean;
  Seen: TStringList;
begin
  Result := False;
  Bad := '';
  Seen := TStringList.Create;
  try
    for i := 0 to AReq.QueryFields.Count - 1 do
    begin
      Name_ := AReq.QueryFields.Names[i];
      { Reject an entry without `=`; TStringList otherwise exposes no name and
        would silently skip the request parameter. }
      if Name_ = '' then
      begin
        Bad := 'malformed query entry: ' + AReq.QueryFields[i];
        Exit;
      end;
      Known := False;
      for j := 0 to High(Allowed) do
        if Allowed[j] = Name_ then
          Known := True;
      if not Known then
      begin
        Bad := 'unknown query parameter: ' + Name_;
        Exit;
      end;
      if Seen.IndexOf(Name_) >= 0 then
      begin
        Bad := 'repeated query parameter: ' + Name_;
        Exit;
      end;
      Seen.Add(Name_);
    end;
    Result := True;
  finally
    Seen.Free;
  end;
end;

{ ---------------------------------------------------------------- login }

{ Constant-time comparison for fixed 64-character digests. Length remains
  observable because the loop follows Length(A), so the login name is treated
  as public and no stronger property is claimed. }
function SameSecretly(const A, B: string): Boolean;
var
  i, Diff: Integer;
begin
  Diff := Length(A) xor Length(B);
  for i := 1 to Length(A) do
    if i <= Length(B) then
      Diff := Diff or (Ord(A[i]) xor Ord(B[i]))
    else
      Diff := Diff or Ord(A[i]);
  Result := Diff = 0;
end;

{ HTTP Basic authenticates but does not prevent cross-origin request forgery;
  browsers may send cached credentials ambiently. Every mutation therefore
  requires the exact Origin and rejects an absent value. Traffic is clear HTTP,
  so the private-network transport can expose credentials to an observer. }
function AuthOk(ARequest: TFPHTTPConnectionRequest): Boolean;
var
  Hdr, Raw, User_, Pass: string;
  p: Integer;
  UserOk, PassOk: Boolean;
begin
  Result := False;
  Hdr := Trim(ARequest.Authorization);
  if (Length(Hdr) < 6) or (not SameText(Copy(Hdr, 1, 6), 'Basic ')) then
    Exit;
  Raw := '';
  try
    { Decode in strict mode; the permissive overload accepts invalid padding. }
    Raw := DecodeStringBase64(Trim(Copy(Hdr, 7, Length(Hdr))), True);
  except
    Exit;   { invalid base64 is not a credential }
  end;
  p := Pos(':', Raw);
  if p = 0 then
    Exit;
  User_ := Copy(Raw, 1, p - 1);
  Pass  := Copy(Raw, p + 1, Length(Raw));
  { Perform both checks independently before combining them; short-circuiting
    would skip the digest work for a wrong username and restore timing leakage. }
  UserOk := SameSecretly(User_, Cfg.User);
  PassOk := SameSecretly(LowerCase(Sha256OfString(Pass)), Cfg.PassHash);
  Result := UserOk and PassOk;
end;

{ Keep help beside the routes it documents. Each entry explains what the route
  does, its effect, and any non-obvious hub semantics. Protocol keys remain in
  Spanish for compatibility; all displayed content is English. }
function HelpJson: string;
  function E(const Route, Action, Outcome: string;
    const Caution: string = ''): string;
  begin
    Result := '{"ruta":' + JsonStr(Route) + ',"que":' + JsonStr(Action) +
              ',"pasa":' + JsonStr(Outcome);
    if Caution <> '' then
      Result := Result + ',"ojo":' + JsonStr(Caution);
    Result := Result + '}';
  end;
var
  A: string;
begin
  A :=
    E('GET /api/feed',
      'Live pizarra activity.',
      'Opens a stream of messages as they arrive. Each event says whether it ' +
      'was sent by pzweb, addressed to it, or exchanged by third parties.',
      'Sequence gaps are NORMAL. Only an explicit gap event means data was ' +
      'lost. System and task notices are not included yet: this stream shows ' +
      'durable messages, not literally every event.') +
    ',' + E('GET /api/teams',
      'All teams and their open tasks.', 'Read-only.') +
    ',' + E('POST /api/message',
      'Sends a message to a team, group, the console, or everyone.',
      'The hub journals it as sent by pzweb and delivers it to the destination.',
      'If the outcome is reported as unknown, DO NOT repeat the request. Reload ' +
      'and check whether it arrived; retrying may duplicate it.') +
    ',' + E('POST /api/task',
      'Creates a task for any team, with an optional milestone and parent.',
      'Returns the created task with its numeric identifier.') +
    ',' + E('POST /api/task/<id>/delete',
      'Deletes a task.',
      'The task and its notes leave the list, but history permanently records ' +
      'who deleted it and what it was. This cannot be undone.',
      'Refused when the task belongs to a workflow or has subtasks that would ' +
      'become orphaned. Remove it from the plan first.') +
    ',' + E('POST /api/workflow',
      'Creates a draft workflow.',
      'The workflow starts empty; add steps and then start it.') +
    ',' + E('POST /api/workflow/<name>/insert',
      'Inserts a step BETWEEN existing steps.',
      'Steps that depended on the predecessor are rewired through the new step.') +
    ',' + E('POST /api/workflow/<name>/start',
      'Starts the workflow.',
      'ALL dependency-free steps start, potentially several at once: this is a ' +
      'graph, not a queue. Their teams are notified.',
      'After starting, the workflow is no longer a draft and its steps cannot ' +
      'be added or removed under draft rules.') +
    ',' + E('POST /api/workflow/<name>/abort',
      'Stops a running workflow.',
      'Its teams are notified and its projected tasks are cancelled.') +
    ',' + E('POST /api/workflow/<name>/delete',
      'Deletes the entire workflow.',
      'Its tasks are NOT deleted; they are detached and continue to exist.',
      'Abort a running workflow first so teams are not left waiting for a step ' +
      'that no longer exists.') +
    ',' + E('POST /api/group/<name>/remove',
      'Removes members from a group, or deletes the group.',
      'With members, only those members leave. WITHOUT members, the ENTIRE ' +
      'GROUP IS DELETED.',
      'These are different operations behind the same control; the application ' +
      'asks for confirmation before deleting the group.') +
    ',' + E('POST /api/project/<name>/boss',
      'Sets the team responsible for a project.',
      'If the name does not exist, this CREATES the project.',
      'There is no separate project-create route; assignment creates it.') +
    ',' + E('POST /api/project/<name>/remove',
      'Deletes a project.',
      'The project disappears from the registry.',
      'Refused while any team or group is assigned to it; the response names ' +
      'those references.') +
    ',' + E('POST /api/team/<name>/set',
      'Changes one team field: prompt, speciality, parent, project, slave, ' +
      'workdir, launch, session, or user.',
      'One field per request. A team address cannot change at runtime; the hub ' +
      'requires configuration and restart. Set it when creating the team.',
      'CAUTION: launch is not passive data. It is a COMMAND THE HUB EXECUTES ' +
      'when opening the team session. With an empty user it runs as the daemon ' +
      'account, commonly root on the hub machine.') +
    ',' + E('POST /api/team',
      'Creates a team. Accepts speciality, parent, prompt, host, session, and ' +
      'launch; set remaining fields later through /set.',
      'The team appears in the registry and can receive messages and tasks.',
      'When launch and session are set, the watchdog OPENS that session and ' +
      'EXECUTES the command on the hub machine.') +

    { ---- teams ---- }
    ',' + E('POST /api/team/<name>/remove',
      'Deletes a team from the registry.',
      'It can no longer receive messages or tasks and is removed from its groups.',
      'This is ONE atomic operation across team and groups. Existing tasks are ' +
      'NOT deleted with the team.') +

    { ---- groups ---- }
    ',' + E('POST /api/group',
      'Creates a group with its members.',
      'The group becomes an address that messages all members at once.',
      'At least one member is required; an empty group is refused.') +
    ',' + E('POST /api/group/<name>/boss',
      'Sets or removes the group owner.',
      'The owner receives escalation notices when a workflow step stalls.',
      'An empty value leaves the group WITHOUT an owner, so nobody receives ' +
      'those escalations.') +
    ',' + E('GET /api/project/<name>',
      'Returns one project card: its owner, assignments, and applications.',
      'Lists teams and groups carrying the project plus each application role ' +
      'within that project.',
      'Team and group project values are labels, and the hub does not verify ' +
      'their target when assigned. Application links are real relations and ' +
      'are removed automatically when the project is deleted.') +
    ',' + E('POST /api/shared/delete',
      'PERMANENTLY deletes shared data: this is the only route that removes ' +
      'filesystem content.',
      'The named file or directory is removed, and the operation records what ' +
      'it was and who requested it even on success.',
      'The directory is in the BODY, not the URL, because the root is named "." ' +
      'and browsers normalize /./ away. Deleting a link removes the link, NEVER ' +
      'its target. A directory must be EMPTY or the server returns 409 with its ' +
      'entry count. recursive:true may empty it, but must be requested explicitly.') +
    ',' + E('POST /api/app/<name>/project',
      'Assigns an application to a project with its role there.',
      'The application appears on the project card and the project on the ' +
      'application card; the updated application card is returned.',
      'The role is optional but belongs to the PAIR: one application may serve ' +
      'different purposes in different projects. Reassigning the pair REPLACES ' +
      'its role rather than duplicating it.') +
    ',' + E('POST /api/app/<name>/unproject',
      'Removes an application from one project.',
      'Each disappears from the other card; the application remains linked to ' +
      'its other projects.',
      'Only that pair is removed. Unlink every project separately or delete the ' +
      'application to remove all links.') +
    ',' + E('POST /api/group/<name>/project',
      'Assigns or unassigns a group project.',
      'The group workflows are then counted within that project.',
      'An empty value unassigns it. The name is stored AS GIVEN; the hub does ' +
      'not verify that the project exists, so a typo can leave a dangling label.') +
    ',' + E('POST /api/group/<name>/exclude',
      'MUTES selected members from @group broadcasts.',
      'They remain full members for listings, ownership, and project accounting, ' +
      'but do not receive group sends. They may still read them from their inbox.',
      '`excluded` is the COMPLETE SET and replaces the previous value; empty ' +
      'clears it. Only the group owner or console may change it. Naming a ' +
      'non-member has no effect because broadcasts already skip non-members.') +
    ',' + E('POST /api/group/<name>/onblock',
      'Sets permission-block handling for a group.',
      '`alarm` keeps the normal operator alarm; `log` records blocks quietly; ' +
      '`default` restores normal alarm behavior.',
      'Log-only affects non-excluded group members and suppresses the loud ' +
      'operator alarm; detection and delivery holds remain active.') +

    { ---- tasks ---- }
    ',' + E('POST /api/task/<id>/state',
      'Opens or closes a task.',
      'Closing removes it from the team pending list; opening restores it.',
      'When the task represents a live workflow step, closing it DOES advance ' +
      'the workflow under the same rules as step completion. Violations are refused.') +
    ',' + E('POST /api/task/<id>/note',
      'Adds a note to a task.',
      'The note is signed and dated, and RESETS the inactivity reminder timer.',
      'Notes cannot be edited or deleted; they are part of the history.') +
    ',' + E('POST /api/task/<id>/assign',
      'Reassigns a task or leaves it unassigned.',
      'The new team sees it in its pending list.',
      'An EMPTY team intentionally UNASSIGNS the task. Omit the field if that ' +
      'is not intended.') +

    { ---- workflow steps ---- }
    ',' + E('POST /api/workflow/<name>/step',
      'Appends a step to the workflow.',
      'The step is created with its team and milestone, plus an optional eta.',
      '`after` names dependencies. Without it, the step depends on its predecessor.') +
    ',' + E('POST /api/workflow/<name>/step/<n>/set',
      'Changes one step field: team, milestone, after, or eta.',
      'One field per request; the workflow is persisted with the change.',
      'The new team must belong to the workflow group. Changing after REPLACES ' +
      'the dependency set rather than extending it. Legacy clients may still ' +
      'send hito as an alias for milestone.') +
    ',' + E('POST /api/workflow/<name>/step/<n>/remove',
      'Removes a workflow step.',
      'Existing step IDs remain stable, and dependants INHERIT the removed ' +
      'step dependencies so the graph is reconnected.',
      'Refused only when the dependant is in ANOTHER workflow, which cannot be ' +
      'rewired without modifying that workflow. The error identifies it.') +

    { ---- workflow lifecycle ---- }
    ',' + E('POST /api/workflow/<name>/done',
      'Completes the active step, or the named step, and advances the workflow.',
      'ALL newly unblocked steps start: several may start together, or none if ' +
      'another dependency remains. Each team is notified.',
      'Proof is stored exactly as submitted. It is REQUIRED in strict workflows ' +
      'and completing with proof closes the step; verification is a different ' +
      'operation under /verify. A console-owned step is an APPROVAL GATE that ' +
      'only the console may close.') +
    ',' + E('POST /api/workflow/<name>/verify',
      'Accepts or rejects the REPAIR of a failed step.',
      'With ok the workflow resumes; with fail it stays STOPPED and requires ' +
      'another repair.',
      'Valid only for a STOPPED workflow whose error step is already fixed. ' +
      'The fixer cannot verify it; the error reporter, group owner, or console can.') +
    ',' + E('POST /api/workflow/<name>/error',
      'Reports that a step failed and explains why.',
      'The workflow becomes STOPPED: sibling branches do not advance and no new ' +
      'work is assigned from this workflow.',
      'Nothing is cancelled. Send fixed after repairing the failure.') +
    ',' + E('POST /api/workflow/<name>/fixed',
      'Marks the failed step as repaired.',
      'The workflow does NOT resume yet. The step waits for verification by ' +
      'ANOTHER party, which is notified.',
      'The step owner sends this, and the repair and test description is stored ' +
      'in history.') +
    ',' + E('POST /api/workflow/<name>/set',
      'Changes one workflow-wide field: strict or eta.',
      'strict requires proof when each step closes; it does NOT require a ' +
      'separate verifier. eta is the default deadline for steps without one.',
      'Enabling strict on a running workflow does not retroactively require ' +
      'proof for already completed steps.') +
    ',' + E('POST /api/workflow/<name>/undo',
      'Restores an earlier workflow-history snapshot.',
      'The workflow returns to its state at that point.',
      'The jump is REVERSIBLE: current state is saved as another snapshot before ' +
      'replacement. The number identifies history, not a step.') +
    ',' + E('POST /api/workflow/<name>/restore',
      'Loads a saved workflow card as live state.',
      'If the workflow exists, the submitted card REPLACES it completely; ' +
      'otherwise it is recreated.',
      'Do not confuse this with undo: undo selects a numbered history point, ' +
      'while restore submits the ENTIRE card and ignores history. Replacing an ' +
      'existing workflow requires its group owner.') +
    ',' + E('POST /api/workflow/<name>/clone',
      'Copies the workflow under another name.',
      'The clone is a draft with the same steps and no history.',
      'It may target another group, but every step team must also belong there.') +

    { ---- application registry ---- }
    ',' + E('POST /api/app',
      'Registers an application and assigns its team.',
      'It appears with its repository, path, and purpose.',
      'The team must already exist.') +
    ',' + E('POST /api/app/<name>/set',
      'Changes one application field: team, repo, path, purpose, or detail.',
      'One field per request.',
      'An empty value DELETES that field intentionally. Omit the field if that ' +
      'is not intended.') +
    ',' + E('POST /api/app/<name>/doc',
      'Writes the application manual.',
      'Replaces the complete manual and saves the previous version in history.',
      'Text is stored EXACTLY as submitted, including indentation and newlines. ' +
      'This is replacement, not append.') +
    ',' + E('POST /api/app/<name>/undo',
      'Undoes ONE application-history change.',
      'Depending on the selected point, restores either a FIELD value or a ' +
      'previous MANUAL version; both share one history.',
      'Creation and deletion CANNOT be undone. Use a snapshot number from the ' +
      'application history.') +
    ',' + E('POST /api/app/<name>/remove',
      'Deletes an application from the registry.',
      'The application and its manual disappear from the list.',
      'HISTORY remains as a permanent deletion record. Source code and the ' +
      'repository are untouched: this route changes the registry, not disk.') +

    ',' + E('POST /api/inbox/ack',
      'Marks this console inbox as read through the selected message.',
      'Those messages stop counting as pending.',
      'Viewing the inbox does NOT acknowledge messages. Acknowledgement is ' +
      'explicit and cannot be undone.') +
    ',' + E('POST /api/upload',
      'Uploads a file to a team shared directory in chunks.',
      'Each chunk carries its offset. The LAST chunk carries the complete-file ' +
      'SHA-256, and only then is the file published. Base64 expands data by 4/3; ' +
      'send 32 KB source chunks rather than 48 KB.',
      'If the received content does not match the hash, NOTHING is published ' +
      'and partial data is removed. Incomplete uploads expire after one hour.') +

    { Explicitly allow the three resource classes used by the application. }
    ',' + E('POST /api/header',
      'Changes what appears in the header attached to EVERY message.',
      'The change affects the ENTIRE fleet from the next message onward.',
      'One field per request. The response includes the complete updated header.') +
    ',' + E('POST /api/backup',
      'Writes a core operational-state backup to the selected directory.',
      'Returns its location, piece count, and verification instructions.',
      'THE BACKUP CONTAINS BUS SECRETS. Treat it as a credential: its holder can ' +
      'speak as any team. The hub refuses to write inside a Git repository ' +
      'unless force is explicitly requested.') +
    ',' + E('POST /api/fleet/update',
      'Tells fleet daemons to update to the PUBLISHED release.',
      'Each selected host downloads the binary and RESTARTS, appearing offline ' +
      'briefly. Without a team, the request targets all hosts.',
      'This route does not choose a version; it uses the release published by ' +
      'the hub. Agent sessions are untouched; only their daemons restart.');
  Result := '{"ayuda":[' + A + ']}';
end;

{ ------------------------------------------------------------- server }

{ ------------- READ A TYPED REQUEST-BODY FIELD -------------

  fpjson's defaulted Body.Get overload searches by the default value's type.
  Numeric input could therefore appear absent and a mistyped value could become
  an empty string. These helpers distinguish absent, present-and-valid, and
  present-with-wrong-type so commands cannot silently change meaning. }

{ Accept only declared keys. Reject misspellings instead of returning 200 for a
  request whose ignored field changed its intended meaning. }
function OnlyKeys(Body: TJSONObject; const Allowed: array of string;
  AResp: TFPHTTPConnectionResponse): Boolean;
var
  i, j: Integer;
  K: string;
  Ok: Boolean;
begin
  Result := False;
  for i := 0 to Body.Count - 1 do
  begin
    K := Body.Names[i];
    Ok := False;
    for j := 0 to High(Allowed) do
      if Allowed[j] = K then
        Ok := True;
    if not Ok then
    begin
      SendErr(AResp, 400, 'unknown field in body: ' + K,
        'check the spelling; this route accepts only its declared fields');
      Exit;
    end;
  end;
  Result := True;
end;

{ String field. Present distinguishes absence; the caller decides whether empty
  is valid for this route. }
function StrField(Body: TJSONObject; const K: string; out V: string;
  out Present: Boolean; AResp: TFPHTTPConnectionResponse): Boolean;
var
  D: TJSONData;
begin
  V := '';
  Present := False;
  Result := True;
  D := Body.Find(K);
  if D = nil then
    Exit;
  Present := True;
  if D.JSONType <> jtString then
  begin
    SendErr(AResp, 400, 'field ' + K + ' must be a string',
      'send it quoted; a number or null is not an empty value');
    Exit(False);
  end;
  { Keep the raw value. Route-specific code may normalize identifiers, while
    free-form text must preserve indentation and whitespace. }
  V := D.AsString;
end;

{ The public HTTP API uses `milestone`; older clients used the hub's wire name
  `hito`. Accept either spelling but never let two conflicting values collapse
  into one silently. The hub request remains unchanged. }
function MilestoneField(Body: TJSONObject; out V: string; Required: Boolean;
  AResp: TFPHTTPConnectionResponse): Boolean;
var
  Present: Boolean;
begin
  Result := False;
  V := '';
  if (Body.Find('milestone') <> nil) and (Body.Find('hito') <> nil) then
  begin
    SendErr(AResp, 400, 'milestone and hito are aliases; send only one',
      'use milestone, or keep hito only for a legacy client');
    Exit;
  end;
  if Body.Find('milestone') <> nil then
  begin
    if not StrField(Body, 'milestone', V, Present, AResp) then
      Exit;
  end
  else if not StrField(Body, 'hito', V, Present, AResp) then
    Exit;
  V := Trim(V);
  if Required and ((not Present) or (V = '')) then
  begin
    SendErr(AResp, 400, 'missing or empty field: milestone',
      'required strings cannot be empty');
    Exit;
  end;
  if TextUnits(V) > 120 then
  begin
    SendErr(AResp, 400, 'milestone is longer than 120 characters',
      'shorten it');
    Exit;
  end;
  Result := True;
end;

{ Integer field with a declared minimum. IDs and steps begin at one, while byte
  offsets legitimately begin at zero. }
function NumField(Body: TJSONObject; const K: string; out N: Integer;
  out Present: Boolean; AResp: TFPHTTPConnectionResponse;
  MinV: Integer = 1): Boolean;
var
  D: TJSONData;
begin
  N := 0;
  Present := False;
  Result := True;
  D := Body.Find(K);
  if D = nil then
    Exit;
  Present := True;
  if (D.JSONType <> jtNumber) or (Frac(D.AsFloat) <> 0) or
     (D.AsFloat < MinV) or (D.AsFloat > 2147483647) then
  begin
    if MinV <= 0 then
      SendErr(AResp, 400, 'field ' + K + ' must be a whole number >= ' +
        IntToStr(MinV), 'send it as a JSON number, not a string')
    else
      SendErr(AResp, 400, 'field ' + K + ' must be a positive whole number',
        'send it as a JSON number, not a string');
    Exit(False);
  end;
  N := D.AsInteger;
end;

{ Send the mutation, then fetch its card. The mutation is the commit point; a
  failed refresh yields applied_stale so the UI does not repeat completed work. }
function MutateWf(const Req, Name_: string;
  AResp: TFPHTTPConnectionResponse): Boolean;
var
  Reply, DataJson, HubErr: string;
  Sent, Malformed: Boolean;
begin
  Result := True;
  if not Bus(Req, Reply, Sent) then
  begin
    SendBusFail(AResp, Sent);
    Exit;
  end;
  if not ProjectNamed(Reply, 'ok:b', DataJson, HubErr, Malformed) then
  begin
    { The request was sent; a malformed response means unknown outcome, never
      `nothing was written`. }
    if Malformed then
      SendJson(AResp, 502, '{"ok":false,"error":' + JsonStr(HubErr) +
        ',"outcome":"unknown"}')
    else
      SendHubErr(AResp, HubErr);
    Exit;
  end;
  { Mutation applied; fetch the resulting card. }
  if not Bus(BuildWfShow(Cfg.Secret, Cfg.Self_, Name_), Reply, Sent) then
  begin
    SendJson(AResp, 200, '{"ok":true,"data":null,"outcome":"applied_stale"' +
      ',"fix":"the operation was applied; reload the view"}');
    Exit;
  end;
  if ProjectNamed(Reply, 'workflow,tree:s', DataJson, HubErr, Malformed) then
    SendOk(AResp, DataJson)
  else
    SendJson(AResp, 200, '{"ok":true,"data":null,"outcome":"applied_stale"' +
      ',"fix":"the operation was applied; reload the view"}');
end;

{ Deletion does not refresh a vanished object; return its name as declared by
  the contract. }
procedure PostWfDelete(const Nm: string; AResp: TFPHTTPConnectionResponse);
var
  Reply, DataJson, HubErr: string;
  Sent, Malformed: Boolean;
begin
  if not Bus(BuildWfDelete(Cfg.Secret, Cfg.Self_, Nm, ''), Reply, Sent) then
  begin
    SendBusFail(AResp, Sent);
    Exit;
  end;
  if ProjectNamed(Reply, 'ok:b', DataJson, HubErr, Malformed) then
    SendOk(AResp, '{"removed":' + JsonStr(Nm) + '}')
  else if Malformed then
    { Deletion was sent; malformed acknowledgement is not proof it failed. }
    SendJson(AResp, 502, '{"ok":false,"error":' + JsonStr(HubErr) +
      ',"outcome":"unknown"}')
  else
    SendHubErr(AResp, HubErr);
end;

{ Workflow write routes. Return False when the route belongs elsewhere. }
function PostWorkflow(const Seg: TStringArray; Body: TJSONObject;
  AResp: TFPHTTPConnectionResponse): Boolean;
var
  n: Integer;
  Nm, Fld, Val, Txt, Res: string;
  StepN: Integer;
  Pres: Boolean;

  { Required string: present, nonempty, and within its limit. }
  function Str(const K: string; out V: string; Max: Integer = 0;
    Norm: Boolean = True): Boolean;
  var
    Pres2: Boolean;
  begin
    Result := False;
    if not StrField(Body, K, V, Pres2, AResp) then
      Exit;
    { Norm=False preserves whitespace in free-form text. }
    if Norm then
      V := Trim(V);
    if (not Pres2) or (Trim(V) = '') then
    begin
      SendErr(AResp, 400, 'missing or empty field: ' + K,
        'required strings cannot be empty');
      Exit;
    end;
    if (Max > 0) and (TextUnits(V) > Max) then
    begin
      SendErr(AResp, 400, Format('%s is longer than %d characters', [K, Max]),
        'shorten it');
      Exit;
    end;
    Result := True;
  end;

  { Optional string: when present it must have the correct type. }
  function Opt(const K: string; out V: string; Max: Integer = 0;
    Norm: Boolean = True): Boolean;
  var
    Pres2: Boolean;
  begin
    Result := False;
    if not StrField(Body, K, V, Pres2, AResp) then
      Exit;
    if Norm then
      V := Trim(V);
    if (Max > 0) and (TextUnits(V) > Max) then
    begin
      SendErr(AResp, 400, Format('%s is longer than %d characters', [K, Max]),
        'shorten it');
      Exit;
    end;
    Result := True;
  end;

  { `-` is an HTTP-layer value translated to an omitted bus step. Accept either
    a numeric step or the literal dash; never drop a numeric choice as absent. }
  function StepOf(const K: string; out N2: Integer): Boolean;
  var
    D: TJSONData;
  begin
    N2 := 0;
    Result := True;
    D := Body.Find(K);
    if D = nil then
      Exit;
    if D.JSONType = jtString then
    begin
      if Trim(D.AsString) = '-' then
        Exit;
      Result := False;
      SendErr(AResp, 400, K + ' as text may only be "-"',
        'send the step as a JSON number, or "-" for the active one');
      Exit;
    end;
    { Enforce the upper bound before conversion so overflow cannot turn an
      impossible step into an omitted step that targets the active one. }
    if (D.JSONType <> jtNumber) or (Frac(D.AsFloat) <> 0) or
       (D.AsFloat < 1) or (D.AsFloat > 2147483647) then
    begin
      Result := False;
      SendErr(AResp, 400, K + ' must be a positive step number or "-"',
        'use the step number as a number, or "-" for the active one');
      Exit;
    end;
    N2 := D.AsInteger;
  end;

begin
  Result := True;
  Fld := '';
  Txt := '';
  Val := '';
  Res := '';
  n := Length(Seg);
  if (n < 1) or (Seg[0] <> 'workflow') then
    Exit(False);

  if n = 1 then          { POST /api/workflow -> create }
  begin
    if not OnlyKeys(Body, ['name', 'group'], AResp) then Exit;
    if not Str('name', Nm) then Exit;
    if not Str('group', Val) then Exit;
    MutateWf(BuildWfCreate(Cfg.Secret, Cfg.Self_, Nm, Val), Nm, AResp);
    Exit;
  end;

  Nm := Seg[1];
  if n = 3 then
  begin
    if Seg[2] = 'step' then
    begin
      if not OnlyKeys(Body, ['team', 'milestone', 'hito', 'after', 'eta'],
                          AResp) then Exit;
      if not Str('team', Val) then Exit;
      if not MilestoneField(Body, Txt, True, AResp) then Exit;
      if not Opt('after', Res) then Exit;
      if not Opt('eta', Fld) then Exit;
      MutateWf(BuildWfStep(Cfg.Secret, Cfg.Self_, Nm, Val, Txt, Res, Fld),
        Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'insert' then
    begin
      if not OnlyKeys(Body, ['team', 'milestone', 'hito', 'after', 'eta'],
                          AResp) then Exit;
      if not Str('team', Val) then Exit;
      { Apply the same milestone limit to append and insert. }
      if not MilestoneField(Body, Txt, True, AResp) then Exit;
      { Forward the declared `eta` so a successful response reflects the
        operator's actual deadline. }
      if not Opt('eta', Fld) then Exit;
      { Insert `after` is one step number, unlike the append dependency list. }
      if not NumField(Body, 'after', StepN, Pres, AResp) then Exit;
      if not Pres then
      begin
        SendErr(AResp, 400, 'insert needs after: the step to insert behind',
          'give a positive step number');
        Exit;
      end;
      MutateWf(BuildWfInsert(Cfg.Secret, Cfg.Self_, Nm, Val, Txt, StepN, Fld),
        Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'start' then
    begin
      { This route has no body fields; extra data changes the request. }
      if not OnlyKeys(Body, [], AResp) then Exit;
      MutateWf(BuildWfStart(Cfg.Secret, Cfg.Self_, Nm), Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'done' then
    begin
      if not OnlyKeys(Body, ['step', 'proof'], AResp) then Exit;
      if not StepOf('step', StepN) then Exit;
      { Proof is free-form text whose indentation belongs to its author. }
      if not Opt('proof', Txt, 4096, False) then Exit;
      MutateWf(BuildWfDone(Cfg.Secret, Cfg.Self_, Nm, StepN, Txt), Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'error' then
    begin
      if not OnlyKeys(Body, ['why', 'step'], AResp) then Exit;
      if not Str('why', Txt, 4096) then Exit;
      if not StepOf('step', StepN) then Exit;
      MutateWf(BuildWfError(Cfg.Secret, Cfg.Self_, Nm, Txt, StepN), Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'fixed' then
    begin
      if not OnlyKeys(Body, ['text'], AResp) then Exit;
      if not Str('text', Txt, 4096, False) then Exit;
      MutateWf(BuildWfFixed(Cfg.Secret, Cfg.Self_, Nm, Txt), Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'abort' then
    begin
      if not OnlyKeys(Body, ['why'], AResp) then Exit;
      if not Str('why', Txt, 4096) then Exit;
      MutateWf(BuildWfAbort(Cfg.Secret, Cfg.Self_, Nm, Txt), Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'delete' then
    begin
      if not OnlyKeys(Body, [], AResp) then Exit;
      { The only workflow mutation that cannot refresh a deleted card. }
      PostWfDelete(Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'verify' then
    begin
      if not OnlyKeys(Body, ['result', 'note'], AResp) then Exit;
      Res := LowerCase(Trim(Body.Get('result', '')));
      if (Res <> 'ok') and (Res <> 'fail') then
      begin
        SendErr(AResp, 400, 'result must be ok or fail',
          'verify carries the verdict, not a step number');
        Exit;
      end;
      if not Opt('note', Txt, 4096, False) then Exit;
      MutateWf(BuildWfVerify(Cfg.Secret, Cfg.Self_, Nm, Res = 'ok', Txt),
        Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'undo' then
    begin
      if not OnlyKeys(Body, ['snapshot'], AResp) then Exit;
      if not NumField(Body, 'snapshot', StepN, Pres, AResp) then Exit;
      MutateWf(BuildWfUndo(Cfg.Secret, Cfg.Self_, Nm, StepN), Nm, AResp);
      Exit;
    end;
    { Restore and undo are distinct: undo selects a numbered history point;
      restore submits a complete saved card. The hub enforces ownership. }
    if Seg[2] = 'restore' then
    begin
      if not OnlyKeys(Body, ['data'], AResp) then Exit;
      { Raw JSON card text must not be trimmed here. }
      if not Str('data', Txt, 0, False) then Exit;
      MutateWf(BuildWfRestore(Cfg.Secret, Cfg.Self_, Nm, Txt), Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'clone' then
    begin
      if not OnlyKeys(Body, ['to', 'group'], AResp) then Exit;
      if not Str('to', Val) then Exit;
      if not Opt('group', Txt) then Exit;
      MutateWf(BuildWfClone(Cfg.Secret, Cfg.Self_, Nm, Val, Txt), Val, AResp);
      Exit;
    end;
    if Seg[2] = 'set' then
    begin
      { Whole-plan setting uses step zero. }
      if not OnlyKeys(Body, ['field', 'value'], AResp) then Exit;
      if not Str('field', Fld) then Exit;
      if (Fld <> 'strict') and (Fld <> 'eta') then
      begin
        SendErr(AResp, 400, 'workflow field must be strict or eta',
          'step fields go to /step/<n>/set');
        Exit;
      end;
      if not Opt('value', Txt) then Exit;
      MutateWf(BuildWfSet(Cfg.Secret, Cfg.Self_, Nm, 0, Fld, Txt), Nm, AResp);
      Exit;
    end;
  end;

  { ---- step routes: /workflow/<name>/step/<n>/set | remove ---- }
  if (n = 5) and (Seg[2] = 'step') then
  begin
    if not AllDigits(Seg[3]) then
    begin
      SendErr(AResp, 400, 'step must be a positive decimal',
        'use /api/workflow/<name>/step/<n>/...');
      Exit;
    end;
    StepN := StrToIntDef(Seg[3], 0);
    if StepN <= 0 then
    begin
      SendErr(AResp, 400, 'step must be a positive decimal', 'use a step number');
      Exit;
    end;
    if Seg[4] = 'set' then
    begin
      if not OnlyKeys(Body, ['field', 'value'], AResp) then Exit;
      if not Str('field', Fld) then Exit;
      if Fld = 'milestone' then
        Fld := 'hito';
      if (Fld <> 'team') and (Fld <> 'hito') and (Fld <> 'after') and
         (Fld <> 'eta') then
      begin
        SendErr(AResp, 400,
          'step field must be team, milestone, after or eta',
          'legacy hito is also accepted; plan fields go to ' +
          '/api/workflow/<name>/set');
        Exit;
      end;
      { The limit belongs to the field: editing a milestone must honor the same
        120-character bound as creating it. }
      if Fld = 'hito' then
      begin
        if not Opt('value', Txt, 120) then Exit;
      end
      else
        if not Opt('value', Txt) then Exit;
      MutateWf(BuildWfSet(Cfg.Secret, Cfg.Self_, Nm, StepN, Fld, Txt),
        Nm, AResp);
      Exit;
    end;
    if Seg[4] = 'remove' then
    begin
      if not OnlyKeys(Body, [], AResp) then Exit;
      MutateWf(BuildWfRemove(Cfg.Secret, Cfg.Self_, Nm, StepN), Nm, AResp);
      Exit;
    end;
  end;
  Result := False;
end;

{ Generic counterpart to MutateWf: mutate, then request the object's card. }
{ The hub lists groups and projects, while the UI needs the changed object. Find
  it by name in the list and wrap it under the singular contract key. }
function PickFromList(const DataJson, ListKey, OneKey, Name_: string;
  out Out_: string): Boolean;
var
  D, Item: TJSONData;
  A: TJSONArray;
  i: Integer;
begin
  Result := False;
  Out_ := '';
  D := GetJSON(DataJson);
  if D = nil then
    Exit;
  try
    if D.JSONType <> jtObject then
      Exit;
    Item := TJSONObject(D).Find(ListKey);
    if (Item = nil) or (Item.JSONType <> jtArray) then
      Exit;
    A := TJSONArray(Item);
    for i := 0 to A.Count - 1 do
      if (A.Items[i].JSONType = jtObject) and
         SameText(TJSONObject(A.Items[i]).Get('name', ''), Name_) then
      begin
        Out_ := '{"' + OneKey + '":' + A.Items[i].AsJSON + '}';
        Exit(True);
      end;
  finally
    D.Free;
  end;
end;

function MutateThen(const Req, ShowReq, Members: string;
  AResp: TFPHTTPConnectionResponse; const PickKey: string = '';
  const PickOne: string = ''; const PickName: string = ''): Boolean;
var
  Reply, DataJson, HubErr: string;
  Sent, Malformed: Boolean;

  { The mutation was sent. Any later failure is projection failure and must not
    be described as unapplied, which would invite a duplicate retry. }
  procedure RespondAppliedStale;
  begin
    SendJson(AResp, 200, '{"ok":true,"data":null,"outcome":"applied_stale"' +
      ',"fix":"the operation was applied; reload the view"}');
  end;

begin
  Result := True;
  if not Bus(Req, Reply, Sent) then
  begin
    SendBusFail(AResp, Sent);
    Exit;
  end;

  { A malformed acknowledgement after sending has unknown outcome, never
    `nothing was written`. }
  if not ProjectNamed(Reply, 'ok:b', DataJson, HubErr, Malformed) then
  begin
    if Malformed then
      SendJson(AResp, 502, '{"ok":false,"error":' + JsonStr(HubErr) +
        ',"outcome":"unknown"}')
    else
      SendHubErr(AResp, HubErr);   { a deliberate hub rejection is definitive }
    Exit;
  end;

  if ShowReq = 'self' then
  begin
    { The command response contains its own card; malformed projection does not
      undo the applied mutation. }
    if ProjectNamed(Reply, Members, DataJson, HubErr, Malformed) and
       (DataJson <> '{}') then
      SendOk(AResp, DataJson)
    else
      RespondAppliedStale;
    Exit;
  end;

  if ShowReq = '' then
  begin
    if Copy(Members, 1, 8) = 'removed:' then
      SendOk(AResp, '{"removed":' + JsonStr(Copy(Members, 9, Length(Members))) + '}')
    else if Copy(Members, 1, 6) = 'acked:' then
      { `acked:` has its own response shape. Emit the numeric acknowledged
        sequence required by the contract instead of forwarding a bare hub ok. }
      SendOk(AResp, '{"acked":' +
        IntToStr(StrToInt64Def(Copy(Members, 7, Length(Members)), 0)) + '}')
    else
      SendOk(AResp, DataJson);
    Exit;
  end;

  if not Bus(ShowReq, Reply, Sent) then
  begin
    RespondAppliedStale;
    Exit;
  end;
  if not ProjectNamed(Reply, Members, DataJson, HubErr, Malformed) then
  begin
    RespondAppliedStale;
    Exit;
  end;
  if PickKey <> '' then
  begin
    if PickFromList(DataJson, PickKey, PickOne, PickName, HubErr) then
      SendOk(AResp, HubErr)
    else
      { Absence from the refreshed list proves removal only for a removal request.
        After creation it means applied state whose card cannot be certified. }
      RespondAppliedStale;
  end
  else
    SendOk(AResp, DataJson);
end;


{ A send has exactly one complete valid form: direct team delivery carries
  seq/queued, while group fan-out carries broadcast/queued_count. }
procedure PostMessage(const Dest, Text: string;
  AResp: TFPHTTPConnectionResponse);
var
  Reply, HubErr, DataJson: string;
  Sent, Malformed: Boolean;
  Obj: TJSONObject;
  DirectForm, BroadcastForm: Boolean;
begin
  if not Bus(BuildSend(Cfg.Secret, Cfg.Self_, Dest, Text), Reply, Sent) then
  begin
    SendBusFail(AResp, Sent);
    Exit;
  end;
  if not ProjectNamed(Reply, 'ok:b', DataJson, HubErr, Malformed) then
  begin
    if Malformed then
      SendJson(AResp, 502, '{"ok":false,"error":' + JsonStr(HubErr) +
        ',"outcome":"unknown"}')
    else
      SendHubErr(AResp, HubErr);
    Exit;
  end;
  Obj := ParseObj(Reply);
  if Obj = nil then
  begin
    SendJson(AResp, 200, '{"ok":true,"data":null,"outcome":"applied_stale"' +
      ',"fix":"the message was sent; reload to see it"}');
    Exit;
  end;
  try
    DirectForm  := CursorOk(Obj.Find('seq')) and TypeOk(Obj.Find('queued'), 'b');
    BroadcastForm := CursorOk(Obj.Find('broadcast')) and
                CursorOk(Obj.Find('queued_count'));
    { Exactly one form must match. Both or neither means malformed acknowledgement
      after a message that was already sent. }
    if DirectForm = BroadcastForm then
    begin
      SendJson(AResp, 200, '{"ok":true,"data":null,"outcome":"applied_stale"' +
        ',"fix":"the message was sent but its acknowledgement is malformed; reload"}');
      Exit;
    end;
    if DirectForm then
      SendOk(AResp, '{"seq":' + IntToStr(Obj.Get('seq', Int64(0))) +
        ',"queued":' + LowerCase(BoolToStr(Obj.Get('queued', False), True)) + '}')
    else
      SendOk(AResp, '{"broadcast":' + IntToStr(Obj.Get('broadcast', Int64(0))) +
        ',"queued_count":' + IntToStr(Obj.Get('queued_count', Int64(0))) + '}');
  finally
    Obj.Free;
  end;
end;

{ Task and registry write routes return False when the route belongs elsewhere. }
{ Greatest sequence in the just-served unread window, or zero for no valid data.
  This is the maximum safe acknowledgement because later messages were unseen. }
function UnreadCeiling(const Reply: string): Int64;
var
  D, Item: TJSONData;
  A: TJSONArray;
  i: Integer;
  Sq: Int64;
begin
  Result := 0;
  D := GetJSON(Reply);
  if D = nil then
    Exit;
  try
    if D.JSONType <> jtObject then
      Exit;
    Item := TJSONObject(D).Find('messages');
    if (Item = nil) or (Item.JSONType <> jtArray) then
      Exit;
    A := TJSONArray(Item);
    for i := 0 to A.Count - 1 do
      if A.Items[i].JSONType = jtObject then
      begin
        Sq := TJSONObject(A.Items[i]).Get('seq', Int64(0));
        if Sq > Result then
          Result := Sq;
      end;
  finally
    D.Free;
  end;
end;

function PostRest(const Seg: TStringArray; Body: TJSONObject;
  AResp: TFPHTTPConnectionResponse): Boolean;
var
  n, Id, ParentN: Integer;
  Nm, V, V2, Milestone, ChunkData, Checksum: string;
  HostName, SessionName, LaunchCommand, PromptText: string;
  AppPath, Purpose, Detail: string;
  Pres, ForceFlag: Boolean;
  AckPeek: string;
  AckSent: Boolean;
  AckCeiling: Int64;

  { As in workflow routes: require a present string of the declared type,
    nonempty and within its field limit. }
  function Str(const K: string; out Out_: string; Max: Integer = 0;
    Norm: Boolean = True): Boolean;
  var
    P2: Boolean;
  begin
    Result := False;
    if not StrField(Body, K, Out_, P2, AResp) then Exit;
    if Norm then
      Out_ := Trim(Out_);
    if (not P2) or (Trim(Out_) = '') then
    begin
      SendErr(AResp, 400, 'missing or empty field: ' + K,
        'required strings cannot be empty');
      Exit;
    end;
    if (Max > 0) and (TextUnits(Out_) > Max) then
    begin
      SendErr(AResp, 400, Format('%s is longer than %d characters', [K, Max]),
        'shorten it');
      Exit;
    end;
    Result := True;
  end;

  function Opt(const K: string; out Out_: string; Max: Integer = 0;
    Norm: Boolean = True): Boolean;
  var
    P2: Boolean;
  begin
    Result := False;
    if not StrField(Body, K, Out_, P2, AResp) then Exit;
    if Norm then
      Out_ := Trim(Out_);
    if (Max > 0) and (TextUnits(Out_) > Max) then
    begin
      SendErr(AResp, 400, Format('%s is longer than %d characters', [K, Max]),
        'shorten it');
      Exit;
    end;
    Result := True;
  end;

  { Optional Boolean with strict type checking; a quoted value must not become
    silently absent. }
  function Flag(const K: string; out B: Boolean): Boolean;
  var
    D: TJSONData;
  begin
    B := False;
    Result := True;
    D := Body.Find(K);
    if D = nil then
      Exit;
    if D.JSONType <> jtBoolean then
    begin
      SendErr(AResp, 400, 'field ' + K + ' must be true or false',
        'send it unquoted; a string is not a boolean');
      Exit(False);
    end;
    B := D.AsBoolean;
  end;

  function IdOf(const Sg: string; out N2: Integer): Boolean;
  begin
    N2 := 0;
    Result := AllDigits(Sg);
    if Result then
      N2 := StrToIntDef(Sg, 0);
    Result := Result and (N2 > 0);
    if not Result then
      SendErr(AResp, 400, 'id must be a positive decimal', 'use /api/task/<n>');
  end;

  { `members` is a contract array. Preserve presence separately from its value:
    absent means delete the group, while a present list removes members. Reject
    malformed arrays rather than collapsing them into the destructive case. }
  function Members(out Csv: string; out Present: Boolean): Boolean;
  var
    D: TJSONData;
    A: TJSONArray;
    k2: Integer;
    It: string;
  begin
    Csv := '';
    Present := False;
    Result := True;
    D := Body.Find('members');
    if D = nil then
      Exit;
    Present := True;
    if D.JSONType <> jtArray then
    begin
      SendErr(AResp, 400, 'members must be an array of team names',
        'send {"members":["team-one","team-two"]}');
      Exit(False);
    end;
    A := TJSONArray(D);
    for k2 := 0 to A.Count - 1 do
    begin
      if A.Items[k2].JSONType <> jtString then
      begin
        SendErr(AResp, 400, 'members must contain only team names',
          'every entry has to be a string');
        Exit(False);
      end;
      It := Trim(A.Items[k2].AsString);
      if It = '' then
      begin
        SendErr(AResp, 400, 'members cannot contain an empty name',
          'drop the empty entry');
        Exit(False);
      end;
      if Csv <> '' then
        Csv := Csv + ',';
      Csv := Csv + It;
    end;
  end;

  { Apply the HTTP field ceiling here instead of forwarding upstream fields that
    the web API intentionally does not expose. Read `field` with its real type. }
  function FieldIn(const Allowed: string; out F: string): Boolean;
  var
    FPres: Boolean;
  begin
    if not StrField(Body, 'field', F, FPres, AResp) then
    begin
      Result := False;
      Exit;
    end;
    F := LowerCase(Trim(F));
    Result := (F <> '') and (Pos('|' + F + '|', Allowed) > 0);
    if not Result then
      SendErr(AResp, 400, 'field not settable from the web: ' + F,
        'allowed: ' + StringReplace(Copy(Allowed, 2, Length(Allowed) - 2),
          '|', ', ', [rfReplaceAll]));
  end;

begin
  Result := True;
  V := ''; V2 := ''; Milestone := ''; ChunkData := ''; Checksum := '';
  HostName := ''; SessionName := ''; LaunchCommand := ''; PromptText := '';
  AppPath := ''; Purpose := ''; Detail := '';
  n := Length(Seg);

  { ---- DELETE AN EXCHANGE ENTRY ----
    POST /api/shared/delete carries `dir`, `name`, and optional `recursive` in
    the body because browsers normalize a root `.` path segment away. The
    server anchors two validated names, follows no links, operates through an
    opened directory descriptor, requires empty directories unless recursion
    is explicit, and always logs this destructive action. }
  if (n = 2) and (Seg[0] = 'shared') and (Seg[1] = 'delete') then
  begin
    if not OnlyKeys(Body, ['dir', 'name', 'recursive'], AResp) then Exit;
    if not Str('dir', V) then Exit;
    if not Str('name', Nm) then Exit;
    { Recursive deletion must be named explicitly, not merely default to False. }
    if not Flag('recursive', ForceFlag) then Exit;
    PostFileDelete(V, Nm, ForceFlag, AResp);
    Exit;
  end;

  { ---- messages ---- }
  if (n = 1) and (Seg[0] = 'message') then
  begin
    if not OnlyKeys(Body, ['to', 'text'], AResp) then Exit;
    if not Str('to', V) then Exit;
    { Message body is free-form text delivered exactly as written. }
    if not Str('text', V2, 8 * 1024, False) then Exit;
    { The hub response itself describes direct or group delivery, so project one
      complete acknowledgement variant rather than independent optional fields. }
    PostMessage(V, V2, AResp);
    Exit;
  end;

  { ---- tasks ---- }
  if (n = 1) and (Seg[0] = 'task') then
  begin
    if not OnlyKeys(Body, ['team', 'title', 'milestone', 'hito', 'parent'],
                        AResp) then Exit;
    if not Str('team', V) then Exit;
    if not Str('title', V2, 500) then Exit;
    if not MilestoneField(Body, Milestone, False, AResp) then Exit;
    { Read numeric `parent` without collapsing it into absence. }
    if not NumField(Body, 'parent', ParentN, Pres, AResp) then Exit;
    MutateThen(BuildTaskAdd(Cfg.Secret, Cfg.Self_, V2, V,
      Milestone, ParentN),
      'self', 'task', AResp);
    Exit;
  end;
  if (n = 3) and (Seg[0] = 'task') then
  begin
    if not IdOf(Seg[1], Id) then Exit;
    if Seg[2] = 'state' then
    begin
      if not OnlyKeys(Body, ['state'], AResp) then Exit;
      if not Str('state', V) then Exit;
      { Task-state vocabulary belongs to the hub and intentionally permits any
        nonempty state. The web checks only nonemptiness and does not impose a
        narrower local enum. }
      if Trim(V) = '' then
      begin
        SendErr(AResp, 400, 'state cannot be empty',
          'send open, done, or whatever state your workflow uses');
        Exit;
      end;
      MutateThen(BuildTaskState(Cfg.Secret, Cfg.Self_, Id, V),
        BuildTaskShow(Cfg.Secret, Cfg.Self_, Id), 'task,subtasks:[n]', AResp);
      Exit;
    end;
    if Seg[2] = 'note' then
    begin
      if not OnlyKeys(Body, ['text'], AResp) then Exit;
      if not Str('text', V, 4096, False) then Exit;
      MutateThen(BuildTaskNote(Cfg.Secret, Cfg.Self_, Id, V),
        BuildTaskShow(Cfg.Secret, Cfg.Self_, Id), 'task,subtasks:[n]', AResp);
      Exit;
    end;
    if Seg[2] = 'assign' then
    begin
      if not OnlyKeys(Body, ['team'], AResp) then Exit;
      { Empty string intentionally unassigns; null is a type error, not empty. }
      if not StrField(Body, 'team', V, Pres, AResp) then Exit;
      if not Pres then
      begin
        SendErr(AResp, 400, 'missing field: team',
          'send "" to unassign on purpose');
        Exit;
      end;
      { AND HERE IT IS TRANSLATED, because the two sides spell the same gesture
        differently: over HTTP, unassigning is the empty string -what the form
        sends when the operator picks 'unassigned', and what the contract
        documents-; on the bus the sentinel is a literal dash. Without this line
        pzweb forwarded '' verbatim, the hub answered 'unknown team: ' naming
        nobody, and THERE WAS NO WAY AT ALL to unassign a task from the web -
        while the comment above and the error text two lines up both promised
        there was. Same shape as step:'-' in the other direction. }
      if V = '' then
        V := '-';
      MutateThen(BuildTaskAssign(Cfg.Secret, Cfg.Self_, Id, V),
        BuildTaskShow(Cfg.Secret, Cfg.Self_, Id), 'task,subtasks:[n]', AResp);
      Exit;
    end;
    if Seg[2] = 'delete' then
    begin
      if not OnlyKeys(Body, [], AResp) then Exit;
      MutateThen(BuildTaskDelete(Cfg.Secret, Cfg.Self_, Id), '',
        'removed:' + Seg[1], AResp);
      Exit;
    end;
  end;

  { ---- inbox acknowledgement: reading is an explicit action, not a view side effect ---- }
  if (n = 2) and (Seg[0] = 'inbox') and (Seg[1] = 'ack') then
  begin
    if not OnlyKeys(Body, ['upto'], AResp) then Exit;
    if not NumField(Body, 'upto', Id, Pres, AResp) then Exit;
    if not Pres then
    begin
      SendErr(AResp, 400, 'upto is required',
        'send the seq of the last message you are acknowledging');
      Exit;
    end;
    { Never acknowledge unseen data. An acknowledgement is a high-water mark, so
      obtain the non-consuming oldest-unread window and reject a cursor above
      its last visible message. Do not trust UI mode alone for this invariant. }
    if not Bus(BuildInbox(Cfg.Secret, Cfg.Self_, True, False), AckPeek,
               AckSent) then
    begin
      SendErr(AResp, 502, 'the hub did not answer',
        'the acknowledgement was not sent: try again');
      Exit;
    end;
    AckCeiling := UnreadCeiling(AckPeek);
    if AckCeiling <= 0 then
    begin
      SendErr(AResp, 409, 'there is nothing unread to acknowledge',
        'refresh the inbox first');
      Exit;
    end;
    if Id > AckCeiling then
    begin
      SendErr(AResp, 409, Format('you can only acknowledge up to #%d', [AckCeiling]),
        Format('everything above #%d has not been shown to you yet, and an ' +
          'acknowledgement marks read EVERYTHING below it: refresh the unread ' +
          'view and acknowledge what it shows', [AckCeiling]));
      Exit;
    end;
    MutateThen(BuildAck(Cfg.Secret, Cfg.Self_, Id), '',
      'acked:' + IntToStr(Id), AResp);
    Exit;
  end;

  { ---- CHUNKED FILE UPLOAD ----
    HTTP body limits remain fixed; clients send more chunks. The hub requires
    exact offsets and verifies the complete SHA-256 before publication. Keep
    upload outside /api/files/... to avoid ambiguous team/list routes. }
  if (n = 1) and (Seg[0] = 'upload') then
  begin
    if not OnlyKeys(Body, ['to', 'name', 'id', 'offset', 'data', 'last',
                           'sha256'], AResp) then Exit;
    if not Str('to', Nm) then Exit;
    if not Str('name', V) then Exit;
    if not Str('id', V2) then Exit;
    if not NumField(Body, 'offset', Id, Pres, AResp, 0) then Exit;
    if not Pres then
    begin
      SendErr(AResp, 400, 'offset is required',
        'send 0 for the first chunk, then how much the hub already has');
      Exit;
    end;
    { Base64 content represents bytes and must not be text-normalized. }
    if not Opt('data', ChunkData, 0, False) then Exit;
    if not Flag('last', ForceFlag) then Exit;
    if not Opt('sha256', Checksum) then Exit;
    if ForceFlag and (Checksum = '') then
    begin
      SendErr(AResp, 400, 'the last chunk must carry sha256 of the whole file',
        'without it the hub cannot tell a complete upload from a truncated one');
      Exit;
    end;
    MutateThen(BuildPutChunk(Cfg.Secret, Cfg.Self_, Nm, V, V2, ChunkData, Id,
      ForceFlag, Checksum),
      'self', 'path:s?,received:n?,sha256:s?', AResp);
    Exit;
  end;

  { ---- BACKUP ----
    The output contains secrets, requires its own delegated family, and uses an
    explicit caller-selected destination. }
  if (n = 1) and (Seg[0] = 'backup') then
  begin
    if not OnlyKeys(Body, ['dir', 'force'], AResp) then Exit;
    if not Str('dir', Nm) then Exit;
    if not Flag('force', ForceFlag) then Exit;
    { `self` means the command response itself carries the report. }
    MutateThen(BuildBackup(Cfg.Secret, Cfg.Self_, Nm, ForceFlag), 'self',
      'tree>report:s', AResp);
    Exit;
  end;

  { ---- FLEET UPDATE ----
    Restarts daemons on other hosts and therefore has its own permission family. }
  if (n = 2) and (Seg[0] = 'fleet') and (Seg[1] = 'update') then
  begin
    { Do not expose `version`: console-originated updates always use the release
      published by the hub, so accepting a discarded version would be false. }
    if not OnlyKeys(Body, ['team', 'force'], AResp) then Exit;
    { Empty team targets the whole fleet, matching the CLI default. }
    if not Opt('team', Nm) then Exit;
    if not Flag('force', ForceFlag) then Exit;
    MutateThen(BuildUpdate(Cfg.Secret, Cfg.Self_, Nm, '', ForceFlag), 'self',
      'tree>report:s', AResp);
    Exit;
  end;

  { ---- delivery header shown to the fleet on every message ---- }
  if (n = 1) and (Seg[0] = 'header') then
  begin
    if not OnlyKeys(Body, ['key', 'value'], AResp) then Exit;
    if not Str('key', Nm) then Exit;
    { `off` is a value; empty is not equivalent. The hub owns key grammar. }
    if not Str('value', V) then Exit;
    MutateThen(BuildHeaderSet(Cfg.Secret, Cfg.Self_, Nm, V),
      BuildHeaderList(Cfg.Secret, Cfg.Self_), 'header', AResp);
    Exit;
  end;

  { ---- teams ---- }
  if (n = 1) and (Seg[0] = 'team') then
  begin
    if not OnlyKeys(Body, ['name', 'speciality', 'parent', 'host', 'session', 'launch', 'prompt'], AResp) then Exit;
    if not Str('name', Nm) then Exit;
    { Team creation exposes launch and session for CLI parity. `launch` executes
      on the hub, so the API help and UI must present an explicit warning. }
    if not Opt('speciality', V) then Exit;
    if not Opt('parent', V2) then Exit;
    if not Opt('host', HostName) then Exit;
    if not Opt('session', SessionName) then Exit;
    if not Opt('launch', LaunchCommand) then Exit;
    { Team prompt is long free-form text. }
    if not Opt('prompt', PromptText, 0, False) then Exit;
    MutateThen(BuildTeamAdd(Cfg.Secret, Cfg.Self_, Nm, V, V2, HostName,
      SessionName, LaunchCommand, PromptText),
      BuildTeamShow(Cfg.Secret, Cfg.Self_, Nm), 'team', AResp);
    Exit;
  end;
  if (n = 3) and (Seg[0] = 'team') then
  begin
    Nm := Seg[1];
    if Seg[2] = 'set' then
    begin
      { Expose every field the hub can mutate, including command-bearing launch,
        with prominent warnings. `host` is intentionally absent because the hub
        requires configuration and restart for that field. }
      if not OnlyKeys(Body, ['field', 'value'], AResp) then Exit;
      if not FieldIn('|prompt|speciality|parent|project|slave|workdir|' +
                     'launch|session|user|', V) then Exit;
      { Validate `value` as a string; explicit "" clears it, wrong types do not. }
      if not StrField(Body, 'value', V2, Pres, AResp) then Exit;
      { Normalize reference fields; preserve prompt and speciality text. }
      if (V <> 'prompt') and (V <> 'speciality') then
        V2 := Trim(V2);
      if not Pres then
      begin
        SendErr(AResp, 400, 'missing field: value',
          'send "" to clear it on purpose');
        Exit;
      end;
      MutateThen(BuildTeamSet(Cfg.Secret, Cfg.Self_, Nm, V, V2),
        BuildTeamShow(Cfg.Secret, Cfg.Self_, Nm), 'team', AResp);
      Exit;
    end;
    if Seg[2] = 'remove' then
    begin
      if not OnlyKeys(Body, [], AResp) then Exit;
      MutateThen(BuildTeamRemove(Cfg.Secret, Cfg.Self_, Nm), '',
        'removed:' + Nm, AResp);
      Exit;
    end;
  end;

  { ---- groups ---- }
  if (n = 1) and (Seg[0] = 'group') then
  begin
    if not OnlyKeys(Body, ['name', 'members'], AResp) then Exit;
    if not Str('name', Nm) then Exit;
    if not Members(V, Pres) then Exit;
    if (not Pres) or (V = '') then
    begin
      SendErr(AResp, 400, 'group needs at least one member',
        'send {"name":"...","members":["team-one"]}');
      Exit;
    end;
    MutateThen(BuildGroupAdd(Cfg.Secret, Cfg.Self_, Nm, V),
      BuildGroupList(Cfg.Secret, Cfg.Self_), 'groups', AResp,
      'groups', 'group', Nm);
    Exit;
  end;
  if (n = 3) and (Seg[0] = 'group') then
  begin
    Nm := Seg[1];
    if Seg[2] = 'remove' then
    begin
      { Absent members deletes the group. Distinguish absence from an explicitly
        empty list so two different operations cannot collapse together. }
      if not OnlyKeys(Body, ['members'], AResp) then Exit;
      if not Members(V, Pres) then Exit;
      if Pres and (V = '') then
      begin
        SendErr(AResp, 400, 'members was given but empty',
          'omit members entirely to delete the group, or name who leaves');
        Exit;
      end;
      { Response shapes also differ: member removal refreshes the existing group,
        while whole-group deletion returns a removed marker. }
      if Pres then
        MutateThen(BuildGroupRemove(Cfg.Secret, Cfg.Self_, Nm, V),
          BuildGroupList(Cfg.Secret, Cfg.Self_), 'groups', AResp,
          'groups', 'group', Nm)
      else
        MutateThen(BuildGroupRemove(Cfg.Secret, Cfg.Self_, Nm, V), '',
          'removed:' + Nm, AResp);
      Exit;
    end;
    if Seg[2] = 'boss' then
    begin
      if not OnlyKeys(Body, ['boss'], AResp) then Exit;
      if not Opt('boss', V) then Exit;
      MutateThen(BuildGroupBoss(Cfg.Secret, Cfg.Self_, Nm, V),
        BuildGroupList(Cfg.Secret, Cfg.Self_), 'groups', AResp,
        'groups', 'group', Nm);
      Exit;
    end;
    if Seg[2] = 'project' then
    begin
      if not OnlyKeys(Body, ['project'], AResp) then Exit;
      if not Opt('project', V) then Exit;
      MutateThen(BuildGroupProject(Cfg.Secret, Cfg.Self_, Nm, V),
        BuildGroupList(Cfg.Secret, Cfg.Self_), 'groups', AResp,
        'groups', 'group', Nm);
      Exit;
    end;
    if Seg[2] = 'exclude' then
    begin
      { the muted set (members excluded from @group broadcasts). Replace
        semantics: 'excluded' is the WHOLE set as a comma list, empty clears it.
        Same boss+console authority the hub enforces for membership. }
      if not OnlyKeys(Body, ['excluded'], AResp) then Exit;
      if not Opt('excluded', V) then Exit;
      MutateThen(BuildGroupExclude(Cfg.Secret, Cfg.Self_, Nm, V),
        BuildGroupList(Cfg.Secret, Cfg.Self_), 'groups', AResp,
        'groups', 'group', Nm);
      Exit;
    end;
    if Seg[2] = 'onblock' then
    begin
      if not OnlyKeys(Body, ['onblock'], AResp) then Exit;
      if not Opt('onblock', V) then Exit;
      MutateThen(BuildGroupOnBlock(Cfg.Secret, Cfg.Self_, Nm, V),
        BuildGroupList(Cfg.Secret, Cfg.Self_), 'groups', AResp,
        'groups', 'group', Nm);
      Exit;
    end;
  end;

  { ---- projects ---- }
  if (n = 3) and (Seg[0] = 'project') then
  begin
    Nm := Seg[1];
    if Seg[2] = 'boss' then
    begin
      { Setting a leader creates a new project; there is no separate create route. }
      if not OnlyKeys(Body, ['boss'], AResp) then Exit;
      if not Str('boss', V) then Exit;
      MutateThen(BuildProjectBoss(Cfg.Secret, Cfg.Self_, Nm, V),
        BuildProjectList(Cfg.Secret, Cfg.Self_), 'projects', AResp,
        'projects', 'project', Nm);
      Exit;
    end;
    if Seg[2] = 'remove' then
    begin
      if not OnlyKeys(Body, [], AResp) then Exit;
      MutateThen(BuildProjectRemove(Cfg.Secret, Cfg.Self_, Nm), '',
        'removed:' + Nm, AResp);
      Exit;
    end;
  end;

  { ---- applications ---- }
  if (n = 1) and (Seg[0] = 'app') then
  begin
    if not OnlyKeys(Body, ['name', 'team', 'repo', 'path', 'purpose', 'detail'], AResp) then Exit;
    if not Str('name', Nm) then Exit;
    if not Str('team', V) then Exit;
    if not Opt('repo', V2) then Exit;
    if not Opt('path', AppPath) then Exit;
    if not Opt('purpose', Purpose) then Exit;
    if not Opt('detail', Detail) then Exit;
    MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'add', Nm, V, V2, AppPath,
      Purpose, Detail, '', ''),
      BuildAppOp(Cfg.Secret, Cfg.Self_, 'show', Nm, '', '', '', '', '', '', ''),
      'app', AResp);
    Exit;
  end;
  if (n = 3) and (Seg[0] = 'app') then
  begin
    Nm := Seg[1];
    if Seg[2] = 'set' then
    begin
      if not OnlyKeys(Body, ['field', 'value'], AResp) then Exit;
      if not FieldIn('|team|repo|path|purpose|detail|', V) then Exit;
      if not StrField(Body, 'value', V2, Pres, AResp) then Exit;
      { `detail` is free-form description; other fields name resources. }
      if V <> 'detail' then
        V2 := Trim(V2);
      if not Pres then
      begin
        SendErr(AResp, 400, 'missing field: value',
          'send "" to clear it on purpose');
        Exit;
      end;
      MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'set', Nm, '', '', '', '',
        '', V, V2),
        BuildAppOp(Cfg.Secret, Cfg.Self_, 'show', Nm, '', '', '', '', '', '', ''),
        'app', AResp);
      Exit;
    end;
    if Seg[2] = 'doc' then
    begin
      { Preserve manual indentation exactly. }
      if not OnlyKeys(Body, ['text'], AResp) then Exit;
      if not Str('text', V, 0, False) then Exit;
      MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'setdoc', Nm, '', '', '', '',
        '', '', '', V),
        BuildAppOp(Cfg.Secret, Cfg.Self_, 'show', Nm, '', '', '', '', '', '', ''),
        'app', AResp);
      Exit;
    end;
    if Seg[2] = 'undo' then
    begin
      { Snapshot is required; zero is not a history point. }
      if not OnlyKeys(Body, ['snapshot'], AResp) then Exit;
      if not NumField(Body, 'snapshot', Id, Pres, AResp) then Exit;
      if not Pres then
      begin
        SendErr(AResp, 400, 'snapshot must be a positive history point',
          'read GET /api/app/<name>/history first');
        Exit;
      end;
      MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'undo', Nm, '', '', '', '',
        '', '', '', '', Id),
        BuildAppOp(Cfg.Secret, Cfg.Self_, 'show', Nm, '', '', '', '', '', '', ''),
        'app', AResp);
      Exit;
    end;
    if Seg[2] = 'remove' then
    begin
      if not OnlyKeys(Body, [], AResp) then Exit;
      MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'remove', Nm, '', '', '', '',
        '', '', ''), '', 'removed:' + Nm, AResp);
      Exit;
    end;
    { ASSIGN AN APP TO A PROJECT, with what it does THERE. The reply is the
      app's card, which now carries its projects: answering with anything else
      would leave the screen guessing what the command actually did. }
    if Seg[2] = 'project' then
    begin
      if not OnlyKeys(Body, ['project', 'role'], AResp) then Exit;
      if not StrField(Body, 'project', V, Pres, AResp) then Exit;
      V := Trim(V);
      if (not Pres) or (V = '') then
      begin
        SendErr(AResp, 400, 'missing field: project',
          'name the project to assign it to');
        Exit;
      end;
      { the role is OPTIONAL: an assignment with no description is still a
        true assignment, and refusing it would push people to write filler }
      if not StrField(Body, 'role', V2, Pres, AResp) then Exit;
      MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'project', Nm, '', '', '',
        '', '', '', '', '', 0, 0, V, V2),
        BuildAppOp(Cfg.Secret, Cfg.Self_, 'show', Nm, '', '', '', '', '', '', ''),
        'app', AResp);
      Exit;
    end;
    if Seg[2] = 'unproject' then
    begin
      if not OnlyKeys(Body, ['project'], AResp) then Exit;
      if not StrField(Body, 'project', V, Pres, AResp) then Exit;
      V := Trim(V);
      if (not Pres) or (V = '') then
      begin
        SendErr(AResp, 400, 'missing field: project',
          'name the project to take it out of');
        Exit;
      end;
      MutateThen(BuildAppOp(Cfg.Secret, Cfg.Self_, 'unproject', Nm, '', '', '',
        '', '', '', '', '', 0, 0, V),
        BuildAppOp(Cfg.Secret, Cfg.Self_, 'show', Nm, '', '', '', '', '', '', ''),
        'app', AResp);
      Exit;
    end;
  end;

  Result := False;
end;

type
  TPzWebServer = class(TFPHttpServer)
  protected
    function CreateConnection(Data: TSocketStream): TFPHTTPConnection; override;
  public
    procedure Handle(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  end;

{ Socket timeout is not a whole-request deadline: SO_RCVTIMEO resets on every
  operation, so a slow trickle can retain a slot. Contract section 4 states this
  limit; network admission contains the residual risk. }
procedure TPzWebConn.SetupSocket;
begin
  inherited SetupSocket;
  Socket.IOTimeout := IO_TIMEOUT_MS;
end;

{ Check body length before allocation. Do not raise here because FPC has not yet
  created the response; mark the request so the normal handler can return 413. }
procedure TPzWebConn.ReadRequestContent(ARequest: TFPHTTPConnectionRequest);
begin
  if ARequest.ContentLength > MAX_BODY then
  begin
    ARequest.Content := '';
    ARequest.SetCustomHeader('X-Pzweb-Reject', '413');
    Exit;
  end;
  inherited ReadRequestContent(ARequest);
end;

procedure TPzWebConn.HandleRequest;
begin
  CurConn := Self;
  CurPeer := Peer;
  try
    inherited HandleRequest;
  finally
    CurConn := nil;
  end;
end;

destructor TPzWebConn.Destroy;
begin
  if not FReleased then
  begin
    FReleased := True;
    ReleasePeer(FPeer);
  end;
  inherited Destroy;
end;

function TPzWebServer.CreateConnection(Data: TSocketStream): TFPHTTPConnection;
var
  C: TPzWebConn;
  Peer: string;
begin
  { Read the peer again from the accepted descriptor; it matches admission and
    depends on no header. }
  Peer := PeerOf(Data.Handle);
  try
    C := TPzWebConn.Create(Self, Data);
  except
    { If construction fails after accept reserved a slot, no destructor exists;
      release the slot manually and re-raise. }
    ReleasePeer(Peer);
    raise;
  end;
  C.Peer := Peer;
  Result := C;
end;

procedure TPzWebServer.Handle(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Path, Reply, DataJson, HubErr, Rest: string;
  A: TAsset;
  Ok, WasSent: Boolean;
  Members, TE, Extra, LEI, FeedPeerName, QErr, Filt, Team_, Org: string;
  BadPath, Malformed: Boolean;
  Segs, SegsP, SegsQ: TStringArray;
  AtN, LimN: Integer;
  AllF: Boolean;
  Arr2: TJSONArray;
  FdD: LongInt;
  StF: Stat;
  AtS: string;
  SinceN: Int64;
  RestP: string;
  Body: TJSONObject;
  BodyReason: string;   { why the body could not be read: four possible causes }
  NSeg, k: Integer;
  Cur, InbAfter: Int64;
  Id, InbLim: Integer;
  T0: TDateTime;
begin
  { MEASURE EVERY REQUEST. Previously only rejections were logged, so when the
    operator said "it is slow" there was no useful data: no route, duration,
    or even proof that the request arrived. One subtraction turns a complaint
    into a place to investigate. The SSE channel is not measured this way: it
    lasts as long as the tab remains open and has its own OPEN and CLOSED log
    entries. }
  T0 := Now;
  try
   try
    { Validate Host BEFORE routing EVERY request: static assets, reads, feeds,
      and errors, not only writes. A read is as sensitive as a write, and DNS
      rebinding could make an unrelated page same-origin and let it read data,
      precisely what the absence of CORS is intended to prevent. }
    { Record this FIRST, before the first guard. A rejection that does not say
      which request it rejected leaves out half the useful information. }
    CurWhat := ARequest.Method + ' ' + ARequest.URI;
    if (Cfg.HostExp <> '') and (ARequest.Host <> Cfg.HostExp) then
    begin
      SendErr(AResponse, 403, 'unexpected Host header',
        'use the configured address: ' + Cfg.HostExp);
      Exit;
    end;

    { Authentication comes AFTER Host validation and BEFORE everything else:
      neither a static asset nor an error is served without credentials. }
    if not AuthOk(ARequest) then
    begin
      { Log this too: "cannot connect" and "cannot sign in" look similar from
        outside but are different failures. }
      Writeln(StdErr, Format('pzweb: 401 to %s (%s) -> no valid credential',
        [CurPeer, CurWhat]));
      Flush(StdErr);
      AResponse.Code := 401;
      AResponse.SetCustomHeader('WWW-Authenticate',
        'Basic realm="pizarra", charset="UTF-8"');
      AResponse.ContentType := 'application/json; charset=utf-8';
      CommonHeaders(AResponse);
      SendExact(AResponse, '{"ok":false,"error":"authentication required",' +
        '"fix":"sign in with the console user and password"}');
      Exit;
    end;

    if ARequest.GetCustomHeader('X-Pzweb-Reject') = '413' then
    begin
      { The remedy states what the caller needs to fix, not merely the number.
        File uploads use base64, which expands data by 4/3, so the BODY limit
        is not the caller's RAW-BYTE limit. A reasonable client once selected
        48 KB chunks, exactly 64 KB in base64, and received an unexplained 413.
        An error that makes callers derive the size calculation is only half
        an error. }
      SendErr(AResponse, 413, 'body too large',
        Format('the body limit is %d bytes. If you are uploading, remember ' +
               'base64 grows 4/3: send chunks of %d KB of raw bytes or less ' +
               '(32 KB is a comfortable size)',
               [MAX_BODY, (MAX_BODY div 1024) * 3 div 4 - 2]));
      Exit;
    end;
    { Check here, not in ReadRequestContent: that method is NOT called when
      Content-Length is zero, so a chunked request used to slip through. }
    { IMPORTANT: httpdefs does NOT map Transfer-Encoding in its known-header
      table. fphttpserver therefore stores it as a custom header, while
      GetHeader(hhTransferEncoding) always read the empty slot. The guard
      existed but inspected nothing. }
    TE := LowerCase(Trim(ARequest.GetCustomHeader('Transfer-Encoding')));
    if (TE <> '') and (TE <> 'identity') then
    begin
      SendErr(AResponse, 400, 'unsupported Transfer-Encoding: ' + TE,
        'send an identity-encoded body with Content-Length');
      Exit;
    end;

    if ARequest.Method = 'OPTIONS' then
    begin
      SendErr(AResponse, 405, 'OPTIONS is not served',
        'no preflight is granted: this server emits no CORS headers');
      Exit;
    end;
    if (ARequest.Method <> 'GET') and (ARequest.Method <> 'POST') then
    begin
      SendErr(AResponse, 405, 'only GET and POST are served', 'use GET or POST');
      Exit;
    end;

    Path := ARequest.URI;
    if Pos('?', Path) > 0 then
      Path := Copy(Path, 1, Pos('?', Path) - 1);
    Path := DecodeOnce(Path, BadPath);
    if BadPath then
    begin
      SendErr(AResponse, 400, 'malformed path',
        'encoded slashes, backslashes, NUL and dot segments are refused');
      Exit;
    end;

    { ORIGIN is the real boundary against forged browser requests. Basic
      credentials are ambient: the browser sends them automatically from any
      tab. Without this check, a hostile page could mutate state on behalf of
      the operator. Require an EXACT match and reject a MISSING value too: a
      cross-origin request may omit it, and trusting that case would leave the
      important attack path open. }
    if ARequest.Method = 'POST' then
    begin
      { Check METHOD first on routes that cannot mutate anything. The request-
        forgery boundary protects nothing there because there is nothing to
        forge, and the caller deserves the real error: "GET only." Complaining
        about Origin or Content-Type would send it to fix something that is not
        wrong. Routes that CAN write do not pass through here; they still
        require Origin before any other mutation check. }
      if Copy(Path, 1, 5) = '/api/' then
      begin
        RestP := Copy(Path, 6, Length(Path));
        SegsQ := SplitString(RestP, '/');
        if ReadOnlyRoute(RestP, SegsQ, Length(SegsQ)) then
        begin
          Send405(AResponse, 'GET');
          Exit;
        end;
      end
      else if FindAsset(Path, A) then
      begin
        Send405(AResponse, 'GET');
        Exit;
      end;
      Org := Trim(ARequest.GetCustomHeader('Origin'));
      if (Org = '') or (Org = 'null') or (Org <> Cfg.Origin) then
      begin
        SendErr(AResponse, 403, 'bad or missing Origin on a mutation',
          'mutations must come from ' + Cfg.Origin);
        Exit;
      end;
    end;

    if Copy(Path, 1, 5) = '/api/' then
    begin
      Ok := False;
      Rest := Copy(Path, 6, Length(Path));

      { --------- HELP: what each action does when selected -----------------
        Keep this in the server deliberately. Whoever changes a route must
        change its explanation, and the two live side by side here. Help kept
        elsewhere becomes stale as soon as someone changes this code. }
      if Rest = 'help' then
      begin
        if ARequest.Method <> 'GET' then
        begin
          Send405(AResponse, 'GET');
          Exit;
        end;
        { Help declares no parameters either; arbitrary queries used to return
          200 instead of being rejected. }
        if not QueryOk(ARequest, [], QErr) then
        begin
          SendErr(AResponse, 400, QErr, 'this route takes no query parameters');
          Exit;
        end;
        SendOk(AResponse, HelpJson);
        Exit;
      end;

      if Rest = 'feed' then
      begin
        if ARequest.Method <> 'GET' then
        begin
          Send405(AResponse, 'GET');
          Exit;
        end;
        { Cursor precedence: Last-Event-ID overrides ?since= because browsers
          resend it when reconnecting. -1 means no cursor. }
        { Browser-driven resumption uses Last-Event-ID. An unreadable cursor
          must NOT silently become "no cursor": that would serve a different
          history while pretending that resumption succeeded. }
        Cur := -1;
        LEI := Trim(ARequest.GetCustomHeader('Last-Event-ID'));
        if LEI <> '' then
        begin
          Cur := StrToInt64Def(LEI, -2);
          if Cur < 0 then
          begin
            SendErr(AResponse, 400, 'malformed Last-Event-ID',
              'reconnect without the header to start from the visible tail');
            Exit;
          end;
        end;
        if CurConn <> nil then
          FeedPeerName := CurConn.Peer
        else
          FeedPeerName := '';
        { REOPENING MUST NOT LOSE EVENTS. Browsers send Last-Event-ID only on
          their own retries. When the page reopens a channel because the
          browser considers it closed and will not retry, that header is absent.
          A fresh channel once started at the tail and silently lost everything
          that happened in the gap, exactly what gap handling is meant to
          prevent. This is why ?since= is accepted. Last-Event-ID still wins
          when present: the browser resends it automatically and it reflects
          the last event actually DELIVERED. }
        if not QueryOk(ARequest, ['since'], QErr) then
        begin
          SendErr(AResponse, 400, QErr,
            'the feed only takes since=, once: resume with Last-Event-ID or since=');
          Exit;
        end;
        if (LEI = '') and (ARequest.QueryFields.IndexOfName('since') >= 0) then
        begin
          AtS := Trim(ARequest.QueryFields.Values['since']);
          Cur := StrToInt64Def(AtS, -2);
          if Cur < 0 then
          begin
            { An unreadable cursor must NOT silently become "no cursor": that
              would serve a different history while pretending resumption
              succeeded. }
            SendErr(AResponse, 400, 'malformed since',
              'since is the seq of the last event you processed, or drop it');
            Exit;
          end;
        end;
        { Log successful opens too. With only rejection logs, "it stays on
          connecting" cannot distinguish "the channel never arrived" from
          "the channel is open but the browser is not processing it." Those
          are different failures with different fixes. }
        if not TakeFeedSlot(FeedPeerName) then
        begin
          SendErr(AResponse, 429,
            Format('this address already has %d live feeds open',
              [MAX_FEED_PEER]),
            'close another tab of this page and retry; each open tab holds ' +
            'one, and a tab that was just closed frees its slot within a few ' +
            'seconds');
          Exit;
        end;
        { Reserving a slot and opening the channel are separate; this only says
          that capacity is available. }
        Writeln(StdErr, Format('pzweb: feed slot for %s (%d active)',
          [FeedPeerName, FeedCount(FeedPeerName)]));
        Flush(StdErr);
        try
          { A DEPARTING CLIENT IS NOT AN ERROR. Closing a tab makes the write
            fail with "Stream write error." That used to reach the general
            handler, which wrote a JSON 500 error ON TOP OF an event stream
            that had already started. The result is neither an event nor a
            response, and a reused connection would pass the corruption to the
            NEXT request. This is the framing corruption that DoWatch warns
            about in the hub. Log it and leave; the connection is no longer
            usable. }
          try
            ServeFeed(AResponse, Cur);
          except
            on E: Exception do
            begin
              { Swallow failures ONLY after the response has started. Swallowing
                failures before headers are sent leaves the caller with no
                response, not even the 500 that can still be returned. }
              if not AResponse.HeadersSent then
                raise;
              Writeln(StdErr, Format('pzweb: feed CLOSED for %s (%s) - %d remain',
                [FeedPeerName, E.Message, FeedCount(FeedPeerName) - 1]));
              Flush(StdErr);
            end;
          end;
        finally
          DropFeedSlot(FeedPeerName);
        end;
        Exit;
      end;

      { --------- WRITES: workflows. Dispatch them before reads because the
        method already distinguishes them, keeping the GET block intact. ----- }
      if ARequest.Method = 'POST' then
      begin
        { BODY guards belong where the body is used. They once ran before
          routing, so POST to a read-only URL returned 415, "fix Content-Type,"
          when the method was wrong. They cannot run early based on the path
          alone: /api/app/<n>/doc supports both reads and writes. Only this
          point, after deciding it is a write, can distinguish them. }
        if not SameText(Trim(MediaTypeOf(ARequest.ContentType)),
                        'application/json') then
        begin
          SendErr(AResponse, 415, 'mutations must be application/json',
            'set Content-Type: application/json');
          Exit;
        end;
        if Trim(ARequest.GetCustomHeader('X-Pizarra')) <> '1' then
        begin
          SendErr(AResponse, 400, 'missing X-Pizarra: 1 header',
            'a plain cross-origin form cannot set it, which is the point');
          Exit;
        end;
        SegsP := SplitString(Rest, '/');
        for k := 0 to High(SegsP) do
          if SegsP[k] = '' then
          begin
            SendErr(AResponse, 404, 'empty path segment in ' + Path,
              'names are exactly one non-empty segment');
            Exit;
          end;
        { No write route declares query parameters, so accept none. Silently
          accepting a filter that the operator believes was applied is another
          form of false operation. }
        if not QueryOk(ARequest, [], QErr) then
        begin
          SendErr(AResponse, 400, QErr, 'write routes take no query parameters');
          Exit;
        end;
        { SAY WHICH of the four failures it was. 'body is not a JSON object' is
          plainly false for a duplicated key -the body IS an object- and sends
          the caller to inspect the wrong thing. }
        Body := ParseObj(ARequest.Content, BodyReason);
        if Body = nil then
        begin
          SendErr(AResponse, 400, BodyReason,
            'send {"...":"..."} with Content-Type: application/json');
          Exit;
        end;
        { The browser NEVER chooses the credential, sender, or command; the
          server supplies them. Reject these fields in the body instead of
          ignoring them. Silently accepting a request that the client believes
          means something else is worse than rejecting it. }
        if (Body.Find('secret') <> nil) or (Body.Find('from') <> nil) or
           (Body.Find('cmd') <> nil) then
        begin
          Body.Free;
          SendErr(AResponse, 400,
            'the body may not carry secret, from or cmd',
            'those are chosen by the server, never by the browser');
          Exit;
        end;
        try
          if (not PostWorkflow(SegsP, Body, AResponse)) and
             (not PostRest(SegsP, Body, AResponse)) then
            { The URL may exist but be read-only: that is 405, not 404. }
            if ReadRouteKnown(Rest, SegsP, Length(SegsP)) then
              Send405(AResponse, 'GET')
            else
              SendErr(AResponse, 404, 'unknown write route: ' + Path,
                'POST changes nothing here; read routes answer to GET. ' +
                'See docs/web-api.md for the exact write routes');
        finally
          Body.Free;
        end;
        Exit;
      end;

      { Split the route into segments and require the EXACT count. Prefix-based
        routing once forwarded the entire remainder: /api/team/x/junk reached
        the hub as a team named "x/junk" and returned 200 with its error, so
        the hub judged malformed paths instead of rejecting them here.
        /api/app//doc also allowed an EMPTY name. }
      Segs := SplitString(Rest, '/');
      NSeg := Length(Segs);
      for k := 0 to NSeg - 1 do
        if Segs[k] = '' then
        begin
          SendErr(AResponse, 404, 'empty path segment in ' + Path,
            'names are exactly one non-empty segment');
          Exit;
        end;

      { Any route that declares no parameters accepts NONE. Without this,
        /api/teams?bogus=1 quietly returned 200. }
      { "tasks" declares filter/team; an app document declares "at" to request
        an EARLIER version, which the console already supports with app doc
        --at. All other routes declare and accept no parameters. }
      if (Rest <> 'tasks') and (Rest <> 'messages') and
         (Rest <> 'inbox') and (Rest <> 'download') and
         (not ((NSeg = 3) and (Segs[0] = 'app') and (Segs[2] = 'doc'))) and
         (not QueryOk(ARequest, [], QErr)) then
      begin
        SendErr(AResponse, 400, QErr, 'this route takes no query parameters');
        Exit;
      end;

      Members := '';
      Extra := '';
      if Rest = 'teams' then
      begin
        Ok := Bus(BuildTeams(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'teams';
      end
      else if (NSeg = 2) and (Segs[0] = 'team') then
      begin
        Ok := Bus(BuildTeamShow(Cfg.Secret, Cfg.Self_, Segs[1]), Reply, WasSent);
        Members := 'team';
      end
      else if Rest = 'groups' then
      begin
        Ok := Bus(BuildGroupList(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'groups';
      end
      { MONITORING IS ALSO ADMINISTRATION. Version drift between hosts was once
        visible only from the console. A web operator could see a healthy board
        without knowing that one host had run an old binary for days. }
      { This console's INBOX is read WITHOUT CONSUMING it, deliberately. In the
        command-line console, reading mail marks it as read because the reader
        is the worker. Here an automatically refreshing page is the reader, and
        marking messages as read while rendering would hide messages that no
        person saw. Acknowledgement is a separate, explicit action. }
      else if Rest = 'inbox' then
      begin
        if not QueryOk(ARequest, ['all', 'after', 'limit'], QErr) then
        begin
          SendErr(AResponse, 400, QErr,
            'only all=, after= and limit= are accepted, once each');
          Exit;
        end;
        AllF := False;
        if ARequest.QueryFields.IndexOfName('all') >= 0 then
        begin
          AtS := LowerCase(Trim(ARequest.QueryFields.Values['all']));
          if (AtS <> '1') and (AtS <> 'true') and (AtS <> '0') and (AtS <> 'false') then
          begin
            SendErr(AResponse, 400, 'all must be true or false',
              'drop it to see only what is unread');
            Exit;
          end;
          AllF := (AtS = '1') or (AtS = 'true');
        end;
        { PAGE: "after" is the last seq already held and "limit" is the desired
          count. Requesting a page NEVER consumes messages; acknowledgement
          remains a separate action. Reject a nonnumeric value instead of
          treating it as zero and returning the first page while pretending it
          was the requested page. }
        InbAfter := 0;
        if ARequest.QueryFields.IndexOfName('after') >= 0 then
        begin
          AtS := Trim(ARequest.QueryFields.Values['after']);
          InbAfter := StrToInt64Def(AtS, -1);
          if InbAfter < 0 then
          begin
            SendErr(AResponse, 400, 'after must be a non-negative whole number',
              'send the seq of the last message you already have');
            Exit;
          end;
        end;
        InbLim := 0;
        if ARequest.QueryFields.IndexOfName('limit') >= 0 then
        begin
          AtS := Trim(ARequest.QueryFields.Values['limit']);
          Cur := StrToInt64Def(AtS, -1);
          if (Cur <= 0) or (Cur > 200) then
          begin
            SendErr(AResponse, 400, 'limit must be between 1 and 200',
              'drop it for the default page of 50');
            Exit;
          end;
          InbLim := Cur;
        end;
        Ok := Bus(BuildInbox(Cfg.Secret, Cfg.Self_, True, AllF, InbAfter, InbLim),
          Reply, WasSent);
        { "more" is the unread count OUTSIDE this window. Without it, the page
          acknowledges the greatest seq it sees and skips older messages that
          were never shown. The server cannot know what was rendered, but it
          can report how much it left out. }
        Members := 'messages,more:n?';
      end
      { CHUNKED DOWNLOAD of a shared file. The HTTP body limit does not apply
        to downloads, but chunks let the page show progress and cancel without
        leaving a partial file. }
      else if Rest = 'download' then
      begin
        if not QueryOk(ARequest, ['path', 'offset', 'max'], QErr) then
        begin
          SendErr(AResponse, 400, QErr,
            'only path=, offset= and max= are accepted, once each');
          Exit;
        end;
        AtS := Trim(ARequest.QueryFields.Values['path']);
        if AtS = '' then
        begin
          SendErr(AResponse, 400, 'path is required',
            'use <team>/<file>, as it appears in /api/files/<team>');
          Exit;
        end;
        { THE PATH IS RELATIVE TO THE EXCHANGE AND ANCHORED BY THE SERVER. It
          was once forwarded unchanged: the application built team/file, the
          hub resolved it against ITS working directory, and containment always
          rejected it, so no download worked. Returning absolute paths in the
          listing would make the browser construct paths, and a browser that
          constructs paths can name outside files. Anchoring here prevents that
          by construction: reject absolute paths and every ".." before using
          the bus, with hub containment still providing a second line. }
        if Cfg.SharedDir = '' then
        begin
          SendErr(AResponse, 501, 'file exchange is not configured',
            'set [web] shared = <dir> to the hub shared directory');
          Exit;
        end;
        if (Copy(AtS, 1, 1) = '/') or (Pos('..', AtS) > 0) or
           (Pos('\', AtS) > 0) then
        begin
          SendErr(AResponse, 400, 'path must be relative to the exchange',
            'use <team>/<file>, exactly as it appears in /api/files/<team>');
          Exit;
        end;
        AtS := IncludeTrailingPathDelimiter(Cfg.SharedDir) + AtS;
        { A malformed number must NOT silently become zero. That used to return
          the FIRST chunk successfully to a caller that requested something
          else, another false operation. Reject it and identify the field. }
        SinceN := 0;
        if ARequest.QueryFields.IndexOfName('offset') >= 0 then
        begin
          SinceN := StrToInt64Def(Trim(ARequest.QueryFields.Values['offset']), -1);
          if SinceN < 0 then
          begin
            SendErr(AResponse, 400, 'offset must be a non-negative number',
              'drop it to start from the beginning');
            Exit;
          end;
        end;
        LimN := 0;
        if ARequest.QueryFields.IndexOfName('max') >= 0 then
        begin
          LimN := StrToIntDef(Trim(ARequest.QueryFields.Values['max']), -1);
          if LimN < 1 then
          begin
            SendErr(AResponse, 400, 'max must be a positive number of bytes',
              'drop it for the default chunk size');
            Exit;
          end;
        end;
        Ok := Bus(BuildGetChunk(Cfg.Secret, Cfg.Self_, AtS, SinceN, LimN),
                  Reply, WasSent);
        Members := 'name:s,size:n,offset:n,len:n,eof:b,data:s,sha256:s?';
      end
      { SHARED FILES are read from disk instead of through the bus by operator
        choice: the hub places them in one directory per team and pzweb runs on
        the same host. Therefore validate the root AT STARTUP with the static-
        tree rules, follow no links here, and descend only one level. }
      else if Rest = 'files' then
      begin
        if Cfg.SharedDir = '' then
        begin
          SendErr(AResponse, 501, 'file exchange is not configured',
            'set [web] shared = <dir> to the hub shared directory');
          Exit;
        end;
        Arr2 := ListShared(Cfg.SharedDir, QErr, True);
        try
          SendOk(AResponse, '{"dirs":' + Arr2.AsJSON + '}');
        finally
          Arr2.Free;
        end;
        Exit;
      end
      else if (NSeg = 2) and (Segs[0] = 'files') then
      begin
        if Cfg.SharedDir = '' then
        begin
          SendErr(AResponse, 501, 'file exchange is not configured',
            'set [web] shared = <dir> to the hub shared directory');
          Exit;
        end;
        { One level only: the name is an already validated segment with no
          slashes or dot segments. Also ensure its entry is not a link that
          could redirect outside the exchange. }
        AtS := IncludeTrailingPathDelimiter(Cfg.SharedDir) + Segs[1];
        { NOT FOUND and OUTSIDE THE TREE are different conditions and must be
          reported differently. Checking safety first accused a team with no
          directory yet of escaping the shared tree, which was false and sent
          the operator looking for the wrong problem. Existence is determined
          with lstat, which does NOT follow links, before safety is explained. }
        { CHECKING AND THEN OPENING BY NAME IS A RACE. Between an lstat that
          says "not a link" and traversal, anyone able to write in the 1777
          tree could replace the entry with a link and make the listing escape.
          Open with O_NOFOLLOW+O_DIRECTORY, which FAILS for links and non-
          directories, then traverse the open DESCRIPTOR through /proc/self/fd.
          The descriptor pins the inode, so changing its name later does not
          change what is read. }
        FdD := FpOpen(AtS, O_RDONLY or O_DIRECTORY or O_NOFOLLOW);
        if FdD < 0 then
        begin
          { Obtain the exact diagnostic from a SEPARATE lstat. O_NOFOLLOW has
            already made the security decision while opening; this check only
            explains truthfully why the open failed. }
          StF := Default(Stat);
          if (fpLStat(AtS, StF) = 0) and fpS_ISLNK(StF.st_mode) then
            SendErr(AResponse, 403, Segs[1] + ' is a symlink: it would leave ' +
              'the shared directory',
              'the exchange has one level per team and follows no links')
          else if (fpLStat(AtS, StF) = 0) and (not fpS_ISDIR(StF.st_mode)) then
            SendErr(AResponse, 404, Segs[1] + ' is not a team directory',
              'the exchange has one level per team')
          else
            SendErr(AResponse, 404, 'no shared directory for ' + Segs[1],
              'it appears once that team has received a file');
          Exit;
        end;
        try
          Arr2 := ListShared('/proc/self/fd/' + IntToStr(FdD), QErr);
          try
            SendOk(AResponse, '{"name":' + JsonStr(Segs[1]) +
              ',"files":' + Arr2.AsJSON + '}');
          finally
            Arr2.Free;
          end;
        finally
          FpClose(FdD);
        end;
        Exit;
      end
      { PAGINATED HISTORY. The live channel carries only the visible tail;
        without this route the web interface could not look further back. }
      else if Rest = 'messages' then
      begin
        if not QueryOk(ARequest, ['since', 'limit'], QErr) then
        begin
          SendErr(AResponse, 400, QErr,
            'only since= and limit= are accepted, once each');
          Exit;
        end;
        SinceN := -1;
        if ARequest.QueryFields.IndexOfName('since') >= 0 then
        begin
          AtS := Trim(ARequest.QueryFields.Values['since']);
          SinceN := StrToInt64Def(AtS, -2);
          if SinceN < 0 then
          begin
            SendErr(AResponse, 400, 'since must be a non-negative number',
              'drop it to read the newest page, or pass a seq from a previous page');
            Exit;
          end;
        end;
        LimN := 30;
        if ARequest.QueryFields.IndexOfName('limit') >= 0 then
        begin
          AtS := Trim(ARequest.QueryFields.Values['limit']);
          LimN := StrToIntDef(AtS, -1);
          if (LimN < 1) or (LimN > 200) then
          begin
            SendErr(AResponse, 400, 'limit must be between 1 and 200',
              'drop it for the default of 30');
            Exit;
          end;
        end;
        Ok := Bus(BuildRecent(Cfg.Secret, SinceN, LimN, Cfg.Self_), Reply, WasSent);
        Members := 'messages';
      end
      else if (NSeg = 2) and (Segs[0] = 'message') then
      begin
        if not AllDigits(Segs[1]) then
        begin
          SendErr(AResponse, 400, 'message id must be a positive decimal',
            'use the seq that came in the list');
          Exit;
        end;
        SinceN := StrToInt64Def(Segs[1], 0);
        if SinceN <= 0 then
        begin
          SendErr(AResponse, 400, 'message id must be a positive decimal',
            'use the seq that came in the list');
          Exit;
        end;
        { Requesting ONE means requesting the window immediately before it. }
        Ok := Bus(BuildRecent(Cfg.Secret, SinceN - 1, 1, Cfg.Self_), Reply, WasSent);
        { This returns a LIST of at most one item rather than pretending it is
          an object. An empty list means the message is no longer present, a
          fact the page must be able to distinguish from an error. }
        Members := 'messages>full';
      end
      else if Rest = 'fleet' then
      begin
        Ok := Bus(BuildFleet(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'rows>fleet';
      end
      else if Rest = 'header' then
      begin
        Ok := Bus(BuildHeaderList(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'header';
      end
      else if Rest = 'version' then
      begin
        Ok := Bus(BuildVer(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'ver:s';
      end
      else if Rest = 'projects' then
      begin
        Ok := Bus(BuildProjectList(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'projects';
      end
      else if Rest = 'apps' then
      begin
        Ok := Bus(BuildAppOp(Cfg.Secret, Cfg.Self_, 'list', '', '', '', '', '', '', '', ''), Reply, WasSent);
        Members := 'rows>apps';
      end
      else if (NSeg = 3) and (Segs[0] = 'app') and (Segs[2] = 'history') then
      begin
        Ok := Bus(BuildAppOp(Cfg.Secret, Cfg.Self_, 'history', Segs[1],
               '', '', '', '', '', '', ''), Reply, WasSent);
        { The hub returns this history as a TEXT BLOCK, not a list. Workflow
          history is a list, so the two schemas are declared differently. }
        Members := 'tree>history:s';
      end
      else if (NSeg = 3) and (Segs[0] = 'app') and (Segs[2] = 'doc') then
      begin
        if not QueryOk(ARequest, ['at'], QErr) then
        begin
          SendErr(AResponse, 400, QErr,
            'only at= is accepted here, once, to read an older manual');
          Exit;
        end;
        AtN := 0;
        if ARequest.QueryFields.IndexOfName('at') >= 0 then
        begin
          { PRESENT-BUT-EMPTY again: ?at= does not mean "current." It is a
            malformed request, and serving the current version would answer a
            different question. The number comes from the app history. }
          AtS := Trim(ARequest.QueryFields.Values['at']);
          AtN := StrToIntDef(AtS, -1);
          if AtN <= 0 then
          begin
            SendErr(AResponse, 400, 'at must be a positive history number',
              'drop it to read the current manual, or take a number from ' +
              '/api/app/<name>/history');
            Exit;
          end;
        end;
        Ok := Bus(BuildAppOp(Cfg.Secret, Cfg.Self_, 'doc',
               Segs[1], '', '', '', '', '', '', '', '', 0, AtN), Reply, WasSent);
        { The hub omits "name" from the document response, so complete the
          contract's name+body schema with the name from the URL. This is an
          adapter and is explicit here; omitting it would return an object that
          does not satisfy the promised schema. }
        Members := 'tree>body:s';
        Extra := '"name":' + JsonStr(Segs[1]);
      end
      else if (NSeg = 2) and (Segs[0] = 'app') then
      begin
        Ok := Bus(BuildAppOp(Cfg.Secret, Cfg.Self_, 'show',
               Segs[1], '', '', '', '', '', '', ''), Reply, WasSent);
        Members := 'app';
      end
      else if (NSeg = 2) and (Segs[0] = 'project') then
      begin
        Ok := Bus(BuildProjectShow(Cfg.Secret, Cfg.Self_, Segs[1]),
               Reply, WasSent);
        Members := 'project';
      end
      else if Rest = 'tasks' then
      begin
        if not QueryOk(ARequest, ['filter', 'team'], QErr) then
        begin
          SendErr(AResponse, 400, QErr,
            'only filter= and team= are accepted, once each');
          Exit;
        end;
        { PRESENT-BUT-EMPTY differs from absent. Reading only the value lost
          that distinction, so ?team= meant "no filter" and returned EVERY
          team: a malformed restriction became no restriction. Check the
          parameter's PRESENCE explicitly. }
        if ARequest.QueryFields.IndexOfName('team') >= 0 then
        begin
          Team_ := Trim(ARequest.QueryFields.Values['team']);
          if Team_ = '' then
          begin
            SendErr(AResponse, 400, 'team was given but is empty',
              'drop the parameter to see every team, or name one');
            Exit;
          end;
        end
        else
          Team_ := '';
        { "team" is ONE team name. The hub accepts @group syntax elsewhere but
          not here; if the same parameter sometimes filtered by team and
          sometimes by group, readers could not know what they were viewing. }
        if (Team_ <> '') and ((Pos('@', Team_) > 0) or (Pos(',', Team_) > 0) or
           (Pos(' ', Team_) > 0)) then
        begin
          SendErr(AResponse, 400, 'team must be a single team name',
            'groups are not accepted here: pass one team');
          Exit;
        end;
        if ARequest.QueryFields.IndexOfName('filter') >= 0 then
        begin
          Filt := Trim(ARequest.QueryFields.Values['filter']);
          if Filt = '' then
          begin
            SendErr(AResponse, 400, 'filter was given but is empty',
              'drop the parameter for the default (open), or name one');
            Exit;
          end;
        end
        else
          Filt := '';
        if (Filt <> '') and
           (Pos('|' + Filt + '|',
                '|open|done|all|superseded|cancelled|waiting|error|') = 0) then
        begin
          SendErr(AResponse, 400, 'unknown filter: ' + Filt,
            'use one of open, done, all, superseded, cancelled, waiting, error');
          Exit;
        end;
        { The hub grammar is overloaded: with filter "open" and an unknown
          team, it reinterprets the TEAM as a STATUS. Sending the explicit
          default therefore changed the meaning: ?filter=open&team=error
          returned error tasks from EVERY team. In HTTP, absent and "open"
          must be equivalent, so normalize the default to empty. Send Filt,
          the ALREADY VALIDATED value; forwarding the raw query would discard
          all validation above. }
        if SameText(Filt, 'open') then
          Filt := '';
        Ok := Bus(BuildTaskList(Cfg.Secret, Cfg.Self_, Filt, Team_),
               Reply, WasSent);
        Members := 'tasks';
      end
      else if (NSeg = 2) and (Segs[0] = 'task') then
      begin
        { StrToIntDef accepts "+1" and " 1", so /api/task/%2B1 once reached
          task 1. The contract requires a positive decimal: validate it byte by
          byte before conversion. }
        Id := 0;
        if AllDigits(Segs[1]) then
          Id := StrToIntDef(Segs[1], 0);
        if Id <= 0 then
        begin
          SendErr(AResponse, 400, 'task id must be a positive decimal',
            'use /api/task/<n> with n greater than zero');
          Exit;
        end;
        Ok := Bus(BuildTaskShow(Cfg.Secret, Cfg.Self_, Id), Reply, WasSent);
        Members := 'task,subtasks:[n]';
      end
      else if Rest = 'workflows' then
      begin
        Ok := Bus(BuildWfList(Cfg.Secret, Cfg.Self_), Reply, WasSent);
        Members := 'workflows';
      end
      else if (NSeg = 3) and (Segs[0] = 'workflow') and (Segs[2] = 'history') then
      begin
        Ok := Bus(BuildWfHistory(Cfg.Secret, Cfg.Self_,
               Segs[1]), Reply, WasSent);
        Members := 'history:[s]';
      end
      else if (NSeg = 2) and (Segs[0] = 'workflow') then
      begin
        Ok := Bus(BuildWfShow(Cfg.Secret, Cfg.Self_, Segs[1]), Reply, WasSent);
        Members := 'workflow,tree:s';
      end
      else
      begin
        { The route table and dispatcher must say the SAME thing. If the table
          recognizes a route but this dispatcher has no branch, the 405 given
          to POST would promise a GET that does not exist. Report that loudly. }
        if ReadRouteKnown(Rest, Segs, NSeg) then
          SendErr(AResponse, 500, 'route table and dispatcher disagree: ' + Path,
            'this is a server defect: the route is declared but not served')
        else
          SendErr(AResponse, 404, 'unknown route: ' + Path,
            'see docs/web-api.md for the exact route list');
        Exit;
      end;

      if not Ok then
      begin
        { The verified fact of whether the request was sent selects the error
          variant. Always saying not_sent would invite callers to repeat an
          operation that may have been sent, and this pattern may be copied to
          mutation routes even though these routes only read.

          DISTINGUISH TIMEOUTS FROM FAILURES. A 502 says the hub is broken; a
          timeout says the hub did not answer in time. Those are different
          problems with different remedies. SendBusFail centralizes this
          distinction for every route. }
        SendBusFail(AResponse, WasSent);
        Exit;
      end;

      if ProjectNamed(Reply, Members, DataJson, HubErr, Malformed) then
      begin
        if (Extra <> '') and (Length(DataJson) >= 2) then
          DataJson := '{' + Extra + ',' + Copy(DataJson, 2, Length(DataJson));
        SendOk(AResponse, DataJson);
      end
      else if Malformed then
        SendProtoErr(AResponse, HubErr)
      else
        SendHubErr(AResponse, HubErr);
      Exit;
    end;

    { Static assets. }
    if FindAsset(Path, A) then
    begin
      { POST to "/" once returned 200 with index.html and silently discarded
        the submitted body. A browser using the wrong route then believed that
        it had saved something. }
      if ARequest.Method <> 'GET' then
      begin
        Send405(AResponse, 'GET');
        Exit;
      end;
      { REVALIDATION, THIS TIME EMITTED AS THE STANDARD REQUIRES.
        The first attempt was removed because it left a BLANK page: it returned
        304 with Content-Length: 0 and Content-Type. A response declared to have
        no body but carrying entity headers left the browser waiting for bytes
        that never arrived.
        The cause is how fcl-web emits headers: CollectHeaders (httpdefs) emits
        one ONLY when its field is nonempty (HeaderIsSet). Therefore the only
        way to omit length and type is NOT TO TOUCH THEM; setting length to zero
        differs from leaving it unset. Sending no body requires only
        SendHeaders: the server later invokes SendContent, whose empty Contents
        writes zero bytes.
        This avoids downloading every one of the page's fourteen files, about
        240 KB, on each load. With a browser's six connections this saves not
        only bandwidth but also the queue that delayed modules. }
      if (ARequest.IfNoneMatch <> '') and
         ETagMatches(ARequest.IfNoneMatch, A.ETag) then
      begin
        AResponse.Code := 304;
        AResponse.CodeText := 'Not Modified';
        { CLEAR THE TYPE EXPLICITLY. Merely not setting it is insufficient:
          TResponse starts with text/html, so HeaderIsSet considers it present
          and emits it. A response declared to have no body must not describe
          the absent body's type. Emptying the field removes the header. }
        AResponse.ContentType := '';
        CommonHeaders(AResponse);
        AResponse.SetCustomHeader('Cache-Control', 'no-cache');
        AResponse.SetCustomHeader('ETag', A.ETag);
        { SendHeaders and STOP. Do not touch ContentType, ContentLength, or
          SendExact: touching either entity field emits the header and returns
          to the blank-page failure. }
        AResponse.SendHeaders;
        Exit;
      end;
      AResponse.Code := 200;
      AResponse.ContentType := A.Mime;
      CommonHeaders(AResponse);
      { no-cache does NOT mean "do not store"; it means "store, but revalidate
        before use." This makes deployments visible immediately without making
        each reload download identical content again. }
      AResponse.SetCustomHeader('Cache-Control', 'no-cache');
      AResponse.SetCustomHeader('ETag', A.ETag);
      SendExact(AResponse, A.Bytes);
      Exit;
    end;

    SendErr(AResponse, 404, 'not found: ' + Path,
      'only the exact URLs loaded at startup are served');
  except
    on E: Exception do
      { If the response has already started, do not append an error. Log it and
        stop. Writing over an in-progress response informs nobody and corrupts
        content that may otherwise have been valid. }
      if AResponse.HeadersSent then
      begin
        Writeln(StdErr, Format('pzweb: failure after response started to %s (%s): %s',
          [CurPeer, CurWhat, E.Message]));
        Flush(StdErr);
      end
      else
        SendErr(AResponse, 500, 'internal error', E.Message);
   end;
  finally
    { Keep this IN A finally, not after the try. Almost every route ends with
      Exit, which skips code placed after the try. The first version logged only
      requests that fell through to 404, almost none, making logging appear
      broken. }
    if Pos('/api/feed', ARequest.URI) <> 1 then
    begin
      { INCLUDE A CLOCK AS PART OF THE CONTRACT. Operation attribution is split
        between two logs: the hub log says WHAT happened and attributes it to
        pzweb, while this log says WHERE it came from. Without a shared clock
        they can only be correlated by order, which is insufficient when two
        sources interleave or when bounding the start of a failure. Use the hub
        log format deliberately. NowStamp from pzlog is unavailable because it
        is private to that unit's implementation. }
      Writeln(StdErr, Format('pzweb: %s %d %s %s %.0f ms',
        [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now),
         AResponse.Code, CurWhat, CurPeer, (Now - T0) * 24 * 60 * 60 * 1000]));
      Flush(StdErr);
    end;
  end;
end;

{ ------------------------------------------------------------------ config }

{ Do NOT replace a malformed port with the default. Someone who wrote
  "port = 708O" believes they selected a port, and starting on another one is
  worse than refusing to start. }
function PortOf(const What, Val: string): Integer;
begin
  Result := StrToIntDef(Trim(Val), -1);
  if (Result < 1) or (Result > 65535) then
    Fail(Format('%s is not a port between 1 and 65535: %s', [What, Val]));
end;

procedure LoadCfg(const Path: string);
var
  Ini: TStringList;
  i: Integer;
  Sec, Line, Key, Val: string;
  p: Integer;
  BadComp: string;
  ListenV: LongWord;
  OErr: string;
  ConfigFd: Integer;
  ConfigStream: THandleStream;
begin
  ConfigFd := -1;
  if not PzOpenPrivateConfig(Path, ConfigFd, BadComp, OErr) then
    Fail('config is unsafe: ' + OErr +
      ' — refusing to start because it holds the web team credential');
  Cfg.Port := 7010;
  Cfg.WebPort := 7080;
  Cfg.Listen := '127.0.0.1';
  Cfg.AppsDir := PZ_WEB_ASSETS_DIR;
  Ini := nil;
  ConfigStream := nil;
  try
    Ini := TStringList.Create;
    ConfigStream := THandleStream.Create(ConfigFd);
    Ini.LoadFromStream(ConfigStream);
    Sec := '';
    for i := 0 to Ini.Count - 1 do
    begin
      Line := Trim(Ini[i]);
      if (Line = '') or (Line[1] = '#') or (Line[1] = ';') then
        Continue;
      if Line[1] = '[' then
      begin
        Sec := LowerCase(Copy(Line, 2, Length(Line) - 2));
        Continue;
      end;
      p := Pos('=', Line);
      if p = 0 then
        Continue;
      Key := LowerCase(Trim(Copy(Line, 1, p - 1)));
      Val := Trim(Copy(Line, p + 1, Length(Line)));
      if Sec = 'pizarra' then
      begin
        if Key = 'host' then Cfg.Host := Val
        else if Key = 'port' then Cfg.Port := PortOf('[pizarra] port', Val)
        else if Key = 'secret' then Cfg.Secret := Val
        else if Key = 'self' then Cfg.Self_ := Val;
      end
      else if Sec = 'web' then
      begin
        if Key = 'listen' then
        begin
          { An EMPTY listen= is not "unset"; it explicitly replaces the
            127.0.0.1 default. With an empty Address, FPC selects
            TInetServer.Create(Port), which ssockets interprets as 0.0.0.0, ALL
            interfaces. The operator could believe the network boundary was
            narrowed while it had actually been opened completely. }
          if Trim(Val) = '' then
            Fail('[web] listen is empty: that would bind every interface ' +
                 '(0.0.0.0), the opposite of the intended boundary');
          { Rejecting empty input closes only ONE path to the same unsafe state;
            an explicit wildcard has exactly the same effect. }
          if not Ip4(Trim(Val), ListenV) then
            Fail('[web] listen is not an IPv4 address: ' + Trim(Val));
          { Decide based on the VALUE, not its spelling. String comparison
            missed its own edge case: 00.00.00.00 parses as zero and is the
            same wildcard written differently. }
          if ListenV = 0 then
            Fail('[web] listen=' + Trim(Val) + ' is the wildcard address ' +
                 '(binds every interface): name the one address this console ' +
                 'must answer on');
          Cfg.Listen := Trim(Val);
        end
        else if Key = 'port' then Cfg.WebPort := PortOf('[web] port', Val)
        else if Key = 'allow_from' then Cfg.AllowFrom := SplitList(Val)
        else if Key = 'host' then Cfg.HostExp := Val
        else if Key = 'user' then Cfg.User := Trim(Val)
        else if Key = 'password_sha256' then Cfg.PassHash := LowerCase(Trim(Val))
        else if Key = 'origin' then Cfg.Origin := Val
        else if Key = 'static' then Cfg.AppsDir := Val
        else if Key = 'shared' then Cfg.SharedDir := Val
        else if Key = 'apps' then
          { The contract says "static." Silently accepting the former name
            would leave configuration that appears to be read but is not. }
          Fail('[web] apps= is not the contract name: use static=');
      end;
    end;
  finally
    FreeAndNil(ConfigStream);
    FpClose(ConfigFd);
    FreeAndNil(Ini);
  end;
  if Cfg.Secret = '' then
    Fail('[pizarra] secret is empty: refusing to start');
  if Cfg.Self_ = '' then
    Fail('[pizarra] self is empty: refusing to start');
  if Length(Cfg.AllowFrom) = 0 then
    Fail('[web] allow_from is empty: the network IS the only boundary, so ' +
         'refusing to start rather than serving everyone');
  if Cfg.HostExp = '' then
    Fail('[web] host is empty: without it any Host header passes and a rebound ' +
         'DNS name would read as same-origin');
  { File exchange is OPTIONAL; without it, its routes report that it is not
    configured. When present, validate it with the static-tree rules BEFORE
    listening. A link in any component can redirect the entire tree, and
    discovering that during the first listing is too late. }
  if Cfg.SharedDir <> '' then
  begin
    { Match the hub loader. ExcludeTrailingPathDelimiter removes only one
      separator in FPC 3.2.2, so normalize the complete suffix before deciding
      whether this is the filesystem root. }
    while (Length(Cfg.SharedDir) > 1) and
          CharInSet(Cfg.SharedDir[Length(Cfg.SharedDir)],
            AllowDirectorySeparators) do
      Delete(Cfg.SharedDir, Length(Cfg.SharedDir), 1);
    if Cfg.SharedDir[1] <> PathDelim then
      Fail('[web] shared must be an absolute path; a relative NFS mount ' +
        'would resolve against the pzweb process working directory');
    if Cfg.SharedDir = PathDelim then
      Fail('[web] shared may not be the filesystem root; configure a ' +
        'dedicated external directory or NFS mount');
    if not NoSymlinkInPath(Cfg.SharedDir, BadComp) then
      Fail('[web] shared dir path is unsafe: ' + BadComp + ' — refusing to start');
    if not DirectoryExists(Cfg.SharedDir) then
      Fail(Format('[web] shared dir %s does not exist: refusing to start',
        [Cfg.SharedDir]));
    Cfg.SharedDir := ExpandFileName(Cfg.SharedDir);
  end;
  if Cfg.Origin = '' then
    Fail('[web] origin is empty: refusing to start');
  { Merely setting Origin is NOT enough. Browsers construct it from the address
    used to reach the server, and that address is the only accepted Host. If
    the configured origin names ANOTHER authority, no browser can ever emit it
    and EVERY mutation remains rejected while the service appears healthy. A
    configuration that cannot work must fail at startup, not at the first
    button click. Compare AUTHORITIES rather than complete strings because a
    front proxy may serve the same name over HTTPS. }
  if not OriginCoherent(Cfg.Origin, Cfg.HostExp, OErr) then
    Fail('[web] origin ' + Cfg.Origin + ' can never be sent by a browser ' +
         'that reaches host ' + Cfg.HostExp + ': ' + OErr);
  { With administration exposed, the network is no longer the only boundary;
    without authentication, anyone on the LAN could create or delete teams.
    Require authentication and store a DIGEST rather than the password because
    configuration files are often read, backed up, and displayed casually. }
  if Cfg.User = '' then
    Fail('[web] user is empty: refusing to start (this console can administer)');
  { HTTP Basic splits on the FIRST colon, so a username containing one could
    never authenticate. An apparently configured login that can never succeed
    is worse than a visibly missing one. }
  if Pos(':', Cfg.User) > 0 then
    Fail('[web] user cannot contain a colon: HTTP Basic splits on it and that ' +
         'account could never sign in');
  { Sixty-four characters are NOT necessarily sixty-four hexadecimal digits.
    A value made of sixty-four "g" characters passed the length check and left
    an unusable login that appeared configured. }
  if Length(Cfg.PassHash) <> 64 then
    Fail('[web] password_sha256 must be a 64-hex SHA-256 digest of the ' +
         'password: refusing to start (never store the password itself)');
  for i := 1 to 64 do
    if not (Cfg.PassHash[i] in ['0'..'9', 'a'..'f']) then
      Fail('[web] password_sha256 is not hexadecimal: refusing to start');
  { Do NOT ignore a malformed perimeter rule with a warning. Its author
    believes it protects something, so refuse to start. }
  for i := 0 to High(Cfg.AllowFrom) do
    if not RuleWellFormed(Cfg.AllowFrom[i]) then
      Fail('[web] malformed allow_from rule: ' + Cfg.AllowFrom[i]);
end;

function ProbeWebListener(out Why: string): Boolean;
var
  Sock: TInetSocket;
begin
  Result := False;
  Why := '';
  Sock := nil;
  try
    try
      { A completed TCP connect proves that the configured address and port are
        actually bound. The server may immediately reject this internal probe
        through allow_from; admission and authentication remain normal request
        boundaries and are not weakened for readiness. }
      Sock := TInetSocket.Create(Cfg.Listen, Word(Cfg.WebPort), 1000);
      Result := True;
    except
      on E: Exception do
        Why := E.Message;
    end;
  finally
    Sock.Free;
  end;
end;

procedure RunWebHealth(WaitSeconds: Integer);
var
  StopAt: QWord;
  Why: string;
begin
  StopAt := GetTickCount64 + QWord(WaitSeconds) * 1000;
  repeat
    if ProbeWebListener(Why) then
    begin
      Writeln(Format('pzweb health: ok endpoint=http://%s:%d',
        [Cfg.Listen, Cfg.WebPort]));
      Exit;
    end;
    if GetTickCount64 >= StopAt then
      Break;
    Sleep(200);
  until False;
  Fail('health check failed: cannot connect to ' + Cfg.Listen + ':' +
    IntToStr(Cfg.WebPort) + ': ' + Why);
end;

{ ---------------------------------------------------------------------- main }

var
  Srv: TPzWebServer;
  CfgPath, ConfigArg, ConfigReason: string;
  i, HealthWait: Integer;
  HealthMode: Boolean;
begin
  { Match the hub and tiza: without this setting fpjson converts decoded text
    through the system code page (often LANG=C under systemd/tmux), producing
    Latin-1 bytes inside a response declared as UTF-8. The browser then receives
    invalid bytes and JSON.parse fails. }
  SetMultiByteConversionCodePage(CP_UTF8);
  ConfigArg := '';
  HealthMode := False;
  HealthWait := 0;
  i := 1;
  while i <= ParamCount do
  begin
    if (ParamStr(i) = '--version') or (ParamStr(i) = '-v') then
    begin
      Writeln('pzweb ', PizarraVersion);
      Halt(0);
    end
    else if ParamStr(i) = '--config' then
    begin
      if i >= ParamCount then
        Fail('--config requires a path');
      ConfigArg := ParamStr(i + 1);
      Inc(i);
    end
    else if ParamStr(i) = '--health' then
      HealthMode := True
    else if ParamStr(i) = '--wait' then
    begin
      if not HealthMode then
        Fail('--wait is valid only after --health');
      if (i >= ParamCount) or
         (not TryStrToInt(ParamStr(i + 1), HealthWait)) or
         (HealthWait < 0) or (HealthWait > 120) then
        Fail('--wait requires seconds between 0 and 120');
      Inc(i);
    end
    else if ParamStr(i) = '--help' then
    begin
      Writeln('usage: pzweb [--config PATH] [--health [--wait SECONDS]] [--version]');
      Halt(0);
    end
    else
      Fail('unknown option: ' + ParamStr(i));
    Inc(i);
  end;
  CfgPath := ResolveConfigStrict(ConfigArg, 'PZWEB_CONF', 'pzweb.conf',
    ConfigReason);
  if CfgPath = '' then
  begin
    if ConfigReason <> '' then
      Fail(ConfigReason)
    else
      Fail('no config found at /etc/pizarra/pzweb.conf; create it with mode ' +
        '0600 or use --config PATH');
  end;

  LoadCfg(CfgPath);
  if HealthMode then
  begin
    RunWebHealth(HealthWait);
    Halt(0);
  end;
  Writeln('pzweb ', PizarraVersion, ' starting');

  { DELIBERATE ORDER: prove that the credential binds first, then open network
    resources. Reversing the order would leave the socket listening until a
    failed binding check completes. }
  ProveBinding;
  LoadAssets;

  InitCriticalSection(ConnLock);
  ConnPeer := TStringList.Create;
  FeedPeer := TStringList.Create;
  Srv := TPzWebServer.Create(nil);
  try
    Srv.Address := Cfg.Listen;
    Srv.Port := Cfg.WebPort;
    Srv.Threaded := True;
    { LISTEN BACKLOG. fcl-web defaults to FIVE
      (fphttpserver.pp: FQueueSize := 5), which is how many connections the
      kernel lets WAIT for the server to accept them. Reloading this page asks
      for fourteen resources almost simultaneously, so two quick reloads can
      make the kernel reject connections before this process sees them. The
      browser reports a dropped connection and the log has NOTHING because the
      server never received it.
      Sixty-four is not magic and does not solve the underlying latency, which
      the timeouts above address. It simply stops dropping connections that
      could otherwise have been handled. }
    Srv.QueueSize := 64;
    Admit := TAdmit.Create;
    Srv.OnAllowConnect := @Admit.Allow;
    Srv.OnRequest := @Srv.Handle;
    { Active=True performs bind/listen and then blocks in the accept loop. Do
      not claim readiness before that call: systemd's authenticated post-start
      probe is the positive readiness signal. }
    Writeln('pzweb: starting HTTP listener on http://', Cfg.Listen, ':',
      Cfg.WebPort, '/');
    { With output redirected to a file, FPC buffers it until the process exits.
      A daemon that never exits therefore had an ALWAYS empty log, including
      the startup checks that had just passed. Evidence nobody can read proves
      nothing, so flush it explicitly. }
    Flush(Output);
    Srv.Active := True;
  finally
    Srv.Free;
    Admit.Free;
    ConnPeer.Free;
    FeedPeer.Free;
    DoneCriticalSection(ConnLock);
  end;
end.
