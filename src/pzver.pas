{ pzver - THE fleet release number, shared by every binary (pizarra, tiza,
  pzweb). Discipline: bump on EVERY change that ships a binary and keep the
  numeric tuple monotonic because endpoint self-update compares it directly.
  `tiza ver` / `/ver` show it, the hub reports its own over the wire
  (cmd=ver), and `tiza fleet` compares them across the fleet. }
unit pzver;

{$mode objfpc}{$H+}

interface

const
  PizarraVersion = '1.1.35';

{ dotted numeric compare (1.0.10 > 1.0.9); missing parts count as 0 }
function VerNewer(const A, B: string): Boolean;
function VerAtLeast(const A, B: string): Boolean;

implementation

uses
  SysUtils;

{ part I (1-based) of a dotted version, 0 when absent/garbage }
function VerPart(const V: string; I: Integer): Integer;
var
  S: string;
  n, p: Integer;
begin
  S := V;
  for n := 1 to I - 1 do
  begin
    p := Pos('.', S);
    if p = 0 then
      Exit(0);
    Delete(S, 1, p);
  end;
  p := Pos('.', S);
  if p > 0 then
    S := Copy(S, 1, p - 1);
  Result := StrToIntDef(Trim(S), 0);
end;

function VerNewer(const A, B: string): Boolean;
var
  i, x, y: Integer;
begin
  for i := 1 to 3 do
  begin
    x := VerPart(A, i);
    y := VerPart(B, i);
    if x > y then
      Exit(True);
    if x < y then
      Exit(False);
  end;
  Result := False;
end;

function VerAtLeast(const A, B: string): Boolean;
begin
  Result := (A = B) or VerNewer(A, B);
end;

end.
