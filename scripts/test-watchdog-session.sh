#!/usr/bin/env bash
# Prove the watchdog separates managed launches from manual tmux sessions.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-watchdog-session.XXXXXXXX")
HUB_PID=''

stop_hub() {
  local attempt
  [[ -n $HUB_PID ]] || return 0
  if kill -0 "$HUB_PID" 2>/dev/null; then
    kill "$HUB_PID" 2>/dev/null || true
    for attempt in {1..100}; do
      kill -0 "$HUB_PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -0 "$HUB_PID" 2>/dev/null && kill -KILL "$HUB_PID" 2>/dev/null || true
  fi
  wait "$HUB_PID" 2>/dev/null || true
}

cleanup() {
  stop_hub
  TMUX_TMPDIR="$TEST_ROOT/tmux" tmux kill-server >/dev/null 2>&1 || true
  case ${TEST_ROOT:-} in
    "${TMPDIR:-/tmp}"/pizarra-watchdog-session.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'not ok: %s\n' "$*" >&2
  [[ ! -f $TEST_ROOT/hub.out ]] || tail -80 "$TEST_ROOT/hub.out" >&2 || true
  [[ ! -f $TEST_ROOT/log/pizarra.log ]] || tail -80 "$TEST_ROOT/log/pizarra.log" >&2 || true
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }

for tool in chmod find grep install kill mktemp rmdir sleep tail tmux; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries are missing; run make debug'

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
install -d -m 0700 "$TEST_ROOT/store" "$TEST_ROOT/log" "$TEST_ROOT/tmux"
cat >"$TEST_ROOT/tmux.conf" <<'EOF'
# Make this disposable server independent of runner/user tmux defaults. Keeping
# an empty server alive also mirrors the shipped pizarra-tmux.service boundary.
set-option -g exit-empty off
EOF
TMUX_TMPDIR="$TEST_ROOT/tmux" tmux -f "$TEST_ROOT/tmux.conf" start-server
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
name = managed
speciality = Synthetic managed session
secret = synthetic-managed-secret
tmux_session = managed
launch = exec /bin/sleep 120
workdir = $TEST_ROOT

[team:2]
name = manual
speciality = Synthetic manually managed session
secret = synthetic-manual-secret
tmux_session = manual
EOF
cat >"$TEST_ROOT/console.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $HUB_PORT
secret = synthetic-console-secret
self = console
EOF
chmod 0600 "$TEST_ROOT/pizarra.conf" "$TEST_ROOT/console.conf"

TMUX_TMPDIR="$TEST_ROOT/tmux" PIZARRA_TICK=1 \
  "$HUB_BIN" --config "$TEST_ROOT/pizarra.conf" >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
"$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 5 >/dev/null ||
  fail 'isolated hub did not become healthy'

for attempt in {1..100}; do
  TMUX_TMPDIR="$TEST_ROOT/tmux" tmux has-session -t '=managed' 2>/dev/null && break
  sleep 0.05
done
TMUX_TMPDIR="$TEST_ROOT/tmux" tmux has-session -t '=managed' 2>/dev/null ||
  fail 'watchdog did not create the session with a configured launch'
[[ $(TMUX_TMPDIR="$TEST_ROOT/tmux" tmux show-options -v -t '=managed' @pizarra_team) == managed ]] ||
  fail 'watchdog did not tag the managed session'
ok 'configured launch is created and tagged'

sleep 2
TMUX_TMPDIR="$TEST_ROOT/tmux" tmux has-session -t '=manual' 2>/dev/null &&
  fail 'watchdog unexpectedly created a session without a launch'
if grep -Fq 'watchdog: respawning session manual' "$TEST_ROOT/log/pizarra.log"; then
  fail 'watchdog falsely claimed it was respawning the manual session'
fi
ok 'missing manual session is neither fabricated nor logged as respawning'

printf 'all watchdog session tests passed\n'
