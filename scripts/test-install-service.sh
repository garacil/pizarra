#!/usr/bin/env bash
# Disposable regression for the transactional installer and configured paths.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-install-test.XXXXXXXX")
DEST_ROOT=$TEST_ROOT/root
OUT=$TEST_ROOT/install.out

cleanup() {
  case ${TEST_ROOT:-} in
    "${TMPDIR:-/tmp}"/pizarra-install-test.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

for tool in awk cmp find grep install make mktemp rmdir sha256sum stat strings; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[[ -f $REPO_ROOT/config.mk ]] || fail 'config.mk is missing; run ./configure'
[[ -f $REPO_ROOT/build/release/verified.manifest ]] ||
  fail 'verified manifest is missing; run make test'

BINDIR=$(awk '$1 == "BINDIR" { print $3 }' "$REPO_ROOT/config.mk")
DATADIR=$(awk '$1 == "DATADIR" { print $3 }' "$REPO_ROOT/config.mk")
UNITDIR=/etc/systemd/system
[[ $BINDIR == /* && $DATADIR == /* ]] || fail 'configured install paths are not absolute'
install -d -m 0700 "$DEST_ROOT"

make -C "$REPO_ROOT" install DESTDIR="$DEST_ROOT" UNITDIR="$UNITDIR" >"$OUT"
MANIFEST=$DEST_ROOT/var/lib/pizarra-installer/current.manifest
[[ -f $MANIFEST ]] || fail 'staged install did not publish its manifest'
[[ -x $DEST_ROOT$BINDIR/pizarra ]] || fail 'staged hub is missing'
[[ -f $DEST_ROOT$UNITDIR/pizarra.service ]] || fail 'rendered hub unit is missing'
[[ -f $DEST_ROOT$DATADIR/examples/pzweb.conf.example ]] ||
  fail 'rendered web example is missing'

grep -Fq "static = $DATADIR/web/apps" \
  "$DEST_ROOT$DATADIR/examples/pzweb.conf.example" ||
  fail 'web example did not receive configured DATADIR'
grep -Fq ";update_path = $BINDIR/tiza" \
  "$DEST_ROOT$DATADIR/examples/tiza.conf.example" ||
  fail 'tiza example did not receive configured BINDIR'
grep -Fq "ExecStart=$BINDIR/pizarra" \
  "$DEST_ROOT$UNITDIR/pizarra.service" ||
  fail 'hub unit did not receive configured BINDIR'
# grep without -q, output discarded: under `set -o pipefail`, `grep -q` exits on
# the first match and closes the pipe, so `strings` on a large binary can die
# with SIGPIPE and the pipeline reports failure even though the match was found.
# Draining all of `strings` makes the check deterministic.
strings "$REPO_ROOT/pzweb" | grep -F "$DATADIR/web/apps" >/dev/null ||
  fail 'pzweb binary does not contain its configured asset default'
strings "$REPO_ROOT/tiza" | grep -F "$BINDIR/tiza" >/dev/null ||
  fail 'tiza binary does not contain its configured update default'
ok 'configured paths reach binaries, examples, units, and staged payload'

set +e
BINDIR="$BINDIR-mismatch" DATADIR="$DATADIR" UNITDIR="$UNITDIR" \
  DESTDIR="$DEST_ROOT" "$REPO_ROOT/scripts/install-service.sh" install \
  >"$TEST_ROOT/mismatch.out" 2>&1
MISMATCH_RC=$?
set -e
((MISMATCH_RC != 0)) || fail 'installer accepted a BINDIR different from the verified build'
grep -Fq 'verified binaries were built for BINDIR=' "$TEST_ROOT/mismatch.out" ||
  fail 'mismatched BINDIR did not produce the expected diagnostic'
ok 'installer rejects paths different from the verified build'

cp "$MANIFEST" "$TEST_ROOT/manifest-before"
make -C "$REPO_ROOT" install DESTDIR="$DEST_ROOT" UNITDIR="$UNITDIR" >"$OUT"
cmp -s "$TEST_ROOT/manifest-before" "$MANIFEST" ||
  fail 'idempotent staged install changed the payload manifest'
ok 'staged reinstall is idempotent'

cp "$MANIFEST" "$TEST_ROOT/manifest-pre-failure"
set +e
PIZARRA_INSTALL_FAIL_STEP=after-payload \
  make -C "$REPO_ROOT" install DESTDIR="$DEST_ROOT" UNITDIR="$UNITDIR" \
  >"$TEST_ROOT/failure.out" 2>&1
FAIL_RC=$?
set -e
((FAIL_RC != 0)) || fail 'injected installer failure unexpectedly succeeded'
cmp -s "$TEST_ROOT/manifest-pre-failure" "$MANIFEST" ||
  fail 'rollback did not restore the preceding manifest'
while IFS=$'\t' read -r kind sha mode uid gid logical; do
  [[ $kind == file ]] || continue
  target=$DEST_ROOT$logical
  [[ -f $target && ! -L $target ]] || fail "rollback lost $logical"
  [[ $(sha256sum "$target" | awk '{print $1}') == "$sha" ]] ||
    fail "rollback changed bytes for $logical"
  [[ $(stat -Lc '%a:%u:%g' "$target") == "$mode:$uid:$gid" ]] ||
    fail "rollback changed metadata for $logical"
done <"$MANIFEST"
ok 'injected post-payload failure restores exact bytes and metadata'

make -C "$REPO_ROOT" uninstall DESTDIR="$DEST_ROOT" UNITDIR="$UNITDIR" >"$OUT"
[[ ! -e $DEST_ROOT$BINDIR/pizarra ]] || fail 'uninstall retained the hub binary'
[[ ! -e $DEST_ROOT$UNITDIR/pizarra.service ]] || fail 'uninstall retained the hub unit'
find "$DEST_ROOT/var/lib/pizarra-installer" -maxdepth 1 \
  -name 'uninstalled-*.manifest' -type f -print -quit | grep -q . ||
  fail 'uninstall did not retain its audit manifest'
ok 'manifest uninstall removes payload and preserves audit evidence'

install -D -m 0755 /bin/true "$DEST_ROOT$BINDIR/pizarra"
make -C "$REPO_ROOT" adopt DESTDIR="$DEST_ROOT" UNITDIR="$UNITDIR" >"$OUT"
[[ -f $DEST_ROOT/var/lib/pizarra-installer/current.manifest ]] ||
  fail 'staged adoption did not create the first transactional manifest'
cmp -s "$REPO_ROOT/pizarra" "$DEST_ROOT$BINDIR/pizarra" ||
  fail 'staged adoption did not replace the reviewed legacy payload'
make -C "$REPO_ROOT" uninstall DESTDIR="$DEST_ROOT" UNITDIR="$UNITDIR" >"$OUT"
ok 'explicit adoption takes over a pre-existing payload transactionally'

printf 'all transactional installer tests passed\n'
