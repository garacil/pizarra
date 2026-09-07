#!/usr/bin/env bash
# Integration test for the `tiza shell` PUSH and DIAL routes: a login shell on
# ANOTHER host's machine, relayed by the hub.
#
# Both "remote" hosts are loopback tiza daemons on this machine. It proves:
#   - PUSH: the hub connects to the daemon and pipes the two sockets; the
#     daemon spawns the login shell and relays.
#   - DIAL: the hub pushes shell_open down the reverse channel; the daemon
#     dials the hub back (shell_join) and the hub pairs it by token. This is
#     the only route to a machine with no inbound path at all.
#   - The HOST's opt-in is authoritative: a daemon without [daemon] shell = on
#     refuses even though the hub authorised the caller.
#   - A shell is per HOST, not per session: a team with NO [session:] block on
#     the daemon still gets a shell, while attach on that same team is refused.
# Only pztest-* sessions are created or removed, always by exact name.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-shell-routes.XXXXXXXX)
HUB_PID=''
PUSHD_PID=''
DIALD_PID=''
NOSHELLD_PID=''

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
  for f in hub.out pushd.out diald.out noshelld.out log/pizarra.log; do
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
  stop_pid HUB_PID; stop_pid PUSHD_PID; stop_pid DIALD_PID; stop_pid NOSHELLD_PID
  local s
  for s in pztest-host pztest-keep pztest-dial pztest-c1 pztest-c2 pztest-c3 pztest-c4 pztest-c5; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  case ${TEST_ROOT:-} in
    /tmp/pizarra-shell-routes.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT

for t in tmux grep sleep mktemp find id; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"; done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'

# The account the shell opens as. Named nowhere in this file on purpose: a real
# account name is operational data. Unprivileged, the only account we can log in
# as is our own, which takes the direct login-shell branch. As root, discover any
# ordinary account with a real login shell so the production `su - <account>`
# branch is what runs. PIZARRA_TEST_SHELL_USER overrides either.
pick_account() {
  local line name uid sh
  if [[ -n ${PIZARRA_TEST_SHELL_USER:-} ]]; then
    printf '%s\n' "$PIZARRA_TEST_SHELL_USER"
    return 0
  fi
  if [[ $(id -u) != 0 ]]; then
    id -un
    return 0
  fi
  while IFS= read -r line; do
    name=${line%%:*}
    uid=$(printf '%s' "$line" | cut -d: -f3)
    sh=${line##*:}
    [[ $name == root ]] && continue
    [[ $uid =~ ^[0-9]+$ ]] || continue
    ((uid >= 1000 && uid < 60000)) || continue
    case $sh in
      */nologin | */false | '') continue ;;
    esac
    [[ -x $sh ]] || continue
    printf '%s\n' "$name"
    return 0
  done < <(getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null)
  return 1
}
ACCT=$(pick_account) || fail 'no usable account; set PIZARRA_TEST_SHELL_USER'
ok "shell account for this run: $ACCT"

choose_port() {
  local a c
  for a in {1..300}; do c=$((20000 + ((BASHPID + RANDOM + a) % 30000))); port_open "$c" || { printf '%s\n' "$c"; return 0; }; done
  return 1
}
PORT=$(choose_port); DPORT=$(choose_port); EPORT=$(choose_port); NPORT=$(choose_port)
SEC=synthetic-master-secret
DIALSEC=synthetic-dialteam-secret
STORE=$TEST_ROOT/store; LOG=$TEST_ROOT/log
install -d -m 0700 "$STORE" "$LOG"

# A bystander session that must survive the whole run.
tmux new-session -d -s pztest-keep -x 80 -y 24 'exec /bin/sh' || fail 'no bystander'
# A dial daemon claims the teams it declares sessions for, and a remote daemon
# may not declare an inbox-only one. Create it up front so the watchdog never
# has to, and note that the shell itself needs none of this - it is the DIAL
# transport that requires the team to be claimed.
tmux new-session -d -s pztest-dial -x 80 -y 24 'exec /bin/sh' || fail 'no pztest-dial'

