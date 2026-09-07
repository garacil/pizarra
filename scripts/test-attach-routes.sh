#!/usr/bin/env bash
# Integration test for `tiza attach` PUSH and DIAL routes: attach to a team
# whose tmux session lives on ANOTHER host's tiza daemon, relayed by the hub.
#
# Both "remote" hosts are loopback tiza daemons on this machine, sharing a
# private tmux server (isolation identical to test-attach.sh: TMUX/TMUX_PANE
# removed, a private -S socket named on every call, status off + window-size
# manual so a viewer of any size cannot perturb the assertions). It proves:
#   - PUSH: the hub connects to the daemon, hands over the handshake, and pipes
#     the two sockets; the daemon spawns the tmux client and relays.
#   - DIAL: the hub pushes attach_open down the reverse channel; the daemon dials
#     the hub back (attach_join) and the hub pairs it to the waiting viewer.
#   - Read-only drops the viewer's keystrokes; write mode carries them through.
# Only pztest-* sessions are created or removed, always by exact name.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-attach-routes.XXXXXXXX)
HUB_PID=''
PUSHD_PID=''
DIALD_PID=''

unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export TMUX_SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
export TMUX_CONF="$TEST_ROOT/tmux.conf"
install -d -m 0700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$(id -u)"
printf '%s\n' 'set -g status off' 'set -g window-size manual' >"$TMUX_CONF"
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
  for f in hub.out pushd.out diald.out log/pizarra.log; do
    [[ -f $TEST_ROOT/$f ]] && { printf -- '--- %s ---\n' "$f" >&2; tail -25 "$TEST_ROOT/$f" >&2 || true; }
  done
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }
contains() { [[ $1 == *"$2"* ]] || fail "$3 (missing '$2' in: ${1:0:400})"; }
lacks() { [[ $1 != *"$2"* ]] || fail "$3 (found '$2' in: ${1:0:400})"; }

