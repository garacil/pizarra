#!/usr/bin/env bash
# Isolated regression test for release-path migration and preservation.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MIGRATOR=$SCRIPT_DIR/migrate-to-system-layout.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-release-layout-test.XXXXXXXX")

cleanup() {
  case ${TEST_ROOT:-} in
    "${TMPDIR:-/tmp}"/pizarra-release-layout-test.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

ini_value() {
  local file=$1 wanted_section=$2 wanted_key=$3
  awk -v wanted_section="$wanted_section" -v wanted_key="$wanted_key" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      section=tolower(trim(section))
      next
    }
    section==tolower(wanted_section) {
      p=index($0, "=")
      if (!p) next
      key=tolower(trim(substr($0, 1, p-1)))
      if (key==tolower(wanted_key)) { print trim(substr($0, p+1)); exit }
    }
  ' "$file"
}

release_manifest() {
  local dir=$1 output=$2
  (
    cd -- "$dir"
    find . -printf '%y\0%P\0' | LC_ALL=C sort -z | sha256sum
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) >"$output"
}

run_migrate() {
  env DEST_ETC="$DEST_ETC_ROOT" DEST_VAR="$DEST_VAR_ROOT" \
    SOURCE_ETC="$SOURCE_ETC_ROOT" WEB_ASSETS_DIR="$ASSETS" \
    "$MIGRATOR" "$@"
}

SOURCE_ROOT=$TEST_ROOT/source
SOURCE_ETC_ROOT=$SOURCE_ROOT/etc
SOURCE_STATE=$SOURCE_ROOT/store
SOURCE_RELEASES=$SOURCE_ROOT/published-artifacts
SHARED_ROOT=$TEST_ROOT/external-nfs-share
DEST_ETC_ROOT=$TEST_ROOT/destination/etc
DEST_VAR_ROOT=$TEST_ROOT/destination/var
DEST_STATE=$DEST_VAR_ROOT/lib/pizarra
DEST_RELEASES=$DEST_STATE/releases
ASSETS=$TEST_ROOT/share/pizarra/web/apps
PIZARRA_SOURCE=$SOURCE_ROOT/pizarra.conf
PZWEB_SOURCE=$SOURCE_ROOT/pzweb.conf

install -d -m 700 "$SOURCE_ETC_ROOT" "$SOURCE_STATE" "$SOURCE_RELEASES/empty-dir" \
  "$SHARED_ROOT/empty-team-dir" "$ASSETS"
printf '%s\n' '1.1.22' >"$SOURCE_RELEASES/VERSION"
printf '%s\n' 'binary artifact bytes' >"$SOURCE_RELEASES/tiza-linux-x86_64"
printf '%s\n' 'source artifact bytes' >"$SOURCE_RELEASES/src.tar.gz"
printf '%s\n' 'legacy log entry' >"$SOURCE_ROOT/pizarra.log"
printf '%s\n' 'external NFS content must remain in place' >"$SHARED_ROOT/sentinel.txt"
sqlite3 "$SOURCE_STATE/org.sqlite" \
  "CREATE TABLE meta(k TEXT PRIMARY KEY,v TEXT NOT NULL); INSERT INTO meta VALUES('fixture','1');"

cat >"$PIZARRA_SOURCE" <<EOF
[server]
listen = 127.0.0.1
port = 7010
secret = fixture-secret
releases = $SOURCE_RELEASES

[registry]
authority = sqlite

[store]
dir = $SOURCE_STATE

[log]
path = $SOURCE_ROOT/pizarra.log

[shared]
dir = $SHARED_ROOT
EOF

cat >"$PZWEB_SOURCE" <<EOF
[pizarra]
host = 127.0.0.1
port = 7010
secret = fixture-web-secret
self = pzweb

[web]
static = $ASSETS
shared = $SHARED_ROOT
EOF

release_manifest "$SOURCE_RELEASES" "$TEST_ROOT/releases-before"
release_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-before"
run_migrate --source-config "$PIZARRA_SOURCE" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_SOURCE" --dry-run >"$TEST_ROOT/dry-run.out"
[[ ! -e $DEST_STATE && ! -e $DEST_ETC_ROOT/pizarra ]] ||
  fail 'migration dry run changed the destination'
