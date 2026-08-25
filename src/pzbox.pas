{ pzbox - boxes and tables for tiza output.

  Golden rule: draw frames ONLY when output goes to a real terminal. When
  output is redirected to a pipe, file, external process, or test suite, return
  the exact plain text expected by parsers.

  Width is measured in CHARACTERS, not bytes: accented text may use multiple
  UTF-8 bytes while occupying a single terminal column. }
unit pzbox;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TCells = array of string;
  TRows  = array of TCells;

{ True when decorated output is appropriate: stdout is a TTY and neither
  NO_COLOR nor PZ_PLAIN requested plain text. Computed once at startup. }
function Pretty: Boolean;
procedure SetPretty(Value: Boolean);

{ Visible width of a UTF-8 string, counted in code points. }
function VisLen(const S: string): Integer;
{ Trim to N visible characters, adding '…' when the value does not fit. }
function VisCut(const S: string; N: Integer): string;

{ A table with a header. MaxCol limits EVERY column's width (0 means unlimited);
  the last column is trimmed until the table fits within Width. }
function Table(const Headers: TCells; const Rows: TRows;
  Width: Integer = 100): string;

{ A card: title plus label/value pairs, with each value fitted to the width. }
function Card(const Title: string; const Keys, Vals: TCells;
  Width: Integer = 100): string;

{ A preformatted text block framed with a title. Lines that do not fit are
  TRIMMED with an ellipsis; intended for text that is already measured. }
function Frame(const Title, Body: string; Width: Integer = 100): string;

{ As above, except long lines WRAP instead of being trimmed, with continuation
  text indented beneath the first line. Intended for trees and lists where
  indentation and line endings both carry information: trimming a milestone
  can hide the exact text the reader needs. }
function FrameWrap(const Title, Body: string; Width: Integer = 100): string;

implementation

var
  GPretty: Boolean = False;

function Pretty: Boolean;
begin
  Result := GPretty;
end;

procedure SetPretty(Value: Boolean);
begin
  GPretty := Value;
end;

{ VISIBLE width: neither UTF-8 continuation bytes nor color sequences occupy a
  column. Color handling used to be missing, so styled lines shifted the frame
  precisely where styling was meant to draw attention. }
