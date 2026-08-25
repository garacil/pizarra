#!/usr/bin/env bash
# Safely migrate a pizarra installation to one system-owned layout.
#
# This script copies; it never removes the source tree, stops a process, or
# touches a tmux session.  SQLite files are captured with the CLI online-backup
# API, so committed WAL data is included in a coherent destination database.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

DEST_ETC=${DEST_ETC:-/etc}
DEST_VAR=${DEST_VAR:-/var}
SOURCE_ETC=${SOURCE_ETC:-/etc}
SOURCE_PIZARRA_CONF=${SOURCE_PIZARRA_CONF:-}
SOURCE_STORE=${SOURCE_STORE:-}
SOURCE_RELEASES=${SOURCE_RELEASES:-}
SOURCE_PZWEB_CONF=${SOURCE_PZWEB_CONF:-}
WEB_ASSETS_DIR=${WEB_ASSETS_DIR:-/usr/local/share/pizarra/web/apps}
PIZARRA_OWNER=${PIZARRA_OWNER:-root}
PIZARRA_GROUP=${PIZARRA_GROUP:-root}
PZWEB_OWNER=${PZWEB_OWNER:-root}
PZWEB_GROUP=${PZWEB_GROUP:-root}
TIZA_OWNER=${TIZA_OWNER:-}
TIZA_GROUP=${TIZA_GROUP:-}
AGENTS_OWNER=${AGENTS_OWNER:-}
AGENTS_GROUP=${AGENTS_GROUP:-}
DRY_RUN=0
REPLACE_STATE=0

usage() {
  cat <<'EOF'
Usage: sudo scripts/migrate-to-system-layout.sh [options]

Copies the newest live pizarra configuration to /etc/pizarra, captures state
with SQLite online backups in /var/lib/pizarra, and rewrites [store] dir,
[server] releases, and [log] path. Sources are retained and no service or tmux
session is stopped.

Options:
  --source-config FILE   select pizarra.conf explicitly
  --source-store DIR     select its state directory explicitly
  --source-releases DIR  select an existing release-artifact directory
  --source-pzweb FILE    select pzweb.conf explicitly
  --source-etc DIR       legacy config root to scan (default: /etc)
  --replace-state        replace a non-empty destination after moving it intact
                         into the rollback bundle
  --dry-run              build and verify the snapshot, but install nothing
  -h, --help             show this help

Test/non-root overrides:
  DEST_ETC=/tmp/layout/etc DEST_VAR=/tmp/layout/var SOURCE_ETC=/tmp/old/etc \
    scripts/migrate-to-system-layout.sh --source-config /tmp/old/pizarra.conf
  WEB_ASSETS_DIR may override /usr/local/share/pizarra/web/apps in an isolated
  test or nonstandard installation.

Ownership defaults to root:root, matching the current tmux-run hub. If systemd
runs the daemons as dedicated users, set for example:
  PIZARRA_OWNER=pizarra PIZARRA_GROUP=pizarra \
  PZWEB_OWNER=pzweb PZWEB_GROUP=pzweb sudo -E scripts/migrate-to-system-layout.sh
The named accounts/groups must already exist. Non-root DEST_* test runs verify
modes and data but deliberately do not attempt chown.
The config directory is PIZARRA_OWNER:PIZARRA_GROUP mode 0711 so the hub can
atomically rewrite its migrated header; agents/ remains root:root mode 0711.

Tiza/Telegram and agent configs retain their resolvable source ownership
(falling back to root:root). Override it explicitly with TIZA_OWNER/GROUP or
AGENTS_OWNER/GROUP; either half may be omitted to retain that half from source.

Canonical results are $DEST_ETC/pizarra/{pizarra,pzweb,tiza...}.conf,
$DEST_ETC/pizarra/agents/, $DEST_VAR/lib/pizarra (including releases/), and
$DEST_VAR/log/pizarra/pizarra.log. A rollback bundle is written beside state in
$DEST_VAR/lib/pizarra-migration-backups/. The obsolete registry.ini is retained
only as legacy/registry.ini.pre-sqlite (archival, never authoritative), while
apps.sqlite is retained explicitly for compatibility. A root-owned record under
the rollback directory pins source lineage and detects canonical writes. Rerun
after a human stops the old hub to capture writes made after an earlier live
snapshot; this script never stops or restarts it itself.
EOF
}

