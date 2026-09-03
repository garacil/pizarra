#!/usr/bin/env bash
# Prove create-if-missing semantics without contacting a real tmux server.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/pizarra-session-preservation.XXXXXXXX)
FAKE_BIN=$SCRIPT_DIR/fixtures/fake-tmux-bin

cleanup() {
  case ${TEST_ROOT:-} in
    /tmp/pizarra-session-preservation.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

[[ -x $REPO_ROOT/pizarra ]] || fail 'release pizarra binary is missing; run make test first'
[[ -x $FAKE_BIN/tmux ]] || fail 'hermetic fake tmux fixture is not executable'

CONFIG=$TEST_ROOT/pizarra.conf
STATE=$TEST_ROOT/session.exists
CALLS=$TEST_ROOT/tmux.calls
OUTPUT=$TEST_ROOT/launcher.out
printf '%s\n' '[server]' 'secret = synthetic-test-only' >"$CONFIG"
chmod 0600 "$CONFIG"

run_launcher() {
  PATH="$FAKE_BIN:$PATH" \
    PIZARRA_FAKE_TMUX_STATE="$STATE" \
    PIZARRA_FAKE_TMUX_LOG="$CALLS" \
    "$REPO_ROOT/pizarra" --config "$CONFIG" --host-session pizarra-test
}

run_launcher >"$OUTPUT" 2>&1 || fail 'missing host session was not created'
[[ -e $STATE ]] || fail 'fake tmux did not record the created session'
[[ $(grep -c '^new-session ' "$CALLS") == 1 ]] ||
  fail 'first launch did not issue exactly one create operation'
grep -q '^new-session -d -s pizarra-test ' "$CALLS" ||
  fail 'create operation targeted the wrong session'
if grep -Eq '(^| )kill-(session|server|window|pane)( |$)' "$CALLS"; then
  fail 'launcher issued a destructive tmux operation'
fi
grep -q 'host session pizarra-test created with the hub inside' "$OUTPUT" ||
  fail 'the create path did not report that it created the session'
ok 'a missing hub session is created once by Pizarra itself'

run_launcher >>"$OUTPUT" 2>&1 || fail 'existing host session was not accepted'
[[ $(grep -c '^new-session ' "$CALLS") == 1 ]] ||
  fail 'existing session received a second launch command'
[[ $(grep -c '^has-session ' "$CALLS") == 3 ]] ||
  fail 'unexpected probe sequence around create/existing checks'
grep -q 'host session pizarra-test already exists; existing sessions are always preserved' "$OUTPUT" ||
  fail 'the existing-session path did not report that it preserved the session'
[[ $(grep -c 'created with the hub inside' "$OUTPUT") == 1 ]] ||
  fail 'a session that was already there was reported as created'
ok 'an existing session always wins and is never relaunched'

printf 'all session-preservation tests passed\n'
