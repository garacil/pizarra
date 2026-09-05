#!/usr/bin/env bash
# Prove that trusted ancestor symbolic links are resolved rather than refused,
# and that everything the rule protects is still enforced on the RESOLVED path.
#
# This exists because "no symbolic link in any path component" cannot be
# satisfied on macOS: /etc and /var are themselves links into /private, so the
# literal rule made every canonical path illegal and an endpoint could only run
# with a hand-written --config.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/pizarra-trusted-path.XXXXXXXX)

cleanup() {
  case ${TEST_ROOT:-} in
    /tmp/pizarra-trusted-path.*)
      [[ ! -d $TEST_ROOT ]] || chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rm -rf -- "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

[[ -x $REPO_ROOT/tiza ]] || fail 'release tiza binary is missing; run make test first'

# An unroutable port: a configuration that LOADS must fail at the transport,
# never at the credential check. That difference is the whole assertion.
mkdir -p "$TEST_ROOT/private/pizarra"
CONF=$TEST_ROOT/private/pizarra/tiza.conf
printf '[pizarra]\nhost = 127.0.0.1\nport = 59999\nself = probe\nsecret = synthetic-test-only\n' >"$CONF"
chmod 0600 "$CONF"
ln -s private "$TEST_ROOT/etc"          # the macOS /etc -> /private/etc shape

run_health() { "$REPO_ROOT/tiza" --config "$1" --health 2>&1 || true; }

out=$(run_health "$TEST_ROOT/etc/pizarra/tiza.conf")
case $out in
  *'symbolic link'*|*'unsafe credential configuration'*)
    fail "a trusted ancestor link was refused: $out" ;;
  *'transport failed'*|*'Connect to'*) ok 'a credential behind a trusted ancestor link is accepted' ;;
  *) fail "unexpected health output: $out" ;;
esac

ln -s private/pizarra/tiza.conf "$TEST_ROOT/linkconf"
out=$(run_health "$TEST_ROOT/linkconf")
[[ $out == *'symbolic link'* ]] ||
  fail "a credential that is itself a symbolic link must be refused: $out"
ok 'a credential that is itself a symbolic link is refused'

if [[ $(id -u) -eq 0 ]] && id nobody >/dev/null 2>&1; then
  mkdir -p "$TEST_ROOT/untrusted/pizarra"
  cp "$CONF" "$TEST_ROOT/untrusted/pizarra/tiza.conf"
  chmod 0600 "$TEST_ROOT/untrusted/pizarra/tiza.conf"
  ln -s untrusted "$TEST_ROOT/badlink"
  chown -h nobody "$TEST_ROOT/badlink"
  out=$(run_health "$TEST_ROOT/badlink/pizarra/tiza.conf")
  [[ $out == *'neither root nor the runtime uid'* ]] ||
    fail "an ancestor link owned by another user must be refused: $out"
  ok 'an ancestor link owned by another user is refused'
else
  printf 'skip: untrusted-link-owner case needs root and a nobody account\n'
fi

chmod 0777 "$TEST_ROOT/private/pizarra"
out=$(run_health "$TEST_ROOT/etc/pizarra/tiza.conf")
[[ $out == *'writable by group/other'* ]] ||
  fail "a group/other-writable resolved ancestor must still be refused: $out"
[[ $out == *"$TEST_ROOT/private/pizarra"* ]] ||
  fail "the refusal should name the resolved path, not the link: $out"
ok 'a group/other-writable ancestor is still refused, named by its resolved path'
chmod 0755 "$TEST_ROOT/private/pizarra"

printf 'all trusted-path resolution tests passed\n'
