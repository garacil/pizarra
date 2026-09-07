#!/usr/bin/env bash
# Prove the watchdog separates managed launches from manual tmux sessions.
#
# ISOLATION. This harness must be unable to reach a real tmux server even when
# an agent runs it from inside a tmux pane. tmux chooses its socket from $TMUX
# BEFORE it looks at TMUX_TMPDIR, so a pane's own variable silently redirects
# every "isolated" command to the live server; the kill-server that used to sit
# in cleanup did exactly that on 2026-09-07 and ended every session on the hub
# host. Therefore: TMUX and TMUX_PANE are removed from the environment, every
# tmux call here names the private socket with -S, the hub under test inherits
# only the private TMUX_TMPDIR, and no command in this file can end a server.
# The private server holds a sentinel session and exits by itself (exit-empty
# is left at its default) once the two sessions this file created are gone.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-watchdog-session.XXXXXXXX")
HUB_PID=''

unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TEST_ROOT/tmux"
TMUX_SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
# Every tmux call of this file: explicit private socket, no user/system config.
ptmux() { command tmux -S "$TMUX_SOCK" -f /dev/null "$@"; }

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
  # Only the two sessions this file created, by exact name (=), on the private
  # socket. The server then exits on its own: it has nothing else.
  case $TMUX_SOCK in
    "$TEST_ROOT"/tmux/*)
      ptmux kill-session -t '=managed' >/dev/null 2>&1 || true
      ptmux kill-session -t '=pztest-boundary' >/dev/null 2>&1 || true
      ;;
  esac
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

for tool in chmod find grep id install kill mktemp rmdir sleep tail tmux tr; do
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
install -d -m 0700 "$TEST_ROOT/store" "$TEST_ROOT/log" \
  "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$(id -u)"

# The private server comes up holding a sentinel session, so it exists before
# the hub does (as the shipped boundary unit exists before pizarra.service) and
# leaves by itself once the harness removes what it created.
ptmux new-session -d -s pztest-boundary 'exec /bin/sleep 600' ||
  fail 'could not start the private tmux server'
[[ -S $TMUX_SOCK ]] || fail "private socket was not created at $TMUX_SOCK"
ok "private tmux server is up on $TMUX_SOCK"

cat >"$TEST_ROOT/pizarra.conf" <<EOC
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
EOC
cat >"$TEST_ROOT/console.conf" <<EOC
[pizarra]
host = 127.0.0.1
port = $HUB_PORT
secret = synthetic-console-secret
self = console
EOC
chmod 0600 "$TEST_ROOT/pizarra.conf" "$TEST_ROOT/console.conf"

PIZARRA_TICK=1 "$HUB_BIN" --config "$TEST_ROOT/pizarra.conf" >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
"$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 5 >/dev/null ||
  fail 'isolated hub did not become healthy'
# The isolation premise, checked on the real process: the hub carries no TMUX
# and the private directory, so its own tmux calls can only reach our socket.
if grep -q '^TMUX=' <(tr '\0' '\n' <"/proc/$HUB_PID/environ"); then
  fail 'the hub under test inherited TMUX; it could address a real server'
fi
grep -qx "TMUX_TMPDIR=$TMUX_TMPDIR" <(tr '\0' '\n' <"/proc/$HUB_PID/environ") ||
  fail 'the hub under test does not carry the private TMUX_TMPDIR'
ok 'hub under test carries the private socket directory and no TMUX'

for attempt in {1..100}; do
  ptmux has-session -t '=managed' 2>/dev/null && break
  sleep 0.05
done
ptmux has-session -t '=managed' 2>/dev/null ||
  fail 'watchdog did not create the session with a configured launch on the private server'
ptmux list-sessions -F '#{session_name} #{@pizarra_team}' | grep -Fxq 'managed managed' ||
  fail 'watchdog did not tag the managed session'
ok 'configured launch is created and tagged, on the private server'

sleep 2
ptmux has-session -t '=manual' 2>/dev/null &&
  fail 'watchdog unexpectedly created a session without a launch'
if grep -Fq 'watchdog: respawning session manual' "$TEST_ROOT/log/pizarra.log"; then
  fail 'watchdog falsely claimed it was respawning the manual session'
fi
ok 'missing manual session is neither fabricated nor logged as respawning'

# An existing session is final: a hub restart must find it and leave it alone.
stop_hub
PANE_BEFORE=$(ptmux display-message -p -t '=managed' '#{pane_pid}')
PIZARRA_TICK=1 "$HUB_BIN" --config "$TEST_ROOT/pizarra.conf" >>"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
"$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 5 >/dev/null ||
  fail 'restarted hub did not become healthy'
sleep 2
ptmux has-session -t '=managed' 2>/dev/null ||
  fail 'the managed session vanished across a hub restart'
[[ $(ptmux display-message -p -t '=managed' '#{pane_pid}') == "$PANE_BEFORE" ]] ||
  fail 'the managed session was replaced across a hub restart'
[[ $(grep -c 'watchdog: respawning session managed' "$TEST_ROOT/log/pizarra.log") == 1 ]] ||
  fail 'the restarted hub tried to respawn a session that already existed'
ok 'a hub restart keeps the existing session untouched (same pane, no second launch)'

printf 'all watchdog session tests passed\n'
