#!/usr/bin/env bash
# Compile and exercise the real Pascal first-run bootstrap below a temp root.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-bootstrap-test.XXXXXXXX")

cleanup() {
  case ${TEST_ROOT:-} in
    "${TMPDIR:-/tmp}"/pizarra-bootstrap-test.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

for tool in awk cat find fpc install mktemp rmdir; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

install -d -m 700 "$TEST_ROOT/root" "$TEST_ROOT/units" "$TEST_ROOT/bin"
if ! fpc -Sew -Sc -Fu"$REPO_ROOT/src" -FU"$TEST_ROOT/units" -FE"$TEST_ROOT/bin" \
  -obootstrap-layout-test "$SCRIPT_DIR/bootstrap-layout-test.pas" \
  >"$TEST_ROOT/fpc.out" 2>&1; then
  cat "$TEST_ROOT/fpc.out" >&2
  fail 'Pascal bootstrap regression program did not compile warning-free'
fi
"$TEST_ROOT/bin/bootstrap-layout-test" "$TEST_ROOT/root" \
  /var/lib/pizarra/releases

unit_state_mode() {
  local unit=$1 key=$2
  awk -F= -v wanted="$key" '
    /^[[:space:]]*\[Service\][[:space:]]*$/ { service=1; next }
    /^[[:space:]]*\[/ { service=0 }
    service && $1==wanted { print $2 }
  ' "$unit"
}

for unit in "$REPO_ROOT/systemd/pizarra.service" "$REPO_ROOT/systemd/tiza.service"; do
  [[ $(unit_state_mode "$unit" StateDirectory) == pizarra ]] ||
    fail "${unit##*/} does not declare StateDirectory=pizarra"
  [[ $(unit_state_mode "$unit" StateDirectoryMode) == 0700 ]] ||
    fail "${unit##*/} does not protect shared state as mode 0700"
done
[[ -z $(unit_state_mode "$REPO_ROOT/systemd/pzweb.service" StateDirectory) ]] ||
  fail 'pzweb unexpectedly declares mutable pizarra state ownership'
ok 'systemd state-directory ownership contract is coherent'

printf 'all bootstrap-layout tests passed\n'
