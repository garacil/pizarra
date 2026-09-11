#!/usr/bin/env bash
# The daemon must create the directory its delivery receipt lives in.
#
# It never did: it relied entirely on the shipped systemd unit's
# StateDirectory. A hand-written unit, a launch agent, or a `state` path the
# operator points elsewhere all leave nobody responsible for that directory,
# and the daemon then logged "cannot save the delivery receipt" every few
# seconds while running with NO persisted position - the case where a restart
# can inject an already-delivered message a second time. Found in production on
# a host whose unit carries no StateDirectory.
#
# No tmux server is involved: the daemon is pointed at a session name that is
# never created, and nothing here touches a real one.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-state.XXXXXXXX)
DPID=''

fail() { printf 'not ok: %s\n' "$*" >&2; [[ -f $TEST_ROOT/out ]] && tail -15 "$TEST_ROOT/out" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
cleanup() {
  [[ -n ${DPID:-} ]] && kill "$DPID" 2>/dev/null || true
  case ${TEST_ROOT:-} in /tmp/pizarra-state.*) rm -rf "$TEST_ROOT" 2>/dev/null || true ;; esac
}
trap cleanup EXIT
[[ -x $TIZA_BIN ]] || fail 'debug binary missing; run make debug'

STATE=$TEST_ROOT/deep/nested/missing/tiza.state
cat >"$TEST_ROOT/d.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = 29999
secret = synthetic
self = probe
[daemon]
listen = 127.0.0.1
port = 29998
secret = synthetic
state = $STATE
[session:probe]
tmux_session = pztest-never-created
EOF
chmod 0600 "$TEST_ROOT/d.conf"

[[ ! -d $(dirname "$STATE") ]] || fail 'premise broken: the directory already exists'

"$TIZA_BIN" daemon --config "$TEST_ROOT/d.conf" >"$TEST_ROOT/out" 2>&1 &
DPID=$!
for _ in {1..60}; do [[ -d $(dirname "$STATE") ]] && break; sleep 0.1; done

[[ -d $(dirname "$STATE") ]] || fail 'the daemon did not create the receipt directory'
ok 'a missing receipt directory is created at startup'

MODE=$(stat -c '%a' "$(dirname "$STATE")" 2>/dev/null || echo '?')
[[ $MODE == 700 ]] || fail "receipt directory is mode $MODE, expected 700"
ok 'it is created private to the daemon user, not world-readable'

sleep 2
[[ $(grep -c 'cannot save the delivery receipt' "$TEST_ROOT/out" || true) == 0 ]] \
  || fail 'the daemon still cannot save its receipt'
ok 'no receipt-save failure is reported'

printf '\nall receipt-directory checks passed\n'
