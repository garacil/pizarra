{ pzsha256 - SHA-256 (FIPS 180-4), self-contained. FPC 3.2.2's hash package
  ships only MD5/SHA-1, and the self-update channel (1.0.3) must verify every
  downloaded artifact, so the digest is implemented here: pure static code,
  no external deps. Verified in the smoke suite against coreutils sha256sum
  (empty string + known vectors + a real file). }
unit pzsha256;

{$mode objfpc}{$H+}
{$Q-}{$R-}  { the algorithm relies on 32-bit modular wrap-around }

interface

type
  TSha256Ctx = record
    H: array[0..7] of DWord;
    Buf: array[0..63] of Byte;
    BufLen: Integer;
    Total: QWord;              { message length in bytes }
  end;

procedure Sha256Init(out Ctx: TSha256Ctx);
procedure Sha256Update(var Ctx: TSha256Ctx; const Data; Len: Integer);
function  Sha256Final(var Ctx: TSha256Ctx): string;   { lowercase hex }

function Sha256OfString(const S: RawByteString): string;
{ streams the file in 64 KB chunks; False if it cannot be opened/read }
function Sha256OfFile(const Path: string; out HexDigest: string): Boolean;
{ Hash the content BEHIND an already opened and verified descriptor. Reopening
  by NAME recreates the race this design closes: between verification and
  hashing, the name may begin referring to something else. }
function Sha256OfHandle(Fd: LongInt; out HexDigest: string): Boolean;

implementation

uses
  SysUtils, Classes, BaseUnix;

const
  K: array[0..63] of DWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1,
    $923f82a4, $ab1c5ed5, $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174, $e49b69c1, $efbe4786,
    $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147,
    $06ca6351, $14292967, $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85, $a2bfe8a1, $a81a664b,
    $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a,
    $5b9cca4f, $682e6ff3, $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function Ror(X: DWord; N: Byte): DWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure Compress(var Ctx: TSha256Ctx; const Block: PByte);
var
  W: array[0..63] of DWord;
  A, B, C, D, E, F, G, H, T1, T2: DWord;
  i: Integer;
begin
  for i := 0 to 15 do
    W[i] := (DWord(Block[i * 4]) shl 24) or (DWord(Block[i * 4 + 1]) shl 16) or
            (DWord(Block[i * 4 + 2]) shl 8) or DWord(Block[i * 4 + 3]);
  for i := 16 to 63 do
    W[i] := (Ror(W[i - 2], 17) xor Ror(W[i - 2], 19) xor (W[i - 2] shr 10)) +
            W[i - 7] +
            (Ror(W[i - 15], 7) xor Ror(W[i - 15], 18) xor (W[i - 15] shr 3)) +
            W[i - 16];
  A := Ctx.H[0]; B := Ctx.H[1]; C := Ctx.H[2]; D := Ctx.H[3];
  E := Ctx.H[4]; F := Ctx.H[5]; G := Ctx.H[6]; H := Ctx.H[7];
  for i := 0 to 63 do
  begin
    T1 := H + (Ror(E, 6) xor Ror(E, 11) xor Ror(E, 25)) +
          ((E and F) xor ((not E) and G)) + K[i] + W[i];
    T2 := (Ror(A, 2) xor Ror(A, 13) xor Ror(A, 22)) +
          ((A and B) xor (A and C) xor (B and C));
    H := G; G := F; F := E; E := D + T1;
    D := C; C := B; B := A; A := T1 + T2;
  end;
  Ctx.H[0] := Ctx.H[0] + A; Ctx.H[1] := Ctx.H[1] + B;
  Ctx.H[2] := Ctx.H[2] + C; Ctx.H[3] := Ctx.H[3] + D;
  Ctx.H[4] := Ctx.H[4] + E; Ctx.H[5] := Ctx.H[5] + F;
  Ctx.H[6] := Ctx.H[6] + G; Ctx.H[7] := Ctx.H[7] + H;
end;

procedure Sha256Init(out Ctx: TSha256Ctx);
begin
  Ctx := Default(TSha256Ctx);
  Ctx.H[0] := $6a09e667; Ctx.H[1] := $bb67ae85;
  Ctx.H[2] := $3c6ef372; Ctx.H[3] := $a54ff53a;
  Ctx.H[4] := $510e527f; Ctx.H[5] := $9b05688c;
  Ctx.H[6] := $1f83d9ab; Ctx.H[7] := $5be0cd19;
