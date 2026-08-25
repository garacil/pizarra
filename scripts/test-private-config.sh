#!/usr/bin/env bash
# Focused regression test for the descriptor-pinned private INI reader.
#
# This builds a disposable Pascal harness against the repository units.  The
# assertions intentionally exercise the public typed loaders, rather than a
# shell reimplementation of their path policy.  FPC 3.2.2's TIniFile stream
# constructor does not add ifoStripQuotes and THandleStream does not own its
# handle; pzconfig must therefore request that option and retain/close the
# descriptor itself.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

for tool in chmod cp dirname find fpc grep ln mkdir mktemp mv rm rmdir; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'not ok: required command is missing: %s\n' "$tool" >&2
    exit 1
  }
done

TEST_ROOT=$(mktemp -d /tmp/pizarra-private-config.XXXXXXXX)
HARNESS_SRC=$TEST_ROOT/private_config_harness.pas
HARNESS_BIN=$TEST_ROOT/private-config-harness
PZWEB_BIN=$TEST_ROOT/pzweb-config-test
UNIT_DIR=$TEST_ROOT/units
BUILD_LOG=$TEST_ROOT/build.log
VALID_CONF=$TEST_ROOT/valid.conf

cleanup() {
  case ${TEST_ROOT:-} in
    /tmp/pizarra-private-config.*)
      [[ ! -d $TEST_ROOT ]] ||
        find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'not ok: %s\n' "$*" >&2
  if [[ -f $BUILD_LOG ]]; then
    printf '%s\n' '--- Pascal harness build output ---' >&2
    tail -80 "$BUILD_LOG" >&2 || true
  fi
  exit 1
}

ok() { printf 'ok: %s\n' "$*"; }

mkdir -m 0700 "$UNIT_DIR"

cat >"$HARNESS_SRC" <<'PASCAL'
program private_config_harness;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, IniFiles, BaseUnix, pzlayout, pzconfig;

procedure Fail(const Msg: string);
begin
  WriteLn(StdErr, 'assertion failed: ', Msg);
  Halt(1);
end;

procedure Need(Condition: Boolean; const Msg: string);
begin
  if not Condition then
    Fail(Msg);
end;

procedure CheckTypedLoaders(const Path: string);
var
  Hub: TPizarraConfig;
  Client: TTizaConfig;
  Daemon: TTizaDaemonConfig;
begin
  Hub := LoadPizarraConfig(Path);
  Need(Hub.Listen = '127.0.0.77', 'quoted hub listen value was not stripped');
  Need(Hub.Secret = 'quoted hub secret', 'quoted hub secret was not stripped');
  Need(Hub.SharedDir = '/tmp/synthetic-private-nfs',
    'absolute quoted hub shared dir was not loaded');
  Need(Length(Hub.Teams) = 2, 'team registry family did not load both teams');
  Need(Hub.Teams[0].Name = 'alpha', 'quoted team name was not stripped');
  Need(Hub.Teams[0].Speciality = 'quoted speciality',
    'quoted team speciality was not stripped');
  Need(Hub.Teams[1].Name = 'beta', 'team registry family lost its second team');
  Need(Length(Hub.Groups) = 1, 'group registry family did not load the group');
  Need(Hub.Groups[0].Name = 'builders', 'group name is wrong');
  Need(Hub.Groups[0].Boss = 'alpha', 'quoted group boss was not stripped');
  Need(Length(Hub.Groups[0].Members) = 2,
    'quoted group members were not split');
  Need((Hub.Groups[0].Members[0] = 'alpha') and
    (Hub.Groups[0].Members[1] = 'beta'),
    'group member values are wrong');
  Need(Hub.Groups[0].HdrNote = 'quoted group instruction',
    'quoted group header was not stripped');

  Client := LoadTizaConfig(Path);
  Need(Client.Host = '127.0.0.88', 'quoted client host was not stripped');
  Need(Client.Secret = 'quoted client secret', 'quoted client secret was not stripped');
  Need(Client.SelfId = 'alpha', 'quoted client identity was not stripped');

  Daemon := LoadTizaDaemonConfig(Path);
  Need(Daemon.Listen = '127.0.0.99', 'quoted daemon listen value was not stripped');
  Need(Length(Daemon.Sessions) = 1, 'daemon loader did not load its session');
  Need(Daemon.Sessions[0].TmuxSession = 'team-alpha',
    'quoted daemon tmux session was not stripped');
  Need(Daemon.Sessions[0].Launch = 'exec synthetic-agent',
    'quoted daemon launch value was not stripped');
end;

procedure CheckPinnedDescriptor(const Path: string);
var
  Handle: Integer;
  Resolved, Why, OpenedPath, Replacement: string;
  Input: THandleStream;
  OutputFile: TFileStream;
  Ini: TIniFile;
