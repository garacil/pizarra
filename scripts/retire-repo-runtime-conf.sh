#!/usr/bin/env bash
# Retire the temporary source-tree runtime layout after a verified cutover.
#
# This is deliberately separate from migrate-to-system-layout.sh. Migration
# copies live state while the old layout still exists; retirement is allowed
# only after the canonical installation is complete and SQLite-authoritative.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DEFAULT_REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

PIZARRA_REPO_ROOT=${PIZARRA_REPO_ROOT:-$DEFAULT_REPO_ROOT}
DEST_ETC=${DEST_ETC:-/etc}
DEST_VAR=${DEST_VAR:-/var}
PIZARRA_WEB_ASSETS_DIR=${PIZARRA_WEB_ASSETS_DIR:-/usr/local/share/pizarra/web/apps}
CONFIRM=0

usage() {
  cat <<'EOF'
Usage: sudo scripts/retire-repo-runtime-conf.sh [--confirm]

Safely retires the temporary repository-local runtime configuration only after
the canonical installation is demonstrably complete. The default is a dry run.
No source file, compatibility link, or directory is changed without --confirm.

The confirmed operation:
  1. verifies /etc/pizarra and /var/lib/pizarra, including canonical releases,
     SQLite authority, integrity, and foreign keys;
  2. refuses any process, tmux launch, or open handle using the old tree;
  3. copies .private/conf across filesystems into the private rollback root,
     compares complete content/tree manifests, and durably publishes it; then
  4. removes the exact archived source, only the three compatibility links
     conf/{pizarra.conf,pzweb.conf,store}, and then that now-empty conf
     directory. Any unexpected entry stops the operation. Public examples are
     never touched.

Test-only path overrides:
  PIZARRA_REPO_ROOT=/tmp/repo DEST_ETC=/tmp/etc DEST_VAR=/tmp/var \
  PIZARRA_WEB_ASSETS_DIR=/tmp/share/pizarra/web/apps \
    scripts/retire-repo-runtime-conf.sh [--confirm]
EOF
}

say() { printf '%s: %s\n' "$PROGRAM" "$*"; }
warn() { printf '%s: WARNING: %s\n' "$PROGRAM" "$*" >&2; }
die() { printf '%s: ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --confirm) CONFIRM=1; shift ;;
    --dry-run) CONFIRM=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

for tool in awk cat chmod cmp cp date dirname find findmnt flock grep id install \
            lsof mktemp mv readlink rmdir sha256sum sort sqlite3 stat sync \
            tmux tr unlink xargs; do
  command -v "$tool" >/dev/null 2>&1 || die "required command is missing: $tool"
done