function VisLen(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := 1;
  while i <= Length(S) do
  begin
    if (Ord(S[i]) = 27) and (i < Length(S)) and (S[i + 1] = '[') then
    begin
      { CSI sequence: ESC [ parameters... final byte between @ and ~. }
      Inc(i, 2);
      while (i <= Length(S)) and not (S[i] in ['@'..'~']) do
        Inc(i);
      Inc(i);
      Continue;
    end;
    { Count only bytes that are NOT UTF-8 continuation bytes (10xxxxxx). }
    if (Ord(S[i]) and $C0) <> $80 then
      Inc(Result);
    Inc(i);
  end;
end;

function VisCut(const S: string; N: Integer): string;
var
  i, seen: Integer;
  HadEsc: Boolean;
begin
  if (N <= 0) or (VisLen(S) <= N) then
    Exit(S);
  Result := '';
  seen := 0;
  i := 1;
  HadEsc := False;
  while (i <= Length(S)) and (seen < N - 1) do
  begin
      { Copy a color sequence WHOLE without counting it. Splitting it would
        leave screen garbage and an active color. }
    if (Ord(S[i]) = 27) and (i < Length(S)) and (S[i + 1] = '[') then
    begin
      HadEsc := True;
      Result := Result + S[i] + S[i + 1];
      Inc(i, 2);
      while (i <= Length(S)) and not (S[i] in ['@'..'~']) do
      begin
        Result := Result + S[i];
        Inc(i);
      end;
      if i <= Length(S) then
      begin
        Result := Result + S[i];
        Inc(i);
      end;
      Continue;
    end;
    Result := Result + S[i];
    Inc(i);
    { Include continuation bytes belonging to the same character. }
    while (i <= Length(S)) and ((Ord(S[i]) and $C0) = $80) do
    begin
      Result := Result + S[i];
      Inc(i);
    end;
    Inc(seen);
  end;
  { If a styled line was cut, close its styling; otherwise color spills across
    the frame border and following lines. }
  if HadEsc then
    Result := Result + #27'[0m';
  Result := Result + '…';
end;

{ Repeat the thin box bar N times. It is multibyte UTF-8, so StringOfChar is
  unsuitable. }
function HLine(N: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to N do
    Result := Result + '─';
end;

function Pad(const S: string; N: Integer): string;
begin
  Result := S;
  if VisLen(Result) < N then
    Result := Result + StringOfChar(' ', N - VisLen(Result));
end;

function Rule(const L, M, R: string; const W: array of Integer): string;
var
  i: Integer;
begin
  Result := L;
  for i := 0 to High(W) do
  begin
    Result := Result + StringOfChar('-', W[i] + 2);
    if i < High(W) then
      Result := Result + M;
  end;
  { Draw horizontal bars with the thin box character. }
  Result := StringReplace(Result, '-', '─', [rfReplaceAll]) + R;
end;

function Table(const Headers: TCells; const Rows: TRows; Width: Integer): string;
var
  W: array of Integer;
  i, j, total, over, last: Integer;
  Line: string;
begin
  if Length(Headers) = 0 then
    Exit('');
  SetLength(W, Length(Headers));
  for j := 0 to High(Headers) do
    W[j] := VisLen(Headers[j]);
  for i := 0 to High(Rows) do
    for j := 0 to High(Rows[i]) do
      if (j <= High(W)) and (VisLen(Rows[i][j]) > W[j]) then
        W[j] := VisLen(Rows[i][j]);

  { Plain text for nonterminal output: classic two-space columns with no frames
    or trimming, preserving the format consumed by existing parsers. }
  if not GPretty then
  begin
    Result := '';
    for i := 0 to High(Rows) do
    begin
      Line := '';
      for j := 0 to High(Rows[i]) do
      begin
        if j > 0 then
          Line := Line + ' ';
        if j < High(Rows[i]) then
          Line := Line + Pad(Rows[i][j], W[j])
        else
          Line := Line + Rows[i][j];
      end;
      Result := Result + TrimRight(Line) + #10;
    end;
    Exit(TrimRight(Result));
  end;

  { If the table does not fit, shrink the WIDEST column and repeat. Previously
    only the last column shrank, so a long middle column such as a team's
    specialty followed by a short final column overflowed and wrapped into an
    unreadable layout. No column shrinks below 10 visible characters. }
  total := 1;
  for j := 0 to High(W) do
    Inc(total, W[j] + 3);
  while total > Width do
  begin
    last := 0;
    for j := 1 to High(W) do
      if W[j] > W[last] then
        last := j;
    if W[last] <= 10 then
      Break;                { Nothing else can be trimmed. }
    over := total - Width;
    if W[last] - over < 10 then
      over := W[last] - 10;
    Dec(W[last], over);
    Dec(total, over);
  end;

  Result := Rule('┌', '┬', '┐', W) + #10;
  Line := '│';
  for j := 0 to High(Headers) do
    Line := Line + ' ' + Pad(VisCut(Headers[j], W[j]), W[j]) + ' │';
  Result := Result + Line + #10 + Rule('├', '┼', '┤', W) + #10;
  for i := 0 to High(Rows) do
  begin
    Line := '│';
    for j := 0 to High(W) do
    begin
      if j <= High(Rows[i]) then
        Line := Line + ' ' + Pad(VisCut(Rows[i][j], W[j]), W[j]) + ' │'
      else
        Line := Line + ' ' + StringOfChar(' ', W[j]) + ' │';
    end;
    Result := Result + Line + #10;
  end;
  Result := Result + Rule('└', '┴', '┘', W);
end;

{ Split S into chunks of N visible characters, breaking at spaces. }
procedure WrapInto(const S: string; N: Integer; Dst: TStrings);
var
  Rest, Chunk: string;
  cut, i, seen: Integer;
begin
  Rest := S;
  if Trim(Rest) = '' then
  begin
    Dst.Add('');
    Exit;
  end;
  while VisLen(Rest) > N do
  begin
    { Advance N characters, then backtrack to the final space. }
    Chunk := '';
    seen := 0;
    i := 1;
    while (i <= Length(Rest)) and (seen < N) do
    begin
      Chunk := Chunk + Rest[i];
      Inc(i);
      while (i <= Length(Rest)) and ((Ord(Rest[i]) and $C0) = $80) do
      begin
        Chunk := Chunk + Rest[i];
        Inc(i);
      end;
      Inc(seen);
    end;
    cut := LastDelimiter(' ', Chunk);
    if cut > 1 then
    begin
      Dst.Add(Copy(Chunk, 1, cut - 1));
      Rest := Trim(Copy(Rest, cut + 1, Length(Rest)));
    end
    else
    begin
      Dst.Add(Chunk);
      Rest := Trim(Copy(Rest, Length(Chunk) + 1, Length(Rest)));
    end;
  end;
  if Rest <> '' then
    Dst.Add(Rest);
end;

function Card(const Title: string; const Keys, Vals: TCells;
  Width: Integer): string;
var
  KW, VW, i, j: Integer;
  L: TStringList;
  Rule2: string;
begin
  KW := 0;
  for i := 0 to High(Keys) do
    if VisLen(Keys[i]) > KW then
      KW := VisLen(Keys[i]);

  if not GPretty then
  begin
    Result := Title + #10;
    for i := 0 to High(Keys) do
      Result := Result + '  ' + Pad(Keys[i] + ':', KW + 3) + Vals[i] + #10;
    Exit(TrimRight(Result));
  end;

  VW := Width - KW - 7;
  if VW < 20 then
    VW := 20;
  Rule2 := HLine(KW + VW + 5);
  Result := '┌' + Rule2 + '┐' + #10 +
    '│ ' + Pad(VisCut(Title, KW + VW + 3), KW + VW + 3) + ' │' + #10 +
    '├' + Rule2 + '┤' + #10;
  L := TStringList.Create;
  try
    for i := 0 to High(Keys) do
    begin
      L.Clear;
      WrapInto(Vals[i], VW, L);
      for j := 0 to L.Count - 1 do
        if j = 0 then
          Result := Result + '│ ' + Pad(Keys[i] + ':', KW + 2) + ' ' +
            Pad(L[j], VW) + ' │' + #10
        else
          Result := Result + '│ ' + StringOfChar(' ', KW + 2) + ' ' +
            Pad(L[j], VW) + ' │' + #10;
    end;
  finally
    L.Free;
  end;
  Result := Result + '└' + Rule2 + '┘';
end;

{ Take N VISIBLE characters without adding an ellipsis. VisCut trims for
  display; this routine splits so processing can continue. }
function TakeVis(const S: string; N: Integer): string;
var
  i, seen: Integer;
begin
  Result := '';
  seen := 0;
  i := 1;
  while (i <= Length(S)) and (seen < N) do
  begin
    Result := Result + S[i];
    Inc(i);
    while (i <= Length(S)) and ((Ord(S[i]) and $C0) = $80) do
    begin
      Result := Result + S[i];
      Inc(i);
    end;
    Inc(seen);
  end;
end;

function FrameWrap(const Title, Body: string; Width: Integer): string;
var
  L: TStringList;
  i, W, PadN, Room, Cut: Integer;
  Payload, Pad, Chunk, Out_, Pre: string;
begin
  W := Width - 4;
  if W < 20 then
    W := 20;
  L := TStringList.Create;
  try
    L.Text := Body;
    Out_ := '';
    for i := 0 to L.Count - 1 do
    begin
      if L[i] = '' then
      begin
        Out_ := Out_ + #10;
        Continue;
      end;
      { Separate tree decoration from text ONCE, then wrap ONLY the text. The
        previous implementation trimmed the whole line and restored indentation
        afterward. If indentation filled the width, the chunk contained no text
        and the remainder never changed, so the loop NEVER advanced and hung
        chat while rendering a deeply nested tree. Wrapping text guarantees
        that every pass consumes input. }
      PadN := 1;
      while (PadN <= Length(L[i])) and (L[i][PadN] in [' ', '|', '`', '-']) do
        Inc(PadN);
      Dec(PadN);
      Pre := Copy(L[i], 1, PadN);
      Payload := Copy(L[i], PadN + 1, Length(L[i]));
      { Continuation indentation must NEVER consume the entire width; always
        reserve room for text. }
      if PadN > W - 8 then
        PadN := W - 8;
      if PadN < 0 then
        PadN := 0;
      Pad := StringOfChar(' ', PadN);
      { Decoration cannot consume the entire box either. Trim it when it leaves
        no room for text. Previously the frame trimmed the complete emitted line
        and lost exactly the text it needed to preserve. }
      if VisLen(Pre) > W - 8 then
        Pre := TakeVis(Pre, W - 8);
      Room := W - VisLen(Pre);
      if Room < 8 then
        Room := 8;
      while True do
      begin
        if VisLen(Payload) <= Room then
        begin
          Out_ := Out_ + Pre + Payload + #10;
          Break;
        end;
        Chunk := TakeVis(Payload, Room);
        Cut := Length(Chunk);
        while (Cut > 1) and (Chunk[Cut] <> ' ') do
          Dec(Cut);
        if Cut <= 1 then
          Cut := Length(Chunk);   { Split a word wider than the box. }
        Out_ := Out_ + Pre + Copy(Chunk, 1, Cut) + #10;
        Payload := TrimLeft(Copy(Payload, Cut + 1, Length(Payload)));
        if Payload = '' then
          Break;
        Pre := Pad;
        Room := W - PadN;
        if Room < 8 then
          Room := 8;
      end;
    end;
  finally
    L.Free;
  end;
  Result := Frame(Title, Out_, Width);
end;

function Frame(const Title, Body: string; Width: Integer): string;
var
  L: TStringList;
  i, W: Integer;
  Rule2: string;
begin
  if not GPretty then
    Exit(Body);
  L := TStringList.Create;
  try
    L.Text := Body;
    W := VisLen(Title);
    for i := 0 to L.Count - 1 do
      if VisLen(L[i]) > W then
        W := VisLen(L[i]);
    if W > Width - 4 then
      W := Width - 4;
    Rule2 := HLine(W + 2);
    Result := '┌' + Rule2 + '┐' + #10;
    if Title <> '' then
      Result := Result + '│ ' + Pad(VisCut(Title, W), W) + ' │' + #10 +
        '├' + Rule2 + '┤' + #10;
    for i := 0 to L.Count - 1 do
      if (i < L.Count - 1) or (Trim(L[i]) <> '') then
        Result := Result + '│ ' + Pad(VisCut(L[i], W), W) + ' │' + #10;
    Result := Result + '└' + Rule2 + '┘';
  finally
    L.Free;
  end;
end;

end.
