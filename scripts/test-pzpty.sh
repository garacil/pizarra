#!/usr/bin/env bash
# Proves src/pzpty.pas on a real child: window size at creation, descriptor
# hygiene, environment isolation from a poisoned TMUX, byte round-trip, and
# zombie-free teardown. No tmux server is involved; it needs only /bin/sh,
# stty and fpc.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/pizarra-pzpty.XXXXXXXX)

cleanup() {
  case ${TEST_ROOT:-} in
    /tmp/pizarra-pzpty.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }

command -v fpc >/dev/null 2>&1 || fail 'fpc is required'
command -v stty >/dev/null 2>&1 || fail 'stty is required'
[[ -x /bin/sh ]] || fail '/bin/sh is required'
install -d -m 700 "$TEST_ROOT/units"

# -Sew: a warning is a build failure, exactly as the release build treats it.
fpc -Sew -Fu"$REPO_ROOT/src" -FU"$TEST_ROOT/units" -FE"$TEST_ROOT" \
  -o"pzpty-test" "$SCRIPT_DIR/pzpty-test.pas" \
  >"$TEST_ROOT/compile.log" 2>&1 || {
    tail -80 "$TEST_ROOT/compile.log" >&2
    fail 'could not compile the pzpty harness'
  }

# The parent deliberately carries TMUX: the child must NOT see it.
if ! TMUX=poisoned-by-test,0,0 "$TEST_ROOT/pzpty-test" >"$TEST_ROOT/run.log" 2>&1; then
  cat "$TEST_ROOT/run.log" >&2
  fail 'pzpty checks failed'
fi
cat "$TEST_ROOT/run.log"

# Nothing of ours may survive the run.
if pgrep -f 'stty size; echo PTY_READY; cat' >/dev/null 2>&1; then
  fail 'a test child survived the harness'
fi
printf '%s\n' 'ok: pzpty harness left no child behind'