end;

procedure Sha256Update(var Ctx: TSha256Ctx; const Data; Len: Integer);
var
  P: PByte;
  Take: Integer;
begin
  if Len <= 0 then
    Exit;
  P := PByte(@Data);
  Inc(Ctx.Total, Len);
  while Len > 0 do
  begin
    Take := 64 - Ctx.BufLen;
    if Take > Len then
      Take := Len;
    Move(P^, Ctx.Buf[Ctx.BufLen], Take);
    Inc(Ctx.BufLen, Take);
    Inc(P, Take);
    Dec(Len, Take);
    if Ctx.BufLen = 64 then
    begin
      Compress(Ctx, @Ctx.Buf[0]);
      Ctx.BufLen := 0;
    end;
  end;
end;

function Sha256Final(var Ctx: TSha256Ctx): string;
var
  BitLen: QWord;
  Pad: array[0..71] of Byte;
  PadLen, i: Integer;
begin
  BitLen := Ctx.Total * 8;
  { append 0x80, zero-fill to 56 mod 64, then the 64-bit big-endian length }
  FillChar(Pad, SizeOf(Pad), 0);
  Pad[0] := $80;
  if Ctx.BufLen < 56 then
    PadLen := 56 - Ctx.BufLen
  else
    PadLen := 120 - Ctx.BufLen;
  for i := 0 to 7 do
    Pad[PadLen + i] := Byte(BitLen shr (56 - i * 8));
  Sha256Update(Ctx, Pad, PadLen + 8);
  Result := '';
  for i := 0 to 7 do
    Result := Result + LowerCase(IntToHex(Ctx.H[i], 8));
  { wipe the state: the ctx is finished }
  Ctx := Default(TSha256Ctx);
end;

function Sha256OfString(const S: RawByteString): string;
var
  Ctx: TSha256Ctx;
begin
  Sha256Init(Ctx);
  if S <> '' then
    Sha256Update(Ctx, S[1], Length(S));
  Result := Sha256Final(Ctx);
end;

function Sha256OfHandle(Fd: LongInt; out HexDigest: string): Boolean;
var
  Ctx: TSha256Ctx;
  Buf: array[0..65535] of Byte;
  N: Integer;
  Pos0: Int64;
begin
  Result := False;
  HexDigest := '';
  Pos0 := FpLseek(Fd, 0, SEEK_CUR);   { Restore the original position. }
  if FpLseek(Fd, 0, SEEK_SET) < 0 then
    Exit;
  Sha256Init(Ctx);
  repeat
    N := FpRead(Fd, Buf, SizeOf(Buf));
    if N > 0 then
      Sha256Update(Ctx, Buf, N);
  until N <= 0;
  if N < 0 then
  begin
    FpLseek(Fd, Pos0, SEEK_SET);
    Exit;
  end;
  HexDigest := Sha256Final(Ctx);
  FpLseek(Fd, Pos0, SEEK_SET);
  Result := True;
end;

function Sha256OfFile(const Path: string; out HexDigest: string): Boolean;
var
  FS: TFileStream;
  Ctx: TSha256Ctx;
  Buf: array[0..65535] of Byte;
  N: Integer;
begin
  Result := False;
  HexDigest := '';
  try
    { SHARED does not mean "unlocked". On Unix, FileOpen always takes a flock
      (rtl/unix/sysutils.pp, DoFileLocking), and sharing bits select its mode.
      Omitting them yields 0, fmShareCompat, which requests LOCK_EX: the
      STRONGEST lock. Hashing under LOCK_EX made every concurrent reader fail
      with EAGAIN ("Try again"), including two downloads of one artifact. }
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    Sha256Init(Ctx);
    repeat
      N := FS.Read(Buf, SizeOf(Buf));
      if N > 0 then
        Sha256Update(Ctx, Buf, N);
    until N <= 0;
    HexDigest := Sha256Final(Ctx);
    Result := True;
  finally
    FS.Free;
  end;
end;

end.