grep -Fq "would use release artifacts at $DEST_RELEASES" "$TEST_ROOT/dry-run.out" ||
  fail 'migration dry run did not report the canonical release path'
ok 'release migration dry run is non-mutating'

PZWEB_MISMATCH=$TEST_ROOT/pzweb-mismatch.conf
cp -p -- "$PZWEB_SOURCE" "$PZWEB_MISMATCH"
sed -i "s|^shared = $SHARED_ROOT$|shared = $TEST_ROOT/other-share|" \
  "$PZWEB_MISMATCH"
if run_migrate --source-config "$PIZARRA_SOURCE" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_MISMATCH" --dry-run >"$TEST_ROOT/shared-mismatch.out" 2>&1; then
  fail 'migration accepted mismatched hub/pzweb shared roots'
fi
grep -Fq 'shared must exactly match' "$TEST_ROOT/shared-mismatch.out" ||
  fail 'migration did not explain the hub/pzweb shared-root mismatch'
[[ ! -e $DEST_STATE && ! -e $DEST_ETC_ROOT/pizarra ]] ||
  fail 'shared-root mismatch changed the destination'
release_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-after-mismatch"
cmp -s -- "$TEST_ROOT/shared-before" "$TEST_ROOT/shared-after-mismatch" ||
  fail 'shared-root mismatch validation touched the external tree'
ok 'mismatched hub/pzweb shared roots abort without touching external data'

PZWEB_WITHOUT_SHARED=$TEST_ROOT/pzweb-without-shared.conf
cp -p -- "$PZWEB_SOURCE" "$PZWEB_WITHOUT_SHARED"
sed -i "s|^shared = $SHARED_ROOT$|shared = |" "$PZWEB_WITHOUT_SHARED"
if run_migrate --source-config "$PIZARRA_SOURCE" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_WITHOUT_SHARED" --dry-run \
  >"$TEST_ROOT/web-shared-empty.out" 2>&1; then
  fail 'migration accepted a hub shared root with empty pzweb shared'
fi
grep -Fq 'shared must exactly match' "$TEST_ROOT/web-shared-empty.out" ||
  fail 'migration did not reject empty pzweb shared against configured hub shared'

HUB_WITHOUT_SHARED=$TEST_ROOT/hub-without-shared.conf
cp -p -- "$PIZARRA_SOURCE" "$HUB_WITHOUT_SHARED"
sed -i "\|^\[shared\]$|,\|^dir = $SHARED_ROOT$|d" "$HUB_WITHOUT_SHARED"
if run_migrate --source-config "$HUB_WITHOUT_SHARED" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_SOURCE" --dry-run \
  >"$TEST_ROOT/hub-shared-empty.out" 2>&1; then
  fail 'migration accepted empty hub shared with configured pzweb shared'
fi
grep -Fq 'shared must exactly match' "$TEST_ROOT/hub-shared-empty.out" ||
  fail 'migration did not reject configured pzweb shared against empty hub shared'
[[ ! -e $DEST_STATE && ! -e $DEST_ETC_ROOT/pizarra ]] ||
  fail 'empty/non-empty shared mismatch changed the destination'
release_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-after-empty-mismatches"
cmp -s -- "$TEST_ROOT/shared-before" "$TEST_ROOT/shared-after-empty-mismatches" ||
  fail 'empty/non-empty shared mismatch validation touched the external tree'
ok 'empty/non-empty shared mismatches are rejected in both directions'

HUB_RELATIVE_SHARED=$TEST_ROOT/hub-relative-shared.conf
cp -p -- "$PIZARRA_SOURCE" "$HUB_RELATIVE_SHARED"
sed -i "s|^dir = $SHARED_ROOT$|dir = relative/nfs|" "$HUB_RELATIVE_SHARED"
if run_migrate --source-config "$HUB_RELATIVE_SHARED" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_SOURCE" --dry-run \
  >"$TEST_ROOT/hub-relative-shared.out" 2>&1; then
  fail 'migration accepted a relative hub shared root'
fi
grep -Fq 'configured [shared] dir must be absolute' \
  "$TEST_ROOT/hub-relative-shared.out" ||
  fail 'migration did not identify the relative hub shared root'