begin
  Handle := -1;
  if not PzOpenPrivateConfig(Path, Handle, Resolved, Why) then
    Fail('could not securely open pin fixture: ' + Why);
  OpenedPath := Path + '.opened';
  if FpRename(PChar(Path), PChar(OpenedPath)) <> 0 then
  begin
    FpClose(Handle);
    Fail('could not rename pin fixture after secure open: ' +
      SysErrorMessage(fpgeterrno));
  end;

  Replacement := '[pin]' + LineEnding + 'value = "replacement"' + LineEnding;
  try
    OutputFile := TFileStream.Create(Path, fmCreate, &600);
    try
      if Replacement <> '' then
        OutputFile.WriteBuffer(Replacement[1], Length(Replacement));
    finally
      OutputFile.Free;
    end;

    Input := THandleStream.Create(Handle);
    try
      Ini := TIniFile.Create(Input, [ifoStripQuotes]);
      try
        Need(Ini.ReadString('pin', 'value', '') = 'original',
          'reader followed the replaced pathname instead of its open descriptor');
      finally
        Ini.Free;
      end;
    finally
      Input.Free;
    end;
  finally
    FpClose(Handle);
  end;
end;

begin
  try
    if ParamCount <> 2 then
      Fail('usage: private-config-harness load|pin PATH');
    if ParamStr(1) = 'load' then
      CheckTypedLoaders(ParamStr(2))
    else if ParamStr(1) = 'pin' then
      CheckPinnedDescriptor(ParamStr(2))
    else
      Fail('unknown operation: ' + ParamStr(1));
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(2);
    end;
  end;
end.
PASCAL

if ! (
  cd -- "$TEST_ROOT"
  fpc -Sc -Sew -Fu"$REPO_ROOT/src" -FU"$UNIT_DIR" -FE"$TEST_ROOT" \
    -o"$(basename -- "$HARNESS_BIN")" "$HARNESS_SRC"
) >"$BUILD_LOG" 2>&1; then
  fail 'could not compile the private-config Pascal harness'
fi
[[ -x $HARNESS_BIN ]] || fail 'compiler did not produce the private-config harness'

if ! (
  cd -- "$TEST_ROOT"
  fpc -Sc -Sew -Fu"$REPO_ROOT/src" -FU"$UNIT_DIR" -FE"$TEST_ROOT" \
    -o"$(basename -- "$PZWEB_BIN")" "$REPO_ROOT/src/pzweb.pas"
) >>"$BUILD_LOG" 2>&1; then
  fail 'could not compile pzweb for its configuration-loader regression'
fi
[[ -x $PZWEB_BIN ]] || fail 'compiler did not produce the pzweb configuration test binary'

cat >"$VALID_CONF" <<'EOF'
[server]
listen = "127.0.0.77"
port = 17710
secret = "quoted hub secret"

[registry]
authority = "sqlite"

[store]
dir = "/tmp/synthetic-private-config-store"

[shared]
dir = "/tmp/synthetic-private-nfs"

[team:1]
name = "alpha"
speciality = "quoted speciality"
tmux_session = "-"

[team:2]
name = "beta"
speciality = "second team"
tmux_session = "-"

[group:builders]
boss = "alpha"
members = "alpha, beta"
header = "quoted group instruction"
on_block = "log"

[pizarra]
host = "127.0.0.88"
port = 17710
secret = "quoted client secret"
self = "alpha"

[daemon]
listen = "127.0.0.99"
port = 17711
secret = "quoted daemon secret"

[session:alpha]
tmux_session = "team-alpha"
launch = "exec synthetic-agent"
EOF
chmod 0600 "$VALID_CONF"

# /tmp is group/other-writable, but its root ownership plus sticky bit is the
# deliberate safe exception.  The file and every remaining ancestor are
# private, and all three typed loaders must parse the same quoted semantics.
if ! "$HARNESS_BIN" load "$VALID_CONF" >"$TEST_ROOT/valid.out" 2>&1; then
  fail 'valid mode-0600 config below the root-owned sticky /tmp was rejected'
fi
ok 'mode-0600 config below root-owned sticky /tmp parses all typed loaders'

expect_rejected() {
  local path=$1 needle=$2 label=$3 output
  if output=$("$HARNESS_BIN" load "$path" 2>&1); then
    fail "$label was accepted"
  fi
  if ! grep -Fq -- "$needle" <<<"$output"; then
    printf '%s\n' "$output" >"$TEST_ROOT/rejection.out"
    fail "$label did not report '$needle'"
  fi
  ok "$label is rejected"
}

ln -s -- "$VALID_CONF" "$TEST_ROOT/final-link.conf"
expect_rejected "$TEST_ROOT/final-link.conf" 'symbolic link' \
  'symbolic-link final component'

mkdir -m 0700 "$TEST_ROOT/real-parent"
cp -- "$VALID_CONF" "$TEST_ROOT/real-parent/ancestor.conf"
chmod 0600 "$TEST_ROOT/real-parent/ancestor.conf"
ln -s -- "$TEST_ROOT/real-parent" "$TEST_ROOT/linked-parent"
expect_rejected "$TEST_ROOT/linked-parent/ancestor.conf" 'symbolic link' \
  'symbolic-link ancestor'