cat >"$TEST_ROOT/hub.conf" <<EOF
[server]
listen = 127.0.0.1
port = $PORT
secret = $SEC
master_console_only = on
attach_local = on
shell_local = off
[registry]
authority = sqlite
[store]
dir = $STORE
[log]
path = $LOG/pizarra.log
[team:1]
name = pushteam
speciality = push-route target host
host = 127.0.0.1:$DPORT
tmux_session = -
[team:3]
name = bareteam
speciality = push target with NO session block on its daemon
host = 127.0.0.1:$DPORT
tmux_session = -
[team:4]
name = noshellteam
speciality = push target whose daemon never opted in
host = 127.0.0.1:$NPORT
tmux_session = -
[team:2]
name = dialteam
speciality = dial-route target host
secret = $DIALSEC
dial = on
tmux_session = -
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

# Push daemon: opted in, with an account. It declares NO [session:] block at
# all - the structural point that a shell belongs to the host, not a session.
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
shell = on
shell_user = $ACCT
EOF
chmod 0600 "$TEST_ROOT/pushd.conf"

# A second push daemon that never opted in.
cat >"$TEST_ROOT/noshelld.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $SEC
self = console
[daemon]
listen = 127.0.0.1
port = $NPORT
secret = $SEC
state = $TEST_ROOT/noshelld.state
EOF
chmod 0600 "$TEST_ROOT/noshelld.conf"

# Dial daemon: reaches the hub outbound, as the NAT'd endpoints do.
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
shell = on
shell_user = $ACCT
[session:dialteam]
tmux_session = pztest-dial
EOF
chmod 0600 "$TEST_ROOT/diald.conf"

tmux new-session -d -s pztest-host -x 100 -y 30 \
  "exec '$HUB_BIN' --config '$TEST_ROOT/hub.conf' >'$TEST_ROOT/hub.out' 2>&1" || fail 'no hub session'
wait_cmd 10 "$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 1 || fail 'hub not healthy'
ok 'hub is up'

"$TIZA_BIN" daemon --config "$TEST_ROOT/pushd.conf" >"$TEST_ROOT/pushd.out" 2>&1 &
PUSHD_PID=$!
for i in {1..100}; do port_open "$DPORT" && break; sleep 0.1; done
port_open "$DPORT" || fail 'push daemon did not listen'
ok 'push daemon is listening'

"$TIZA_BIN" daemon --config "$TEST_ROOT/noshelld.conf" >"$TEST_ROOT/noshelld.out" 2>&1 &
NOSHELLD_PID=$!
for i in {1..100}; do port_open "$NPORT" && break; sleep 0.1; done
port_open "$NPORT" || fail 'opt-out daemon did not listen'
ok 'opt-out daemon is listening'

"$TIZA_BIN" daemon --config "$TEST_ROOT/diald.conf" >"$TEST_ROOT/diald.out" 2>&1 &
DIALD_PID=$!
wait_file "$LOG/pizarra.log" 'dial accepted from=dialteam' 10 || fail 'dial daemon did not dial in'
ok 'dial daemon dialed the hub in'

# run_client SESS COLSxROWS VERB ARGS...
run_client() {
  local sess=$1 size=$2; shift 2
  local IFS=' '; local args="$*"
  rm -f "$TEST_ROOT/$sess.err"
  case $sess in
    pztest-*) tmux kill-session -t "=$sess" 2>/dev/null || true ;;
    *) fail "refusing a non-pztest session name: $sess" ;;
  esac
  tmux new-session -d -s "$sess" -x "${size%x*}" -y "${size#*x}" \
    "'$TIZA_BIN' --config '$TEST_ROOT/console.conf' $args 2>'$TEST_ROOT/$sess.err'; echo CX=\$? >>'$TEST_ROOT/$sess.err'; sleep 3" \
    || fail "could not start client $sess"
}

