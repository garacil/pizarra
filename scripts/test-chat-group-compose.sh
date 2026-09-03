#!/usr/bin/env bash
# Focused disposable integration test for tiza chat group composition.
#
# It runs the real hub and console against loopback-only state.  All members
# are inbox-only, so this test neither invokes nor needs a tmux server.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-chat-group-compose.XXXXXXXX)
HUB_PID=''

fail() {
  printf 'not ok: %s\n' "$*" >&2
  if [[ -f $TEST_ROOT/hub.out ]]; then
    printf '%s\n' '--- isolated hub output ---' >&2
    tail -80 "$TEST_ROOT/hub.out" >&2 || true
  fi
  exit 1
}

ok() { printf 'ok: %s\n' "$*"; }

contains() {
  local value=$1 expected=$2 label=$3
  [[ $value == *"$expected"* ]] ||
    fail "$label (missing '$expected' in: ${value:0:500})"
}

stop_hub() {
  local attempt
  [[ -n ${HUB_PID:-} ]] || return 0
  if kill -0 "$HUB_PID" 2>/dev/null; then
    kill "$HUB_PID" 2>/dev/null || true
    for attempt in {1..100}; do
      kill -0 "$HUB_PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -0 "$HUB_PID" 2>/dev/null && kill -KILL "$HUB_PID" 2>/dev/null || true
  fi
  wait "$HUB_PID" 2>/dev/null || true
  HUB_PID=''
}

cleanup() {
  stop_hub
  case ${TEST_ROOT:-} in
    /tmp/pizarra-chat-group-compose.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

for tool in cat chmod find install kill mktemp rmdir sleep tail timeout; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] ||
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

PORT=$(choose_port) || fail 'could not choose a free loopback port'
STORE=$TEST_ROOT/store
LOG_DIR=$TEST_ROOT/log
HUB_CONF=$TEST_ROOT/pizarra.conf
CONSOLE_CONF=$TEST_ROOT/console.conf
LEADER_CONF=$TEST_ROOT/leader.conf
WORKER_CONF=$TEST_ROOT/worker.conf

install -d -m 0700 "$STORE" "$LOG_DIR" "$TEST_ROOT/home"
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

[team:1]
name = leader
speciality = Synthetic group leader
secret = synthetic-leader-secret
tmux_session = -

[team:2]
name = worker
speciality = Synthetic group member
secret = synthetic-worker-secret
tmux_session = -

[group:builders]
boss = leader
members = leader, worker
EOF

cat >"$CONSOLE_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-console-secret
self = console
EOF

cat >"$LEADER_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-leader-secret
self = leader
EOF

cat >"$WORKER_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-worker-secret
self = worker
EOF
chmod 0600 "$HUB_CONF" "$CONSOLE_CONF" "$LEADER_CONF" "$WORKER_CONF"

as_leader() { "$TIZA_BIN" --config "$LEADER_CONF" "$@"; }
as_worker() { "$TIZA_BIN" --config "$WORKER_CONF" "$@"; }

"$HUB_BIN" --config "$HUB_CONF" >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
ready=0
for attempt in {1..100}; do
  if "$TIZA_BIN" --config "$CONSOLE_CONF" --health --wait 1 \
      >"$TEST_ROOT/health.out" 2>&1; then
    ready=1
    break
  fi
  kill -0 "$HUB_PID" 2>/dev/null || fail 'isolated hub exited before becoming healthy'
  sleep 0.05
done
((ready == 1)) || fail 'isolated hub did not become healthy'

run_chat() {
  local name=$1
  shift
  if ! printf '%s\n' "$@" | HOME="$TEST_ROOT/home" TIZA_CONF="$CONSOLE_CONF" \
      timeout 10 "$TIZA_BIN" chat --plain >"$TEST_ROOT/$name.out" 2>&1; then
    fail "chat case '$name' did not exit cleanly"
  fi
  cat "$TEST_ROOT/$name.out"
}

chat_out=$(run_chat explicit-group /msg @builders 'explicit first line' \
  'explicit second line' . /quit)
contains "$chat_out" '(composing for @builders: a "." line sends, /cancel aborts)' \
  '/msg @group did not enter compose mode'
contains "$chat_out" 'sent to @builders (2 teams' \
  '/msg @group did not send a group broadcast'

chat_out=$(run_chat bare-group @builders 'bare first line' 'bare second line' . /quit)
contains "$chat_out" '(composing for @builders: a "." line sends, /cancel aborts)' \
  'bare @group did not enter compose mode'
contains "$chat_out" 'sent to @builders (2 teams' \
  'bare @group did not send a group broadcast'

chat_out=$(run_chat cancel-group /msg @builders 'discard this message' /cancel /quit)
contains "$chat_out" '(composition cancelled)' \
  '/cancel did not abort group composition'

chat_out=$(run_chat immediate-group '@builders: immediate group message' /quit)
contains "$chat_out" 'sent to @builders (2 teams' \
  '@group: text did not remain an immediate group send'

chat_out=$(run_chat help-commands '/help commands' /quit)
contains "$chat_out" '/msg | /mensaje' \
  '/help commands did not name the /msg alias'
contains "$chat_out" '<team|@group>' \
  '/help commands did not document /msg @group'
contains "$chat_out" '@group: text' \
  '/help commands did not distinguish immediate group sends'

leader_messages=$(as_leader inbox --keep --all)
worker_messages=$(as_worker inbox --keep --all)
for messages in "$leader_messages" "$worker_messages"; do
  contains "$messages" $'explicit first line\nexplicit second line' \
    'explicit group body was not delivered intact'
  contains "$messages" $'bare first line\nbare second line' \
    'bare group body was not delivered intact'
  contains "$messages" 'immediate group message' \
    'one-line group shorthand was not delivered'
  [[ $messages != *'discard this message'* ]] ||
    fail '/cancel created a durable group message'
done
ok 'explicit and bare group composition share dot-send and cancel semantics'

printf 'all chat group composition integration tests passed\n'