PZWEB_RELATIVE_SHARED=$TEST_ROOT/pzweb-relative-shared.conf
cp -p -- "$PZWEB_SOURCE" "$PZWEB_RELATIVE_SHARED"
sed -i "s|^shared = $SHARED_ROOT$|shared = relative/nfs|" \
  "$PZWEB_RELATIVE_SHARED"
if run_migrate --source-config "$PIZARRA_SOURCE" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_RELATIVE_SHARED" --dry-run \
  >"$TEST_ROOT/web-relative-shared.out" 2>&1; then
  fail 'migration accepted a relative pzweb shared root'
fi
grep -Fq 'configured pzweb [web] shared must be absolute' \
  "$TEST_ROOT/web-relative-shared.out" ||
  fail 'migration did not identify the relative pzweb shared root'

HUB_ROOT_SHARED=$TEST_ROOT/hub-root-shared.conf
cp -p -- "$PIZARRA_SOURCE" "$HUB_ROOT_SHARED"
sed -i "s|^dir = $SHARED_ROOT$|dir = ////|" "$HUB_ROOT_SHARED"
if run_migrate --source-config "$HUB_ROOT_SHARED" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_SOURCE" --dry-run \
  >"$TEST_ROOT/hub-root-shared.out" 2>&1; then
  fail 'migration accepted filesystem root as hub shared root'
fi
grep -Fq 'configured [shared] dir may not be the filesystem root' \
  "$TEST_ROOT/hub-root-shared.out" ||
  fail 'migration did not reject the normalized hub filesystem root'

PZWEB_ROOT_SHARED=$TEST_ROOT/pzweb-root-shared.conf
cp -p -- "$PZWEB_SOURCE" "$PZWEB_ROOT_SHARED"
sed -i "s|^shared = $SHARED_ROOT$|shared = ////|" "$PZWEB_ROOT_SHARED"
if run_migrate --source-config "$PIZARRA_SOURCE" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_ROOT_SHARED" --dry-run \
  >"$TEST_ROOT/web-root-shared.out" 2>&1; then
  fail 'migration accepted filesystem root as pzweb shared root'
fi
grep -Fq 'configured pzweb [web] shared may not be the filesystem root' \
  "$TEST_ROOT/web-root-shared.out" ||
  fail 'migration did not reject the normalized pzweb filesystem root'
release_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-after-path-rejections"
cmp -s -- "$TEST_ROOT/shared-before" "$TEST_ROOT/shared-after-path-rejections" ||
  fail 'shared path validation touched the external tree'
ok 'relative and filesystem-root shared paths are rejected without NFS access'

run_migrate --source-config "$PIZARRA_SOURCE" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_SOURCE" >"$TEST_ROOT/migrate.out"
[[ $(awk -F= '/^[[:space:]]*releases[[:space:]]*=/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' \
  "$DEST_ETC_ROOT/pizarra/pizarra.conf") == "$DEST_RELEASES" ]] ||
  fail 'migrated [server] releases is not canonical'
[[ $(ini_value "$DEST_ETC_ROOT/pizarra/pizarra.conf" shared dir) == "$SHARED_ROOT" ]] ||
  fail 'migrated hub [shared] dir was not preserved literally'
[[ $(ini_value "$DEST_ETC_ROOT/pizarra/pzweb.conf" web shared) == "$SHARED_ROOT" ]] ||
  fail 'migrated pzweb [web] shared was not preserved literally'
release_manifest "$SOURCE_RELEASES" "$TEST_ROOT/releases-source-after"
release_manifest "$DEST_RELEASES" "$TEST_ROOT/releases-destination"
cmp -s -- "$TEST_ROOT/releases-before" "$TEST_ROOT/releases-source-after" ||
  fail 'source release artifacts changed during migration'
cmp -s -- "$TEST_ROOT/releases-before" "$TEST_ROOT/releases-destination" ||
  fail 'canonical release artifacts differ from the source snapshot'
release_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-after-migration"
cmp -s -- "$TEST_ROOT/shared-before" "$TEST_ROOT/shared-after-migration" ||
  fail 'external shared tree changed during migration'
[[ ! -e $DEST_STATE/sentinel.txt && ! -e $DEST_STATE/empty-team-dir ]] ||
  fail 'external shared content was copied into canonical state'
[[ $(stat -Lc '%a' -- "$DEST_RELEASES") == 700 ]] ||
  fail 'canonical release directory is not private'
