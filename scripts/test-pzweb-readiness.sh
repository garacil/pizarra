#!/usr/bin/env bash
# Prove that pzweb readiness follows a real bind and an occupied port fails.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
WEB_BIN=${PIZARRA_TEST_WEB_BIN:-$REPO_ROOT/pzweb-debug}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-pzweb-ready.XXXXXXXX")
HUB_PID=''
WEB_PID=''

stop_pid() {
  local pid=${1:-} attempt
  [[ -n $pid ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for attempt in {1..100}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_pid "$WEB_PID"
  stop_pid "$HUB_PID"
  case ${TEST_ROOT:-} in
    "${TMPDIR:-/tmp}"/pizarra-pzweb-ready.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'not ok: %s\n' "$*" >&2
  for output in "$TEST_ROOT"/*.out; do
    [[ -f $output ]] || continue
    printf '%s\n' "--- ${output##*/} ---" >&2
    tail -80 "$output" >&2 || true
  done
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }

for tool in chmod find grep install kill mktemp rmdir sleep tail timeout; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[[ -x $HUB_BIN && -x $TIZA_BIN && -x $WEB_BIN ]] ||
  fail 'debug binaries are missing; run make debug'

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

HUB_PORT=$(choose_port) || fail 'could not choose a hub port'
while :; do
  WEB_PORT=$(choose_port) || fail 'could not choose a web port'
  [[ $WEB_PORT != "$HUB_PORT" ]] && break
done

install -d -m 0700 "$TEST_ROOT/store" "$TEST_ROOT/log"
cat >"$TEST_ROOT/pizarra.conf" <<EOF
[server]
listen = 127.0.0.1
port = $HUB_PORT
secret = synthetic-console-secret
master_console_only = on

[store]
dir = $TEST_ROOT/store

[log]
path = $TEST_ROOT/log/pizarra.log

[team:1]
name = web
speciality = Synthetic web readiness identity
secret = synthetic-web-secret
delegate = team, group, project, app, task, workflow, watch, backup, update, header
tmux_session = -
EOF

cat >"$TEST_ROOT/console.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $HUB_PORT
secret = synthetic-console-secret
self = console
EOF

cat >"$TEST_ROOT/pzweb.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $HUB_PORT
secret = synthetic-web-secret
self = web

[web]
listen = 127.0.0.1
port = $WEB_PORT
allow_from = 127.0.0.1
host = 127.0.0.1:$WEB_PORT
origin = http://127.0.0.1:$WEB_PORT
static = $REPO_ROOT/web/apps
user = operator
password_sha256 = 0000000000000000000000000000000000000000000000000000000000000000
EOF
chmod 0600 "$TEST_ROOT/pizarra.conf" "$TEST_ROOT/console.conf" \
  "$TEST_ROOT/pzweb.conf"

PIZARRA_TICK=60 "$HUB_BIN" --config "$TEST_ROOT/pizarra.conf" \
  >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
"$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 5 \
  >"$TEST_ROOT/hub-health.out" 2>&1 || fail 'isolated hub did not become healthy'

set +e
"$WEB_BIN" --config "$TEST_ROOT/pzweb.conf" --health \
  >"$TEST_ROOT/pre-health.out" 2>&1
PRE_RC=$?
set -e
((PRE_RC != 0)) || fail 'web health succeeded before any listener existed'
ok 'web health fails before bind'

"$WEB_BIN" --config "$TEST_ROOT/pzweb.conf" >"$TEST_ROOT/web.out" 2>&1 &
WEB_PID=$!
"$WEB_BIN" --config "$TEST_ROOT/pzweb.conf" --health --wait 5 \
  >"$TEST_ROOT/web-health.out" 2>&1 || fail 'web listener did not become healthy'
grep -Fq "pzweb health: ok endpoint=http://127.0.0.1:$WEB_PORT" \
  "$TEST_ROOT/web-health.out" || fail 'web health output is not the strict success shape'
ok 'web health succeeds only after a real connect'

set +e
timeout 8 "$WEB_BIN" --config "$TEST_ROOT/pzweb.conf" \
  >"$TEST_ROOT/collision.out" 2>&1
COLLISION_RC=$?
set -e
((COLLISION_RC != 0 && COLLISION_RC != 124)) ||
  fail 'second web server did not fail promptly on the occupied port'
if grep -Fq 'pzweb: listening on' "$TEST_ROOT/collision.out"; then
  fail 'occupied-port startup falsely claimed that it was listening'
fi
grep -Fq 'pzweb: starting HTTP listener on' "$TEST_ROOT/collision.out" ||
  fail 'occupied-port startup did not reach the bind attempt'
ok 'occupied web port fails without a false listening claim'

printf 'all pzweb readiness tests passed\n'
