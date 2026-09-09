#!/usr/bin/env bash
# Integration test for comma-separated destinations: `tiza a,b "text"`.
#
# Before 1.1.35 that resolved as ONE destination literally named "a,b", was
# accepted because a non-team destination is legitimate (it is how the console
# receives mail), stored against a phantom name and delivered to nobody, while
# the sender was told "sent". This proves the new behaviour AND that every
# existing spelling is unchanged - especially the non-team path, which carries
# the console.
#
# Every team here is inbox-only (tmux_session = -), so no tmux server is
# involved at any point and nothing on this machine can be touched.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-multi.XXXXXXXX)
HUB_PID=''

fail() {
  printf 'not ok: %s\n' "$*" >&2
  [[ -f $TEST_ROOT/hub.out ]] && { echo '--- hub ---' >&2; tail -25 "$TEST_ROOT/hub.out" >&2; }
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }
cleanup() {
  if [[ -n ${HUB_PID:-} ]] && kill -0 "$HUB_PID" 2>/dev/null; then
    kill "$HUB_PID" 2>/dev/null || true
    for _ in {1..100}; do kill -0 "$HUB_PID" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$HUB_PID" 2>/dev/null && kill -KILL "$HUB_PID" 2>/dev/null || true
  fi
  case ${TEST_ROOT:-} in
    /tmp/pizarra-multi.*) rm -rf "$TEST_ROOT" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'