ok 'release artifacts and empty directories are preserved exactly'

run_migrate --source-config "$DEST_ETC_ROOT/pizarra/pizarra.conf" \
  --source-store "$DEST_STATE" --source-pzweb "$DEST_ETC_ROOT/pizarra/pzweb.conf" \
  >"$TEST_ROOT/canonical-rerun.out"
grep -Fq "config_source=$DEST_ETC_ROOT/pizarra/pizarra.conf" \
  "$DEST_VAR_ROOT/lib/pizarra-migration-backups/installed-state.record" ||
  fail 'canonical rerun did not pin canonical config lineage'
grep -Fq "state_source=$DEST_STATE" \
  "$DEST_VAR_ROOT/lib/pizarra-migration-backups/installed-state.record" ||
  fail 'canonical rerun did not pin canonical state lineage'
release_manifest "$DEST_RELEASES" "$TEST_ROOT/releases-after-rerun"
cmp -s -- "$TEST_ROOT/releases-before" "$TEST_ROOT/releases-after-rerun" ||
  fail 'canonical rerun changed release artifact bytes or names'
release_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-after-rerun"
cmp -s -- "$TEST_ROOT/shared-before" "$TEST_ROOT/shared-after-rerun" ||
  fail 'canonical rerun changed the external shared tree'
ok 'canonical in-place rerun retains release artifacts and records final lineage'

CONFLICT_ROOT=$TEST_ROOT/conflict
CONFLICT_STATE=$CONFLICT_ROOT/store
CONFLICT_RELEASES=$CONFLICT_ROOT/external-releases
CONFLICT_CONFIG=$CONFLICT_ROOT/pizarra.conf
CONFLICT_DEST_VAR=$CONFLICT_ROOT/destination/var
CONFLICT_DEST_ETC=$CONFLICT_ROOT/destination/etc
install -d -m 700 "$CONFLICT_STATE/releases" "$CONFLICT_RELEASES"
sqlite3 "$CONFLICT_STATE/org.sqlite" 'CREATE TABLE fixture(id INTEGER PRIMARY KEY);'
printf '%s\n' 'state artifact' >"$CONFLICT_STATE/releases/VERSION"
printf '%s\n' 'configured artifact' >"$CONFLICT_RELEASES/VERSION"
cat >"$CONFLICT_CONFIG" <<EOF
[server]
port = 7010
secret = conflict-secret
releases = $CONFLICT_RELEASES
[registry]
authority = sqlite
[store]
dir = $CONFLICT_STATE
EOF
if env DEST_ETC="$CONFLICT_DEST_ETC" DEST_VAR="$CONFLICT_DEST_VAR" \
  SOURCE_ETC="$CONFLICT_ROOT/etc" WEB_ASSETS_DIR="$ASSETS" \
  "$MIGRATOR" --source-config "$CONFLICT_CONFIG" --source-store "$CONFLICT_STATE" \
  --source-pzweb "$PZWEB_SOURCE" >"$TEST_ROOT/conflict.out" 2>&1; then
  fail 'migration accepted conflicting release authorities'
fi
grep -Fq 'configured release artifacts conflict' "$TEST_ROOT/conflict.out" ||
  fail 'release conflict rejection was not reported'
[[ ! -e $CONFLICT_DEST_VAR && ! -e $CONFLICT_DEST_ETC ]] ||
  fail 'release conflict rejection mutated the destination'
ok 'conflicting release trees abort before destination mutation'

RELATIVE_CONFIG=$TEST_ROOT/relative-pizarra.conf
cat >"$RELATIVE_CONFIG" <<EOF
[server]
port = 7010
secret = relative-secret
releases = published-artifacts
[registry]
authority = sqlite
[store]
dir = $SOURCE_STATE
EOF
if run_migrate --source-config "$RELATIVE_CONFIG" --source-store "$SOURCE_STATE" \
  --source-pzweb "$PZWEB_SOURCE" --dry-run >"$TEST_ROOT/relative.out" 2>&1; then
  fail 'migration guessed a process-relative release directory'
fi
grep -Fq 'process-working-directory dependent' "$TEST_ROOT/relative.out" ||
  fail 'relative release ambiguity was not reported'
ok 'process-relative releases require an explicit source directory'

printf 'all release-layout migration tests passed\n'