# check_route TEAM SESSION ROUTELABEL SIZE
check_route() {
  local team=$1 sess=$2 route=$3 size=$4
  run_client "$sess" "$size" shell "$team"
  wait_file "$TEST_ROOT/$sess.err" 'tiza shell:' 15 ||
    fail "$route: shell never opened for $team"
  local out; out=$(<"$TEST_ROOT/$sess.err")
  contains "$out" "$ACCT@" "$route: banner names the account"
  contains "$out" "$size" "$route: pty is sized to the viewer"
  # A real interactive shell on the far side.
  tmux send-keys -t "$sess" 'id -un' Enter
  wait_cmd 15 bash -c "tmux capture-pane -p -t $sess | grep -q '^$ACCT\$'" ||
    fail "$route: the far shell did not answer id -un"
  tmux send-keys -t "$sess" 'exit' Enter
  wait_file "$TEST_ROOT/$sess.err" 'shell closed:' 10 ||
    fail "$route: the shell did not close on exit"
  ok "$route: a real login shell opened as $ACCT, ran a command, and closed"
}

check_route pushteam pztest-c1 PUSH 110x30
grep -q 'shell opened: console -> pushteam (push 127.0.0.1' "$LOG/pizarra.log" ||
  fail 'the hub did not log the push route'
grep -q "shell opened by console -> pushteam ($ACCT@" "$TEST_ROOT/pushd.out" ||
  fail 'the push daemon did not log the CALLING TEAM and the account it opened as'
ok 'hub logs who and where; the daemon logs as whom'

check_route dialteam pztest-c2 DIAL 90x28
grep -q 'shell opened: console -> dialteam (dial' "$LOG/pizarra.log" ||
  fail 'the hub did not name the CALLER on the dial route'
grep -q "shell opened by console -> dialteam ($ACCT@" "$TEST_ROOT/diald.out" ||
  fail 'the dial daemon did not log the calling team (control line lost it)'
ok 'the dial route is paired by token and logged'

# A shell is per HOST: bareteam has no [session:] block anywhere, so attach
# cannot work for it, but the shell must.
check_route bareteam pztest-c3 PUSH-NOSESSION 100x30
run_client pztest-c4 80x24 attach bareteam
wait_file "$TEST_ROOT/pztest-c4.err" 'CX=' 10 || fail 'attach probe did not exit'
contains "$(<"$TEST_ROOT/pztest-c4.err")" 'no session declared' \
  'attach on a session-less team should say so'
ok 'a shell reaches a host with no declared session; attach on it cannot'

# The host opt-in is authoritative: the hub authorised, the daemon refuses.
run_client pztest-c5 80x24 shell noshellteam
wait_file "$TEST_ROOT/pztest-c5.err" 'CX=' 15 || fail 'opt-out client did not exit'
OUT=$(<"$TEST_ROOT/pztest-c5.err")
contains "$OUT" 'not enabled on this host' 'the daemon refuses without its own opt-in'
contains "$OUT" 'CX=1' 'a refused client exits 1'
ok 'the hub cannot override a host that has the shell off'

# A dial host that is not connected.
stop_pid DIALD_PID
sleep 1
run_client pztest-c2 80x24 shell dialteam
wait_file "$TEST_ROOT/pztest-c2.err" 'CX=' 20 || fail 'client did not exit for an offline dial host'
OUT=$(<"$TEST_ROOT/pztest-c2.err")
# Either refusal is correct and which one appears is a race with the hub
# noticing the channel is gone: the reverse channel is either already dropped
# (not currently dialed in) or still registered and nothing dials back within
# SHELL_DIAL_MS (did not dial back in time). Both must refuse and exit 1.
if [[ $OUT != *'not currently dialed in'* && $OUT != *'did not dial back in time'* ]]; then
  fail "an offline dial host should be refused clearly (got: ${OUT:0:300})"
fi
contains "$OUT" 'CX=1' 'a client to an offline dial host exits 1'
ok 'an offline dial host is refused clearly'

tmux has-session -t pztest-keep 2>/dev/null || fail 'the bystander session did not survive'
ok 'no tmux session was harmed'

printf '\nall shell route checks passed\n'
