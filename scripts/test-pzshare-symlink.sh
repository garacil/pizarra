#!/usr/bin/env bash
# Proves that local/NFS sharing never follows a preplanted temporary symlink.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/pizarra-share-symlink.XXXXXXXX)

cleanup() {
  case ${TEST_ROOT:-} in
    /tmp/pizarra-share-symlink.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }

command -v fpc >/dev/null 2>&1 || fail 'fpc is required'
install -d -m 700 "$TEST_ROOT/units"
install -d -m 1777 "$TEST_ROOT/shared"
printf '%s\n' 'payload that must be shared' >"$TEST_ROOT/payload.txt"
printf '%s\n' 'protected bytes' >"$TEST_ROOT/protected.txt"

fpc -Sew -Fu"$REPO_ROOT/src" -FU"$TEST_ROOT/units" -FE"$TEST_ROOT" \
  -o"pzshare-symlink-test" "$SCRIPT_DIR/pzshare-symlink-test.pas" \
  >"$TEST_ROOT/compile.log" 2>&1 || {
    tail -80 "$TEST_ROOT/compile.log" >&2
    fail 'could not compile the real pzshare harness'
  }

FINAL_PATH=$("$TEST_ROOT/pzshare-symlink-test" \
  "$TEST_ROOT/payload.txt" "$TEST_ROOT/shared" "$TEST_ROOT/protected.txt") ||
  fail 'the real ShareCopy call failed'

[[ -f $FINAL_PATH && ! -L $FINAL_PATH ]] || fail 'published path is not a regular file'
cmp -s -- "$TEST_ROOT/payload.txt" "$FINAL_PATH" || fail 'published bytes differ'
[[ $(cat "$TEST_ROOT/protected.txt") == 'protected bytes' ]] ||
  fail 'preplanted symlink target was modified'
[[ $(stat -c '%a' -- "$FINAL_PATH") == 644 ]] ||
  fail 'published shared file is not mode 0644'
[[ -n $(find "$TEST_ROOT/shared" -maxdepth 1 -type l \
  -name '.pzshare-*-1-payload.txt.partial' -print -quit) ]] ||
  fail 'the adversarial symlink was not left untouched'
[[ -z $(find "$TEST_ROOT/shared" -maxdepth 1 -type f -name '*.partial' -print -quit) ]] ||
  fail 'a reserved regular partial file remained after publication'

printf '%s\n' 'ok: pzshare skipped a preplanted symlink and published only its reserved inode'
