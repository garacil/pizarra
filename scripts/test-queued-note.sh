#!/usr/bin/env bash
# What the sender is told when a message is queued must be true.
#
# Delivery to a DIAL team is always reported as queued, connected or not: the
# ack that marks it delivered arrives later on the reverse channel. The console
# rendered that single flag as "host down, will be delivered", so on every
# message to every dial host an operator was told the host was unreachable while
# the message was arriving instantly. Reported from the console.
#
# The hub now distinguishes the two cases in `note`. This proves both readings
# against a real dial daemon, and that the false claim is gone from the console.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-qnote.XXXXXXXX)
HUB_PID=''; DIALD_PID=''

fail() { printf 'not ok: %s\n' "$*" >&2; for f in hub.out diald.out; do [[ -f $TEST_ROOT/$f ]] && { echo "--- $f ---" >&2; tail -15 "$TEST_ROOT/$f" >&2; }; done; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
stop() { local v=$1 p=${!1:-}; [[ -n $p ]] && kill "$p" 2>/dev/null || true; printf -v "$v" '%s' ''; }
cleanup() { stop HUB_PID; stop DIALD_PID; case ${TEST_ROOT:-} in /tmp/pizarra-qnote.*) rm -rf "$TEST_ROOT" 2>/dev/null || true ;; esac; }
trap cleanup EXIT
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'

port_open() { (: <>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
choose_port() { local a c; for a in {1..300}; do c=$((20000 + ((BASHPID + RANDOM + a) % 30000))); port_open "$c" || { printf '%s\n' "$c"; return 0; }; done; return 1; }
PORT=$(choose_port); EPORT=$(choose_port)
SEC=synthetic-master; DSEC=synthetic-dial
install -d -m 0700 "$TEST_ROOT/store"

printf '%s\n' '[server]' 'listen = 127.0.0.1' "port = $PORT" "secret = $SEC" \
  '[registry]' 'authority = sqlite' '[store]' "dir = $TEST_ROOT/store" \
  '[log]' "path = $TEST_ROOT/pizarra.log" \
  '[team:1]' 'name = dialteam' 'speciality = synthetic dial member' \
  "secret = $DSEC" 'dial = on' 'tmux_session = -' \
  '[team:2]' 'name = awayteam' 'speciality = a dial team that never connects' \
  'secret = synthetic-away' 'dial = on' 'tmux_session = -' \
  > "$TEST_ROOT/hub.conf"
printf '%s\n' '[pizarra]' 'host = 127.0.0.1' "port = $PORT" "secret = $SEC" 'self = console' > "$TEST_ROOT/c.conf"
printf '%s\n' '[pizarra]' 'host = 127.0.0.1' "port = $PORT" "secret = $DSEC" 'self = dialteam' \
  '[daemon]' 'listen = 127.0.0.1' "port = $EPORT" 'dial = on' 'keepalive = 5' \
  "state = $TEST_ROOT/diald.state" \
  '[session:dialteam]' 'tmux_session = pztest-qnote-never' > "$TEST_ROOT/d.conf"
chmod 0600 "$TEST_ROOT"/*.conf

"$HUB_BIN" --config "$TEST_ROOT/hub.conf" >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
for _ in {1..100}; do port_open "$PORT" && break; sleep 0.1; done
port_open "$PORT" || fail 'hub did not listen'

"$TIZA_BIN" daemon --config "$TEST_ROOT/d.conf" >"$TEST_ROOT/diald.out" 2>&1 &
DIALD_PID=$!
for _ in {1..150}; do grep -q 'established' "$TEST_ROOT/diald.out" 2>/dev/null && break; sleep 0.1; done
grep -q 'established' "$TEST_ROOT/diald.out" || fail 'the dial daemon never connected'
sleep 1
ok 'a dial daemon is connected, and another dial team is not'

OUT=$("$TIZA_BIN" --config "$TEST_ROOT/c.conf" dialteam "hello" 2>&1 | head -1 || true)
[[ $OUT == *"dialed in"* ]] || fail "a connected dial host was not reported as such: $OUT"
[[ $OUT != *"not dialed in"* ]] || fail "a connected dial host was reported as away: $OUT"
ok 'a CONNECTED dial host is reported as handed over, not as a failure'

OUT=$("$TIZA_BIN" --config "$TEST_ROOT/c.conf" awayteam "hello" 2>&1 | head -1 || true)
[[ $OUT == *"not dialed in"* ]] || fail "an absent dial host was not reported as absent: $OUT"
ok 'an ABSENT dial host is reported as absent, and says it will deliver on return'

# The console must never assert the host is down from the queued flag alone.
# Match the emitted STRING, not the word: the comment explaining why this claim
# was wrong necessarily contains the phrase, and a naive grep fails on its own
# documentation.
grep -q "host down, will be delivered" "$REPO_ROOT/src/pzchat.pas" \
  && fail 'the console still emits the "host down" claim'
ok 'the console no longer claims the host is down'

grep -q "Obj.Get('note'" "$REPO_ROOT/src/pzchat.pas" \
  || fail 'the console still ignores the reason the hub sends'
ok 'the console renders the reason the hub sends'

printf '\nall queued-reason checks passed\n'