wait_file() { local f=$1 p=$2 s=$3 i; for ((i=0;i<s*10;i++)); do [[ -f $f ]] && grep -q -- "$p" "$f" && return 0; sleep 0.1; done; return 1; }
wait_cmd()  { local s=$1 i; shift; for ((i=0;i<s*10;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
port_open() { (: <>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

stop_pid() {
  local var=$1 pid=${!1:-} a
  [[ -n $pid ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for a in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  printf -v "$var" '%s' ''
}
cleanup() {
  stop_pid HUB_PID; stop_pid PUSHD_PID; stop_pid DIALD_PID
  local s
  for s in pztest-host pztest-push pztest-push2 pztest-dial pztest-v pztest-w; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  case ${TEST_ROOT:-} in
    /tmp/pizarra-attach-routes.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT

for t in tmux stty pgrep grep sleep mktemp find; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"; done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'

choose_port() {
  local a c
  for a in {1..300}; do c=$((20000 + ((BASHPID + RANDOM + a) % 30000))); port_open "$c" || { printf '%s\n' "$c"; return 0; }; done
  return 1
}
PORT=$(choose_port); DPORT=$(choose_port); EPORT=$(choose_port)
[[ -n $PORT && -n $DPORT && -n $EPORT && $PORT != "$DPORT" && $PORT != "$EPORT" && $DPORT != "$EPORT" ]] || fail 'could not choose ports'
SEC=synthetic-master-secret
DIALSEC=synthetic-dialteam-secret
STORE=$TEST_ROOT/store; LOG=$TEST_ROOT/log
install -d -m 0700 "$STORE" "$LOG"

# Target sessions on the "remote" daemons, distinct non-default sizes so an
# 80x24 viewer that leaked its own size would be caught.
tmux new-session -d -s pztest-push -x 110 -y 30 'exec /bin/sh' || fail 'no pztest-push'
tmux new-session -d -s pztest-dial -x 90  -y 28 'exec /bin/sh' || fail 'no pztest-dial'
tmux new-session -d -s pztest-push2 -x 100 -y 30 'exec /bin/sh' || fail 'no pztest-push2'
sleep 0.3
ok 'push and dial target sessions are up'

cat >"$TEST_ROOT/hub.conf" <<EOF
[server]
listen = 127.0.0.1
port = $PORT
secret = $SEC
master_console_only = on
attach_local = on
[registry]
authority = sqlite
[store]
dir = $STORE
[log]
path = $LOG/pizarra.log
[team:1]
name = pushteam
speciality = push-route target
host = 127.0.0.1:$DPORT
tmux_session = pztest-push
[team:3]
name = pushteam2
speciality = push target WITHOUT attach opt-in
host = 127.0.0.1:$DPORT
tmux_session = pztest-push2
[team:2]
name = dialteam
speciality = dial-route target
secret = $DIALSEC
dial = on
tmux_session = pztest-dial
EOF
chmod 0600 "$TEST_ROOT/hub.conf"

cat >"$TEST_ROOT/console.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $SEC
self = console
EOF
chmod 0600 "$TEST_ROOT/console.conf"

# Push daemon: listens; the hub reaches it and presents the master secret.
cat >"$TEST_ROOT/pushd.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $SEC
self = console
[daemon]
listen = 127.0.0.1
port = $DPORT
secret = $SEC
state = $TEST_ROOT/pushd.state
[session:pushteam]
tmux_session = pztest-push
attach = on
[session:pushteam2]
tmux_session = pztest-push2
EOF
chmod 0600 "$TEST_ROOT/pushd.conf"

# Dial daemon: dials the hub with the team's own secret.
cat >"$TEST_ROOT/diald.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $DIALSEC
self = dialteam
[daemon]
listen = 127.0.0.1
port = $EPORT
dial = on
keepalive = 5
state = $TEST_ROOT/diald.state
[session:dialteam]
tmux_session = pztest-dial
attach = on
EOF
chmod 0600 "$TEST_ROOT/diald.conf"

# Hub inside tmux, as in production (proves the attach relay carries no $TMUX).
tmux new-session -d -s pztest-host -x 100 -y 30 \
  "exec '$HUB_BIN' --config '$TEST_ROOT/hub.conf' >'$TEST_ROOT/hub.out' 2>&1" || fail 'no hub session'
wait_cmd 10 "$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 1 || fail 'hub not healthy'
ok 'hub is up'

"$TIZA_BIN" daemon --config "$TEST_ROOT/pushd.conf" >"$TEST_ROOT/pushd.out" 2>&1 &
PUSHD_PID=$!
for i in {1..100}; do port_open "$DPORT" && break; sleep 0.1; done
port_open "$DPORT" || fail 'push daemon did not listen'
ok 'push daemon is listening'

"$TIZA_BIN" daemon --config "$TEST_ROOT/diald.conf" >"$TEST_ROOT/diald.out" 2>&1 &
DIALD_PID=$!
wait_file "$LOG/pizarra.log" 'dial accepted from=dialteam' 10 || fail 'dial daemon did not dial in'
ok 'dial daemon dialed the hub in'

# run_viewer SESS ARGS...: `tiza attach ARGS` inside its own 80x24 tmux session.
run_viewer() {
  local sess=$1; shift
  local IFS=' '; local args="$*"
  rm -f "$TEST_ROOT/$sess.err"
  tmux new-session -d -s "$sess" -x 80 -y 24 \
    "'$TIZA_BIN' --config '$TEST_ROOT/console.conf' attach $args 2>'$TEST_ROOT/$sess.err'; echo VX=\$? >>'$TEST_ROOT/$sess.err'; sleep 3" \
    || fail "could not start viewer $sess"
}
detach_viewer() {
  local sess=$1
  tmux send-keys -t "$sess" C-] q
  wait_file "$TEST_ROOT/$sess.err" 'attach closed:' 5 || fail "$sess did not close"
}

check_route() {   # $1 = team, $2 = target session, $3 = its size WxH
  local team=$1 sess=$2 size=$3

  # read-only: opens at the SESSION size, and typed bytes never reach the pane.
  run_viewer pztest-v "$team"
  wait_file "$TEST_ROOT/pztest-v.err" "$team (read-only) $size" 12 ||
    fail "$team read-only attach did not open at $size: $(cat "$TEST_ROOT/pztest-v.err" 2>/dev/null)"
  ok "$team: read-only attach opened at $size"
  tmux send-keys -t pztest-v 'echo RO_LEAK' Enter
  sleep 1
  lacks "$(tmux capture-pane -p -t "$sess" -S -50)" 'RO_LEAK' "$team: read-only keystrokes reached the pane"
  ok "$team: read-only drops the viewer's keystrokes"
  detach_viewer pztest-v
  tmux kill-session -t =pztest-v 2>/dev/null || true

  # write: typed bytes reach the pane and its output comes back.
  run_viewer pztest-w "$team" --write
  wait_file "$TEST_ROOT/pztest-w.err" "$team (write) $size" 12 ||
    fail "$team write attach did not open: $(cat "$TEST_ROOT/pztest-w.err" 2>/dev/null)"
  tmux send-keys -t pztest-w 'echo WROK_'"$team" Enter
  wait_cmd 6 bash -c "tmux capture-pane -p -t $sess -S -50 | grep -q '^WROK_$team'" ||
    fail "$team: typed command did not reach the pane in write mode"
  ok "$team: write carries keystrokes to the pane"
  # The echo's output round-trips daemon -> hub -> viewer; over a network hop
  # that redraw can lag the keystroke, so wait for it rather than sampling once.
  wait_cmd 6 bash -c "tmux capture-pane -p -t pztest-w -S -50 | grep -q 'WROK_$team'" ||
    fail "$team: pane output was not relayed back to the viewer"
  ok "$team: write relays the pane output back to the viewer"
  [[ $(tmux display-message -p -t "$sess" '#{window_width}x#{window_height}') == "$size" ]] ||
    fail "$team: a viewer resized the $size session"
  ok "$team: the viewer did not resize the session"
  detach_viewer pztest-w
  tmux kill-session -t =pztest-w 2>/dev/null || true
}

########## PUSH route ##########
check_route pushteam pztest-push 110x30
wait_file "$LOG/pizarra.log" 'attach opened: console -> pushteam (write, push' 5 ||
  fail 'hub did not log the push attach'
ok 'push route: hub logged the relayed attach'

########## DIAL route ##########
check_route dialteam pztest-dial 90x28
wait_file "$LOG/pizarra.log" 'attach opened: console -> dialteam (write, dial)' 5 ||
  fail 'hub did not name the CALLER on the dial attach'
ok 'dial route: hub logged the dialed-back attach'

########## consent gate: a session without attach=on is refused ##########
run_viewer pztest-v pushteam2
wait_file "$TEST_ROOT/pztest-v.err" 'VX=' 12 || fail 'consent-gate viewer did not exit'
contains "$(cat "$TEST_ROOT/pztest-v.err")" 'not enabled for pushteam2' 'a session without attach=on was not refused'
contains "$(cat "$TEST_ROOT/pztest-v.err")" 'VX=1' 'the refusal did not exit non-zero'
tmux kill-session -t =pztest-v 2>/dev/null || true
ok 'consent gate: attach to a session without attach=on is refused'

########## the tmux clients carry no $TMUX (production shape) ##########
tmux has-session -t pztest-host 2>/dev/null || fail 'hub session vanished'
tmux has-session -t pztest-push 2>/dev/null || fail 'push target destroyed'
tmux has-session -t pztest-dial 2>/dev/null || fail 'dial target destroyed'
ok 'all target sessions survived the attaches'

printf 'all tiza attach route (push + dial) tests passed\n'