validate_base_path() {
  local label=$1 value=$2 wrapped
  [[ $value == /* ]] || die "$label must be an absolute path"
  [[ $value != / ]] || die "$label may not be /"
  [[ $value != */ ]] || die "$label may not have a trailing slash"
  [[ $value != *//* ]] || die "$label may not contain repeated slashes"
  [[ $value != *$'\n'* ]] || die "$label may not contain newlines"
  [[ $value != *'?'* && $value != *'#'* && $value != *'%'* ]] ||
    die "$label may not contain URI metacharacters (?, #, or %)"
  wrapped=/${value#/}/
  [[ $wrapped != */./* && $wrapped != */../* ]] ||
    die "$label may not contain . or .. components"
}

validate_base_path PIZARRA_REPO_ROOT "$PIZARRA_REPO_ROOT"
validate_base_path DEST_ETC "$DEST_ETC"
validate_base_path DEST_VAR "$DEST_VAR"
validate_base_path PIZARRA_WEB_ASSETS_DIR "$PIZARRA_WEB_ASSETS_DIR"
[[ -d $PIZARRA_REPO_ROOT ]] || die "repository root does not exist: $PIZARRA_REPO_ROOT"
PIZARRA_REPO_ROOT=$(cd -- "$PIZARRA_REPO_ROOT" && pwd -P)

CONFIG_DIR=$DEST_ETC/pizarra
PIZARRA_CONF=$CONFIG_DIR/pizarra.conf
PZWEB_CONF=$CONFIG_DIR/pzweb.conf
STATE_DIR=$DEST_VAR/lib/pizarra
RELEASE_DIR=$STATE_DIR/releases
LOG_DIR=$DEST_VAR/log/pizarra
LOG_PATH=$LOG_DIR/pizarra.log
BACKUP_ROOT=$DEST_VAR/lib/pizarra-migration-backups
TRUSTED_STATE_RECORD=$BACKUP_ROOT/installed-state.record
SOURCE_CONF=$PIZARRA_REPO_ROOT/.private/conf
RUNTIME_LINK_DIR=$PIZARRA_REPO_ROOT/conf
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

for item in "$CONFIG_DIR" "$PIZARRA_CONF" "$PZWEB_CONF" "$STATE_DIR" "$RELEASE_DIR" \
            "$LOG_DIR" "$LOG_PATH" "$BACKUP_ROOT" "$TRUSTED_STATE_RECORD" "$SOURCE_CONF" \
            "$RUNTIME_LINK_DIR"; do
  [[ $item != *$'\n'* ]] || die "derived path contains a newline: $item"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-retire.XXXXXXXX")
SOURCE_LOCK_FD=''
cleanup() {
  if [[ -n ${SOURCE_LOCK_FD:-} ]]; then
    eval "exec ${SOURCE_LOCK_FD}>&-" || true
  fi
  case ${WORK:-} in
    "${TMPDIR:-/tmp}"/pizarra-retire.*)
      [[ ! -d $WORK ]] || find "$WORK" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $WORK ]] || rmdir "$WORK" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

reject_symlink_components() {
  local path=$1 label=$2 component current=''
  local -a components=()
  IFS=/ read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    current=$current/$component
    [[ ! -L $current ]] || die "$label has a symbolic-link component: $current"
    if [[ -e $current && $current != "$path" && ! -d $current ]]; then
      die "$label has a non-directory ancestor: $current"
    fi
  done
}

path_within() {
  local candidate=$1 parent=$2
  [[ $candidate == "$parent" || $candidate == "$parent"/* ]]
}

require_real_directory() {
  local path=$1 label=$2 mode
  reject_symlink_components "$path" "$label"
  [[ -d $path && ! -L $path ]] || die "$label is not a real directory: $path"
  mode=$(stat -Lc '%a' -- "$path")
  (( (8#$mode & 0077) == 0 )) ||
    die "$label grants group/other permissions (expected private): $path mode=$mode"
}

require_secure_file() {
  local path=$1 label=$2 exact_mode=${3:-} mode
  reject_symlink_components "$path" "$label"
  [[ -f $path && ! -L $path ]] || die "$label is not a regular file: $path"
  mode=$(stat -Lc '%a' -- "$path")
  if [[ -n $exact_mode ]]; then
    [[ $mode == "$exact_mode" ]] || die "$label must be mode $exact_mode: $path mode=$mode"
  elif (( (8#$mode & 0077) != 0 )); then
    die "$label grants group/other permissions: $path mode=$mode"
  fi
}

ini_get() {
  local file=$1 want_section=$2 want_key=$3
  awk -v wanted_section="$want_section" -v wanted_key="$want_key" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ {
      s=$0
      sub(/^[[:space:]]*\[/, "", s)
      sub(/\][[:space:]]*$/, "", s)
      section=tolower(trim(s))
      next
    }
    section==tolower(wanted_section) {
      p=index($0, "=")
      if (p==0) next
      key=tolower(trim(substr($0,1,p-1)))
      if (key==tolower(wanted_key)) {
        value=trim(substr($0,p+1))
        if (length(value)>1) {
          first=substr(value,1,1)
          last=substr(value,length(value),1)
          if ((first=="\"" || first=="\047") && last==first)
            value=substr(value,2,length(value)-2)
        }
        print value
        exit
      }
    }
  ' "$file"
}

validate_shared_path_value() {
  local label=$1 value=$2 normalized
  [[ -n $value ]] || return 0
  [[ $value == /* ]] || die "$label must be absolute"
  normalized=$value
  while [[ $normalized != / && $normalized == */ ]]; do
    normalized=${normalized%/}
  done
  [[ $normalized != / ]] ||
    die "$label may not be the filesystem root; use a dedicated external directory or mount"
}

strip_typed_comment() {
  local value=$1
  value=${value%%#*}
  value=${value%%;*}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

registry_sections() {
  awk '
    /^[[:space:]]*\[/ {
      s=tolower($0)
      if (s ~ /^[[:space:]]*\[(team:|group:|project:|app:)/) n++
    }
    END { print n+0 }
  ' "$1"
}

sqlite_scalar() {
  local db=$1 sql=$2 result
  # This is the canonical database, which may legitimately have committed data
  # in its WAL while the new hub runs. immutable=1 would ignore that WAL and
  # validate a stale main file. mode=ro participates in SQLite's normal WAL
  # snapshot rules and therefore checks the state the hub actually serves.
  result=$(sqlite3 -batch -noheader -readonly \
    "file:$db?mode=ro" "$sql" 2>&1) ||
    die "SQLite query failed for ${db##*/}: $result"
  printf '%s\n' "$result"
}

trusted_record_get() {
  local key=$1
  awk -v wanted="$key" '
    /^--manifest--$/ { exit }
    index($0, wanted "=")==1 { print substr($0, length(wanted)+2); exit }
  ' "$TRUSTED_STATE_RECORD"
}

validate_canonical_migration_record() {
  local expected_uid config_source state_source owner
  require_real_directory "$BACKUP_ROOT" 'trusted migration metadata directory'
  require_secure_file "$TRUSTED_STATE_RECORD" 'trusted migration state record' 600
  expected_uid=$(id -u)
  owner=$(stat -Lc '%u' -- "$BACKUP_ROOT")
  [[ $owner == "$expected_uid" ]] ||
    die "trusted migration metadata directory has the wrong owner: $BACKUP_ROOT"
  owner=$(stat -Lc '%u' -- "$TRUSTED_STATE_RECORD")
  [[ $owner == "$expected_uid" ]] ||
    die "trusted migration state record has the wrong owner: $TRUSTED_STATE_RECORD"
  config_source=$(trusted_record_get config_source)
  state_source=$(trusted_record_get state_source)
  [[ $config_source == "$PIZARRA_CONF" && $state_source == "$STATE_DIR" ]] ||
    die "migration record still names repository-local sources; while the old hub is stopped, rerun migrate-to-system-layout.sh with --source-config $PIZARRA_CONF --source-store $STATE_DIR --source-pzweb $PZWEB_CONF before retirement"
}

validate_sqlite() {
  local db=$1 name integrity foreign
  name=${db##*/}
  require_secure_file "$db" "canonical SQLite $name"
  integrity=$(sqlite_scalar "$db" 'PRAGMA integrity_check;')
  [[ $integrity == ok ]] || die "SQLite integrity_check failed for $db: $integrity"
  foreign=$(sqlite_scalar "$db" 'PRAGMA foreign_key_check;')
  [[ -z $foreign ]] || die "SQLite foreign_key_check failed for $db: $foreign"
  say "SQLite verified: $name"
}

validate_port() {
  local label=$1 raw=$2 value
  value=$(strip_typed_comment "$raw")
  [[ $value =~ ^[0-9]+$ ]] || die "$label is not a decimal port"
  ((10#$value >= 1 && 10#$value <= 65535)) || die "$label is outside 1..65535"
  printf '%s\n' "$value"
}

validate_canonical_layout() {
  local hub_store hub_releases hub_log hub_shared web_shared authority hub_port web_port static_path marker app_marker
  local required value hash legacy_count
  local -a dbs=(apps.sqlite org.sqlite work.sqlite)

  require_secure_file "$PIZARRA_CONF" 'canonical pizarra.conf' 600
  require_secure_file "$PZWEB_CONF" 'canonical pzweb.conf' 600
  validate_canonical_migration_record
  require_real_directory "$STATE_DIR" 'canonical state directory'
  require_real_directory "$RELEASE_DIR" 'canonical release directory'
  path_within "$RELEASE_DIR" "$PIZARRA_REPO_ROOT" &&
    die "canonical release directory is still inside the repository: $RELEASE_DIR"
  [[ -z $(find "$RELEASE_DIR" -type l -print -quit) ]] ||
    die "canonical release directory contains a symbolic link: $RELEASE_DIR"
  [[ -z $(find "$RELEASE_DIR" -mindepth 1 ! -type d ! -type f -print -quit) ]] ||
    die "canonical release directory contains a socket, device, or other unsupported entry: $RELEASE_DIR"
  require_real_directory "$LOG_DIR" 'canonical log directory'
  reject_symlink_components "$PIZARRA_WEB_ASSETS_DIR" 'canonical web assets'
  [[ -d $PIZARRA_WEB_ASSETS_DIR && ! -L $PIZARRA_WEB_ASSETS_DIR ]] ||
    die "canonical web assets directory is missing or linked: $PIZARRA_WEB_ASSETS_DIR"
  [[ -f $PIZARRA_WEB_ASSETS_DIR/index.html && ! -L $PIZARRA_WEB_ASSETS_DIR/index.html ]] ||
    die "canonical web assets are incomplete: index.html is missing"

  hub_store=$(ini_get "$PIZARRA_CONF" store dir || true)
  hub_releases=$(ini_get "$PIZARRA_CONF" server releases || true)
  hub_log=$(ini_get "$PIZARRA_CONF" log path || true)
  hub_shared=$(ini_get "$PIZARRA_CONF" shared dir || true)
  validate_shared_path_value 'canonical pizarra.conf [shared] dir' "$hub_shared"
  authority=$(strip_typed_comment "$(ini_get "$PIZARRA_CONF" registry authority || true)")
  authority=$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')
  [[ $hub_store == "$STATE_DIR" ]] ||
    die "canonical pizarra.conf [store] dir is not $STATE_DIR: $hub_store"
  [[ $hub_releases == "$RELEASE_DIR" ]] ||
    die "canonical pizarra.conf [server] releases is not $RELEASE_DIR: $hub_releases"
  [[ $hub_log == "$LOG_PATH" ]] ||
    die "canonical pizarra.conf [log] path is not $LOG_PATH: $hub_log"
  [[ $authority == sqlite ]] ||
    die "canonical pizarra.conf does not declare [registry] authority=sqlite"
  legacy_count=$(registry_sections "$PIZARRA_CONF")
  [[ $legacy_count == 0 ]] ||
    die "canonical pizarra.conf still has $legacy_count legacy registry section(s)"
  value=$(ini_get "$PIZARRA_CONF" server secret || true)
  [[ -n $value ]] || die 'canonical pizarra.conf has an empty [server] secret'
  hub_port=$(validate_port 'canonical [server] port' \
    "$(ini_get "$PIZARRA_CONF" server port || true)")

  for required in host secret self; do
    value=$(ini_get "$PZWEB_CONF" pizarra "$required" || true)
    [[ -n $value ]] || die "canonical pzweb.conf has empty [pizarra] $required"
  done
  web_port=$(validate_port 'canonical pzweb [pizarra] port' \
    "$(ini_get "$PZWEB_CONF" pizarra port || true)")
  [[ $web_port == "$hub_port" ]] ||
    die "pzweb hub port $web_port differs from pizarra port $hub_port"
  for required in listen allow_from host origin user; do
    value=$(ini_get "$PZWEB_CONF" web "$required" || true)
    [[ -n $value ]] || die "canonical pzweb.conf has empty [web] $required"
  done
  validate_port 'canonical pzweb [web] port' \
    "$(ini_get "$PZWEB_CONF" web port || true)" >/dev/null
  static_path=$(ini_get "$PZWEB_CONF" web static || true)
  [[ $static_path == "$PIZARRA_WEB_ASSETS_DIR" ]] ||
    die "canonical pzweb.conf [web] static is not $PIZARRA_WEB_ASSETS_DIR: $static_path"
  web_shared=$(ini_get "$PZWEB_CONF" web shared || true)
  validate_shared_path_value 'canonical pzweb.conf [web] shared' "$web_shared"
  if [[ $web_shared != "$hub_shared" ]]; then
    die 'canonical pzweb.conf [web] shared does not exactly match pizarra.conf [shared] dir'
  fi
  hash=$(ini_get "$PZWEB_CONF" web password_sha256 || true)
  hash=$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')
  [[ $hash =~ ^[0-9a-f]{64}$ ]] ||
    die 'canonical pzweb.conf [web] password_sha256 is not 64 hexadecimal digits'

  for required in "${dbs[@]}"; do
    validate_sqlite "$STATE_DIR/$required"
  done
  marker=$(sqlite_scalar "$STATE_DIR/org.sqlite" \
    "SELECT v FROM meta WHERE k='registry_authority';")
  [[ $marker == sqlite-v1 ]] ||
    die "org.sqlite registry_authority is not sqlite-v1: ${marker:-missing}"
  app_marker=$(sqlite_scalar "$STATE_DIR/org.sqlite" \
    "SELECT v FROM meta WHERE k='apps_en_org';")
  [[ $app_marker == 1 ]] || die "org.sqlite apps_en_org marker is not 1: ${app_marker:-missing}"
  require_secure_file "$STATE_DIR/.pizarra-hub.lock" 'canonical hub lifetime lock' 600
  [[ ! -e $STATE_DIR/registry.ini && ! -L $STATE_DIR/registry.ini ]] ||
    die 'canonical state still has a top-level registry.ini'
}

validate_source_shape_in_canonical() {
  local item found=0 backup source_hub_shared canonical_hub_shared
  local source_web_shared canonical_web_shared
  [[ -d $SOURCE_CONF ]] || return 0
  [[ -f $SOURCE_CONF/pizarra.conf && ! -L $SOURCE_CONF/pizarra.conf ]] ||
    die "source pizarra.conf is missing or linked: $SOURCE_CONF/pizarra.conf"
  [[ -f $SOURCE_CONF/pzweb.conf && ! -L $SOURCE_CONF/pzweb.conf ]] ||
    die "source pzweb.conf is missing or linked: $SOURCE_CONF/pzweb.conf"
  [[ -d $SOURCE_CONF/store && ! -L $SOURCE_CONF/store ]] ||
    die "source store is missing or linked: $SOURCE_CONF/store"
  # The exchange path is an operator-owned external mount, not migration state.
  # Before deleting the old configs, prove both configured references survived
  # literally. Never stat or enumerate the shared path here: an unavailable NFS
  # must not turn retirement into a filesystem operation against that tree.
  source_hub_shared=$(ini_get "$SOURCE_CONF/pizarra.conf" shared dir || true)
  canonical_hub_shared=$(ini_get "$PIZARRA_CONF" shared dir || true)
  [[ $canonical_hub_shared == "$source_hub_shared" ]] ||
    die 'canonical pizarra.conf did not preserve the source [shared] dir; reconcile it before retirement'
  source_web_shared=$(ini_get "$SOURCE_CONF/pzweb.conf" web shared || true)
  canonical_web_shared=$(ini_get "$PZWEB_CONF" web shared || true)
  [[ $canonical_web_shared == "$source_web_shared" ]] ||
    die 'canonical pzweb.conf did not preserve the source [web] shared; reconcile it before retirement'
  for item in messages.jsonl state.json tareas.json workflows.json; do
    if [[ -f $SOURCE_CONF/store/$item ]]; then
      [[ -f $STATE_DIR/$item && ! -L $STATE_DIR/$item ]] ||
        die "canonical state omitted source runtime file: $item"
    fi
  done
  for item in appdocs wfhistory backups; do
    if [[ -d $SOURCE_CONF/store/$item ]]; then
      [[ -d $STATE_DIR/$item && ! -L $STATE_DIR/$item ]] ||
        die "canonical state omitted source directory: $item"
    fi
  done
  if [[ -f $SOURCE_CONF/store/registry.ini ]]; then
    [[ -f $STATE_DIR/legacy/registry.ini.pre-sqlite ]] ||
      die 'canonical state did not archive the source registry.ini'
  fi
  if (( $(registry_sections "$SOURCE_CONF/pizarra.conf") > 0 )); then
    shopt -s nullglob
    for backup in "$CONFIG_DIR"/pizarra.conf.pre-registry-sqlite.*.bak; do
      require_secure_file "$backup" 'canonical pre-SQLite configuration backup'
      found=1
    done
    shopt -u nullglob
    ((found)) || die 'canonical cutover backup pizarra.conf.pre-registry-sqlite.*.bak is missing'
  fi
}

manifest_tree() {
  local dir=$1 output=$2 tree_hash
  (
    cd -- "$dir" || exit 1
    # Directory inode sizes legitimately differ between NFS and ext4. Content
    # bytes are hashed below; the tree digest covers types, modes, names, empty
    # directories, and symlink targets without filesystem-specific sizes.
    tree_hash=$(find . -printf '%y\0%m\0%P\0%l\0' | LC_ALL=C sort -z | sha256sum | awk '{print $1}') || exit 1
    printf '@tree=%s\n' "$tree_hash"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) >"$output" || return 1
  chmod 600 "$output"
}

examples_manifest() {
  local output=$1
  (
    for directory in "$RUNTIME_LINK_DIR" "$PIZARRA_REPO_ROOT/examples"; do
      [[ -d $directory ]] || continue
      find "$directory" -maxdepth 1 -type f -name '*.example' -print0
    done | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) >"$output"
  chmod 600 "$output"
}

reject_nested_mounts() {
  local mounts mount
  mounts=$(findmnt -rn -o TARGET) || die 'cannot enumerate mounted filesystems'
  while IFS= read -r mount; do
    [[ -n $mount ]] || continue
    if path_within "$mount" "$SOURCE_CONF"; then
      die "source tree contains a mount point and cannot be retired safely: $mount"
    fi
  done <<<"$mounts"
}

declare -A IGNORE_PID=()
build_ignored_pids() {
  local pid=$$ next
  while [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/status ]]; do
    IGNORE_PID[$pid]=1
    next=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status")
    [[ -n $next && $next != "$pid" && $next != 0 ]] || break
    pid=$next
  done
}

process_file_mentions_runtime() {
  local file=$1 cwd=$2
  [[ -r $file ]] || return 1
  grep -azFq -- "$SOURCE_CONF" "$file" && return 0
  if [[ -n $LEGACY_LOG ]]; then
    grep -azFq -- "$LEGACY_LOG" "$file" && return 0
  fi
  grep -azFq -- "$RUNTIME_LINK_DIR/pizarra.conf" "$file" && return 0
  grep -azFq -- "$RUNTIME_LINK_DIR/pzweb.conf" "$file" && return 0
  grep -azFq -- "$RUNTIME_LINK_DIR/store" "$file" && return 0
  if path_within "$cwd" "$PIZARRA_REPO_ROOT"; then
    grep -azFq -- 'conf/pizarra.conf' "$file" && return 0
    grep -azFq -- 'conf/pzweb.conf' "$file" && return 0
    grep -azFq -- 'conf/store' "$file" && return 0
  fi
  return 1
}

scan_runtime_users() {
  local proc pid cwd ref target line session pane_path start_command
  local current_pid='' current_command='' blockers=0 lsof_rc=0
  build_ignored_pids
  : >"$WORK/lsof"

  if [[ -d $SOURCE_CONF ]]; then
    lsof -nP -Fpcn +D "$SOURCE_CONF" >"$WORK/lsof-source" 2>"$WORK/lsof.err" || lsof_rc=$?
    ((lsof_rc <= 1)) || die "lsof could not inspect the source tree (exit $lsof_rc)"
    cat "$WORK/lsof-source" >>"$WORK/lsof"
  fi
  if [[ -n $LEGACY_LOG && ( -e $LEGACY_LOG || -L $LEGACY_LOG ) ]]; then
    lsof_rc=0
    lsof -nP -Fpcn -- "$LEGACY_LOG" >"$WORK/lsof-log" 2>"$WORK/lsof-log.err" || lsof_rc=$?
    ((lsof_rc <= 1)) || die "lsof could not inspect the legacy log (exit $lsof_rc)"
    cat "$WORK/lsof-log" >>"$WORK/lsof"
  fi
  while IFS= read -r line; do
    case $line in
      p*) current_pid=${line#p}; current_command='' ;;
      c*) current_command=${line#c} ;;
      n*)
        if [[ -n $current_pid && ! ${IGNORE_PID[$current_pid]+ignored} ]]; then
          warn "open repository runtime path: pid=$current_pid command=${current_command:-unknown} path=${line#n}"
          blockers=1
        fi
        ;;
    esac
  done <"$WORK/lsof"

  for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    [[ ! ${IGNORE_PID[$pid]+ignored} ]] || continue
    cwd=$(readlink "$proc/cwd" 2>/dev/null || true)
    if path_within "$cwd" "$SOURCE_CONF" ||
       process_file_mentions_runtime "$proc/cmdline" "$cwd" ||
       process_file_mentions_runtime "$proc/environ" "$cwd"; then
      warn "process still references repository runtime paths: pid=$pid"
      blockers=1
      continue
    fi
    for ref in "$proc"/fd/*; do
      [[ -e $ref || -L $ref ]] || continue
      target=$(readlink "$ref" 2>/dev/null || true)
      target=${target% (deleted)}
      if path_within "$target" "$SOURCE_CONF" ||
         { [[ -n $LEGACY_LOG ]] && [[ $target == "$LEGACY_LOG" ]]; }; then
        warn "process has an open source descriptor: pid=$pid path=$target"
        blockers=1
        break
      fi
    done
  done

  while IFS=$'\t' read -r session pane_path start_command; do
    [[ -n ${session:-} ]] || continue
    if [[ $start_command == *"$SOURCE_CONF"* ||
          $start_command == *"$RUNTIME_LINK_DIR/pizarra.conf"* ||
          $start_command == *"$RUNTIME_LINK_DIR/pzweb.conf"* ||
          $start_command == *"$RUNTIME_LINK_DIR/store"* ]] ||
       { path_within "$pane_path" "$PIZARRA_REPO_ROOT" &&
         [[ $start_command == *conf/pizarra.conf* ||
            $start_command == *conf/pzweb.conf* ||
            $start_command == *conf/store* ]]; }; then
      warn "tmux session still launches from repository runtime paths: $session"
      blockers=1
    fi
  done < <(tmux list-panes -a -F $'#{session_name}\t#{pane_current_path}\t#{pane_start_command}' 2>/dev/null || true)

  ((blockers == 0)) || die 'source runtime is still in use; stop those exact processes/sessions and retry'
}

acquire_source_lock() {
  local lock=$SOURCE_CONF/store/.pizarra-hub.lock
  [[ -d $SOURCE_CONF ]] || return 0
  if [[ ! -e $lock && $CONFIRM == 0 ]]; then
    say "dry run: source hub lock is absent; --confirm would create and hold $lock"
    return 0
  fi
  [[ ! -e $lock || ( -f $lock && ! -L $lock ) ]] ||
    die "source hub lock is not a regular file: $lock"
  if ((CONFIRM)); then
    exec {SOURCE_LOCK_FD}<>"$lock"
    chmod 600 "$lock"
  else
    require_secure_file "$lock" 'source hub lifetime lock' 600
    exec {SOURCE_LOCK_FD}<"$lock"
  fi
  flock -n "$SOURCE_LOCK_FD" || die 'the source store lifetime lock is held by a hub/restore process'
}

declare -a LINK_NAMES=(pizarra.conf pzweb.conf store)
declare -a LINK_EXPECTED=("$SOURCE_CONF/pizarra.conf" "$SOURCE_CONF/pzweb.conf" "$SOURCE_CONF/store")
declare -a LINK_PRESENT=()
declare -a LINK_TARGET=()
LEGACY_LOG=''
LOG_RETIRE_DONE=0

inspect_runtime_links() {
  local i link raw target expected entry name known
  if [[ ! -e $RUNTIME_LINK_DIR && ! -L $RUNTIME_LINK_DIR ]]; then
    for i in "${!LINK_NAMES[@]}"; do
      LINK_PRESENT[$i]=0
      LINK_TARGET[$i]=${LINK_EXPECTED[$i]}
    done
    return 0
  fi
  [[ -d $RUNTIME_LINK_DIR && ! -L $RUNTIME_LINK_DIR ]] ||
    die "repository conf path is not a real directory: $RUNTIME_LINK_DIR"

  # Parent removal is allowed only when the directory is exactly the temporary
  # compatibility layout. Detect ordinary and dot entries before archiving, so
  # an unknown file can never be stranded after source retirement.
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    known=0
    for i in "${!LINK_NAMES[@]}"; do
      [[ $name != "${LINK_NAMES[$i]}" ]] || known=1
    done
    ((known)) || die "unexpected entry in repository conf directory; refusing retirement: $entry"
  done < <(find "$RUNTIME_LINK_DIR" -mindepth 1 -maxdepth 1 -print0)

  for i in "${!LINK_NAMES[@]}"; do
    link=$RUNTIME_LINK_DIR/${LINK_NAMES[$i]}
    expected=${LINK_EXPECTED[$i]}
    if [[ -e $link || -L $link ]]; then
      [[ -L $link ]] || die "refusing non-symlink runtime path: $link"
      raw=$(readlink -- "$link") || die "cannot read compatibility link: $link"
      target=$(readlink -m -- "$(dirname -- "$link")/$raw")
      path_within "$target" "$SOURCE_CONF" ||
        die "compatibility link points outside the source archive: $link -> $target"
      [[ $target == "$expected" ]] ||
        die "compatibility link has an unexpected target: $link -> $target (expected $expected)"
      if [[ -d $SOURCE_CONF ]]; then
        [[ -e $target || -L $target ]] || die "compatibility link target is missing: $link -> $target"
      fi
      LINK_PRESENT[$i]=1
      LINK_TARGET[$i]=$target
    else
      LINK_PRESENT[$i]=0
      LINK_TARGET[$i]=$expected
    fi
  done
}

inspect_legacy_log() {
  local configured resolved
  LEGACY_LOG=''
  [[ -f $SOURCE_CONF/pizarra.conf ]] || return 0
  configured=$(ini_get "$SOURCE_CONF/pizarra.conf" log path || true)
  [[ -n $configured ]] || return 0
  # TPzLog passes this value directly to AssignFile; a relative name therefore
  # depends on the old process working directory, not on the INI directory.
  # There is no safe offline target to infer, so retire only an explicit path.
  if [[ $configured != /* ]]; then
    say "relative legacy log path is ambiguous and will not be retired automatically: $configured"
    return 0
  fi
  resolved=$(readlink -m -- "$configured")
  if ! path_within "$resolved" "$PIZARRA_REPO_ROOT"; then
    say "legacy log is outside the repository and will not be retired: $resolved"
    return 0
  fi
  # A log already inside .private/conf is part of the main archive and removal.
  if path_within "$resolved" "$SOURCE_CONF"; then
    return 0
  fi
  if [[ ! -e $resolved && ! -L $resolved ]]; then
    say "repository-local legacy log is already absent: $resolved"
    return 0
  fi
  reject_symlink_components "$resolved" 'legacy repository log'
  [[ -f $resolved && ! -L $resolved ]] ||
    die "repository-local legacy log is not a regular file: $resolved"
  require_secure_file "$LOG_PATH" 'canonical pizarra log'
  LEGACY_LOG=$resolved
}

record_get() {
  local file=$1 key=$2
  awk -v wanted="$key" 'index($0,wanted "=")==1 {print substr($0,length(wanted)+2); exit}' "$file"
}

validate_archive_record() {
  local record=$1 expected_manifest=${2:-} archive manifest source_manifest source mode legacy_log
  [[ -f $record && ! -L $record ]] || return 1
  mode=$(stat -Lc '%a' -- "$record")
  [[ $mode == 600 ]] || return 1
  [[ $(record_get "$record" version) == 1 ]] || return 1
  source=$(record_get "$record" source)
  archive=$(record_get "$record" archive)
  [[ $source == "$SOURCE_CONF" ]] || return 1
  [[ $archive == "$BACKUP_ROOT"/retired-source-conf-* ]] || return 1
  [[ $(dirname -- "$archive") == "$BACKUP_ROOT" ]] || return 1
  [[ -d $archive && ! -L $archive ]] || return 1
  mode=$(stat -Lc '%a' -- "$archive")
  (( (8#$mode & 0077) == 0 )) || return 1
  [[ -d $archive/source-conf && ! -L $archive/source-conf ]] || return 1
  manifest=$archive.MANIFEST
  source_manifest=$archive.SOURCE-CONF.MANIFEST
  [[ -f $manifest && ! -L $manifest ]] || return 1
  [[ -f $source_manifest && ! -L $source_manifest ]] || return 1
  [[ $(stat -Lc '%a' -- "$manifest") == 600 ]] || return 1
  [[ $(stat -Lc '%a' -- "$source_manifest") == 600 ]] || return 1
  manifest_tree "$archive" "$WORK/archive-current" || return 1
  cmp -s -- "$manifest" "$WORK/archive-current" || return 1
  manifest_tree "$archive/source-conf" "$WORK/archive-source-current" || return 1
  cmp -s -- "$source_manifest" "$WORK/archive-source-current" || return 1
  if [[ -n $expected_manifest ]]; then
    cmp -s -- "$source_manifest" "$expected_manifest" || return 1
  fi
  legacy_log=$(record_get "$record" legacy_log)
  if [[ -n $legacy_log ]]; then
    [[ -f $archive/legacy-repo-log/log && ! -L $archive/legacy-repo-log/log ]] || return 1
  fi
  if [[ -n $expected_manifest && -n $LEGACY_LOG ]]; then
    [[ $legacy_log == "$LEGACY_LOG" ]] || return 1
    cmp -s -- "$LEGACY_LOG" "$archive/legacy-repo-log/log" || return 1
  fi
  printf '%s\n' "$archive"
}

FOUND_ARCHIVE=''
find_verified_archive() {
  local expected_manifest=${1:-} record candidate found=''
  FOUND_ARCHIVE=''
  [[ ! -e $BACKUP_ROOT && ! -L $BACKUP_ROOT ]] && return 1
  require_real_directory "$BACKUP_ROOT" 'retirement rollback root'
  shopt -s nullglob
  local -a records=("$BACKUP_ROOT"/retired-source-conf-*.retirement-record)
  shopt -u nullglob
  for record in "${records[@]}"; do
    candidate=$(validate_archive_record "$record" "$expected_manifest" || true)
    [[ -n $candidate ]] || continue
    if [[ -n $found && $found != "$candidate" ]]; then
      warn "multiple verified retirement archives exist; using newest encountered: $candidate"
    fi
    found=$candidate
  done
  [[ -n $found ]] || return 1
  FOUND_ARCHIVE=$found
}

archive_sqlite_check() {
  local archive=$1 db integrity foreign
  for db in "$archive"/store/*.sqlite; do
    [[ -e $db || -L $db ]] || continue
    [[ -f $db && ! -L $db ]] || die "archived SQLite is not a regular file: $db"
    integrity=$(sqlite_scalar "$db" 'PRAGMA integrity_check;')
    [[ $integrity == ok ]] || die "archived SQLite failed integrity_check: $db"
    foreign=$(sqlite_scalar "$db" 'PRAGMA foreign_key_check;')
    [[ -z $foreign ]] || die "archived SQLite failed foreign_key_check: $db"
  done
}

PUBLISHED_ARCHIVE=''
publish_archive() {
  local source_manifest=$1 staging final manifest_tmp source_manifest_tmp record_tmp i
  staging=$BACKUP_ROOT/.retired-source-conf-staging-$STAMP-$$
  final=$BACKUP_ROOT/retired-source-conf-$STAMP-$$
  [[ ! -e $staging && ! -L $staging ]] || die "archive staging already exists: $staging"
  [[ ! -e $final && ! -L $final ]] || die "archive target already exists: $final"
  install -d -m 700 "$staging" "$staging/source-conf"
  cp -a -- "$SOURCE_CONF/." "$staging/source-conf/" ||
    die "archive copy failed; incomplete staging was retained at $staging"
  chmod 700 "$staging"
  chmod --reference="$SOURCE_CONF" "$staging/source-conf"

  manifest_tree "$SOURCE_CONF" "$WORK/source-after-copy" || die 'cannot re-read source after archive copy'
  cmp -s -- "$source_manifest" "$WORK/source-after-copy" ||
    die "source changed during archive copy; staging was retained at $staging"
  manifest_tree "$staging/source-conf" "$WORK/archive-staging" || die 'cannot manifest archive staging'
  cmp -s -- "$source_manifest" "$WORK/archive-staging" ||
    die "archive manifest differs from source; staging was retained at $staging"
  archive_sqlite_check "$staging/source-conf"

  if [[ -n $LEGACY_LOG ]]; then
    install -d -m 700 "$staging/legacy-repo-log"
    cp -a -- "$LEGACY_LOG" "$staging/legacy-repo-log/log" ||
      die "legacy log copy failed; incomplete staging was retained at $staging"
    cmp -s -- "$LEGACY_LOG" "$staging/legacy-repo-log/log" ||
      die "legacy log differs after archive copy; staging was retained at $staging"
  fi
  manifest_tree "$staging" "$WORK/archive-payload" || die 'cannot manifest complete archive payload'

  find "$staging" -type f -exec sync -d -- {} +
  sync -f -- "$staging"
  mv -- "$staging" "$final"
  sync -f -- "$BACKUP_ROOT"

  manifest_tmp=$final.MANIFEST.new-$$
  install -m 600 -- "$WORK/archive-payload" "$manifest_tmp"
  mv -- "$manifest_tmp" "$final.MANIFEST"
  source_manifest_tmp=$final.SOURCE-CONF.MANIFEST.new-$$
  install -m 600 -- "$source_manifest" "$source_manifest_tmp"
  mv -- "$source_manifest_tmp" "$final.SOURCE-CONF.MANIFEST"
  record_tmp=$final.retirement-record.new-$$
  {
    printf 'version=1\n'
    printf 'created=%s\n' "$STAMP"
    printf 'source=%s\n' "$SOURCE_CONF"
    printf 'archive=%s\n' "$final"
    printf 'legacy_log=%s\n' "$LEGACY_LOG"
    for i in "${!LINK_NAMES[@]}"; do
      printf 'link_%s=%s\n' "${LINK_NAMES[$i]}" "${LINK_TARGET[$i]}"
    done
  } >"$record_tmp"
  chmod 600 "$record_tmp"
  sync -d -- "$record_tmp"
  mv -- "$record_tmp" "$final.retirement-record"
  sync -f -- "$BACKUP_ROOT"

  manifest_tree "$final" "$WORK/archive-final" || die 'cannot manifest published archive'
  cmp -s -- "$final.MANIFEST" "$WORK/archive-final" ||
    die 'published archive payload changed after durable rename; source was retained'
  manifest_tree "$final/source-conf" "$WORK/archive-source-final" ||
    die 'cannot manifest published source-conf archive'
  cmp -s -- "$source_manifest" "$WORK/archive-source-final" ||
    die 'published source-conf archive changed after durable rename; source was retained'
  PUBLISHED_ARCHIVE=$final
}

remove_archived_source() {
  local archive=$1 quarantine manifest_now
  quarantine=$PIZARRA_REPO_ROOT/.private/.pizarra-conf-retiring-$STAMP-$$
  [[ ! -e $quarantine && ! -L $quarantine ]] ||
    die "source quarantine already exists: $quarantine"
  manifest_now=$WORK/source-before-remove
  manifest_tree "$SOURCE_CONF" "$manifest_now" || die 'cannot manifest source before removal'
  cmp -s -- "$archive.SOURCE-CONF.MANIFEST" "$manifest_now" ||
    die 'source no longer matches the verified archive; refusing removal'

  scan_runtime_users
  mv -- "$SOURCE_CONF" "$quarantine" || die 'could not atomically quarantine the archived source'
  sync -f -- "$PIZARRA_REPO_ROOT/.private"
  manifest_tree "$quarantine" "$WORK/quarantine" ||
    die "cannot verify quarantined source; retained at $quarantine"
  cmp -s -- "$archive.SOURCE-CONF.MANIFEST" "$WORK/quarantine" ||
    die "quarantined source differs from archive; retained at $quarantine"

  find "$quarantine" -xdev -depth -mindepth 1 -delete ||
    die "could not remove every archived source entry; remainder retained at $quarantine"
  rmdir "$quarantine" || die "could not remove empty source quarantine: $quarantine"
  sync -f -- "$PIZARRA_REPO_ROOT/.private"
  say "archived source tree removed from repository: $SOURCE_CONF"
}

load_recorded_legacy_log() {
  local archive=$1 record declared
  record=$archive.retirement-record
  declared=$(record_get "$record" legacy_log)
  LEGACY_LOG=''
  [[ -n $declared ]] || return 0
  [[ $declared == /* && $declared != *$'\n'* ]] ||
    die 'retirement record contains an invalid legacy log path'
  path_within "$declared" "$PIZARRA_REPO_ROOT" ||
    die "retirement record legacy log is outside the repository: $declared"
  [[ $declared != "$PIZARRA_REPO_ROOT" ]] ||
    die 'retirement record attempts to name the repository root as a log'
  path_within "$declared" "$SOURCE_CONF" &&
    die 'retirement record duplicates a source-conf path as the separate log'
  LEGACY_LOG=$declared
}

remove_archived_legacy_log() {
  local archive=$1 archived_log quarantine log_dir log_name
  load_recorded_legacy_log "$archive"
  [[ -n $LEGACY_LOG ]] || return 0
  archived_log=$archive/legacy-repo-log/log
  [[ -f $archived_log && ! -L $archived_log ]] ||
    die "verified archive lacks the recorded legacy log: $archived_log"
  if [[ ! -e $LEGACY_LOG && ! -L $LEGACY_LOG ]]; then
    say "legacy repository log was already retired: $LEGACY_LOG"
    return 0
  fi
  reject_symlink_components "$LEGACY_LOG" 'legacy repository log before removal'
  [[ -f $LEGACY_LOG && ! -L $LEGACY_LOG ]] ||
    die "legacy repository log changed into a non-regular file: $LEGACY_LOG"
  cmp -s -- "$LEGACY_LOG" "$archived_log" ||
    die 'legacy repository log changed after archival; refusing removal'
  scan_runtime_users

  log_dir=$(dirname -- "$LEGACY_LOG")
  log_name=${LEGACY_LOG##*/}
  quarantine=$log_dir/.${log_name}.pizarra-retiring-$STAMP-$$
  [[ ! -e $quarantine && ! -L $quarantine ]] ||
    die "legacy-log quarantine already exists: $quarantine"
  mv -- "$LEGACY_LOG" "$quarantine" || die 'could not quarantine the archived legacy log'
  sync -f -- "$log_dir"
  cmp -s -- "$quarantine" "$archived_log" ||
    die "quarantined legacy log differs from archive; retained at $quarantine"
  unlink -- "$quarantine"
  sync -f -- "$log_dir"
  say "archived legacy log removed from repository: $LEGACY_LOG"
}

remove_runtime_links() {
  local archive=$1 i link target rel archived_target unexpected
  for i in "${!LINK_NAMES[@]}"; do
    link=$RUNTIME_LINK_DIR/${LINK_NAMES[$i]}
    [[ -e $link || -L $link ]] || continue
    [[ -L $link ]] || die "runtime link changed into a non-symlink; refusing: $link"
    target=$(readlink -m -- "$(dirname -- "$link")/$(readlink -- "$link")")
    [[ $target == "${LINK_TARGET[$i]}" ]] ||
      die "runtime link target changed during retirement: $link -> $target"
    path_within "$target" "$SOURCE_CONF" ||
      die "runtime link target escaped archived source: $link -> $target"
    rel=${target#"$SOURCE_CONF"/}
    archived_target=$archive/source-conf/$rel
    [[ -e $archived_target || -L $archived_target ]] ||
      die "verified archive does not contain link target: $archived_target"
    unlink -- "$link"
    say "compatibility link removed: $link"
  done
  if [[ -d $RUNTIME_LINK_DIR && ! -L $RUNTIME_LINK_DIR ]]; then
    unexpected=$(find "$RUNTIME_LINK_DIR" -mindepth 1 -maxdepth 1 -print -quit)
    [[ -z $unexpected ]] ||
      die "repository conf directory gained an unexpected entry; retained: $unexpected"
    sync -f -- "$RUNTIME_LINK_DIR"
    rmdir -- "$RUNTIME_LINK_DIR" ||
      die "repository conf directory is not empty; it was retained: $RUNTIME_LINK_DIR"
    sync -f -- "$PIZARRA_REPO_ROOT"
    say "empty compatibility directory removed: $RUNTIME_LINK_DIR"
  elif [[ -e $RUNTIME_LINK_DIR || -L $RUNTIME_LINK_DIR ]]; then
    die "repository conf path changed before removal: $RUNTIME_LINK_DIR"
  else
    say "compatibility directory was already absent: $RUNTIME_LINK_DIR"
  fi
}

validate_canonical_layout
inspect_runtime_links
examples_manifest "$WORK/examples-before"

if [[ -d $SOURCE_CONF ]]; then
  [[ ! -L $SOURCE_CONF ]] || die "source configuration tree is a symlink: $SOURCE_CONF"
  reject_symlink_components "$SOURCE_CONF" 'source configuration tree'
  reject_nested_mounts
  if [[ -n $(find "$SOURCE_CONF" -mindepth 1 ! -type d ! -type f ! -type l -print -quit) ]]; then
    die "source tree contains a socket, device, or other unsupported entry: $SOURCE_CONF"
  fi
  validate_source_shape_in_canonical
  inspect_legacy_log
  acquire_source_lock
  scan_runtime_users
  manifest_tree "$SOURCE_CONF" "$WORK/source" || die 'cannot build source archive manifest'
  ARCHIVE=''
  if find_verified_archive "$WORK/source"; then
    ARCHIVE=$FOUND_ARCHIVE
  fi
  if [[ -n $ARCHIVE ]]; then
    say "reusing already verified retirement archive: $ARCHIVE"
  elif ((CONFIRM == 0)); then
    say "dry run complete: canonical state and source quiescence checks passed"
    say "would archive $SOURCE_CONF under $BACKUP_ROOT/retired-source-conf-$STAMP-<pid>"
    say "would then remove only the three repository runtime links and their empty conf directory"
    exit 0
  else
    [[ -d $BACKUP_ROOT ]] || install -d -m 700 "$BACKUP_ROOT"
    require_real_directory "$BACKUP_ROOT" 'retirement rollback root'
    publish_archive "$WORK/source"
    ARCHIVE=$PUBLISHED_ARCHIVE
    say "verified retirement archive published: $ARCHIVE"
  fi

  if ((CONFIRM == 0)); then
    say "dry run complete: existing archive matches source; no files changed"
    exit 0
  fi
  remove_archived_legacy_log "$ARCHIVE"
  LOG_RETIRE_DONE=1
  remove_archived_source "$ARCHIVE"
else
  ARCHIVE=''
  if find_verified_archive; then
    ARCHIVE=$FOUND_ARCHIVE
  fi
  [[ -n $ARCHIVE ]] ||
    die "source tree is absent but no verified retirement archive records it: $SOURCE_CONF"
  load_recorded_legacy_log "$ARCHIVE"
  scan_runtime_users
  if ((CONFIRM == 0)); then
    say "dry run complete: source is already archived at $ARCHIVE"
    say 'would remove any remaining verified compatibility symlinks and their empty conf directory; no examples are touched'
    exit 0
  fi
  say "source tree was already retired; using verified archive: $ARCHIVE"
fi

if ((LOG_RETIRE_DONE == 0)); then
  remove_archived_legacy_log "$ARCHIVE"
fi
remove_runtime_links "$ARCHIVE"
examples_manifest "$WORK/examples-after"
cmp -s -- "$WORK/examples-before" "$WORK/examples-after" ||
  die 'a public .example file changed during retirement'
say "retirement complete; rollback archive: $ARCHIVE"
say 'public examples and .gitignore were not modified'
