#!/usr/bin/env bash
# `tiza attach` trust model: [server] attach_trust and [daemon] attach.
#
# Proves that on a fleet the operator trusts fully, ANY authenticated team can
# attach AND write ANY other team with its OWN credential (no shared console
# secret), and that one [daemon] attach = on opts in every session on a host
# without a per-session key. Same private-socket isolation as the other attach
# harnesses; only pztest-* sessions are touched.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-attach-trust.XXXXXXXX)
HUB_PID=''; DPID=''

unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export TMUX_SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
export TMUX_CONF="$TEST_ROOT/tmux.conf"
install -d -m 0700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$(id -u)"
printf '%s\n' 'set -g status off' 'set -g window-size manual' >"$TMUX_CONF"
tmux() {
  if [[ ${1:-} == send-keys ]]; then shift
    command tmux -S "$TMUX_SOCK" -f "$TMUX_CONF" send-keys -c pztest-no-client "$@"
  else command tmux -S "$TMUX_SOCK" -f "$TMUX_CONF" "$@"; fi
}
export -f tmux

fail() { printf 'not ok: %s\n' "$*" >&2
  for f in hub.out d.out log/pizarra.log; do [[ -f $TEST_ROOT/$f ]] && { printf -- '--- %s ---\n' "$f" >&2; tail -20 "$TEST_ROOT/$f" >&2 || true; }; done
  exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
contains() { [[ $1 == *"$2"* ]] || fail "$3 (missing '$2' in: ${1:0:400})"; }
wait_file() { local f=$1 p=$2 s=$3 i; for ((i=0;i<s*10;i++)); do [[ -f $f ]] && grep -q -- "$p" "$f" && return 0; sleep 0.1; done; return 1; }
wait_cmd()  { local s=$1 i; shift; for ((i=0;i<s*10;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
port_open() { (: <>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
stop() { local v=$1 pid=${!1:-} a; [[ -n $pid ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null||true; for a in {1..100}; do kill -0 "$pid" 2>/dev/null||break; sleep 0.05; done; kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null||true; fi; printf -v "$v" '%s' ''; }
cleanup() { stop HUB_PID; stop DPID
  for s in pztest-host pztest-beta pztest-w; do tmux kill-session -t "=$s" 2>/dev/null || true; done
  case ${TEST_ROOT:-} in /tmp/pizarra-attach-trust.*) [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null||true; [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null||true;; esac; }
trap cleanup EXIT

[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'
choose_port(){ local a c; for a in {1..300}; do c=$((20000+((BASHPID+RANDOM+a)%30000))); port_open "$c"||{ printf '%s\n' "$c"; return 0; }; done; return 1; }
PORT=$(choose_port); DPORT=$(choose_port)
[[ -n $PORT && -n $DPORT && $PORT != "$DPORT" ]] || fail 'ports'
SEC=synthetic-master-secret; ASEC=synthetic-alpha-secret
STORE=$TEST_ROOT/store; LOG=$TEST_ROOT/log; install -d -m 0700 "$STORE" "$LOG"

tmux new-session -d -s pztest-beta -x 110 -y 30 'exec /bin/sh' || fail 'no pztest-beta'
sleep 0.3

# Hub: trust the whole fleet. alpha is an ordinary team (its own bound secret,
# no session of its own); beta lives on the push daemon.
cat >"$TEST_ROOT/hub.conf" <<EOF
[server]
listen = 127.0.0.1
port = $PORT
secret = $SEC
master_console_only = on
attach_local = on
attach_trust = all
[registry]
authority = sqlite
[store]
dir = $STORE
[log]
path = $LOG/pizarra.log
[team:1]
name = alpha
speciality = an ordinary team, not the console
secret = $ASEC
tmux_session = -
[team:2]
name = beta
speciality = push target
host = 127.0.0.1:$DPORT
tmux_session = pztest-beta
EOF
chmod 0600 "$TEST_ROOT/hub.conf"

# alpha's OWN credential (bound; From=alpha, proven). Not console.
cat >"$TEST_ROOT/alpha.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $ASEC
self = alpha
EOF
chmod 0600 "$TEST_ROOT/alpha.conf"

# Push daemon: ONE [daemon] attach = on opts in every session; beta itself has
# no per-session attach key, so this proves the host-wide default.
cat >"$TEST_ROOT/d.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $SEC
self = console
[daemon]
listen = 127.0.0.1
port = $DPORT
secret = $SEC
state = $TEST_ROOT/d.state
attach = on
[session:beta]
tmux_session = pztest-beta
EOF
chmod 0600 "$TEST_ROOT/d.conf"

tmux new-session -d -s pztest-host -x 100 -y 30 \
  "exec '$HUB_BIN' --config '$TEST_ROOT/hub.conf' >'$TEST_ROOT/hub.out' 2>&1" || fail 'no hub'
wait_cmd 10 "$TIZA_BIN" --config "$TEST_ROOT/alpha.conf" --health --wait 1 || fail 'hub not healthy'
ok 'hub up with attach_trust = all'

"$TIZA_BIN" daemon --config "$TEST_ROOT/d.conf" >"$TEST_ROOT/d.out" 2>&1 &
DPID=$!
for i in {1..100}; do port_open "$DPORT" && break; sleep 0.1; done
port_open "$DPORT" || fail 'daemon not listening'
ok 'push daemon up with [daemon] attach = on'

# alpha (NOT console) attaches beta with --write: trusted, so write is granted.
rm -f "$TEST_ROOT/w.err"
tmux new-session -d -s pztest-w -x 80 -y 24 \
  "'$TIZA_BIN' --config '$TEST_ROOT/alpha.conf' attach beta --write 2>'$TEST_ROOT/w.err'; echo VX=\$? >>'$TEST_ROOT/w.err'; sleep 3" \
  || fail 'no viewer'
wait_file "$TEST_ROOT/w.err" 'beta (write) 110x30' 12 ||
  fail "alpha was not granted write on beta: $(cat "$TEST_ROOT/w.err" 2>/dev/null)"
ok 'a non-console team is granted WRITE by attach_trust = all'

tmux send-keys -t pztest-w 'echo TRUSTOK' Enter
wait_cmd 6 bash -c "tmux capture-pane -p -t pztest-beta -S -50 | grep -q '^TRUSTOK'" ||
  fail 'trusted write did not reach the pane'
ok 'trusted write reaches the pane (beta had no per-session attach: [daemon] attach on)'

wait_file "$LOG/pizarra.log" 'attach opened: alpha -> beta (write, push' 5 ||
  fail 'hub did not log alpha -> beta (write)'
ok 'hub logs the attach under the real identity: alpha -> beta (write)'

tmux send-keys -t pztest-w C-] q
wait_file "$TEST_ROOT/w.err" 'attach closed:' 5 || fail 'did not close'
tmux has-session -t pztest-beta 2>/dev/null || fail 'target destroyed'
ok 'detached cleanly; target session survived'

printf 'all tiza attach trust-model tests passed\n'
