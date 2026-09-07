#!/usr/bin/env bash
# Integration test for `tiza attach`: a raw terminal into a team's tmux
# session, relayed by the hub. Part A covers the LOCAL route (the hub host's
# own sessions); the push and dial-in routes extend this file.
#
# It runs the real hub and the real client against loopback-only, disposable
# state. The hub is started INSIDE a tmux session on purpose - exactly the
# production shape - so the test proves the tmux client it spawns does not
# inherit $TMUX (which would make it switch the hub's own client instead of
# attaching). Only pztest-* tmux sessions are ever created or removed.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-attach.XXXXXXXX)
HUB_PID=''
SESSIONS=(pztest-host pztest-att pztest-viewer pztest-writer pztest-plain
          pztest-v1 pztest-v2 pztest-v3 pztest-stty)

# ISOLATION. Nothing here may reach a real tmux server, even when an agent runs
# this file from inside a tmux pane: tmux chooses its socket from $TMUX before
# TMUX_TMPDIR, so the pane's own variable would redirect every command to the
# live server. TMUX and TMUX_PANE are removed, TMUX_TMPDIR is a private
# directory the hub under test and its attach child inherit, and every direct
# tmux call names that socket with -S. Sessions are removed by exact name (=).
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export TMUX_SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
export TMUX_CONF="$TEST_ROOT/tmux.conf"
install -d -m 0700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$(id -u)"
# Disposable server config, read when the first new-session starts the server.
# status off: a 120x40 client on a status-on server yields a 120x39 window (the
# status line eats a row) - not a resize by the viewer, but it would make the
# size assertions off by one. With no status line the window is exactly the
# client size, so "an 80x24 viewer did not shrink this session" is what the
# checks measure. exit-empty is left on, so the server still leaves by itself
# once the sessions are gone.
printf '%s\n' 'set -g status off' 'set -g window-size manual' >"$TMUX_CONF"
# send-keys resolves a "target client" even without -c, and refuses to run when
# that client is read-only (tmux cmd-send-keys.c). On this private server the
# only attached client is the hub's read-only viewer, so every send-keys would
# be refused. Name a client that cannot exist: the command tolerates that
# (CMD_CLIENT_CANFAIL) and injects the keys into the target pane with no client.
tmux() {
  if [[ ${1:-} == send-keys ]]; then
    shift
    command tmux -S "$TMUX_SOCK" -f "$TMUX_CONF" send-keys -c pztest-no-client "$@"
  else
    command tmux -S "$TMUX_SOCK" -f "$TMUX_CONF" "$@"
  fi
}
export -f tmux

fail() {
  printf 'not ok: %s\n' "$*" >&2
  if [[ -f $TEST_ROOT/hub.out ]]; then
    printf '%s\n' '--- isolated hub output ---' >&2
    tail -40 "$TEST_ROOT/hub.out" >&2 || true
  fi
  if [[ -f $TEST_ROOT/log/pizarra.log ]]; then
    printf '%s\n' '--- isolated hub log ---' >&2
    tail -20 "$TEST_ROOT/log/pizarra.log" >&2 || true
  fi
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }

contains() {
  local value=$1 expected=$2 label=$3
  [[ $value == *"$expected"* ]] ||
    fail "$label (missing '$expected' in: ${value:0:400})"
}
lacks() {
  local value=$1 unexpected=$2 label=$3
  [[ $value != *"$unexpected"* ]] ||
    fail "$label (found '$unexpected' in: ${value:0:400})"
}

