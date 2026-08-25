unit pzansi;

{ pzansi - THE single ANSI color gate + identity palette for every human-facing
  pizarra surface (tiza chat feed, /full, /log, /inbox, future tiza log).

  Contract (docs/cli.md):
  - ONE gate for the whole project. AnsiInit decides once; every primitive
    returns its input untouched when colors are off, so plain output is
    byte-identical to the pre-color era by construction.
  - Colors are applied at PRINT-TIME only: never store styled text in rings,
    buffers, history or anything that could reach the wire (C1 purity).
  - No nesting: a wrapped segment ends in a full reset, so nesting an outer
    style around Dim/Fg/Bold loses the outer style after the inner segment.
    Compose lines from adjacent styled segments instead.
  - No background colors ever: ESC[K erases with the current bg and smears.
  - Identity colors are deterministic (FNV-1a of the lowercased name) so the
    same team gets the same color in every process, pane and restart.        }

{$mode objfpc}{$H+}

interface

type
  TColorMode = (cmAuto, cmAlways, cmNever);

{ Decide the gate once, at program/surface start.
    cmNever  - hard off (--plain: the frozen machine surface).
    cmAlways - hard on  (e.g. a future --color always for piping into less -R).
    cmAuto   - on iff stdout is a tty AND NO_COLOR is unset/empty AND TERM is
               neither empty nor 'dumb'. The TIZA_COLOR env var overrides auto:
               'always' forces on (pipes), 'never'/'off' forces off.          }
procedure AnsiInit(Mode: TColorMode);

{ Late kill switch: termios degradation after a colored banner, etc. }
procedure AnsiOff;

function ColorsOn: Boolean;

{ Primitives: S wrapped in SGR when colors are on; S untouched otherwise. }
function Dim(const S: string): string;
function Bold(const S: string): string;
function Inverse(const S: string): string;   { reverse video (SGR 7) }
function Fg(Color: Byte; const S: string): string;       { 256-color foreground }
function FgBold(Color: Byte; const S: string): string;

{ Identity colors (stable across processes and restarts). }
function TeamColor(const Team: string): Byte;
function GroupColor(const Grp: string): Byte;

{ Collision-free palette assignment over a known roster: sorts the names
  (case-insensitive) so ANY process with the same roster computes the same
  assignment, then places each at its hash slot probing forward to the first
  free one. With <= 12 teams every team gets a distinct color. Names not in
  the roster fall back to the plain hash. Call on every roster refresh. }
procedure AssignPalette(const Names: array of string);

{ Render a team name with its identity: console = bold white (the operator
  must spot themself instantly), all/broadcast = dim, anything else = its
  palette color. }
function TeamName(const Team: string): string;

const
  { reserved semantic colors — never assigned to teams. Soft-pastel family to
    match the team palette, except ALERT which stays punchy on purpose (a gap
    is the one event that must grab the eye). }
  ALERT_FG = 203;   { soft red: gap markers, errors (still pops) }
  TASK_FG  = 222;   { soft gold: task events }
  HINT_FG  = 159;   { pale aqua: affordances like '/full 2216' }
  SELF_FG  = 231;   { near-white: console/self (always bold) }

{ Display cells of S, skipping CSI escape sequences. Cell rule matches
  pzchat.CellsUpto: every byte that is not a UTF-8 continuation byte counts
  as one cell (invalid bytes degrade to one cell each, never crash).         }
function VisCells(const S: string): Integer;

{ Strip color sequences from text. The HUB styles rendered output, such as a
  workflow tree, without knowing whether the client is a terminal or a file.
  The client decides: when colors are disabled, it strips them before printing. }
function StripAnsi(const S: string): string;

implementation

uses
  SysUtils, Classes, termio;

const
  ESC = #27;

  { 12 curated SOFT-PASTEL 256-color slots: light, desaturated tones from the
    upper color cube, well separated in hue and readable on dark backgrounds.
    Reserved semantics (203/222/159/231) are not in the pool. }
  TEAM_PALETTE: array[0..11] of Byte =
    (210,   { soft coral   }
     216,   { soft orange  }
     189,   { pale lavender-blue }
     150,   { soft lime    }
     157,   { soft mint    }
     152,   { soft teal    }
     153,   { soft sky     }
     147,   { periwinkle   }
     183,   { soft violet  }
     176,   { soft orchid  }
     218,   { soft pink    }
     180);  { soft tan     }

  { muted (grayed-pastel) pool for group accents: soft but must not compete
    with the team colors that sit on top }
  GROUP_PALETTE: array[0..5] of Byte = (108, 103, 144, 66, 96, 138);

var
  GOn: Boolean = False;
  { roster assignment: lowercased name -> palette index, built by AssignPalette }
  GMap: TStringList = nil;

procedure AnsiInit(Mode: TColorMode);
var
  Env: string;
begin
  case Mode of
    cmNever:  GOn := False;
    cmAlways: GOn := True;
    cmAuto:
      begin
        Env := LowerCase(Trim(GetEnvironmentVariable('TIZA_COLOR')));
        if Env = 'always' then
          GOn := True
        else if (Env = 'never') or (Env = 'off') then
          GOn := False
        else
          GOn := (IsATTY(1) = 1) and
                 (GetEnvironmentVariable('NO_COLOR') = '') and
                 (GetEnvironmentVariable('TERM') <> '') and
                 (GetEnvironmentVariable('TERM') <> 'dumb');
      end;
  end;
end;

procedure AnsiOff;
begin
  GOn := False;
end;

function ColorsOn: Boolean;
begin
  Result := GOn;
end;

{ core wrapper: full reset at the end (see the no-nesting rule above) }
function Sgr(const Codes, S: string): string;
begin
  if GOn then
    Result := ESC + '[' + Codes + 'm' + S + ESC + '[0m'
  else
    Result := S;
end;

function Dim(const S: string): string;
begin
  Result := Sgr('2', S);
end;

function Bold(const S: string): string;
begin
  Result := Sgr('1', S);
end;

function Inverse(const S: string): string;
begin
  Result := Sgr('7', S);
end;

function Fg(Color: Byte; const S: string): string;
begin
  Result := Sgr('38;5;' + IntToStr(Color), S);
end;

function FgBold(Color: Byte; const S: string): string;
begin
  Result := Sgr('1;38;5;' + IntToStr(Color), S);
end;

{ FNV-1a needs wrap-around multiplication: locally disable overflow/range
  checks so the debug build (-Ci -Co -Cr) survives. }
{$push}{$Q-}{$R-}
function Fnv1a(const S: string): Cardinal;
var
  i: Integer;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
  begin
    Result := Result xor Byte(S[i]);
    Result := Result * 16777619;
  end;
end;
{$pop}

procedure AssignPalette(const Names: array of string);
var
  Sorted: TStringList;
  Used: array[0..High(TEAM_PALETTE)] of Boolean;
  i, Slot, Probes: Integer;
begin
  if GMap = nil then
    GMap := TStringList.Create;
  GMap.Clear;
  for i := 0 to High(Used) do
    Used[i] := False;
  Sorted := TStringList.Create;
  try
    for i := 0 to High(Names) do
      if Trim(Names[i]) <> '' then
        Sorted.Add(LowerCase(Trim(Names[i])));
    Sorted.Sort;   { deterministic order regardless of arrival order }
    for i := 0 to Sorted.Count - 1 do
    begin
      Slot := Integer(Fnv1a(Sorted[i]) mod Cardinal(Length(TEAM_PALETTE)));
      Probes := 0;
      while Used[Slot] and (Probes < Length(TEAM_PALETTE)) do
      begin
        Slot := (Slot + 1) mod Length(TEAM_PALETTE);
        Inc(Probes);
      end;
      { > 12 teams: palette exhausted, later names share their hash slot }
      Used[Slot] := True;
      GMap.Values[Sorted[i]] := IntToStr(Slot);
    end;
  finally
    Sorted.Free;
  end;
end;

function TeamColor(const Team: string): Byte;
var
  V: string;
begin
  if GMap <> nil then
  begin
    V := GMap.Values[LowerCase(Team)];
    if V <> '' then
      Exit(TEAM_PALETTE[StrToIntDef(V, 0)]);
  end;
  Result := TEAM_PALETTE[Fnv1a(LowerCase(Team)) mod Cardinal(Length(TEAM_PALETTE))];
end;

function GroupColor(const Grp: string): Byte;
begin
  Result := GROUP_PALETTE[Fnv1a(LowerCase(Grp)) mod Cardinal(Length(GROUP_PALETTE))];
end;

function TeamName(const Team: string): string;
begin
  if SameText(Team, 'console') then
    Result := FgBold(SELF_FG, Team)
  else if SameText(Team, 'all') then
    Result := Dim(Team)
  else
    Result := Fg(TeamColor(Team), Team);
end;

function StripAnsi(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (Byte(S[i]) = 27) and (i < Length(S)) and (S[i + 1] = '[') then
    begin
      Inc(i, 2);
      while (i <= Length(S)) and not (S[i] in ['@'..'~']) do
        Inc(i);
      Inc(i);
      Continue;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

function VisCells(const S: string): Integer;
var
  i: Integer;
  b: Byte;
begin
  Result := 0;
  i := 1;
  while i <= Length(S) do
  begin
    b := Byte(S[i]);
    if (b = 27) and (i < Length(S)) and (S[i + 1] = '[') then
    begin
      { skip the CSI sequence: ESC [ params... final byte in @..~ }
      Inc(i, 2);
      while (i <= Length(S)) and not (S[i] in ['@'..'~']) do
        Inc(i);
      if i <= Length(S) then
        Inc(i);   { consume the final byte }
    end
    else
    begin
      if (b and $C0) <> $80 then
        Inc(Result);   { non-continuation byte = one cell }
      Inc(i);
    end;
  end;
end;

finalization
  GMap.Free;

end.