port_open() { (: <>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
choose_port() {
  local a c
  for a in {1..300}; do c=$((20000 + ((BASHPID + RANDOM + a) % 30000))); port_open "$c" || { printf '%s\n' "$c"; return 0; }; done
  return 1
}
PORT=$(choose_port) || fail 'no free port'
SEC=synthetic-master-secret
STORE=$TEST_ROOT/store; LOG=$TEST_ROOT/log
install -d -m 0700 "$STORE" "$LOG"

cat >"$TEST_ROOT/hub.conf" <<EOF
[server]
listen = 127.0.0.1
port = $PORT
secret = $SEC
[registry]
authority = sqlite
[store]
dir = $STORE
[log]
path = $LOG/pizarra.log
[team:1]
name = alpha
speciality = inbox-only test member
secret = sec-alpha
tmux_session = -
[team:2]
name = beta
speciality = inbox-only test member
secret = sec-beta
tmux_session = -
[team:3]
name = gamma
speciality = inbox-only test member
secret = sec-gamma
tmux_session = -
[group:pair]
members = alpha, beta
EOF
chmod 0600 "$TEST_ROOT/hub.conf"

mkconf() { cat >"$TEST_ROOT/$1.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $2
self = $1
EOF
chmod 0600 "$TEST_ROOT/$1.conf"; }
mkconf console "$SEC"
mkconf alpha sec-alpha
mkconf beta  sec-beta
mkconf gamma sec-gamma

"$HUB_BIN" --config "$TEST_ROOT/hub.conf" >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
for _ in {1..100}; do port_open "$PORT" && break; sleep 0.1; done
port_open "$PORT" || fail 'hub did not listen'
ok 'isolated hub is up'

# A refusal makes tiza exit 1, which is correct and is one of the things under
# test, so the status must not abort the run (pipefail + set -e would).
send() { "$TIZA_BIN" --config "$TEST_ROOT/console.conf" "$1" "$2" 2>&1 | head -1 || true; }
# count how many times a marker appears in a team's inbox
got() { "$TIZA_BIN" --config "$TEST_ROOT/$1.conf" inbox --all 2>/dev/null | grep -c -- "$2" || true; }
send_as() { "$TIZA_BIN" --config "$TEST_ROOT/$1.conf" "$2" "$3" >/dev/null 2>&1 || true; }

# ---------- the new behaviour ----------
OUT=$(send "alpha,beta" "MARK_AB")
[[ $OUT == *"broadcast"* || $OUT == *"sent"* ]] || fail "unexpected reply for a,b: $OUT"
[[ $(got alpha MARK_AB) == 1 ]] || fail 'alpha did not receive the comma send'
[[ $(got beta  MARK_AB) == 1 ]] || fail 'beta did not receive the comma send'
[[ $(got gamma MARK_AB) == 0 ]] || fail 'gamma received a message it was not sent'
ok 'a,b delivers to both named teams and to nobody else'

# ---------- a typo must refuse the WHOLE send ----------
OUT=$(send "alpha,nosuchteam" "MARK_BAD")
[[ $OUT == *"unknown destination"* ]] || fail "a typo was not refused: $OUT"
[[ $(got alpha MARK_BAD) == 0 ]] || fail 'a refused list still delivered to alpha'
ok 'an unknown element refuses the whole send and delivers nothing'

# ---------- duplicates collapse ----------
send "alpha,alpha" "MARK_DUP" >/dev/null
[[ $(got alpha MARK_DUP) == 1 ]] || fail 'a duplicated destination delivered twice'
ok 'a repeated destination delivers exactly once'

# ---------- groups and teams mix ----------
send "pair,gamma" "MARK_MIX" >/dev/null
[[ $(got alpha MARK_MIX) == 1 && $(got beta MARK_MIX) == 1 && $(got gamma MARK_MIX) == 1 ]] \
  || fail 'a group + team list did not reach everyone'
ok 'a list mixing a group and a team expands correctly'

# ---------- @group spelling inside a list ----------
send "@pair,gamma" "MARK_AT" >/dev/null
[[ $(got alpha MARK_AT) == 1 && $(got gamma MARK_AT) == 1 ]] || fail '@group in a list failed'
ok '@group works inside a list'

# ---------- the sender is skipped, as in a group fan-out ----------
"$TIZA_BIN" --config "$TEST_ROOT/alpha.conf" "alpha,beta" "MARK_SELF" >/dev/null 2>&1 || true
[[ $(got alpha MARK_SELF) == 0 ]] || fail 'the sender received its own list message'
[[ $(got beta  MARK_SELF) == 1 ]] || fail 'beta missed the message'
ok 'naming yourself in a list does not echo back'

# ---------- EVERY existing spelling is unchanged ----------
send alpha "MARK_ONE" >/dev/null
[[ $(got alpha MARK_ONE) == 1 && $(got beta MARK_ONE) == 0 ]] || fail 'single destination changed'
ok 'a single team destination is unchanged'

send "@pair" "MARK_GRP" >/dev/null
[[ $(got alpha MARK_GRP) == 1 && $(got gamma MARK_GRP) == 0 ]] || fail '@group changed'
ok '@group is unchanged'

send pair "MARK_BARE" >/dev/null
[[ $(got alpha MARK_BARE) == 1 && $(got gamma MARK_BARE) == 0 ]] || fail 'bare group changed'
ok 'a bare group name is unchanged'

send all "MARK_ALL" >/dev/null
[[ $(got alpha MARK_ALL) == 1 && $(got beta MARK_ALL) == 1 && $(got gamma MARK_ALL) == 1 ]] \
  || fail 'all changed'
ok 'all is unchanged'

# the non-team path is how the console receives mail: it MUST still work
"$TIZA_BIN" --config "$TEST_ROOT/alpha.conf" console "MARK_CONSOLE" >/dev/null 2>&1
"$TIZA_BIN" --config "$TEST_ROOT/console.conf" inbox --all 2>/dev/null | grep -q MARK_CONSOLE \
  || fail 'the non-team console destination broke'
ok 'the non-team console destination still works'

# a trailing comma is one name, so it keeps its old meaning exactly
OUT=$(send "alpha," "MARK_TRAIL")
[[ $OUT != *"unknown destination"* ]] || fail 'a trailing comma changed meaning'
ok 'a trailing comma resolves as before'

printf '\nall multi-destination send checks passed\n'
