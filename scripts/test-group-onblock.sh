#!/usr/bin/env bash
# Focused disposable integration test for `tiza group onblock`.
#
# The test uses only a private tree under /tmp and loopback. It imports a
# minimal legacy team/group registry, exercises the real TCP protocol through
# tiza (plus one deliberately invalid raw request), restarts the hub, and reads
# the stopped SQLite store to prove durability.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}

for tool in cat chmod find grep install ln mktemp rm rmdir sleep sqlite3 stat tail; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'not ok: required command is missing: %s\n' "$tool" >&2
    exit 1
  }
done
[[ -x $HUB_BIN ]] || {
  printf 'not ok: debug hub is missing; run make debug: %s\n' "$HUB_BIN" >&2
  exit 1
}
[[ -x $TIZA_BIN ]] || {
  printf 'not ok: debug client is missing; run make debug: %s\n' "$TIZA_BIN" >&2
  exit 1
}

TEST_ROOT=$(mktemp -d /tmp/pizarra-group-onblock.XXXXXXXX)
STORE=$TEST_ROOT/store
LOG_DIR=$TEST_ROOT/log
HUB_CONF=$TEST_ROOT/pizarra.conf
CONSOLE_CONF=$TEST_ROOT/console.conf
BOSS_CONF=$TEST_ROOT/boss.conf
MEMBER_CONF=$TEST_ROOT/member.conf
HUB_LOG=$TEST_ROOT/hub.out
SHARED_ROOT=$TEST_ROOT/operator-owned-share
HUB_PID=''

