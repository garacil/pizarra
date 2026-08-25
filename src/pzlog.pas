{ pzlog - human-readable append-only text log. The machine journal and the
  inbox live in pzstore; this file is for eyes and grep. Thread-safe. }
unit pzlog;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs;

type
  TPzLog = class
  private
    FPath: string;
    FLock: TCriticalSection;
    procedure AppendFile(const Line: string);
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    { One line per routed message. }
    procedure Store(const From, Dest, Text, Via: string);
    { Free-form informational line (startup, watchdog, retries). }
    procedure Info(const Line: string);
  end;

implementation

function NowStamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
end;

function OneLine(const S: string): string;
begin
  Result := StringReplace(S, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

constructor TPzLog.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FLock := TCriticalSection.Create;
end;

destructor TPzLog.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TPzLog.AppendFile(const Line: string);
var
  F: TextFile;
begin
  AssignFile(F, FPath);
  try
    if FileExists(FPath) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, Line);
    finally
      CloseFile(F);
    end;
  except
    { never let logging kill the daemon }
  end;
end;

procedure TPzLog.Store(const From, Dest, Text, Via: string);
begin
  FLock.Enter;
  try
    AppendFile(Format('%s | %s -> %s | %s | %s',
      [NowStamp, From, Dest, Via, OneLine(Text)]));
  finally
    FLock.Leave;
  end;
end;

procedure TPzLog.Info(const Line: string);
begin
  FLock.Enter;
  try
    AppendFile(Format('%s | -- | info | %s', [NowStamp, OneLine(Line)]));
  finally
    FLock.Leave;
  end;
end;

end.