cp -- "$VALID_CONF" "$TEST_ROOT/permissive.conf"
chmod 0644 "$TEST_ROOT/permissive.conf"
expect_rejected "$TEST_ROOT/permissive.conf" 'regular mode-0600 file' \
  'mode-0644 final configuration'

mkdir -m 0700 "$TEST_ROOT/writable-parent"
cp -- "$VALID_CONF" "$TEST_ROOT/writable-parent/ancestor.conf"
chmod 0600 "$TEST_ROOT/writable-parent/ancestor.conf"
chmod 0777 "$TEST_ROOT/writable-parent"
expect_rejected "$TEST_ROOT/writable-parent/ancestor.conf" \
  'writable by group/other users' 'non-sticky writable ancestor'

cp -- "$VALID_CONF" "$TEST_ROOT/relative-shared.conf"
sed -i 's|^dir = "/tmp/synthetic-private-nfs"$|dir = "relative/nfs"|' \
  "$TEST_ROOT/relative-shared.conf"
chmod 0600 "$TEST_ROOT/relative-shared.conf"
expect_rejected "$TEST_ROOT/relative-shared.conf" \
  '[shared] dir must be an absolute path' 'relative hub shared directory'

cp -- "$VALID_CONF" "$TEST_ROOT/trailing-shared.conf"
sed -i 's|^dir = "/tmp/synthetic-private-nfs"$|dir = "/tmp/synthetic-private-nfs////"|' \
  "$TEST_ROOT/trailing-shared.conf"
chmod 0600 "$TEST_ROOT/trailing-shared.conf"
if ! "$HARNESS_BIN" load "$TEST_ROOT/trailing-shared.conf" \
    >"$TEST_ROOT/trailing-shared.out" 2>&1; then
  fail 'hub loader did not normalize every trailing shared-directory separator'
fi
ok 'hub loader normalizes every trailing shared-directory separator'

for root_value in / ////; do
  root_name=${root_value//\//slash}
  cp -- "$VALID_CONF" "$TEST_ROOT/root-shared-$root_name.conf"
  sed -i "s|^dir = \"/tmp/synthetic-private-nfs\"$|dir = \"$root_value\"|" \
    "$TEST_ROOT/root-shared-$root_name.conf"
  chmod 0600 "$TEST_ROOT/root-shared-$root_name.conf"
  expect_rejected "$TEST_ROOT/root-shared-$root_name.conf" \
    '[shared] dir may not be the filesystem root' \
    "hub filesystem-root shared directory ($root_value)"
done

cat >"$TEST_ROOT/pzweb-relative-shared.conf" <<'EOF'
[pizarra]
host = 127.0.0.1
port = 17010
secret = pzweb-test-secret
self = pzweb

[web]
listen = 127.0.0.1
port = 17080
allow_from = 127.0.0.1
host = 127.0.0.1:17080
origin = http://127.0.0.1:17080
user = operator
password_sha256 = 0000000000000000000000000000000000000000000000000000000000000000
shared = relative/nfs
EOF
chmod 0600 "$TEST_ROOT/pzweb-relative-shared.conf"
if "$PZWEB_BIN" --config "$TEST_ROOT/pzweb-relative-shared.conf" \
    >"$TEST_ROOT/pzweb-relative.out" 2>&1; then
  fail 'pzweb accepted a relative shared directory'
fi
grep -Fq '[web] shared must be an absolute path' \
  "$TEST_ROOT/pzweb-relative.out" ||
  fail 'pzweb relative shared rejection did not identify the absolute-path requirement'
ok 'relative pzweb shared directory is rejected by its real loader'

for root_value in / ////; do
  root_name=${root_value//\//slash}
  cp -- "$TEST_ROOT/pzweb-relative-shared.conf" \
    "$TEST_ROOT/pzweb-root-shared-$root_name.conf"
  sed -i "s|^shared = relative/nfs$|shared = $root_value|" \
    "$TEST_ROOT/pzweb-root-shared-$root_name.conf"
  if "$PZWEB_BIN" --config "$TEST_ROOT/pzweb-root-shared-$root_name.conf" \
      >"$TEST_ROOT/pzweb-root-$root_name.out" 2>&1; then
    fail "pzweb accepted filesystem-root shared directory ($root_value)"
  fi
  grep -Fq '[web] shared may not be the filesystem root' \
    "$TEST_ROOT/pzweb-root-$root_name.out" ||
    fail "pzweb did not identify filesystem-root shared directory ($root_value)"
done
ok 'pzweb rejects root after normalizing every trailing separator'

cat >"$TEST_ROOT/pinned.conf" <<'EOF'
[pin]
value = "original"
EOF
chmod 0600 "$TEST_ROOT/pinned.conf"
if ! "$HARNESS_BIN" pin "$TEST_ROOT/pinned.conf" >"$TEST_ROOT/pin.out" 2>&1; then
  fail 'open descriptor did not remain pinned after pathname replacement'
fi
ok 'open descriptor remains pinned when its pathname is replaced'

printf '%s\n' 'all private configuration reader tests passed'