# wait_file FILE PATTERN SECONDS: until FILE contains PATTERN
wait_file() {
  local file=$1 pat=$2 secs=$3 i
  for ((i = 0; i < secs * 10; i++)); do
    [[ -f $file ]] && grep -q -- "$pat" "$file" && return 0
    sleep 0.1
  done
  return 1
}
# wait_cmd SECONDS CMD...: until CMD succeeds
wait_cmd() {
  local secs=$1 i; shift
  for ((i = 0; i < secs * 10; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
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
  HUB_PID=''
}

cleanup() {
  stop_hub
  local s
  for s in "${SESSIONS[@]}"; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  case ${TEST_ROOT:-} in
    /tmp/pizarra-attach.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

for tool in tmux stty pgrep ps grep sleep mktemp find; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries are missing; run make debug'
for s in "${SESSIONS[@]}"; do
  tmux has-session -t "$s" 2>/dev/null && fail "stale session $s exists; another run in progress?"
done

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
PLAIN_CONF=$TEST_ROOT/plain.conf
install -d -m 0700 "$STORE" "$LOG_DIR" "$TEST_ROOT/home"

write_hub_conf() {   # $1 = attach_local value
  cat >"$HUB_CONF" <<EOF
[server]
listen = 127.0.0.1
port = $PORT
secret = synthetic-console-secret
master_console_only = on
attach_local = $1

[registry]
authority = sqlite

[store]
dir = $STORE

[log]
path = $LOG_DIR/pizarra.log

[team:1]
name = att
speciality = Synthetic local team with a real terminal
tmux_session = pztest-att

[team:2]
name = plain
speciality = Synthetic team with no attach authority
secret = synthetic-plain-secret
tmux_session = -
EOF
  chmod 0600 "$HUB_CONF"
}
cat >"$CONSOLE_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-console-secret
self = console
EOF
cat >"$PLAIN_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-plain-secret
self = plain
EOF
chmod 0600 "$CONSOLE_CONF" "$PLAIN_CONF"

# The target: a plain shell in a 120x40 session, created before the hub.
tmux new-session -d -s pztest-att -x 120 -y 40 'exec /bin/sh' ||
  fail 'could not create the target session'
sleep 0.3
[[ $(tmux display-message -p -t pztest-att '#{window_width}x#{window_height}') == 120x40 ]] ||
  fail 'target session did not come up at 120x40'
ok 'target session pztest-att is up at 120x40'

start_hub() {
  # Inside tmux, as in production, so the hub process carries $TMUX.
  rm -f "$TEST_ROOT/hub.out"
  tmux new-session -d -s pztest-host -x 100 -y 30 \
    "exec '$HUB_BIN' --config '$HUB_CONF' >'$TEST_ROOT/hub.out' 2>&1" ||
    fail 'could not start the hub inside tmux'
  local ready=0 attempt
  for attempt in {1..100}; do
    if "$TIZA_BIN" --config "$CONSOLE_CONF" --health --wait 1 \
        >"$TEST_ROOT/health.out" 2>&1; then
      ready=1
      break
    fi
    sleep 0.05
  done
  ((ready == 1)) || fail 'isolated hub did not become healthy'
  # pgrep -f takes a regex: match on the config path, which has no
  # metacharacters, not on the repository path (a '+' in it would be one).
  HUB_PID=$(pgrep -f -- "--config $HUB_CONF" | head -1 || true)
  [[ -n $HUB_PID ]] || fail 'could not find the hub pid'
  grep -q '^TMUX=' <(tr '\0' '\n' <"/proc/$HUB_PID/environ") ||
    fail 'test premise broken: the hub does not carry TMUX in its environment'
}
restart_hub() {
  stop_hub
  tmux kill-session -t =pztest-host 2>/dev/null || true
  wait_cmd 5 bash -c "! tmux has-session -t pztest-host 2>/dev/null" || true
  start_hub
}

# run_viewer SESSION CONF ARGS...: start `tiza attach` inside its own 80x24
# tmux session, stderr to $TEST_ROOT/SESSION.err, exit code appended.
run_viewer() {
  local sess=$1 conf=$2; shift 2
  local err=$TEST_ROOT/$sess.err
  # This script runs with IFS=$'\n\t'; "$*" would join the arguments with a
  # NEWLINE and split the tmux command in two. Join with spaces explicitly.
  local IFS=' '
  local args="$*"
  rm -f "$err"
  tmux new-session -d -s "$sess" -x 80 -y 24 \
    "'$TIZA_BIN' --config '$conf' attach $args 2>'$err'; echo VIEWER_EXIT=\$? >>'$err'; sleep 3" ||
    fail "could not start viewer $sess"
}
detach_viewer() {   # send the local escape and wait for the closing line
  local sess=$1
  tmux send-keys -t "$sess" C-] q
  wait_file "$TEST_ROOT/$sess.err" 'attach closed:' 5 ||
    fail "viewer $sess did not report a close after Ctrl-] q"
  wait_file "$TEST_ROOT/$sess.err" 'VIEWER_EXIT=' 5 ||
    fail "viewer $sess did not exit"
}
attach_child_pid() {   # the tmux client the hub spawned for pztest-att
  pgrep -f 'attach-session -[rf].* -t pztest-att' | head -1 || true
}

########## 4) opt-in: with attach_local off the console is refused ##########
write_hub_conf off
start_hub
run_viewer pztest-viewer "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-viewer.err" 'VIEWER_EXIT=' 10 || fail 'viewer did not exit (opt-in off)'
contains "$(cat "$TEST_ROOT/pztest-viewer.err")" 'attach not enabled for local teams' \
  'attach_local=off did not refuse'
contains "$(cat "$TEST_ROOT/pztest-viewer.err")" 'VIEWER_EXIT=1' 'refusal did not exit 1'
tmux kill-session -t =pztest-viewer 2>/dev/null || true
ok 'attach_local=off refuses even the console'

########## switch on and restart (config is bootstrap; the registry persists) ##########
write_hub_conf on
restart_hub

########## 3) authority: a plain team credential is refused ##########
run_viewer pztest-plain "$PLAIN_CONF" att
wait_file "$TEST_ROOT/pztest-plain.err" 'VIEWER_EXIT=' 10 || fail 'plain viewer did not exit'
contains "$(cat "$TEST_ROOT/pztest-plain.err")" 'may open a terminal into another team' \
  'a plain team credential was not refused'
tmux kill-session -t =pztest-plain 2>/dev/null || true
ok 'a plain team credential is refused'

########## 5/9/14/15) read-only attach: nothing typed reaches the pane ##########
run_viewer pztest-viewer "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-viewer.err" 'tiza attach: att (read-only) 120x40' 10 ||
  fail "read-only attach did not open: $(cat "$TEST_ROOT/pztest-viewer.err" 2>/dev/null)"
sleep 0.5
CHILD=$(attach_child_pid)
[[ -n $CHILD ]] || fail 'no tmux attach child found for the read-only viewer'
ok "read-only attach opened (tmux client pid $CHILD)"

tmux send-keys -t pztest-viewer 'echo RO_LEAK' Enter
sleep 1
lacks "$(tmux capture-pane -p -t pztest-att -S -100)" 'RO_LEAK' \
  'keystrokes from a read-only viewer reached the pane'
ok 'read-only: typed bytes never reach the pane'

[[ $(tmux display-message -p -t pztest-att '#{window_width}x#{window_height}') == 120x40 ]] ||
  fail 'an 80x24 read-only viewer resized the 120x40 session'
ok 'sizing: the 120x40 session was not shrunk by an 80x24 viewer'

[[ $(stty size <"/proc/$CHILD/fd/0" 2>/dev/null) == '40 120' ]] ||
  fail "attach pty is not 40x120: $(stty size <"/proc/$CHILD/fd/0" 2>&1)"
ok 'the attach pty was created at the session size (40 120)'

CHILD_ENV=$(tr '\0' '\n' <"/proc/$CHILD/environ")
lacks "$CHILD_ENV" $'\nTMUX=' 'the tmux client inherited TMUX from the hub'
lacks "$CHILD_ENV" 'TMUX_PANE=' 'the tmux client inherited TMUX_PANE'
contains "$CHILD_ENV" 'TERM=' 'the tmux client has no TERM'
contains "$CHILD_ENV" 'LANG=C.UTF-8' 'the tmux client has no UTF-8 locale'
tmux has-session -t pztest-host 2>/dev/null || fail 'the hub tmux session vanished'
kill -0 "$HUB_PID" 2>/dev/null || fail 'the hub died during attach'
ok 'the tmux client environment is clean: no TMUX, TERM and LANG set; hub session intact'

FD_COUNT=$(find "/proc/$CHILD/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
# tmux itself opens its server socket and a few fds after exec; what matters
# is that nothing of the HUB's was inherited: no listening socket on our port.
lacks "$(ss -lntp 2>/dev/null | grep ":$PORT " || true)" "pid=$CHILD," \
  'the tmux client holds the hub listening socket'
ok "fd hygiene: the tmux client does not hold the hub listener ($FD_COUNT fds of its own)"

detach_viewer pztest-viewer
contains "$(cat "$TEST_ROOT/pztest-viewer.err")" 'attach closed: att (read-only' \
  'closing line missing'
wait_cmd 5 bash -c "! kill -0 $CHILD 2>/dev/null" || fail 'tmux attach child survived detach'
[[ -z $(ps -o stat= -p "$CHILD" 2>/dev/null) ]] || fail 'tmux attach child left as a zombie'
tmux has-session -t pztest-att 2>/dev/null || fail 'the TARGET session was destroyed by detach'
wait_file "$LOG_DIR/pizarra.log" 'attach opened: console -> att (read-only' 5 ||
  fail 'hub log has no attach opened line'
wait_file "$LOG_DIR/pizarra.log" 'attach closed: console -> att (read-only' 5 ||
  fail 'hub log has no attach closed line'
tmux kill-session -t =pztest-viewer 2>/dev/null || true
ok 'detach: client reaped, target session preserved, open/close logged'

########## 5b) Ctrl-b d detaches too, and in read-only ##########
# The tmux-native detach key, typeable on every layout unlike Ctrl-]. It is
# intercepted by the client, so it must work even read-only (input dropped).
run_viewer pztest-viewer "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-viewer.err" 'att (read-only) 120x40' 10 ||
  fail "read-only attach did not open for the Ctrl-b d check"
sleep 0.5
tmux send-keys -t pztest-viewer C-b d
wait_file "$TEST_ROOT/pztest-viewer.err" 'attach closed:' 5 ||
  fail 'Ctrl-b d did not detach a read-only viewer'
wait_file "$TEST_ROOT/pztest-viewer.err" 'VIEWER_EXIT=' 5 ||
  fail 'viewer did not exit after Ctrl-b d'
tmux has-session -t pztest-att 2>/dev/null || fail 'Ctrl-b d destroyed the target session'
tmux kill-session -t =pztest-viewer 2>/dev/null || true
ok 'Ctrl-b d detaches (read-only), target session preserved'

########## 6) write attach: typed bytes reach the pane ##########
run_viewer pztest-writer "$CONSOLE_CONF" att --write
wait_file "$TEST_ROOT/pztest-writer.err" 'tiza attach: att (write) 120x40' 10 ||
  fail "write attach did not open: $(cat "$TEST_ROOT/pztest-writer.err" 2>/dev/null)"
sleep 0.5
tmux send-keys -t pztest-writer 'echo ATT_OK' Enter
wait_cmd 5 bash -c "tmux capture-pane -p -t pztest-att -S -100 | grep -q '^ATT_OK'" ||
  fail 'typed command did not reach the pane in write mode'
ok 'write: typed bytes reach the pane and execute'
contains "$(tmux capture-pane -p -t pztest-writer -S -50)" 'ATT_OK' \
  'the pane output did not come back to the writer'
ok 'write: pane output is relayed back to the viewer'
[[ $(tmux display-message -p -t pztest-att '#{window_width}x#{window_height}') == 120x40 ]] ||
  fail 'a write viewer resized the session'
detach_viewer pztest-writer
wait_file "$LOG_DIR/pizarra.log" 'attach closed: console -> att (write' 5 ||
  fail 'hub log has no write close line'
tmux kill-session -t =pztest-writer 2>/dev/null || true
ok 'write attach closed cleanly and was logged'

########## 11) bounds: the third attach to one team is refused ##########
run_viewer pztest-v1 "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-v1.err" '(read-only) 120x40' 10 || fail 'v1 did not open'
run_viewer pztest-v2 "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-v2.err" '(read-only) 120x40' 10 || fail 'v2 did not open'
run_viewer pztest-v3 "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-v3.err" 'VIEWER_EXIT=' 10 || fail 'v3 did not exit'
contains "$(cat "$TEST_ROOT/pztest-v3.err")" 'per-team limit reached for att' \
  'third attach to one team was not refused'
detach_viewer pztest-v1
detach_viewer pztest-v2
for s in pztest-v1 pztest-v2 pztest-v3; do tmux kill-session -t "=$s" 2>/dev/null || true; done
wait_cmd 5 bash -c "[ -z \"\$(pgrep -f 'attach-session -[rf].* -t pztest-att')\" ]" ||
  fail 'attach children survived the bounds test'
ok 'bounds: per-team limit enforced and counters released'

# After release, a new attach must succeed again (counters were decremented).
run_viewer pztest-v1 "$CONSOLE_CONF" att
wait_file "$TEST_ROOT/pztest-v1.err" '(read-only) 120x40' 10 ||
  fail 'attach refused after the counters should have been released'
detach_viewer pztest-v1
tmux kill-session -t =pztest-v1 2>/dev/null || true
ok 'bounds: counters are released on close'

########## 12) terminal restore ##########
tmux new-session -d -s pztest-stty -x 80 -y 24 \
  "stty -a >'$TEST_ROOT/stty.before'; '$TIZA_BIN' --config '$CONSOLE_CONF' attach att 2>'$TEST_ROOT/pztest-stty.err'; stty -a >'$TEST_ROOT/stty.after'; echo DONE >>'$TEST_ROOT/pztest-stty.err'; sleep 3" ||
  fail 'could not start the stty viewer'
wait_file "$TEST_ROOT/pztest-stty.err" '(read-only) 120x40' 10 || fail 'stty viewer did not open'
tmux send-keys -t pztest-stty C-] q
wait_file "$TEST_ROOT/pztest-stty.err" 'DONE' 10 || fail 'stty viewer did not finish'
cmp -s "$TEST_ROOT/stty.before" "$TEST_ROOT/stty.after" ||
  fail "terminal modes differ after attach: $(diff "$TEST_ROOT/stty.before" "$TEST_ROOT/stty.after" | head -5)"
tmux kill-session -t =pztest-stty 2>/dev/null || true
ok 'terminal restore: stty -a identical before and after'

########## 2) a hub without the command refuses cleanly ##########
# Simulated with the real hub: an unknown cmd is exactly what an old hub says.
printf '%s\n' "{\"cmd\":\"attach_nope\",\"secret\":\"synthetic-console-secret\",\"from\":\"console\"}" |
  timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; cat >&3; head -c 200 <&3" \
  >"$TEST_ROOT/unknown.out" 2>&1 || true
contains "$(cat "$TEST_ROOT/unknown.out")" 'unknown cmd' 'hub did not answer unknown cmd'
ok 'an unknown command is refused with the text the client maps to "needs 1.2.0"'

stop_hub
tmux kill-session -t =pztest-host 2>/dev/null || true
printf '%s\n' 'all tiza attach (local route) tests passed'
