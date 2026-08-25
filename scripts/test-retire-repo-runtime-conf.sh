#!/usr/bin/env bash
# Isolated regression test for retire-repo-runtime-conf.sh.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
RETIRER=$SCRIPT_DIR/retire-repo-runtime-conf.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-retire-test.XXXXXXXX")
HOLDER_PID=''

cleanup() {
  if [[ -n ${HOLDER_PID:-} ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  case ${TEST_ROOT:-} in
    "${TMPDIR:-/tmp}"/pizarra-retire-test.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

tree_manifest() {
  local dir=$1 output=$2
  (
    cd -- "$dir"
    find . -printf '%y\0%m\0%P\0%l\0' | LC_ALL=C sort -z | sha256sum
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) >"$output"
}

REPO=$TEST_ROOT/repo
ETC_ROOT=$TEST_ROOT/etc
VAR_ROOT=$TEST_ROOT/var
ASSETS=$TEST_ROOT/usr/local/share/pizarra/web/apps
SOURCE=$REPO/.private/conf
STATE=$VAR_ROOT/lib/pizarra
RELEASES=$STATE/releases
LOG=$VAR_ROOT/log/pizarra/pizarra.log
BACKUP_ROOT=$VAR_ROOT/lib/pizarra-migration-backups
SHARED_ROOT=$TEST_ROOT/external-nfs-share

install -d -m 755 "$REPO/conf" "$REPO/examples"
install -d -m 700 "$REPO/.private" "$STATE" "$RELEASES" "$VAR_ROOT/log/pizarra" "$ASSETS" \
  "$BACKUP_ROOT" "$SHARED_ROOT/empty-team-dir"
install -d -m 700 "$SOURCE/store/appdocs" "$SOURCE/store/wfhistory" \
  "$SOURCE/store/backups" "$STATE/appdocs" "$STATE/wfhistory" \
  "$STATE/backups" "$STATE/legacy"
install -d -m 711 "$ETC_ROOT/pizarra"

cat >"$ETC_ROOT/pizarra/pizarra.conf" <<EOF
[server]
listen = 127.0.0.1
port = 7010
secret = canonical-test-secret
releases = $RELEASES

[registry]
authority = sqlite

[store]
dir = $STATE

[log]
path = $LOG

[shared]
dir = $SHARED_ROOT
EOF

cat >"$ETC_ROOT/pizarra/pzweb.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = 7010
secret = pzweb-test-secret
self = pzweb

[web]
listen = 127.0.0.1
port = 7080
allow_from = 127.0.0.1
host = 127.0.0.1:7080
origin = http://127.0.0.1:7080
static = $ASSETS
shared = $SHARED_ROOT
user = operator
password_sha256 = 0000000000000000000000000000000000000000000000000000000000000000
EOF

cat >"$SOURCE/pizarra.conf" <<EOF
[server]
port = 7010
secret = legacy-test-secret
[store]
dir = $SOURCE/store
[log]
path = $REPO/pizarra.log
[shared]
dir = $SHARED_ROOT
[team:1]
name = retired-team
EOF

cat >"$SOURCE/pzweb.conf" <<EOF
[pizarra]
host = 127.0.0.1
port = 7010
secret = old-web-secret
self = pzweb

[web]
shared = $SHARED_ROOT
EOF
cat >"$ETC_ROOT/pizarra/pizarra.conf.pre-registry-sqlite.test.bak" <<'EOF'
[team:1]
name = retired-team
EOF

printf '%s\n' 'legacy audit log' >"$REPO/pizarra.log"
printf '%s\n' 'legacy audit log' >"$LOG"
printf '%s\n' 'external NFS content must survive retirement' >"$SHARED_ROOT/sentinel.txt"
tree_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-before"
printf '%s\n' '1.1.22' >"$RELEASES/VERSION"
printf '%s\n' '<!doctype html><title>pizarra test</title>' >"$ASSETS/index.html"
printf '%s\n' 'must survive retirement' >"$REPO/examples/preserve.example"
printf '%s\n' 'versioned public example' >"$REPO/examples/pizarra.conf.example"
printf '%s\n' 'historical config' >"$SOURCE/pizarra.conf.pre-test.bak"
chmod 640 "$SOURCE/pizarra.conf.pre-test.bak"
printf '%s\n' 'legacy registry' >"$SOURCE/store/registry.ini"
printf '%s\n' 'legacy registry' >"$STATE/legacy/registry.ini.pre-sqlite"

for file in messages.jsonl state.json tareas.json workflows.json; do
  printf '%s\n' '{}' >"$SOURCE/store/$file"
  cp -p -- "$SOURCE/store/$file" "$STATE/$file"
done
printf '%s\n' 'manual' >"$SOURCE/store/appdocs/example.md"
cp -p -- "$SOURCE/store/appdocs/example.md" "$STATE/appdocs/example.md"
printf '%s\n' '{}' >"$SOURCE/store/wfhistory/example.json"
cp -p -- "$SOURCE/store/wfhistory/example.json" "$STATE/wfhistory/example.json"
printf '%s\n' 'backup' >"$SOURCE/store/backups/example"
cp -p -- "$SOURCE/store/backups/example" "$STATE/backups/example"

sqlite3 "$STATE/apps.sqlite" 'CREATE TABLE meta(k TEXT PRIMARY KEY,v TEXT NOT NULL);'
sqlite3 "$STATE/work.sqlite" 'CREATE TABLE meta(k TEXT PRIMARY KEY,v TEXT NOT NULL);'
sqlite3 "$STATE/org.sqlite" <<'SQL'
PRAGMA foreign_keys=ON;
CREATE TABLE meta(k TEXT PRIMARY KEY,v TEXT NOT NULL);
INSERT INTO meta VALUES('registry_authority','not-ready');
INSERT INTO meta VALUES('apps_en_org','1');
CREATE TABLE parent(id INTEGER PRIMARY KEY);
CREATE TABLE child(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES parent(id));
SQL
for db in apps.sqlite org.sqlite work.sqlite; do
  cp -p -- "$STATE/$db" "$SOURCE/store/$db"
done
printf '' >"$STATE/.pizarra-hub.lock"
chmod 600 "$ETC_ROOT/pizarra/"*.conf "$ETC_ROOT/pizarra/"*.bak \
  "$STATE/"*.sqlite "$STATE/.pizarra-hub.lock" "$LOG"
cat >"$BACKUP_ROOT/installed-state.record" <<EOF
version=1
config_source=$ETC_ROOT/pizarra/pizarra.conf
state_source=$STATE
--manifest--
EOF
chmod 600 "$BACKUP_ROOT/installed-state.record"
ln -s "$ETC_ROOT/pizarra/pzweb.conf" "$SOURCE/tiza.conf"
ln -s ../.private/conf/pizarra.conf "$REPO/conf/pizarra.conf"
ln -s ../.private/conf/pzweb.conf "$REPO/conf/pzweb.conf"
ln -s ../.private/conf/store "$REPO/conf/store"

run_retire() {
  env PIZARRA_REPO_ROOT="$REPO" DEST_ETC="$ETC_ROOT" DEST_VAR="$VAR_ROOT" \
    PIZARRA_WEB_ASSETS_DIR="$ASSETS" "$RETIRER" "$@"
}

cp -p -- "$BACKUP_ROOT/installed-state.record" "$TEST_ROOT/canonical-state.record"

sed -i "s|^config_source=.*|config_source=$SOURCE/pizarra.conf|" \
  "$BACKUP_ROOT/installed-state.record"
if run_retire >"$TEST_ROOT/noncanonical-record.out" 2>&1; then
  fail 'retirement accepted a migration record that still names the repository source'
fi
grep -q 'migration record still names repository-local sources' \
  "$TEST_ROOT/noncanonical-record.out" ||
  fail 'non-canonical migration record rejection was not reported'
cp -p -- "$TEST_ROOT/canonical-state.record" "$BACKUP_ROOT/installed-state.record"
ok 'repository-local migration lineage is rejected'

if run_retire >"$TEST_ROOT/not-ready.out" 2>&1; then
  fail 'retirement accepted a missing SQLite authority marker'
fi
grep -q 'registry_authority is not sqlite-v1' "$TEST_ROOT/not-ready.out" ||
  fail 'authority rejection did not identify the marker'
sqlite3 "$STATE/org.sqlite" \
  "UPDATE meta SET v='sqlite-v1' WHERE k='registry_authority';"
ok 'missing authority is rejected'

sed -i "s|^releases = .*|releases = $REPO/releases|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
if run_retire >"$TEST_ROOT/repo-release.out" 2>&1; then
  fail 'retirement accepted repository-local release configuration'
fi
grep -q 'canonical pizarra.conf \[server\] releases is not' \
  "$TEST_ROOT/repo-release.out" ||
  fail 'repository-local release rejection was not reported'
sed -i "s|^releases = .*|releases = $RELEASES|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
ok 'repository-local releases are rejected'

sed -i "s|^dir = $SHARED_ROOT$|dir = relative/nfs|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
if run_retire >"$TEST_ROOT/hub-relative-shared.out" 2>&1; then
  fail 'retirement accepted a relative canonical hub shared root'
fi
grep -q 'canonical pizarra.conf \[shared\] dir must be absolute' \
  "$TEST_ROOT/hub-relative-shared.out" ||
  fail 'retirement did not identify the relative canonical hub shared root'
sed -i "s|^dir = relative/nfs$|dir = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pizarra.conf"

sed -i "s|^shared = $SHARED_ROOT$|shared = relative/nfs|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
if run_retire >"$TEST_ROOT/web-relative-shared.out" 2>&1; then
  fail 'retirement accepted a relative canonical pzweb shared root'
fi
grep -q 'canonical pzweb.conf \[web\] shared must be absolute' \
  "$TEST_ROOT/web-relative-shared.out" ||
  fail 'retirement did not identify the relative canonical pzweb shared root'
sed -i "s|^shared = relative/nfs$|shared = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pzweb.conf"

sed -i "s|^dir = $SHARED_ROOT$|dir = ////|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
if run_retire >"$TEST_ROOT/hub-root-shared.out" 2>&1; then
  fail 'retirement accepted filesystem root as canonical hub shared root'
fi
grep -q 'canonical pizarra.conf \[shared\] dir may not be the filesystem root' \
  "$TEST_ROOT/hub-root-shared.out" ||
  fail 'retirement did not reject the normalized canonical hub root'
sed -i "s|^dir = ////$|dir = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pizarra.conf"

sed -i "s|^shared = $SHARED_ROOT$|shared = ////|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
if run_retire >"$TEST_ROOT/web-root-shared.out" 2>&1; then
  fail 'retirement accepted filesystem root as canonical pzweb shared root'
fi
grep -q 'canonical pzweb.conf \[web\] shared may not be the filesystem root' \
  "$TEST_ROOT/web-root-shared.out" ||
  fail 'retirement did not reject the normalized canonical pzweb root'
sed -i "s|^shared = ////$|shared = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
ok 'retirement rejects relative and filesystem-root shared paths'

sed -i "s|^shared = $SHARED_ROOT$|shared = $TEST_ROOT/wrong-shared|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
if run_retire >"$TEST_ROOT/shared-mismatch.out" 2>&1; then
  fail 'retirement accepted mismatched hub/pzweb shared roots'
fi
grep -q 'shared does not exactly match' "$TEST_ROOT/shared-mismatch.out" ||
  fail 'shared-root mismatch rejection was not reported'
sed -i "s|^shared = $TEST_ROOT/wrong-shared$|shared = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
ok 'mismatched hub/pzweb shared roots are rejected'

sed -i "s|^shared = $SHARED_ROOT$|shared = |" \
  "$ETC_ROOT/pizarra/pzweb.conf"
if run_retire >"$TEST_ROOT/web-shared-empty.out" 2>&1; then
  fail 'retirement accepted a hub shared root with empty pzweb shared'
fi
grep -q 'shared does not exactly match' "$TEST_ROOT/web-shared-empty.out" ||
  fail 'retirement did not reject empty pzweb shared against configured hub shared'
sed -i "s|^shared = $|shared = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pzweb.conf"

sed -i "s|^dir = $SHARED_ROOT$|dir = |" \
  "$ETC_ROOT/pizarra/pizarra.conf"
if run_retire >"$TEST_ROOT/hub-shared-empty.out" 2>&1; then
  fail 'retirement accepted empty hub shared with configured pzweb shared'
fi
grep -q 'shared does not exactly match' "$TEST_ROOT/hub-shared-empty.out" ||
  fail 'retirement did not reject configured pzweb shared against empty hub shared'
sed -i "s|^dir = $|dir = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
ok 'empty/non-empty shared mismatches are rejected in both directions'

sed -i "s|^dir = $SHARED_ROOT$|dir = $TEST_ROOT/wrong-shared|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
sed -i "s|^shared = $SHARED_ROOT$|shared = $TEST_ROOT/wrong-shared|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
if run_retire >"$TEST_ROOT/shared-not-preserved.out" 2>&1; then
  fail 'retirement accepted a canonical shared root different from its source'
fi
grep -q 'did not preserve the source \[shared\] dir' \
  "$TEST_ROOT/shared-not-preserved.out" ||
  fail 'source shared-root preservation rejection was not reported'
sed -i "s|^dir = $TEST_ROOT/wrong-shared$|dir = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pizarra.conf"
sed -i "s|^shared = $TEST_ROOT/wrong-shared$|shared = $SHARED_ROOT|" \
  "$ETC_ROOT/pizarra/pzweb.conf"
ok 'retirement requires literal preservation of the source shared root'

sqlite3 "$STATE/org.sqlite" 'INSERT INTO child VALUES(1,999);'
if run_retire >"$TEST_ROOT/foreign-key.out" 2>&1; then
  fail 'retirement accepted a canonical foreign-key violation'
fi
grep -q 'foreign_key_check failed' "$TEST_ROOT/foreign-key.out" ||
  fail 'foreign-key rejection was not reported'
sqlite3 "$STATE/org.sqlite" 'DELETE FROM child;'
ok 'canonical foreign-key violations are rejected'

printf '%s\n' 'must block retirement' >"$REPO/conf/unexpected"
if run_retire >"$TEST_ROOT/unexpected-entry.out" 2>&1; then
  fail 'retirement accepted an unexpected conf entry'
fi
grep -q 'unexpected entry in repository conf directory' "$TEST_ROOT/unexpected-entry.out" ||
  fail 'unexpected conf entry rejection was not reported'
[[ -d $SOURCE && -L $REPO/conf/pizarra.conf ]] ||
  fail 'unexpected conf entry rejection changed the source layout'
rm -- "$REPO/conf/unexpected"
ok 'unexpected conf entries are rejected before retirement'

(
  exec 9<"$SOURCE/store/messages.jsonl"
  sleep 20
) &
HOLDER_PID=$!
if run_retire >"$TEST_ROOT/open-handle.out" 2>&1; then
  fail 'retirement accepted an open source handle'
fi
grep -Eq 'open source|open source descriptor|still in use' "$TEST_ROOT/open-handle.out" ||
  fail 'open-handle rejection was not reported'
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=''
ok 'open source handles are rejected'

(
  exec 9<"$REPO/pizarra.log"
  sleep 20
) &
HOLDER_PID=$!
if run_retire >"$TEST_ROOT/open-log-handle.out" 2>&1; then
  fail 'retirement accepted an open legacy-log handle'
fi
grep -Eq 'open repository runtime path|open source descriptor|still in use' \
  "$TEST_ROOT/open-log-handle.out" || fail 'legacy-log handle rejection was not reported'
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=''
ok 'open legacy-log handles are rejected'

run_retire >"$TEST_ROOT/dry-run.out"
[[ -d $SOURCE ]] || fail 'dry run removed source'
[[ -L $REPO/conf/pizarra.conf && -L $REPO/conf/pzweb.conf && -L $REPO/conf/store ]] ||
  fail 'dry run removed a compatibility link'
cmp -s -- "$BACKUP_ROOT/installed-state.record" "$TEST_ROOT/canonical-state.record" ||
  fail 'dry run changed the trusted migration record'
[[ -z $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \
  ! -name installed-state.record -print -quit) ]] ||
  fail 'dry run created rollback material'
ok 'default dry run is non-mutating'

run_retire --confirm >"$TEST_ROOT/confirm.out"
[[ ! -e $SOURCE && ! -L $SOURCE ]] || fail 'confirmed retirement left source tree'
[[ ! -e $REPO/pizarra.log && ! -L $REPO/pizarra.log ]] ||
  fail 'confirmed retirement left legacy repository log'
[[ ! -e $REPO/conf && ! -L $REPO/conf ]] ||
  fail 'confirmed retirement left the compatibility directory'
[[ $(<"$REPO/examples/preserve.example") == 'must survive retirement' ]] ||
  fail 'public example changed'
[[ $(<"$REPO/examples/pizarra.conf.example") == 'versioned public example' ]] ||
  fail 'examples/ content changed'
[[ $(<"$RELEASES/VERSION") == '1.1.22' ]] ||
  fail 'canonical release artifact changed during retirement'
tree_manifest "$SHARED_ROOT" "$TEST_ROOT/shared-after"
cmp -s -- "$TEST_ROOT/shared-before" "$TEST_ROOT/shared-after" ||
  fail 'external shared tree changed during retirement'

mapfile -d '' -t ARCHIVES < <(find "$VAR_ROOT/lib/pizarra-migration-backups" \
  -mindepth 1 -maxdepth 1 -type d -name 'retired-source-conf-*' -print0)
((${#ARCHIVES[@]} == 1)) || fail 'confirmed retirement did not publish exactly one archive'
ARCHIVE=${ARCHIVES[0]}
[[ -f $ARCHIVE/source-conf/pizarra.conf.pre-test.bak ]] || fail 'historical config was not archived'
[[ $(stat -c '%a' "$ARCHIVE/source-conf/pizarra.conf.pre-test.bak") == 640 ]] ||
  fail 'historical config mode was not preserved'
[[ -L $ARCHIVE/source-conf/tiza.conf &&
   $(readlink "$ARCHIVE/source-conf/tiza.conf") == "$ETC_ROOT/pizarra/pzweb.conf" ]] ||
  fail 'top-level source symlink was not preserved'
[[ -f $ARCHIVE/source-conf/store/appdocs/example.md ]] || fail 'source store was not archived'
[[ -f $ARCHIVE/legacy-repo-log/log ]] || fail 'legacy log was not archived'
[[ -f $ARCHIVE.MANIFEST && -f $ARCHIVE.SOURCE-CONF.MANIFEST &&
   -f $ARCHIVE.retirement-record ]] || fail 'archive verification metadata is incomplete'
ok 'confirmed cross-filesystem archive and exact retirement succeed'

run_retire --confirm >"$TEST_ROOT/idempotent.out"
mapfile -d '' -t ARCHIVES_AFTER < <(find "$VAR_ROOT/lib/pizarra-migration-backups" \
  -mindepth 1 -maxdepth 1 -type d -name 'retired-source-conf-*' -print0)
((${#ARCHIVES_AFTER[@]} == 1)) || fail 'idempotent rerun created another archive'
[[ ! -e $REPO/conf && -f $REPO/examples/preserve.example ]] ||
  fail 'idempotent rerun recreated conf or changed a public example'
ok 'confirmed rerun is idempotent'

printf 'all retirement tests passed\n'