stop_hub() {
  local attempt pid=${HUB_PID:-}
  [[ -n $pid ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for attempt in {1..100}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
  HUB_PID=''
}

cleanup() {
  stop_hub
  case ${TEST_ROOT:-} in
    /tmp/pizarra-group-onblock.*)
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
  if [[ -f $HUB_LOG ]]; then
    printf '%s\n' '--- isolated hub output ---' >&2
    tail -80 "$HUB_LOG" >&2 || true
  fi
  exit 1
}

ok() { printf 'ok: %s\n' "$*"; }

contains() {
  local value=$1 expected=$2 label=$3
  [[ $value == *"$expected"* ]] ||
    fail "$label (missing '$expected' in: ${value:0:500})"
}

choose_port() {
  local attempt candidate
  for attempt in {1..200}; do
    candidate=$((20000 + ((BASHPID + RANDOM + attempt) % 30000)))
    if (: <>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

PORT=$(choose_port) || fail 'could not find a free loopback test port'

install -d -m 0700 "$STORE" "$LOG_DIR"

cat >"$HUB_CONF" <<EOF
[server]
listen = 127.0.0.1
port = $PORT
secret = synthetic-console-secret
master_console_only = on

[registry]
authority = sqlite

[store]
dir = $STORE

[log]
path = $LOG_DIR/pizarra.log

[shared]
dir = $SHARED_ROOT

[team:1]
name = leader
speciality = Synthetic group administrator
secret = synthetic-leader-secret
tmux_session = -

[team:2]
name = worker
speciality = Synthetic ordinary member
secret = synthetic-worker-secret
tmux_session = -

[group:builders]
boss = leader
members = leader, worker
on_block = default
EOF

cat >"$CONSOLE_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-console-secret
self = console
EOF

cat >"$BOSS_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-leader-secret
self = leader
EOF

cat >"$MEMBER_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-worker-secret
self = worker
EOF
chmod 0600 "$HUB_CONF" "$CONSOLE_CONF" "$BOSS_CONF" "$MEMBER_CONF"

# All three programs share the same descriptor-based credential-file opener.
# Prove the hub rejects both a permissive file and a linked final component
# before it opens SQLite or a listener.
chmod 0644 "$HUB_CONF"
if "$HUB_BIN" --config "$HUB_CONF" --migrate-only \
    >"$TEST_ROOT/permissive-config.out" 2>&1; then
  fail 'hub accepted a credential configuration with mode 0644'
fi
grep -q 'regular mode-0600 file' "$TEST_ROOT/permissive-config.out" ||
  fail 'permissive credential rejection did not report the mode contract'
chmod 0600 "$HUB_CONF"
ln -s "$HUB_CONF" "$TEST_ROOT/linked-pizarra.conf"
if "$HUB_BIN" --config "$TEST_ROOT/linked-pizarra.conf" --migrate-only \
    >"$TEST_ROOT/linked-config.out" 2>&1; then
  fail 'hub accepted a credential configuration through a symbolic link'
fi
grep -q 'symbolic link' "$TEST_ROOT/linked-config.out" ||
  fail 'linked credential rejection did not identify the symbolic link'
rm -- "$TEST_ROOT/linked-pizarra.conf"
ok 'credential configuration requires a real mode-0600 file'

as_console() { TIZA_CONF=$CONSOLE_CONF "$TIZA_BIN" "$@"; }
as_boss() { TIZA_CONF=$BOSS_CONF "$TIZA_BIN" "$@"; }
as_member() { TIZA_CONF=$MEMBER_CONF "$TIZA_BIN" "$@"; }

wait_ready() {
  local attempt output
  for attempt in {1..200}; do
    if output=$(as_console group list builders 2>&1); then
      contains "$output" '@builders' 'legacy group was not loaded'
      return 0
    fi
    kill -0 "$HUB_PID" 2>/dev/null ||
      fail 'isolated hub exited before accepting requests'
    sleep 0.05
  done
  fail "isolated hub did not become ready on 127.0.0.1:$PORT"
}

start_hub() {
  [[ -z ${HUB_PID:-} ]] || fail 'test attempted to start a second hub'
  PIZARRA_TICK=1 "$HUB_BIN" --config "$HUB_CONF" >>"$HUB_LOG" 2>&1 &
  HUB_PID=$!
  wait_ready
}

raw_request() {
  local request=$1 reply fd
  exec {fd}<>"/dev/tcp/127.0.0.1/$PORT" ||
    fail 'could not open raw loopback request'
  printf '%s\n' "$request" >&"$fd"
  if ! IFS= read -r reply <&"$fd"; then
    exec {fd}>&-
    fail 'hub closed the invalid-policy request without a reply'
  fi
  exec {fd}>&-
  printf '%s\n' "$reply"
}

start_hub

# shared.dir is an operator-owned mount. A missing NFS mount must never be
# fabricated locally, and the hub must not chmod the configured root. Once the
# operator supplies it, only fixed one-level child directories are created.
[[ ! -e $SHARED_ROOT && ! -L $SHARED_ROOT ]] ||
  fail 'hub created a missing operator-owned shared root'
install -d -m 0755 "$SHARED_ROOT"
printf '%s\n' 'victim bytes must not change' >"$TEST_ROOT/manual-victim"
ln -s "$TEST_ROOT/manual-victim" "$SHARED_ROOT/AGENTS.md"
for attempt in {1..100}; do
  [[ -d $SHARED_ROOT/console && -d $SHARED_ROOT/leader &&
     -d $SHARED_ROOT/worker ]] && break
  sleep 0.05
done
[[ -d $SHARED_ROOT/console && -d $SHARED_ROOT/leader &&
   -d $SHARED_ROOT/worker ]] ||
  fail 'hub did not create team children below the supplied shared root'
[[ $(stat -Lc '%a' -- "$SHARED_ROOT") == 755 ]] ||
  fail 'hub chmodded the operator-owned shared root'
for child in console leader worker; do
  [[ $(stat -Lc '%a' -- "$SHARED_ROOT/$child") == 1777 ]] ||
    fail "hub did not protect shared child $child as mode 1777"
done
[[ -L $SHARED_ROOT/AGENTS.md ]] ||
  fail 'exclusive manual creation replaced a pre-existing link'
[[ $(<"$TEST_ROOT/manual-victim") == 'victim bytes must not change' ]] ||
  fail 'manual creation followed a planted link and changed its target'
ok 'shared root stays operator-owned and manual creation follows no link'

# The first startup must import the legacy sections into SQLite and remove them
# from the active bootstrap file only after the authoritative reload succeeds.
[[ $(sqlite3 -batch -noheader "$STORE/org.sqlite" \
  "SELECT v FROM meta WHERE k='registry_authority';") == sqlite-v1 ]] ||
  fail 'legacy startup did not publish the sqlite-v1 authority marker'
if grep -Eq '^[[:space:]]*\[(team:|group:)' "$HUB_CONF"; then
  fail 'legacy registry sections remained in the active bootstrap config'
fi
ok 'minimal legacy registry migrated into authoritative SQLite'

# An ordinary member is authenticated but has no policy authority.
if member_out=$(as_member group onblock builders log 2>&1); then
  fail 'ordinary member changed group onblock policy'
fi
contains "$member_out" 'only the console or @builders' \
  'ordinary-member rejection was not explicit'
contains "$member_out" "boss (leader)" \
  'ordinary-member rejection did not identify the group boss'
list_out=$(as_console group list builders)
contains "$list_out" 'on block: alarm' \
  'rejected member request changed the effective policy'
ok 'ordinary member is rejected without changing policy'

# The public CLI rejects unknown policy tokens before sending them, while the
# hub independently rejects the same invalid value at the protocol boundary.
if cli_invalid=$(as_console group onblock builders loud 2>&1); then
  fail 'CLI accepted an invalid onblock policy'
fi
contains "$cli_invalid" 'onblock must be alarm, log, or default' \
  'CLI validation did not report the accepted grammar'

raw_invalid=$(raw_request \
  '{"secret":"synthetic-console-secret","cmd":"group","from":"console","op":"onblock","name":"builders","onblock":"loud"}')
contains "$raw_invalid" '"ok" : false' \
  'hub accepted an invalid raw onblock policy'
contains "$raw_invalid" 'onblock must be alarm, log, or default' \
  'hub validation did not report the accepted grammar'
list_out=$(as_console group list builders)
contains "$list_out" 'on block: alarm' \
  'invalid policy request changed the effective policy'
ok 'CLI and hub independently validate onblock policy values'

# `alarm` is also an explicit stored policy, distinct from the empty/default
# representation even though both render as the normal alarm behavior.
console_alarm=$(as_console group onblock builders alarm)
contains "$console_alarm" 'on block: alarm' \
  'console could not set the explicit alarm policy'
[[ $(sqlite3 -batch -noheader "$STORE/org.sqlite" \
  "SELECT on_block FROM grp WHERE name='builders';") == alarm ]] ||
  fail 'explicit alarm policy was not committed to org.sqlite'
ok 'console is authorized to store the explicit alarm policy'

# The configured boss may change policy, and group list must project it.
boss_out=$(as_boss group onblock builders log)
contains "$boss_out" 'on block: log only' \
  'group boss change was not projected in its reply'
list_out=$(as_member group list builders)
contains "$list_out" '@builders' 'group list lost the selected group'
contains "$list_out" 'admin leader' 'group list lost the group boss'
contains "$list_out" '#1 leader' 'group list lost the boss member'
contains "$list_out" '#2 worker' 'group list lost the ordinary member'
contains "$list_out" 'on block: log only' \
  'group list did not render the boss-set policy'
ok 'group boss is authorized and group list renders log-only policy'

# Stop before inspecting durability, then restart from the stripped config.
stop_hub
[[ $(sqlite3 -batch -noheader "$STORE/org.sqlite" \
  "SELECT on_block FROM grp WHERE name='builders';") == log ]] ||
  fail 'boss-set log policy was not committed to org.sqlite'
start_hub
list_out=$(as_console group list builders)
contains "$list_out" 'on block: log only' \
  'boss-set policy did not survive hub restart'
ok 'boss-set policy persists in SQLite and survives restart'

# Console authority can restore the default. Empty is the stored canonical
# representation; group list deliberately renders it as the normal alarm.
console_out=$(as_console group onblock builders default)
contains "$console_out" 'on block: alarm' \
  'console default reset was not projected as alarm'
stop_hub
[[ -z $(sqlite3 -batch -noheader "$STORE/org.sqlite" \
  "SELECT on_block FROM grp WHERE name='builders';") ]] ||
  fail 'default reset was not stored canonically as an empty policy'
start_hub
list_out=$(as_member group list builders)
contains "$list_out" 'on block: alarm' \
  'console default reset did not survive restart'
ok 'console is authorized; default reset persists and renders as alarm'

stop_hub
[[ $(sqlite3 -batch -noheader "$STORE/org.sqlite" 'PRAGMA integrity_check;') == ok ]] ||
  fail 'org.sqlite failed final integrity_check'
[[ -z $(sqlite3 -batch -noheader "$STORE/org.sqlite" \
  'PRAGMA foreign_key_check;') ]] || fail 'org.sqlite failed foreign_key_check'

# A non-empty marker is not sufficient evidence of a completed compatible
# cutover.  Refuse unknown marker values before loading a possibly incompatible
# registry instead of treating them as authoritative.
sqlite3 "$STORE/org.sqlite" \
  "UPDATE meta SET v='unsupported-test-marker' WHERE k='registry_authority';"
if "$HUB_BIN" --config "$HUB_CONF" --migrate-only \
    >"$TEST_ROOT/unsupported-marker.out" 2>&1; then
  fail 'hub accepted an unsupported non-empty registry authority marker'
fi
grep -q 'unsupported SQLite registry authority marker' \
  "$TEST_ROOT/unsupported-marker.out" ||
  fail 'unsupported marker rejection did not identify the authority marker'
[[ $(sqlite3 -batch -noheader "$STORE/org.sqlite" \
  "SELECT v FROM meta WHERE k='registry_authority';") == unsupported-test-marker ]] ||
  fail 'rejected startup changed the unsupported authority marker'
sqlite3 "$STORE/org.sqlite" \
  "UPDATE meta SET v='sqlite-v1' WHERE k='registry_authority';"
ok 'unknown non-empty registry authority markers fail closed'

printf 'all group onblock integration tests passed\n'