say() { printf '%s: %s\n' "$PROGRAM" "$*"; }
warn() { printf '%s: WARNING: %s\n' "$PROGRAM" "$*" >&2; }
die() { printf '%s: ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --source-config)
      (($# >= 2)) || die '--source-config needs a file'
      SOURCE_PIZARRA_CONF=$2
      shift 2
      ;;
    --source-store)
      (($# >= 2)) || die '--source-store needs a directory'
      SOURCE_STORE=$2
      shift 2
      ;;
    --source-releases)
      (($# >= 2)) || die '--source-releases needs a directory'
      SOURCE_RELEASES=$2
      shift 2
      ;;
    --source-pzweb)
      (($# >= 2)) || die '--source-pzweb needs a file'
      SOURCE_PZWEB_CONF=$2
      shift 2
      ;;
    --source-etc)
      (($# >= 2)) || die '--source-etc needs a directory'
      SOURCE_ETC=$2
      shift 2
      ;;
    --replace-state) REPLACE_STATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

for tool in awk cat chmod chown cmp cp date dirname find fuser getent id install \
            mktemp mv readlink rmdir sha256sum sort sqlite3 stat sync xargs; do
  command -v "$tool" >/dev/null 2>&1 || die "required command is missing: $tool"
done

validate_base_path() {
  local label=$1 value=$2 wrapped
  [[ $value == /* ]] || die "$label must be an absolute path"
  [[ $value != / ]] || die "$label may not be /"
  [[ $value != */ ]] || die "$label may not have a trailing slash"
  [[ $value != *//* ]] || die "$label may not contain repeated slashes"
  [[ $value != *$'\n'* ]] || die "$label may not contain newlines"
  wrapped=/${value#/}/
  [[ $wrapped != */./* && $wrapped != */../* ]] ||
    die "$label may not contain . or .. components"
}

validate_base_path DEST_ETC "$DEST_ETC"
validate_base_path DEST_VAR "$DEST_VAR"
validate_base_path SOURCE_ETC "$SOURCE_ETC"
validate_base_path WEB_ASSETS_DIR "$WEB_ASSETS_DIR"
[[ -z $SOURCE_RELEASES ]] || validate_base_path SOURCE_RELEASES "$SOURCE_RELEASES"
getent passwd "$PIZARRA_OWNER" >/dev/null || die "PIZARRA_OWNER does not exist: $PIZARRA_OWNER"
getent group "$PIZARRA_GROUP" >/dev/null || die "PIZARRA_GROUP does not exist: $PIZARRA_GROUP"
getent passwd "$PZWEB_OWNER" >/dev/null || die "PZWEB_OWNER does not exist: $PZWEB_OWNER"
getent group "$PZWEB_GROUP" >/dev/null || die "PZWEB_GROUP does not exist: $PZWEB_GROUP"
[[ -z $TIZA_OWNER ]] || getent passwd "$TIZA_OWNER" >/dev/null || die "TIZA_OWNER does not exist: $TIZA_OWNER"
[[ -z $TIZA_GROUP ]] || getent group "$TIZA_GROUP" >/dev/null || die "TIZA_GROUP does not exist: $TIZA_GROUP"
[[ -z $AGENTS_OWNER ]] || getent passwd "$AGENTS_OWNER" >/dev/null || die "AGENTS_OWNER does not exist: $AGENTS_OWNER"
[[ -z $AGENTS_GROUP ]] || getent group "$AGENTS_GROUP" >/dev/null || die "AGENTS_GROUP does not exist: $AGENTS_GROUP"
RUNNING_AS_ROOT=0
(( $(id -u) == 0 )) && RUNNING_AS_ROOT=1

CONFIG_DIR=$DEST_ETC/pizarra
STATE_DIR=$DEST_VAR/lib/pizarra
RELEASE_DIR=$STATE_DIR/releases
LOG_DIR=$DEST_VAR/log/pizarra
LOG_PATH=$LOG_DIR/pizarra.log
BACKUP_ROOT=$DEST_VAR/lib/pizarra-migration-backups
TRUSTED_STATE_RECORD=$BACKUP_ROOT/installed-state.record
CONFIG_SOURCE_WAS_EXPLICIT=0
[[ -z $SOURCE_PIZARRA_CONF ]] || CONFIG_SOURCE_WAS_EXPLICIT=1
RELEASE_SOURCE_WAS_EXPLICIT=0
[[ -z $SOURCE_RELEASES ]] || RELEASE_SOURCE_WAS_EXPLICIT=1
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-layout.XXXXXXXX")
cleanup() {
  case ${WORK:-} in
    "${TMPDIR:-/tmp}"/pizarra-layout.*)
      [[ -d $WORK ]] && find "$WORK" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ -d $WORK ]] && rmdir "$WORK" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

real_existing() { readlink -f -- "$1"; }

same_existing_path() {
  [[ -e $1 && -e $2 ]] || return 1
  [[ $(real_existing "$1") == $(real_existing "$2") ]]
}

mtime() { stat -Lc '%Y' -- "$1"; }

# Create a directory when missing without ever chmodding an existing shared
# parent such as /var/lib. Only paths owned by this migration use managed=1.
ensure_directory() {
  local path=$1 mode=$2 managed=${3:-0}
  [[ ! -L $path ]] || die "directory path may not be a symlink: $path"
  if [[ -e $path ]]; then
    [[ -d $path ]] || die "directory path is occupied by a non-directory: $path"
  else
    install -d -m "$mode" "$path"
  fi
  ((managed == 0)) || chmod "$mode" "$path"
}

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

validate_file_target() {
  local path=$1 label=$2
  reject_symlink_components "$path" "$label"
  [[ ! -e $path || -f $path ]] || die "$label target is not a regular file: $path"
}

require_writable_destination() {
  local path=$1 label=$2 probe
  probe=$path
  while [[ ! -e $probe ]]; do
    probe=$(dirname -- "$probe")
  done
  [[ -d $probe && -w $probe && -x $probe ]] ||
    die "$label is not writable through its nearest existing parent: $probe"
}

durable_file() {
  local path=$1
  sync -d -- "$path"
  sync -f -- "$(dirname -- "$path")"
}

durable_directory() { sync -f -- "$1"; }

state_has_open_handles() {
  local dir=$1 file
  local -a live_files=()
  fuser -s "$dir" 2>/dev/null && return 0
  shopt -s nullglob
  live_files=("$dir"/*.sqlite "$dir"/*.sqlite-wal "$dir"/*.sqlite-shm \
              "$dir"/.pizarra-hub.lock \
              "$dir"/messages.jsonl "$dir"/state.json "$dir"/tareas.json \
              "$dir"/workflows.json)
  shopt -u nullglob
  for file in "${live_files[@]}"; do
    [[ -e $file ]] || continue
    fuser -s "$file" 2>/dev/null && return 0
  done
  return 1
}

for destination_dir in "$CONFIG_DIR" "$CONFIG_DIR/agents" "$STATE_DIR" "$RELEASE_DIR" \
                       "$LOG_DIR" "$BACKUP_ROOT"; do
  reject_symlink_components "$destination_dir" 'canonical destination'
  [[ ! -e $destination_dir || -d $destination_dir ]] ||
    die "canonical directory target is not a directory: $destination_dir"
done
validate_file_target "$CONFIG_DIR/pizarra.conf" 'pizarra config'
validate_file_target "$CONFIG_DIR/pzweb.conf" 'pzweb config'
validate_file_target "$LOG_PATH" 'pizarra log'
validate_file_target "$TRUSTED_STATE_RECORD" 'trusted migration state record'
require_writable_destination "$CONFIG_DIR" 'configuration destination'
require_writable_destination "$(dirname -- "$STATE_DIR")" 'state destination'
require_writable_destination "$LOG_DIR" 'log destination'
require_writable_destination "$BACKUP_ROOT" 'rollback destination'

trusted_metadata_file() {
  local file=$1 expected_uid mode parent
  [[ -f $file && ! -L $file ]] || return 1
  expected_uid=$(id -u)
  parent=$(dirname -- "$file")
  [[ $(stat -Lc '%u' -- "$file") == "$expected_uid" ]] ||
    die "trusted metadata has the wrong owner: $file"
  [[ $(stat -Lc '%u' -- "$parent") == "$expected_uid" ]] ||
    die "trusted metadata directory has the wrong owner: $parent"
  mode=$(stat -Lc '%a' -- "$file")
  (( (8#$mode & 0022) == 0 )) || die "trusted metadata is group/other writable: $file"
  mode=$(stat -Lc '%a' -- "$parent")
  (( (8#$mode & 0022) == 0 )) || die "trusted metadata directory is group/other writable: $parent"
}

trusted_metadata_directory() {
  local dir=$1 expected_uid mode
  [[ -d $dir && ! -L $dir ]] || return 1
  expected_uid=$(id -u)
  [[ $(stat -Lc '%u' -- "$dir") == "$expected_uid" ]] ||
    die "trusted metadata directory has the wrong owner: $dir"
  mode=$(stat -Lc '%a' -- "$dir")
  (( (8#$mode & 0022) == 0 )) ||
    die "trusted metadata directory is group/other writable: $dir"
}

trusted_record_get() {
  local key=$1
  awk -v wanted="$key" '
    /^--manifest--$/ { exit }
    index($0, wanted "=")==1 { print substr($0, length(wanted)+2); exit }
  ' "$TRUSTED_STATE_RECORD"
}

TRUSTED_RECORD_PRESENT=0
RECORDED_CONFIG_SOURCE=''
RECORDED_STATE_SOURCE=''
if [[ -e $BACKUP_ROOT ]]; then
  trusted_metadata_directory "$BACKUP_ROOT" ||
    die "trusted metadata directory is unsafe: $BACKUP_ROOT"
fi
if [[ -e $TRUSTED_STATE_RECORD ]]; then
  trusted_metadata_file "$TRUSTED_STATE_RECORD" ||
    die "trusted migration state record is not a safe regular file: $TRUSTED_STATE_RECORD"
  RECORDED_CONFIG_SOURCE=$(trusted_record_get config_source)
  RECORDED_STATE_SOURCE=$(trusted_record_get state_source)
  [[ $RECORDED_CONFIG_SOURCE == /* && $RECORDED_CONFIG_SOURCE != *$'\n'* ]] ||
    die 'trusted migration record has an invalid config source'
  [[ $RECORDED_STATE_SOURCE == /* && $RECORDED_STATE_SOURCE != *$'\n'* ]] ||
    die 'trusted migration record has an invalid state source'
  TRUSTED_RECORD_PRESENT=1
fi

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
  [[ $value == /* ]] ||
    die "$label must be absolute; migration will not guess a process working directory"
  normalized=$value
  while [[ $normalized != / && $normalized == */ ]]; do
    normalized=${normalized%/}
  done
  [[ $normalized != / ]] ||
    die "$label may not be the filesystem root; use a dedicated external directory or mount"
}

registry_sections() {
  awk '
    /^[[:space:]]*\[(team:|group:|project:|app:)/ { n++ }
    END { print n+0 }
  ' "$1"
}

# Pick the newest distinct file. Equal-time, different-content candidates are
# ambiguous and require an explicit choice instead of a silent guess.
choose_newest_file() {
  local explicit=$1 label=$2
  shift 2
  local candidate resolved best='' best_resolved='' best_time=-1 now ambiguous=0
  local -A seen=()

  if [[ -n $explicit ]]; then
    [[ -f $explicit ]] || die "$label source does not exist: $explicit"
    printf '%s\n' "$explicit"
    return
  fi

  for candidate in "$@"; do
    [[ -f $candidate ]] || continue
    resolved=$(real_existing "$candidate")
    [[ ${seen[$resolved]+yes} ]] && continue
    seen[$resolved]=1
    now=$(mtime "$candidate")
    say "$label candidate: $candidate (mtime=$now)" >&2
    if ((now > best_time)); then
      best=$candidate
      best_resolved=$resolved
      best_time=$now
      ambiguous=0
    elif ((now == best_time)) && [[ $resolved != "$best_resolved" ]] &&
         ! cmp -s -- "$candidate" "$best"; then
      ambiguous=1
    fi
  done
  [[ -n $best ]] || return 1
  ((ambiguous == 0)) || die "ambiguous $label sources have equal mtimes; use an explicit source option"
  printf '%s\n' "$best"
}

if ((CONFIG_SOURCE_WAS_EXPLICIT == 0 && TRUSTED_RECORD_PRESENT)); then
  [[ -f $RECORDED_CONFIG_SOURCE ]] ||
    die "recorded original config source is unavailable; select the new authority explicitly with --source-config: $RECORDED_CONFIG_SOURCE"
  SOURCE_PIZARRA_CONF=$RECORDED_CONFIG_SOURCE
  say "using root-trusted original config source: $SOURCE_PIZARRA_CONF"
fi

PIZARRA_SOURCE=$(choose_newest_file "$SOURCE_PIZARRA_CONF" 'pizarra config' \
  "$REPO_ROOT/conf/pizarra.conf" \
  "$REPO_ROOT/.private/conf/pizarra.conf" \
  "$CONFIG_DIR/pizarra.conf" \
  "$SOURCE_ETC/pizarra/pizarra.conf") ||
  die 'no pizarra.conf found; use --source-config'
PIZARRA_SOURCE_REAL=$(real_existing "$PIZARRA_SOURCE")
say "selected pizarra config: $PIZARRA_SOURCE ($(registry_sections "$PIZARRA_SOURCE") registry sections)"
SOURCE_HUB_SHARED=$(ini_get "$PIZARRA_SOURCE" shared dir || true)
validate_shared_path_value 'configured [shared] dir' "$SOURCE_HUB_SHARED"

resolve_store_value() {
  local config=$1 value
  value=$(ini_get "$config" store dir || true)
  if [[ -z $value ]]; then
    printf '%s/store\n' "$(cd -- "$(dirname -- "$config")" && pwd -P)"
  elif [[ $value == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$(cd -- "$(dirname -- "$config")" && pwd -P)" "$value"
  fi
}

state_score() {
  local dir=$1 score=0 n
  [[ -f $dir/org.sqlite ]] && ((score+=100))
  [[ -f $dir/work.sqlite ]] && ((score+=50))
  [[ -f $dir/apps.sqlite ]] && ((score+=25))
  [[ -f $dir/messages.jsonl ]] && ((score+=20))
  [[ -f $dir/state.json ]] && ((score+=10))
  [[ -f $dir/tareas.json ]] && ((score+=10))
  [[ -f $dir/workflows.json ]] && ((score+=10))
  n=$(find "$dir" -type f 2>/dev/null | awk 'END { print NR+0 }')
  ((n > 99)) && n=99
  printf '%d\n' $((score+n))
}

choose_state_dir() {
  local explicit=$1
  shift
  local candidate resolved best='' best_score=-1 best_time=-1 score now
  local -A seen=()
  if [[ -n $explicit ]]; then
    [[ -d $explicit ]] || die "state source does not exist: $explicit"
    printf '%s\n' "$explicit"
    return
  fi
  for candidate in "$@"; do
    [[ -d $candidate ]] || continue
    resolved=$(real_existing "$candidate")
    [[ ${seen[$resolved]+yes} ]] && continue
    seen[$resolved]=1
    score=$(state_score "$resolved")
    now=$(mtime "$resolved")
    say "state candidate: $candidate (score=$score mtime=$now)" >&2
    if ((score > best_score || (score == best_score && now > best_time))); then
      best=$candidate
      best_score=$score
      best_time=$now
    fi
  done
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

DECLARED_STORE=$(resolve_store_value "$PIZARRA_SOURCE")
if [[ -z $SOURCE_STORE ]] && ((CONFIG_SOURCE_WAS_EXPLICIT == 0 && TRUSTED_RECORD_PRESENT)); then
  [[ -d $RECORDED_STATE_SOURCE ]] ||
    die "recorded original state source is unavailable; select the new authority explicitly with --source-store: $RECORDED_STATE_SOURCE"
  SOURCE_STORE=$RECORDED_STATE_SOURCE
  say "using root-trusted original state source: $SOURCE_STORE"
fi
if [[ -z $SOURCE_STORE && -d $DECLARED_STORE ]]; then
  SOURCE_STORE=$DECLARED_STORE
  say "using state declared by selected config: $SOURCE_STORE"
fi
STATE_SOURCE=$(choose_state_dir "$SOURCE_STORE" \
  "$DECLARED_STORE" \
  "$REPO_ROOT/conf/store" \
  "$REPO_ROOT/.private/conf/store" \
  "$SOURCE_ETC/pizarra/store" \
  "$STATE_DIR") || die 'no state directory found; use --source-store'
STATE_SOURCE_REAL=$(real_existing "$STATE_SOURCE")
if [[ $STATE_SOURCE != "$STATE_SOURCE_REAL" ]]; then
  say "selected state: $STATE_SOURCE -> $STATE_SOURCE_REAL"
else
  say "selected state: $STATE_SOURCE"
fi
# Following the root once is deliberate: a compatibility symlink such as
# repo/conf/store -> private/store is a valid source. Descendant symlinks remain
# forbidden so a changing entry cannot redirect one part of the copied tree.
STATE_SOURCE=$STATE_SOURCE_REAL

paths_overlap() {
  local first=$1 second=$2
  [[ $first == "$second" || $first == "$second"/* || $second == "$first"/* ]]
}

DECLARED_RELEASES=$(ini_get "$PIZARRA_SOURCE" server releases || true)
if ((RELEASE_SOURCE_WAS_EXPLICIT)); then
  [[ -d $SOURCE_RELEASES && ! -L $SOURCE_RELEASES ]] ||
    die "release source does not exist or is not a real directory: $SOURCE_RELEASES"
elif [[ -n $DECLARED_RELEASES ]]; then
  if [[ $DECLARED_RELEASES != /* ]]; then
    die "relative [server] releases is process-working-directory dependent; select its real directory explicitly with --source-releases: $DECLARED_RELEASES"
  fi
  validate_base_path 'configured [server] releases' "$DECLARED_RELEASES"
  SOURCE_RELEASES=$DECLARED_RELEASES
fi

RELEASE_SOURCE_REAL=''
RELEASE_SOURCE_PRESENT=0
if [[ -n $SOURCE_RELEASES ]]; then
  if [[ -e $SOURCE_RELEASES || -L $SOURCE_RELEASES ]]; then
    reject_symlink_components "$SOURCE_RELEASES" 'release source'
    [[ -d $SOURCE_RELEASES && ! -L $SOURCE_RELEASES ]] ||
      die "release source is not a real directory: $SOURCE_RELEASES"
    [[ -z $(find "$SOURCE_RELEASES" -type l -print -quit) ]] ||
      die "release source contains a symbolic link: $SOURCE_RELEASES"
    [[ -z $(find "$SOURCE_RELEASES" -mindepth 1 ! -type d ! -type f -print -quit) ]] ||
      die "release source contains a socket, device, or other non-file entry: $SOURCE_RELEASES"
    RELEASE_SOURCE_REAL=$(real_existing "$SOURCE_RELEASES")
    RELEASE_SOURCE_PRESENT=1
    say "selected release artifacts: $SOURCE_RELEASES"
  elif ((RELEASE_SOURCE_WAS_EXPLICIT)); then
    die "explicit release source does not exist: $SOURCE_RELEASES"
  else
    say "configured release directory is absent; no legacy artifacts to copy: $SOURCE_RELEASES"
  fi
else
  say 'selected config has no explicit release directory'
fi
if ((RELEASE_SOURCE_PRESENT == 0)) &&
   [[ -e $STATE_SOURCE_REAL/releases || -L $STATE_SOURCE_REAL/releases ]]; then
  reject_symlink_components "$STATE_SOURCE_REAL/releases" 'state-contained release source'
  [[ -d $STATE_SOURCE_REAL/releases && ! -L $STATE_SOURCE_REAL/releases ]] ||
    die "state-contained releases path is not a real directory: $STATE_SOURCE_REAL/releases"
  [[ -z $(find "$STATE_SOURCE_REAL/releases" -type l -print -quit) ]] ||
    die "state-contained release source contains a symbolic link: $STATE_SOURCE_REAL/releases"
  [[ -z $(find "$STATE_SOURCE_REAL/releases" -mindepth 1 ! -type d ! -type f -print -quit) ]] ||
    die "state-contained release source contains an unsupported entry: $STATE_SOURCE_REAL/releases"
  SOURCE_RELEASES=$STATE_SOURCE_REAL/releases
  RELEASE_SOURCE_REAL=$SOURCE_RELEASES
  RELEASE_SOURCE_PRESENT=1
  say "preserving state-contained release artifacts: $SOURCE_RELEASES"
fi
if ((RELEASE_SOURCE_PRESENT == 0)); then
  say 'canonical releases/ will start empty (no existing artifact tree found)'
fi

PLANNED_STATE_STAGING=$DEST_VAR/lib/.pizarra-state-staging-$STAMP-$$
PLANNED_RELEASE_STAGING=$DEST_VAR/lib/.pizarra-releases-staging-$STAMP-$$
if [[ $STATE_SOURCE_REAL != "$STATE_DIR" ]] &&
   paths_overlap "$STATE_SOURCE_REAL" "$STATE_DIR"; then
  die "state source and canonical destination may not contain one another (exact equality is the only allowed overlap): $STATE_SOURCE_REAL <> $STATE_DIR"
fi
paths_overlap "$STATE_SOURCE_REAL" "$BACKUP_ROOT" &&
  die "state source may not overlap the rollback root: $STATE_SOURCE_REAL <> $BACKUP_ROOT"
paths_overlap "$STATE_SOURCE_REAL" "$PLANNED_STATE_STAGING" &&
  die "state source may not overlap destination-local staging: $STATE_SOURCE_REAL <> $PLANNED_STATE_STAGING"
if ((RELEASE_SOURCE_PRESENT)); then
  [[ $RELEASE_SOURCE_REAL != "$STATE_SOURCE_REAL" ]] ||
    die "release source may not be the state root itself: $RELEASE_SOURCE_REAL"
  [[ $STATE_SOURCE_REAL != "$RELEASE_SOURCE_REAL"/* ]] ||
    die "release source may not contain the state source: $RELEASE_SOURCE_REAL <> $STATE_SOURCE_REAL"
  paths_overlap "$RELEASE_SOURCE_REAL" "$BACKUP_ROOT" &&
    die "release source may not overlap the rollback root: $RELEASE_SOURCE_REAL <> $BACKUP_ROOT"
  paths_overlap "$RELEASE_SOURCE_REAL" "$PLANNED_STATE_STAGING" &&
    die "release source may not overlap state staging: $RELEASE_SOURCE_REAL <> $PLANNED_STATE_STAGING"
  paths_overlap "$RELEASE_SOURCE_REAL" "$PLANNED_RELEASE_STAGING" &&
    die "release source may not overlap release staging: $RELEASE_SOURCE_REAL <> $PLANNED_RELEASE_STAGING"
fi

if [[ -n $(find "$STATE_SOURCE" -type l -print -quit) ]]; then
  die "state contains a symbolic link; refusing to copy a tree with mutable path targets: $STATE_SOURCE"
fi
if [[ -n $(find "$STATE_SOURCE" -mindepth 1 ! -type d ! -type f -print -quit) ]]; then
  die "state contains a socket, device, or other non-file entry; refusing unsafe migration: $STATE_SOURCE"
fi

shopt -s nullglob
SOURCE_DATABASES=("$STATE_SOURCE"/*.sqlite)
shopt -u nullglob
((${#SOURCE_DATABASES[@]} > 0)) || die "state has no SQLite databases: $STATE_SOURCE"

sqlite_integrity() {
  local db=$1 result
  result=$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;' 2>&1) || {
    warn "SQLite could not read $db: $result"
    return 1
  }
  [[ $result == ok ]] || {
    warn "SQLite integrity_check failed for $db: $result"
    return 1
  }
}

table_counts() {
  local db=$1 table count tables table_total=0
  if ! tables=$(sqlite3 -readonly "$db" \
    "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"); then
    warn "could not enumerate tables in $db"
    return 1
  fi
  if [[ -n $tables ]]; then
    table_total=$(printf '%s\n' "$tables" | awk 'NF {n++} END {print n+0}')
  fi
  printf '@tables=%s\n' "$table_total"
  while IFS= read -r table; do
    [[ -n $table ]] || continue
    [[ $table =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "unsafe table name in $db: $table"
    if ! count=$(sqlite3 -readonly "$db" "SELECT count(*) FROM \"$table\";"); then
      warn "could not count $table in $db"
      return 1
    fi
    [[ $count =~ ^[0-9]+$ ]] || die "could not count $table in $db"
    printf '%s=%s\n' "$table" "$count"
  done <<<"$tables"
}

dot_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

online_backup_one() {
  local source=$1 destination=$2 before after copied attempt command stale
  for attempt in 1 2 3; do
    before=$(table_counts "$source") || {
      warn "could not capture pre-backup counts for ${source##*/}; retry $attempt/3"
      continue
    }
    for stale in "$destination" "$destination-wal" "$destination-shm"; do
      [[ ! -e $stale ]] || find "$stale" -maxdepth 0 -type f -delete
      [[ ! -e $stale ]] || die "cannot clear temporary SQLite path: $stale"
    done
    command=".backup $(dot_quote "$destination")"
    if ! sqlite3 -readonly "$source" '.timeout 10000' "$command" >/dev/null; then
      warn "SQLite online backup failed for ${source##*/}; retry $attempt/3"
      continue
    fi
    sqlite_integrity "$destination" || continue
    copied=$(table_counts "$destination") || continue
    after=$(table_counts "$source") || continue
    if [[ $copied == "$before" || $copied == "$after" ]]; then
      printf '%s\n' "$copied" >"$destination.counts"
      chmod 600 "$destination" "$destination.counts"
      say "SQLite verified: ${source##*/} ($(printf '%s\n' "$copied" | awk -F= '$1=="@tables" {print $2; exit}') tables)"
      return 0
    fi
    warn "table counts changed around backup of ${source##*/}; retry $attempt/3"
  done
  return 1
}

secure_tree() {
  local dir=$1
  find "$dir" -type d -exec chmod 700 {} +
  find "$dir" -type f -exec chmod 600 {} +
}

secure_state_tree() {
  local dir=$1
  secure_tree "$dir"
  if ((RUNNING_AS_ROOT)); then
    find "$dir" -exec chown -- "$PIZARRA_OWNER:$PIZARRA_GROUP" {} +
  fi
}

source_owner_group() {
  local source=$1 uid gid passwd_entry group_entry owner group
  uid=$(stat -Lc '%u' -- "$source")
  gid=$(stat -Lc '%g' -- "$source")
  passwd_entry=$(getent passwd "$uid" || true)
  group_entry=$(getent group "$gid" || true)
  owner=${passwd_entry%%:*}
  group=${group_entry%%:*}
  if [[ -z $owner || -z $group ]]; then
    owner=root
    group=root
  fi
  printf '%s:%s\n' "$owner" "$group"
}

aux_owner_group() {
  local relative=$1 source=$2 inherited owner group
  inherited=$(source_owner_group "$source")
  owner=${inherited%%:*}
  group=${inherited#*:}
  if [[ $relative == agents/* ]]; then
    [[ -z $AGENTS_OWNER ]] || owner=$AGENTS_OWNER
    [[ -z $AGENTS_GROUP ]] || group=$AGENTS_GROUP
  else
    [[ -z $TIZA_OWNER ]] || owner=$TIZA_OWNER
    [[ -z $TIZA_GROUP ]] || group=$TIZA_GROUP
  fi
  printf '%s:%s\n' "$owner" "$group"
}

secure_config_layout() {
  local relative ownership
  install -d -m 711 "$CONFIG_DIR" "$CONFIG_DIR/agents"
  chmod 711 "$CONFIG_DIR" "$CONFIG_DIR/agents"
  find "$CONFIG_DIR" -type f -exec chmod 600 {} +
  if ((RUNNING_AS_ROOT)); then
    chown -- "$PIZARRA_OWNER:$PIZARRA_GROUP" "$CONFIG_DIR"
    chown -- root:root "$CONFIG_DIR/agents"
    [[ ! -f $CONFIG_DIR/pizarra.conf ]] ||
      chown -- "$PIZARRA_OWNER:$PIZARRA_GROUP" "$CONFIG_DIR/pizarra.conf"
    [[ ! -f $CONFIG_DIR/pzweb.conf ]] ||
      chown -- "$PZWEB_OWNER:$PZWEB_GROUP" "$CONFIG_DIR/pzweb.conf"
    for relative in "${!AUX_SOURCE[@]}"; do
      [[ -f $CONFIG_DIR/$relative ]] || continue
      ownership=$(aux_owner_group "$relative" "${AUX_SOURCE[$relative]}")
      chown -- "$ownership" "$CONFIG_DIR/$relative"
    done
  fi
}

stable_copy_live_file() {
  local source=$1 destination=$2 before after tmp attempt
  [[ -f $source ]] || return 0
  tmp=$destination.stable-$$
  for attempt in 1 2 3; do
    before=$(stat -Lc '%s:%Y:%y' -- "$source")
    cp -p -- "$source" "$tmp"
    after=$(stat -Lc '%s:%Y:%y' -- "$source")
    if [[ $before == "$after" ]]; then
      mv -f -- "$tmp" "$destination"
      return 0
    fi
    warn "live file changed while copied: ${source##*/}; retry $attempt/3"
  done
  find "$tmp" -maxdepth 0 -type f -delete 2>/dev/null || true
  return 1
}

snapshot_state() {
  local source=$1 destination=$2 db name tmp counts live legacy previous
  install -d -m 700 "$destination"
  cp -a -- "$source/." "$destination/"
  # Hub and restore coordinate through this persistent inode. It carries no
  # data; the open flock is the ownership signal. Always stage it so restore
  # dry-runs never need to mutate the canonical store merely to take a lock.
  [[ ! -L $destination/.pizarra-hub.lock ]] ||
    die 'source hub lock path is a symbolic link'
  install -m 600 /dev/null "$destination/.pizarra-hub.lock"
  # Never carry a previous installation's freshness proof into a new snapshot.
  for live in .pizarra-layout-installed.sha256 .pizarra-layout-source; do
    if [[ -e $destination/$live ]]; then
      [[ -f $destination/$live ]] ||
        die "source contains a non-file obsolete migration marker: $live"
      find "$destination/$live" -maxdepth 0 -type f -delete
    fi
  done
  { # Recopy mutable root records only when size+mtime stayed unchanged.
    for live in messages.jsonl state.json tareas.json workflows.json registry.ini; do
      stable_copy_live_file "$source/$live" "$destination/$live" ||
        die "could not take a stable copy of $source/$live; stop the hub manually and rerun"
    done
  }
  # registry.ini was the pre-SQLite registry replica. Preserve it for forensic
  # reference, but never install it at state root where it could look current.
  if [[ -f $destination/registry.ini ]]; then
    install -d -m 700 "$destination/legacy"
    legacy=$destination/legacy/registry.ini.pre-sqlite
    if [[ -e $legacy ]]; then
      if cmp -s -- "$destination/registry.ini" "$legacy"; then
        find "$destination/registry.ini" -maxdepth 0 -type f -delete
      else
        previous=$legacy.before-$STAMP-$$
        [[ ! -e $previous ]] || die "legacy registry archive collision: $previous"
        mv -- "$legacy" "$previous"
        mv -- "$destination/registry.ini" "$legacy"
      fi
    else
      mv -- "$destination/registry.ini" "$legacy"
    fi
    chmod 600 "$legacy"
    say 'legacy registry.ini archived (SQLite remains authoritative)'
  fi
  for db in "$source"/*.sqlite; do
    [[ -f $db ]] || continue
    name=${db##*/}
    tmp=$destination/.online-$name
    online_backup_one "$db" "$tmp" || die "could not make a coherent online backup of $db"
    counts=$tmp.counts
    mv -f -- "$tmp" "$destination/$name"
    mv -f -- "$counts" "$destination/.$name.counts"
    find "$destination" -maxdepth 1 -type f \
      \( -name "$name-wal" -o -name "$name-shm" \
         -o -name ".online-$name-wal" -o -name ".online-$name-shm" \) -delete
  done
  secure_tree "$destination"
}

verify_state() {
  local dir=$1 db expected actual
  shopt -s nullglob
  local dbs=("$dir"/*.sqlite)
  shopt -u nullglob
  ((${#dbs[@]} > 0)) || return 1
  for db in "${dbs[@]}"; do
    sqlite_integrity "$db" || return 1
    expected=$dir/.${db##*/}.counts
    if [[ -f $expected ]]; then
      actual=$(table_counts "$db") || return 1
      [[ $actual == "$(<"$expected")" ]] || return 1
    fi
  done
}

state_content_manifest() {
  local dir=$1 output=$2
  (
    cd -- "$dir" || exit 1
    find . -printf '%y %m %u %g %P %l\0' |
      sort -z | sha256sum | awk '{print "@tree=" $1}' || exit 1
    find . -type f -print0 |
      sort -z | xargs -0 -r sha256sum || exit 1
  ) >"$output" || return 1
  chmod 600 "$output" || return 1
}

payload_manifest() {
  local dir=$1 output=$2
  (
    cd -- "$dir" || exit 1
    find . -printf '%y %m %u %g %P %l\0' |
      sort -z | sha256sum | awk '{print "@tree=" $1}' || exit 1
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum || exit 1
  ) >"$output" || return 1
  chmod 600 "$output" || return 1
}

# Release artifacts are immutable payloads selected by releases/VERSION.  The
# canonical layout normalizes ownership/modes, so this manifest deliberately
# verifies the complete entry/type/name set and every regular-file byte rather
# than treating ownership metadata as application data.
release_payload_manifest() {
  local dir=$1 output=$2 tree_hash
  (
    cd -- "$dir" || exit 1
    tree_hash=$(find . -printf '%y\0%P\0' | LC_ALL=C sort -z |
      sha256sum | awk '{print $1}') || exit 1
    printf '@tree=%s\n' "$tree_hash"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) >"$output" || return 1
  chmod 600 "$output" || return 1
}

clear_work_directory() {
  local dir=$1
  [[ $dir == "$WORK"/* && $dir != "$WORK" ]] ||
    die "refusing to clear a non-work directory: $dir"
  [[ ! -L $dir ]] || die "temporary release path became a symbolic link: $dir"
  [[ ! -e $dir || -d $dir ]] || die "temporary release path is not a directory: $dir"
  if [[ -d $dir ]]; then
    find "$dir" -depth -mindepth 1 -delete
    rmdir -- "$dir"
  fi
}

snapshot_release_tree() {
  local source=$1 destination=$2 attempt
  local before=$WORK/releases-before.sha256
  local after=$WORK/releases-after.sha256
  local copied=$WORK/releases-copied.sha256
  for attempt in 1 2 3; do
    clear_work_directory "$destination"
    release_payload_manifest "$source" "$before" ||
      die "cannot manifest release source: $source"
    if ! cp -a -- "$source" "$destination"; then
      warn "release copy failed; retry $attempt/3"
      continue
    fi
    release_payload_manifest "$source" "$after" ||
      die "cannot re-read release source: $source"
    release_payload_manifest "$destination" "$copied" ||
      die 'cannot manifest copied release artifacts'
    if cmp -s -- "$before" "$after" && cmp -s -- "$before" "$copied"; then
      cp -p -- "$copied" "$WORK/releases-snapshot.sha256"
      secure_tree "$destination"
      say 'release artifacts captured with a stable byte-for-byte manifest'
      return 0
    fi
    warn "release artifacts changed while copied; retry $attempt/3"
  done
  die "could not take an exact release snapshot; stop publishers and rerun: $source"
}

remove_staged_release_source() {
  local staged_state=$1 relative old
  ((RELEASE_SOURCE_PRESENT)) || return 0
  [[ $RELEASE_SOURCE_REAL == "$STATE_SOURCE_REAL"/* ]] || return 0
  relative=${RELEASE_SOURCE_REAL#"$STATE_SOURCE_REAL"/}
  [[ $relative != releases ]] || return 0
  old=$staged_state/$relative
  [[ $old == "$staged_state"/* && $old != "$staged_state" ]] ||
    die "invalid staged release-source path: $old"
  [[ ! -L $old ]] || die "staged release source became a symbolic link: $old"
  if [[ -d $old ]]; then
    find "$old" -depth -mindepth 1 -delete
    rmdir -- "$old"
  elif [[ -e $old ]]; then
    die "staged release source is no longer a directory: $old"
  fi
}

prepare_staged_releases() {
  local staged_state=$1 target current=$WORK/releases-current.sha256
  target=$staged_state/releases
  if [[ -e $target && ! -d $target ]]; then
    die "staged canonical release path is not a directory: $target"
  fi
  if ((RELEASE_SOURCE_PRESENT)); then
    if [[ -d $target && -n $(find "$target" -mindepth 1 -print -quit) ]]; then
      release_payload_manifest "$target" "$current" ||
        die 'cannot manifest release artifacts already present in staged state'
      if [[ $RELEASE_SOURCE_REAL != "$STATE_SOURCE_REAL/releases" ]] &&
         ! cmp -s -- "$WORK/releases-snapshot.sha256" "$current"; then
        die 'configured release artifacts conflict with a different non-empty state/releases tree; no destination was changed'
      fi
    fi
    remove_staged_release_source "$staged_state"
    if [[ $RELEASE_SOURCE_REAL == "$STATE_SOURCE_REAL/releases" ]] ||
       [[ ! -d $target ]] ||
       [[ -z $(find "$target" -mindepth 1 -print -quit) ]]; then
      clear_work_directory "$target"
      mv -- "$WORK/releases-source" "$target"
    fi
  elif [[ ! -d $target ]]; then
    install -d -m 700 "$target"
  fi
  secure_tree "$target"
}

CANONICAL_RELEASE_ACTION=none
assess_canonical_releases() {
  local current=$WORK/canonical-releases.sha256
  if [[ -e $RELEASE_DIR || -L $RELEASE_DIR ]]; then
    reject_symlink_components "$RELEASE_DIR" 'canonical release directory'
    [[ -d $RELEASE_DIR && ! -L $RELEASE_DIR ]] ||
      die "canonical release path is not a real directory: $RELEASE_DIR"
    [[ -z $(find "$RELEASE_DIR" -type l -print -quit) ]] ||
      die "canonical release directory contains a symbolic link: $RELEASE_DIR"
    [[ -z $(find "$RELEASE_DIR" -mindepth 1 ! -type d ! -type f -print -quit) ]] ||
      die "canonical release directory contains a socket, device, or other non-file entry: $RELEASE_DIR"
  fi

  if ((RELEASE_SOURCE_PRESENT)) && [[ $RELEASE_SOURCE_REAL != "$RELEASE_DIR" ]]; then
    if [[ -d $RELEASE_DIR && -n $(find "$RELEASE_DIR" -mindepth 1 -print -quit) ]]; then
      release_payload_manifest "$RELEASE_DIR" "$current" ||
        die "cannot manifest canonical release directory: $RELEASE_DIR"
      if cmp -s -- "$WORK/releases-snapshot.sha256" "$current"; then
        say 'canonical release artifacts already match the selected snapshot'
      else
        die 'selected release artifacts conflict with non-empty canonical releases; reconcile them explicitly before migration'
      fi
    else
      CANONICAL_RELEASE_ACTION=install
    fi
  elif [[ ! -d $RELEASE_DIR ]]; then
    CANONICAL_RELEASE_ACTION=create
  fi
}

install_canonical_releases() {
  local staged_manifest=$WORK/releases-staged.sha256 current=$WORK/releases-immediate.sha256
  case $CANONICAL_RELEASE_ACTION in
    none)
      return 0
      ;;
    create)
      if [[ -e $RELEASE_DIR || -L $RELEASE_DIR ]]; then
        reject_symlink_components "$RELEASE_DIR" 'canonical release directory'
        [[ -d $RELEASE_DIR && ! -L $RELEASE_DIR ]] ||
          die "canonical release path changed into a non-directory: $RELEASE_DIR"
      else
        install -d -m 700 "$RELEASE_DIR"
      fi
      say "canonical release directory created: $RELEASE_DIR"
      ;;
    install)
      [[ ! -e $PLANNED_RELEASE_STAGING && ! -L $PLANNED_RELEASE_STAGING ]] ||
        die "release staging path already exists: $PLANNED_RELEASE_STAGING"
      cp -a -- "$WORK/releases-source" "$PLANNED_RELEASE_STAGING" ||
        die 'could not transfer the verified release snapshot to destination-local staging'
      secure_state_tree "$PLANNED_RELEASE_STAGING"
      release_payload_manifest "$PLANNED_RELEASE_STAGING" "$staged_manifest" ||
        die 'cannot verify destination-local release staging'
      cmp -s -- "$WORK/releases-snapshot.sha256" "$staged_manifest" ||
        die 'destination-local release staging differs from the verified snapshot'
      find "$PLANNED_RELEASE_STAGING" -type f -exec sync -d -- {} +
      durable_directory "$PLANNED_RELEASE_STAGING"

      if [[ -e $RELEASE_DIR || -L $RELEASE_DIR ]]; then
        reject_symlink_components "$RELEASE_DIR" 'canonical release directory before install'
        [[ -d $RELEASE_DIR && ! -L $RELEASE_DIR ]] ||
          die "canonical release path changed into a non-directory: $RELEASE_DIR"
        [[ -z $(find "$RELEASE_DIR" -mindepth 1 -print -quit) ]] || {
          release_payload_manifest "$RELEASE_DIR" "$current" || true
          if [[ -f $current ]] && cmp -s -- "$WORK/releases-snapshot.sha256" "$current"; then
            find "$PLANNED_RELEASE_STAGING" -depth -mindepth 1 -delete
            rmdir -- "$PLANNED_RELEASE_STAGING"
            say 'canonical release artifacts became current during migration; kept them'
            return 0
          fi
          die 'canonical release directory became non-empty during migration; verified staging was retained'
        }
        mv -- "$RELEASE_DIR" "$BACKUP_DIR/releases-empty-before"
      fi
      mv -- "$PLANNED_RELEASE_STAGING" "$RELEASE_DIR" || {
        [[ ! -d $BACKUP_DIR/releases-empty-before ]] ||
          mv -- "$BACKUP_DIR/releases-empty-before" "$RELEASE_DIR"
        die 'could not publish canonical release directory; previous empty directory was restored'
      }
      release_payload_manifest "$RELEASE_DIR" "$current" ||
        die 'cannot verify installed canonical releases'
      cmp -s -- "$WORK/releases-snapshot.sha256" "$current" ||
        die 'installed canonical releases differ from the verified snapshot'
      durable_directory "$STATE_DIR"
      say "release artifacts installed and verified: $RELEASE_DIR"
      ;;
    *)
      die "internal invalid canonical release action: $CANONICAL_RELEASE_ACTION"
      ;;
  esac
}

installed_state_unchanged() {
  local dir=$1 recorded=$WORK/recorded-state.sha256 current=$WORK/current-state.sha256
  ((TRUSTED_RECORD_PRESENT)) || return 1
  awk '
    /^--manifest--$/ { found=1; next }
    found { print }
    END { if (!found) exit 1 }
  ' "$TRUSTED_STATE_RECORD" >"$recorded" || return 1
  state_content_manifest "$dir" "$current"
  cmp -s -- "$current" "$recorded"
}

record_installed_state() {
  local dir=$1 manifest=$WORK/installed-state.sha256 staged=$WORK/installed-state.record
  [[ $PIZARRA_SOURCE_REAL != *$'\n'* && $STATE_SOURCE_REAL != *$'\n'* ]] ||
    die 'source paths with newlines cannot be recorded safely'
  state_content_manifest "$dir" "$manifest"
  {
    printf 'version=1\n'
    printf 'config_source=%s\n' "$PIZARRA_SOURCE_REAL"
    printf 'state_source=%s\n' "$STATE_SOURCE_REAL"
    printf '%s\n' '--manifest--'
    cat "$manifest"
  } >"$staged"
  chmod 600 "$staged"
  if [[ -f $TRUSTED_STATE_RECORD ]]; then
    cp -p -- "$TRUSTED_STATE_RECORD" "$BACKUP_DIR/installed-state.record-before"
  fi
  install -m 600 -- "$staged" "$TRUSTED_STATE_RECORD.new-$$"
  if ((RUNNING_AS_ROOT)); then
    chown -- root:root "$TRUSTED_STATE_RECORD.new-$$"
  fi
  mv -f -- "$TRUSTED_STATE_RECORD.new-$$" "$TRUSTED_STATE_RECORD"
  durable_file "$TRUSTED_STATE_RECORD"
}

for db in "${SOURCE_DATABASES[@]}"; do
  sqlite_integrity "$db" || die "source SQLite is not healthy: $db"
  table_counts "$db" >"$WORK/source-${db##*/}.counts"
done
if ((RELEASE_SOURCE_PRESENT)); then
  snapshot_release_tree "$RELEASE_SOURCE_REAL" "$WORK/releases-source"
fi

STATE_IS_CANONICAL=0
CANONICAL_REGISTRY_ARCHIVE=0
if same_existing_path "$STATE_SOURCE" "$STATE_DIR"; then
  STATE_IS_CANONICAL=1
  state_has_open_handles "$STATE_DIR" &&
    die "canonical state is in use; stop that hub manually before consolidating in place: $STATE_DIR"
  if [[ -e $STATE_DIR/registry.ini ]]; then
    [[ -f $STATE_DIR/registry.ini ]] ||
      die 'canonical top-level registry.ini is not a regular file'
    CANONICAL_REGISTRY_ARCHIVE=1
    say 'canonical legacy registry.ini will be archived in place'
  fi
  assess_canonical_releases
  say 'state already uses the canonical directory; verified in place'
else
  say 'building a coherent state snapshot (source remains untouched)'
  snapshot_state "$STATE_SOURCE" "$WORK/state"
  prepare_staged_releases "$WORK/state"
  verify_state "$WORK/state" || die 'staged state failed post-backup verification'
fi

rewrite_pizarra_config() {
  local source=$1 destination=$2 source_shared destination_shared
  awk -v new_store="$STATE_DIR" -v new_releases="$RELEASE_DIR" \
      -v new_log="$LOG_PATH" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function finish_section() {
      if (section=="server" && !releases_key) { print "releases = " new_releases; releases_key=1 }
      if (section=="store" && !store_key) { print "dir = " new_store; store_key=1 }
      if (section=="log" && !log_key) { print "path = " new_log; log_key=1 }
    }
    function section_of(line, s) {
      s=line
      sub(/^[[:space:]]*\[/, "", s)
      sub(/\][[:space:]]*$/, "", s)
      return tolower(trim(s))
    }
    /^[[:space:]]*#/ {
      sub(/#/, ";")
      print
      next
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      finish_section()
      section=section_of($0)
      if (section=="server") { saw_server=1; releases_key=0 }
      if (section=="store") { saw_store=1; store_key=0 }
      if (section=="log") { saw_log=1; log_key=0 }
      print
      next
    }
    {
      p=index($0,"=")
      key=""
      if (p>0) key=tolower(trim(substr($0,1,p-1)))
      if (section=="server" && key=="releases") {
        if (!releases_key) print "releases = " new_releases
        releases_key=1
        next
      }
      if (section=="store" && key=="dir") {
        if (!store_key) print "dir = " new_store
        store_key=1
        next
      }
      if (section=="log" && key=="path") {
        if (!log_key) print "path = " new_log
        log_key=1
        next
      }
      print
    }
    END {
      finish_section()
      if (!saw_server) { print ""; print "[server]"; print "releases = " new_releases }
      if (!saw_store) { print ""; print "[store]"; print "dir = " new_store }
      if (!saw_log) { print ""; print "[log]"; print "path = " new_log }
    }
  ' "$source" >"$destination"
  chmod 600 "$destination"
  [[ $(ini_get "$destination" server releases) == "$RELEASE_DIR" ]] ||
    die 'failed to rewrite [server] releases'
  [[ $(ini_get "$destination" store dir) == "$STATE_DIR" ]] || die 'failed to rewrite [store] dir'
  [[ $(ini_get "$destination" log path) == "$LOG_PATH" ]] || die 'failed to rewrite [log] path'
  # shared.dir is an operator-owned mount path, commonly an external NFS.
  # It is configuration, not state: migration must preserve the value exactly
  # and must never walk, copy, chmod, move, or delete the shared tree.
  source_shared=$(ini_get "$source" shared dir || true)
  destination_shared=$(ini_get "$destination" shared dir || true)
  [[ $destination_shared == "$source_shared" ]] ||
    die 'failed to preserve [shared] dir literally'
}

rewrite_pzweb_config() {
  local source=$1 destination=$2 source_shared destination_shared
  source_shared=$(ini_get "$source" web shared || true)
  validate_shared_path_value 'configured pzweb [web] shared' "$source_shared"
  awk -v new_static="$WEB_ASSETS_DIR" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function finish_section() {
      if (section=="web" && !static_key) { print "static = " new_static; static_key=1 }
    }
    function section_of(line, s) {
      s=line
      sub(/^[[:space:]]*\[/, "", s)
      sub(/\][[:space:]]*$/, "", s)
      return tolower(trim(s))
    }
    /^[[:space:]]*#/ {
      sub(/#/, ";")
      print
      next
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      finish_section()
      section=section_of($0)
      if (section=="web") { saw_web=1; static_key=0 }
      print
      next
    }
    {
      p=index($0,"=")
      key=""
      if (p>0) key=tolower(trim(substr($0,1,p-1)))
      if (section=="web" && key=="static") {
        if (!static_key) print "static = " new_static
        static_key=1
        next
      }
      print
    }
    END {
      finish_section()
      if (!saw_web) { print ""; print "[web]"; print "static = " new_static }
    }
  ' "$source" >"$destination"
  chmod 600 "$destination"
  [[ $(ini_get "$destination" web static) == "$WEB_ASSETS_DIR" ]] ||
    die 'failed to rewrite pzweb [web] static path'
  # pzweb reads the same exchange directly for listings/deletions and sends
  # absolute download paths to the hub. Preserve this independently configured
  # mount value exactly; the shared data itself remains outside migration.
  destination_shared=$(ini_get "$destination" web shared || true)
  [[ $destination_shared == "$source_shared" ]] ||
    die 'failed to preserve pzweb [web] shared literally'
}

install -d -m 700 "$WORK/config" "$WORK/config/agents"
rewrite_pizarra_config "$PIZARRA_SOURCE" "$WORK/config/pizarra.conf"

PZWEB_SOURCE=$(choose_newest_file "$SOURCE_PZWEB_CONF" 'pzweb config' \
  "$REPO_ROOT/conf/pzweb.conf" \
  "$REPO_ROOT/.private/conf/pzweb.conf" \
  "$CONFIG_DIR/pzweb.conf" \
  "$SOURCE_ETC/pizarra/pzweb.conf" \
  "$SOURCE_ETC/pzweb/pzweb.conf") || true
if [[ -n ${PZWEB_SOURCE:-} ]]; then
  rewrite_pzweb_config "$PZWEB_SOURCE" "$WORK/config/pzweb.conf"
  HUB_SHARED=$(ini_get "$WORK/config/pizarra.conf" shared dir || true)
  WEB_SHARED=$(ini_get "$WORK/config/pzweb.conf" web shared || true)
  if [[ $WEB_SHARED != "$HUB_SHARED" ]]; then
    die 'pzweb [web] shared must exactly match the hub [shared] dir; the web console reads locally but downloads through the hub'
  fi
  if [[ -n $HUB_SHARED ]]; then
    say 'preserving configured shared exchange in place (its external contents are not migrated)'
  fi
  say "selected pzweb config: $PZWEB_SOURCE"
else
  warn 'no real pzweb.conf found; pzweb config will not be installed'
fi

declare -A AUX_SOURCE=()

consider_aux() {
  local relative=$1 source=$2 old old_time new_time
  [[ -f $source ]] || return 0
  old=${AUX_SOURCE[$relative]:-}
  if [[ -z $old ]]; then
    AUX_SOURCE[$relative]=$source
    return
  fi
  same_existing_path "$old" "$source" && return 0
  old_time=$(mtime "$old")
  new_time=$(mtime "$source")
  if ((new_time > old_time)); then
    AUX_SOURCE[$relative]=$source
  elif ((new_time == old_time)) && ! cmp -s -- "$old" "$source"; then
    die "ambiguous ancillary config $relative; equal-time files differ: $old and $source"
  fi
}

scan_aux_dir() {
  local dir=$1 file base
  [[ -d $dir ]] || return 0
  shopt -s nullglob
  for file in "$dir"/tiza.conf "$dir"/tiza-*.conf "$dir"/telegram.conf; do
    [[ -f $file ]] || continue
    base=${file##*/}
    consider_aux "$base" "$file"
  done
  shopt -u nullglob
}

scan_agent_dir() {
  local dir=$1 file base
  [[ -d $dir ]] || return 0
  shopt -s nullglob
  for file in "$dir"/*.conf; do
    [[ -f $file ]] || continue
    base=${file##*/}
    consider_aux "agents/$base" "$file"
  done
  shopt -u nullglob
}

scan_aux_dir "$REPO_ROOT/conf"
scan_aux_dir "$REPO_ROOT/.private/conf"
scan_aux_dir "$SOURCE_ETC/pizarra"
scan_aux_dir "$SOURCE_ETC/tiza"
scan_aux_dir "$CONFIG_DIR"
scan_agent_dir "$REPO_ROOT/conf/agents"
scan_agent_dir "$REPO_ROOT/.private/conf/agents"
scan_agent_dir "$SOURCE_ETC/pizarra/agents"
scan_agent_dir "$SOURCE_ETC/tiza/agents"
scan_agent_dir "$CONFIG_DIR/agents"

for relative in "${!AUX_SOURCE[@]}"; do
  install -d -m 700 "$WORK/config/$(dirname -- "$relative")"
  cp -p -- "${AUX_SOURCE[$relative]}" "$WORK/config/$relative"
  chmod 600 "$WORK/config/$relative"
  validate_file_target "$CONFIG_DIR/$relative" "ancillary config $relative"
done

SOURCE_LOG=$(ini_get "$PIZARRA_SOURCE" log path || true)
if [[ -n $SOURCE_LOG && $SOURCE_LOG != /* ]]; then
  SOURCE_LOG=$(cd -- "$(dirname -- "$PIZARRA_SOURCE")" && pwd -P)/$SOURCE_LOG
fi

# Refuse a deliberately selected older pizarra.conf before changing state. The
# auxiliary configs are chosen per-file with the destination included as a
# candidate, but this required generated file has to be decided as one unit.
if [[ -f $CONFIG_DIR/pizarra.conf ]] &&
   ! cmp -s -- "$WORK/config/pizarra.conf" "$CONFIG_DIR/pizarra.conf" &&
   ! same_existing_path "$CONFIG_DIR/pizarra.conf" "$PIZARRA_SOURCE" &&
   (( $(mtime "$CONFIG_DIR/pizarra.conf") >= $(mtime "$PIZARRA_SOURCE") )); then
  die "canonical pizarra.conf is same-age/newer and differs; select it as --source-config or reconcile it manually: $CONFIG_DIR/pizarra.conf"
fi

DEST_STATE_NONEMPTY=0
if ((STATE_IS_CANONICAL == 0)) && [[ -d $STATE_DIR ]] &&
   [[ -n $(find "$STATE_DIR" -mindepth 1 -print -quit) ]]; then
  DEST_STATE_NONEMPTY=1
  state_has_open_handles "$STATE_DIR" &&
    die "canonical destination state is in use; stop that hub manually before refresh/replacement: $STATE_DIR"
  if ((REPLACE_STATE == 0)); then
    if ((TRUSTED_RECORD_PRESENT == 0)) || [[ ! -d $RECORDED_STATE_SOURCE ]] ||
       [[ $(real_existing "$RECORDED_STATE_SOURCE") != "$STATE_SOURCE_REAL" ]]; then
      die "destination state is non-empty and is not a prior snapshot of this source: $STATE_DIR; inspect it and rerun with --replace-state to preserve it in rollback and install the selected source"
    fi
    installed_state_unchanged "$STATE_DIR" ||
      die "canonical state changed after its migration snapshot; refusing to discard newer writes (select canonical state, or use --replace-state to preserve it intact in rollback)"
    say 'destination is an unchanged verified snapshot of the same source; safe refresh enabled'
  else
    say 'non-empty destination will be preserved intact in rollback (--replace-state)'
  fi
  payload_manifest "$STATE_DIR" "$WORK/state-before.sha256" ||
    die "cannot read every existing destination file for rollback verification: $STATE_DIR"
fi

if ((DRY_RUN)); then
  say "dry run complete: snapshot, collision, path, and SQLite checks passed"
  say "would install configs under $CONFIG_DIR"
  say "would install state at $STATE_DIR"
  say "would use release artifacts at $RELEASE_DIR"
  say "would use log $LOG_PATH"
  exit 0
fi

ensure_directory "$DEST_VAR/lib" 755 0
ensure_directory "$BACKUP_ROOT" 700 1
if ((RUNNING_AS_ROOT)); then
  chown -- root:root "$BACKUP_ROOT"
fi
BACKUP_DIR=$BACKUP_ROOT/$STAMP-$$
install -d -m 700 "$BACKUP_DIR" "$BACKUP_DIR/replaced-configs" "$BACKUP_DIR/source-configs"
cp -p -- "$PIZARRA_SOURCE" "$BACKUP_DIR/source-configs/pizarra.conf"
if [[ -n ${PZWEB_SOURCE:-} ]]; then
  cp -p -- "$PZWEB_SOURCE" "$BACKUP_DIR/source-configs/pzweb.conf"
fi

{
  printf 'created=%s\n' "$STAMP"
  printf 'source_config=%s\n' "$PIZARRA_SOURCE"
  printf 'source_state=%s\n' "$STATE_SOURCE"
  printf 'source_releases=%s\n' "$SOURCE_RELEASES"
  printf 'destination_config=%s\n' "$CONFIG_DIR"
  printf 'destination_state=%s\n' "$STATE_DIR"
  printf 'destination_releases=%s\n' "$RELEASE_DIR"
  printf 'pizarra_owner=%s\n' "$PIZARRA_OWNER:$PIZARRA_GROUP"
  printf 'pzweb_owner=%s\n' "$PZWEB_OWNER:$PZWEB_GROUP"
  printf 'sessions_touched=no\n'
  printf 'sources_deleted=no\n'
} >"$BACKUP_DIR/migration.info"
chmod 600 "$BACKUP_DIR/migration.info"

if ((STATE_IS_CANONICAL)); then
  [[ ! -L $STATE_DIR/.pizarra-hub.lock ]] ||
    die 'canonical hub lock path is a symbolic link'
  if [[ -e $STATE_DIR/.pizarra-hub.lock ]]; then
    [[ -f $STATE_DIR/.pizarra-hub.lock ]] ||
      die 'canonical hub lock path is not a regular file'
  else
    install -m 600 /dev/null "$STATE_DIR/.pizarra-hub.lock"
    durable_file "$STATE_DIR/.pizarra-hub.lock"
  fi
fi

for db in "${SOURCE_DATABASES[@]}"; do
  printf '%s\n' "${db##*/}" >>"$BACKUP_DIR/sqlite-files"
  table_counts "$db" >"$BACKUP_DIR/${db##*/}.source-counts"
done
find "$BACKUP_DIR" -maxdepth 1 -type f -exec chmod 600 {} +

if ((CANONICAL_REGISTRY_ARCHIVE)); then
  cp -p -- "$STATE_DIR/registry.ini" "$BACKUP_DIR/registry.ini-before-archive"
  install -d -m 700 "$STATE_DIR/legacy"
  CANONICAL_LEGACY_REGISTRY=$STATE_DIR/legacy/registry.ini.pre-sqlite
  if [[ -e $CANONICAL_LEGACY_REGISTRY ]]; then
    if cmp -s -- "$STATE_DIR/registry.ini" "$CANONICAL_LEGACY_REGISTRY"; then
      find "$STATE_DIR/registry.ini" -maxdepth 0 -type f -delete
    else
      CANONICAL_PREVIOUS_REGISTRY=$CANONICAL_LEGACY_REGISTRY.before-$STAMP-$$
      [[ ! -e $CANONICAL_PREVIOUS_REGISTRY ]] ||
        die "legacy registry archive collision: $CANONICAL_PREVIOUS_REGISTRY"
      mv -- "$CANONICAL_LEGACY_REGISTRY" "$CANONICAL_PREVIOUS_REGISTRY"
      mv -- "$STATE_DIR/registry.ini" "$CANONICAL_LEGACY_REGISTRY"
    fi
  else
    mv -- "$STATE_DIR/registry.ini" "$CANONICAL_LEGACY_REGISTRY"
  fi
  chmod 600 "$CANONICAL_LEGACY_REGISTRY"
  durable_directory "$STATE_DIR"
  say 'canonical legacy registry.ini archived; SQLite remains authoritative'
fi

if ((STATE_IS_CANONICAL == 0)); then
  STATE_STAGING=$PLANNED_STATE_STAGING
  [[ ! -e $STATE_STAGING ]] || die "state staging path already exists: $STATE_STAGING"
  if ! mv -- "$WORK/state" "$STATE_STAGING"; then
    [[ ! -e $STATE_STAGING ]] ||
      mv -- "$STATE_STAGING" "$BACKUP_DIR/failed-staging-state"
    die 'could not transfer the verified snapshot to destination-local staging; canonical state was not changed'
  fi
  verify_state "$STATE_STAGING" || {
    mv -- "$STATE_STAGING" "$BACKUP_DIR/failed-staging-state"
    die 'destination-local staging failed verification; canonical state was not changed'
  }
  durable_directory "$STATE_STAGING"

  if state_has_open_handles "$STATE_DIR"; then
    mv -- "$STATE_STAGING" "$BACKUP_DIR/aborted-staging-state"
    durable_directory "$BACKUP_DIR"
    die "canonical destination became active; stop that hub manually and rerun: $STATE_DIR"
  fi
  if ((DEST_STATE_NONEMPTY)); then
    payload_manifest "$STATE_DIR" "$WORK/state-before-immediate.sha256" || {
      mv -- "$STATE_STAGING" "$BACKUP_DIR/aborted-staging-state"
      die 'could not re-read destination immediately before replacement'
    }
    if ! cmp -s -- "$WORK/state-before.sha256" "$WORK/state-before-immediate.sha256"; then
      mv -- "$STATE_STAGING" "$BACKUP_DIR/aborted-staging-state"
      durable_directory "$BACKUP_DIR"
      die 'canonical destination changed during migration preflight; it was not replaced'
    fi
  fi

  OLD_STATE=''
  if [[ -d $STATE_DIR ]]; then
    OLD_STATE=$BACKUP_DIR/state-before
    mv -- "$STATE_DIR" "$OLD_STATE"
    durable_directory "$DEST_VAR/lib"
    durable_directory "$BACKUP_DIR"
    if [[ -f $WORK/state-before.sha256 ]]; then
      cp -p -- "$WORK/state-before.sha256" "$BACKUP_DIR/state-before.sha256"
    fi
    if ((DEST_STATE_NONEMPTY)); then
      STATE_BEFORE_STABLE=1
      state_has_open_handles "$OLD_STATE" && STATE_BEFORE_STABLE=0
      payload_manifest "$OLD_STATE" "$WORK/state-before-after-move-1.sha256" ||
        STATE_BEFORE_STABLE=0
      payload_manifest "$OLD_STATE" "$WORK/state-before-after-move-2.sha256" ||
        STATE_BEFORE_STABLE=0
      if ((STATE_BEFORE_STABLE)) &&
         { ! cmp -s -- "$WORK/state-before.sha256" "$WORK/state-before-after-move-1.sha256" ||
           ! cmp -s -- "$WORK/state-before-after-move-1.sha256" "$WORK/state-before-after-move-2.sha256"; }; then
        STATE_BEFORE_STABLE=0
      fi
      if ((STATE_BEFORE_STABLE == 0)); then
        mv -- "$STATE_STAGING" "$BACKUP_DIR/aborted-staging-state"
        mv -- "$OLD_STATE" "$STATE_DIR"
        durable_directory "$DEST_VAR/lib"
        durable_directory "$BACKUP_DIR"
        die 'canonical destination changed or remained open across rename; previous state was restored and no replacement was published'
      fi
    fi
  fi
  if ! mv -- "$STATE_STAGING" "$STATE_DIR"; then
    [[ ! -e $STATE_DIR ]] || mv -- "$STATE_DIR" "$BACKUP_DIR/failed-new-state"
    [[ -z $OLD_STATE || ! -d $OLD_STATE ]] || mv -- "$OLD_STATE" "$STATE_DIR"
    durable_directory "$DEST_VAR/lib"
    durable_directory "$BACKUP_DIR"
    die 'could not install staged state; previous destination was restored'
  fi
  durable_directory "$DEST_VAR/lib"
  STATE_INSTALL_OK=1
  secure_state_tree "$STATE_DIR" || STATE_INSTALL_OK=0
  if ((STATE_INSTALL_OK)) && ! verify_state "$STATE_DIR"; then
    STATE_INSTALL_OK=0
  fi
  if ((STATE_INSTALL_OK == 0)); then
    mv -- "$STATE_DIR" "$BACKUP_DIR/failed-new-state"
    [[ -z $OLD_STATE || ! -d $OLD_STATE ]] || mv -- "$OLD_STATE" "$STATE_DIR"
    durable_directory "$DEST_VAR/lib"
    durable_directory "$BACKUP_DIR"
    die 'installed state failed verification; previous destination was restored'
  fi
  durable_directory "$STATE_DIR"
  say "state installed and verified: $STATE_DIR"
fi

install -d -m 700 "$LOG_DIR"
validate_file_target "$LOG_PATH" 'pizarra log'
if [[ -n ${SOURCE_LOG:-} && -f $SOURCE_LOG ]] && ! same_existing_path "$SOURCE_LOG" "$LOG_PATH"; then
  if [[ ! -e $LOG_PATH ]]; then
    install -m 600 -- "$SOURCE_LOG" "$LOG_PATH"
    say "log copied to $LOG_PATH"
  elif cmp -s -- "$SOURCE_LOG" "$LOG_PATH"; then
    chmod 600 "$LOG_PATH"
  elif (( $(mtime "$LOG_PATH") > $(mtime "$SOURCE_LOG") )); then
    cp -p -- "$SOURCE_LOG" "$BACKUP_DIR/log-from-source"
    warn "destination log is newer; kept it and preserved the source log in $BACKUP_DIR/log-from-source"
  else
    cp -p -- "$LOG_PATH" "$BACKUP_DIR/replaced-log"
    install -m 600 -- "$SOURCE_LOG" "$LOG_PATH"
  fi
fi
chmod 700 "$LOG_DIR"
[[ ! -f $LOG_PATH ]] || chmod 600 "$LOG_PATH"
if ((RUNNING_AS_ROOT)); then
  chown -- "$PIZARRA_OWNER:$PIZARRA_GROUP" "$LOG_DIR"
  [[ ! -f $LOG_PATH ]] || chown -- "$PIZARRA_OWNER:$PIZARRA_GROUP" "$LOG_PATH"
fi
[[ ! -f $LOG_PATH ]] || durable_file "$LOG_PATH"

if ((STATE_IS_CANONICAL)); then
  install_canonical_releases
fi

backup_config_target() {
  local target=$1 relative=$2 backup
  backup=$BACKUP_DIR/replaced-configs/$relative
  [[ -f $target ]] || return 0
  install -d -m 700 "$(dirname -- "$backup")"
  cp -p -- "$target" "$backup"
}

atomic_install_config() {
  local staged=$1 target=$2 relative=$3 source_ref=$4 required=${5:-0}
  local target_time source_time tmp
  validate_file_target "$target" "config $relative"
  ensure_directory "$(dirname -- "$target")" 711 1
  if [[ -f $target ]] && cmp -s -- "$staged" "$target"; then
    chmod 600 "$target"
    durable_file "$target"
    say "config already current: $target"
    return
  fi
  if [[ -f $target ]] && ! same_existing_path "$target" "$source_ref"; then
    target_time=$(mtime "$target")
    source_time=$(mtime "$source_ref")
    if ((target_time >= source_time)); then
      if ((required)); then
        die "refusing to overwrite same-age/newer required config: $target (select it explicitly if it is authoritative)"
      fi
      warn "kept same-age/newer config: $target (candidate was $source_ref)"
      return
    fi
  fi
  backup_config_target "$target" "$relative"
  tmp=$target.migrate-$$
  install -m 600 -- "$staged" "$tmp"
  mv -f -- "$tmp" "$target"
  durable_file "$target"
  say "config installed: $target"
}

atomic_install_config "$WORK/config/pizarra.conf" "$CONFIG_DIR/pizarra.conf" \
  pizarra.conf "$PIZARRA_SOURCE" 1
if [[ -f $WORK/config/pzweb.conf ]]; then
  atomic_install_config "$WORK/config/pzweb.conf" "$CONFIG_DIR/pzweb.conf" \
    pzweb.conf "$PZWEB_SOURCE" 0
fi
for relative in "${!AUX_SOURCE[@]}"; do
  atomic_install_config "$WORK/config/$relative" "$CONFIG_DIR/$relative" \
    "$relative" "${AUX_SOURCE[$relative]}" 0
done

secure_config_layout
durable_directory "$CONFIG_DIR"
if ((STATE_IS_CANONICAL)); then
  secure_state_tree "$STATE_DIR"
fi
verify_state "$STATE_DIR" || die 'final state verification failed'
[[ -d $RELEASE_DIR && ! -L $RELEASE_DIR ]] ||
  die "final canonical release directory is missing or linked: $RELEASE_DIR"
[[ -z $(find "$RELEASE_DIR" -type l -print -quit) ]] ||
  die "final canonical release directory contains a symbolic link: $RELEASE_DIR"
[[ -z $(find "$RELEASE_DIR" -mindepth 1 ! -type d ! -type f -print -quit) ]] ||
  die "final canonical release directory contains an unsupported entry: $RELEASE_DIR"
if ((RELEASE_SOURCE_PRESENT)); then
  release_payload_manifest "$RELEASE_DIR" "$WORK/releases-final.sha256" ||
    die 'cannot manifest final canonical releases'
  cmp -s -- "$WORK/releases-snapshot.sha256" "$WORK/releases-final.sha256" ||
    die 'final canonical releases differ from the verified source snapshot'
fi
record_installed_state "$STATE_DIR"
durable_directory "$STATE_DIR"

find "$CONFIG_DIR" -type f -print0 | sort -z | xargs -0 sha256sum >"$BACKUP_DIR/config.sha256"
find "$STATE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum >"$BACKUP_DIR/state.sha256"
chmod 600 "$BACKUP_DIR/config.sha256" "$BACKUP_DIR/state.sha256"

cat >"$BACKUP_DIR/ROLLBACK.txt" <<EOF
No source was removed and no process/session was stopped.

Previous destination files that were replaced are under:
  $BACKUP_DIR/replaced-configs
Their original ownership and mode are preserved beneath the private 0700
rollback directory.

If a previous state directory existed (explicit replacement or safe refresh),
it is:
  $BACKUP_DIR/state-before

Restore only while the hub is stopped. Move the new state aside (do not delete
it), restore state-before if present, and copy the required replaced configs
back to $CONFIG_DIR. Otherwise the unchanged original source remains at:
  config: $PIZARRA_SOURCE
  state:  $STATE_SOURCE
  releases: ${SOURCE_RELEASES:-none}

If present, restore $BACKUP_DIR/installed-state.record-before together with the
old state to $TRUSTED_STATE_RECORD; otherwise remove the newer trusted record
while stopped so a later migration requires an explicit authority choice.

Canonical ownership after migration is:
  $CONFIG_DIR                 $PIZARRA_OWNER:$PIZARRA_GROUP 0711
  $CONFIG_DIR/agents          root:root 0711
  $STATE_DIR, $RELEASE_DIR,
  and $LOG_DIR                $PIZARRA_OWNER:$PIZARRA_GROUP 0700
EOF
chmod 600 "$BACKUP_DIR/ROLLBACK.txt"
durable_directory "$BACKUP_ROOT"

say "migration complete; rollback bundle: $BACKUP_DIR"
say 'no service or tmux session was stopped/restarted'
say 'before restarting on the canonical paths, stop the old hub manually and rerun this command once to capture its final writes'
