#!/usr/bin/env bash
# Transactional installer for a canonical Pizarra systemd deployment.
#
# A real-root install publishes only artifacts already certified by `make test`,
# initializes/verifies the canonical store, starts the hub, and commits its
# manifest only after authenticated protocol health succeeds. DESTDIR stages
# the identical payload and manifest without inspecting or changing the host.
# `adopt` is the explicit first transactional cutover from a stopped, already
# migrated installation. It preserves a reviewed existing tmux server and takes
# ownership of known payload paths only after an exact session inventory match.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
MODE=${1:-install}

BINDIR=${BINDIR:-/usr/local/bin}
DATADIR=${DATADIR:-/usr/local/share/pizarra}
UNITDIR=${UNITDIR:-/etc/systemd/system}
DESTDIR=${DESTDIR:-}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
TMUX_BIN=${TMUX_BIN:-}
FAIL_STEP=${PIZARRA_INSTALL_FAIL_STEP:-}
ADOPT_TMUX_SESSIONS=${PIZARRA_ADOPT_TMUX_SESSIONS:-}

CONFIG_DIR=/etc/pizarra
STATE_DIR=/var/lib/pizarra
LOG_DIR=/var/log/pizarra
INSTALL_STATE=/var/lib/pizarra-installer

say() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { printf '%s: ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

usage() {
  printf '%s\n' \
    "Usage: $PROGRAM install|adopt|uninstall" \
    '' \
    'Environment:' \
    '  BINDIR=/usr/local/bin' \
    '  DATADIR=/usr/local/share/pizarra' \
    '  UNITDIR=/etc/systemd/system' \
    '  DESTDIR=/tmp/package-root   stage only; never bootstrap/start/systemctl' \
    '  PIZARRA_ADOPT_TMUX_SESSIONS=name,...  exact reviewed live inventory' \
    '' \
    'Install requires build/release/verified.manifest from a successful make test.' \
    'A real install enables only pizarra-tmux.service and pizarra.service.' \
    '`adopt` requires a stopped hub and an already migrated canonical layout.' \
    'The tiza and pzweb units are installed but remain opt-in.'
}

case $MODE in
  install|adopt|uninstall) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; die "unknown operation: $MODE" ;;
esac

validate_path() {
  local label=$1 value=$2 wrapped
  [[ $value == /* ]] || die "$label must be absolute: $value"
  [[ $value != / ]] || die "$label may not be filesystem root"
  [[ $value != */ ]] || die "$label may not end in /: $value"
  [[ $value != *//* && $value != *$'\n'* && $value != *$'\t'* ]] ||
    die "$label has an unsafe separator: $value"
  wrapped=/${value#/}/
  [[ $wrapped != */./* && $wrapped != */../* ]] ||
    die "$label may not contain . or .. components: $value"
  [[ $value =~ ^/[A-Za-z0-9._/+:-]+$ ]] ||
    die "$label contains unsupported characters: $value"
}

validate_path BINDIR "$BINDIR"
validate_path DATADIR "$DATADIR"
validate_path UNITDIR "$UNITDIR"
validate_path CONFIG_DIR "$CONFIG_DIR"
validate_path STATE_DIR "$STATE_DIR"
validate_path LOG_DIR "$LOG_DIR"
validate_path INSTALL_STATE "$INSTALL_STATE"

if [[ -n $DESTDIR ]]; then
  validate_path DESTDIR "$DESTDIR"
  [[ -d $DESTDIR && ! -L $DESTDIR ]] ||
    die "DESTDIR must already be a real directory: $DESTDIR"
  DESTDIR=$(cd -- "$DESTDIR" && pwd -P)
fi

rooted() { printf '%s%s\n' "$DESTDIR" "$1"; }

ROOT_BINDIR=$(rooted "$BINDIR")
ROOT_DATADIR=$(rooted "$DATADIR")
ROOT_UNITDIR=$(rooted "$UNITDIR")
ROOT_CONFIG_DIR=$(rooted "$CONFIG_DIR")
ROOT_STATE_DIR=$(rooted "$STATE_DIR")
ROOT_LOG_DIR=$(rooted "$LOG_DIR")
ROOT_INSTALL_STATE=$(rooted "$INSTALL_STATE")
CURRENT_MANIFEST=$ROOT_INSTALL_STATE/current.manifest

for tool in awk chmod chown cmp cp date dirname find grep install mktemp mv \
            readlink rm rmdir sed sha256sum sort stat sync tail tr; do
  command -v "$tool" >/dev/null 2>&1 || die "required command is missing: $tool"
done

if [[ -z $DESTDIR ]]; then
  ((EUID == 0)) || die 'real service installation must run as root'
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || die "systemctl is missing: $SYSTEMCTL"
  [[ -n $TMUX_BIN ]] || TMUX_BIN=$(command -v tmux 2>/dev/null || true)
  [[ -n $TMUX_BIN && -x $TMUX_BIN ]] || die 'tmux is required for the session boundary'
  validate_path TMUX_BIN "$TMUX_BIN"
else
  # A staged image records the normal target path. It must not discover a host
  # tmux binary merely because the build machine happens to have one elsewhere.
  [[ -n $TMUX_BIN ]] || TMUX_BIN=/usr/bin/tmux
  validate_path TMUX_BIN "$TMUX_BIN"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pizarra-service-install.XXXXXXXX")
STAGE=$WORK/stage
UNION_PATHS=$WORK/union.paths
DESIRED_PATHS=$WORK/desired.paths
ROLLBACK_NEEDED=0
ROLLBACK_KIND=''
BACKUP_DIR=''
MUTATION_STARTED=0
SYSTEM_SNAPSHOT_READY=0
PRESERVE_TMUX_BOUNDARY=0

remove_private_work() {
  case ${WORK:-} in
    "${TMPDIR:-/tmp}"/pizarra-service-install.*)
      [[ ! -d $WORK ]] || find "$WORK" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $WORK ]] || rmdir "$WORK" 2>/dev/null || true
      ;;
  esac
}

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

reject_symlink_components() {
  local path=$1 relative current part
  [[ $path == "$DESTDIR"/* || (-z $DESTDIR && $path == /*) ]] ||
    die "target escaped selected root: $path"
  relative=$path
  [[ -z $DESTDIR ]] || relative=${path#"$DESTDIR"}
  current=$DESTDIR
  while IFS= read -r part; do
    [[ -n $part ]] || continue
    current=$current/$part
    [[ ! -L $current ]] || die "target path contains a symbolic link: $current"
  done < <(printf '%s\n' "${relative#/}" | tr / '\n')
}

prepare_install_state() {
  local parent mode owner expected_owner
  parent=$(dirname -- "$ROOT_INSTALL_STATE")
  reject_symlink_components "$parent"
  reject_symlink_components "$ROOT_INSTALL_STATE"
  if [[ -e $ROOT_INSTALL_STATE || -L $ROOT_INSTALL_STATE ]]; then
    [[ -d $ROOT_INSTALL_STATE && ! -L $ROOT_INSTALL_STATE ]] ||
      die "installer state is not a real directory: $ROOT_INSTALL_STATE"
    mode=$(stat -Lc '%a' -- "$ROOT_INSTALL_STATE")
    [[ $mode == 700 ]] || die "installer state must be mode 0700: $ROOT_INSTALL_STATE"
    owner=$(stat -Lc '%u' -- "$ROOT_INSTALL_STATE")
    if [[ -z $DESTDIR ]]; then expected_owner=0; else expected_owner=$EUID; fi
    [[ $owner == "$expected_owner" ]] ||
      die "installer state has unexpected owner uid $owner: $ROOT_INSTALL_STATE"
  else
    install -d -m 0700 -- "$ROOT_INSTALL_STATE"
    reject_symlink_components "$ROOT_INSTALL_STATE"
  fi
  if [[ -e $CURRENT_MANIFEST || -L $CURRENT_MANIFEST ]]; then
    [[ -f $CURRENT_MANIFEST && ! -L $CURRENT_MANIFEST ]] ||
      die "current installer manifest is not a regular file: $CURRENT_MANIFEST"
  fi
}

manifest_rows() {
  local manifest=$1
  [[ -f $manifest && ! -L $manifest ]] || return 0
  awk -F '\t' '$1 == "file" { print $0 }' "$manifest"
}

manifest_has_path() {
  local manifest=$1 wanted=$2
  [[ -f $manifest ]] || return 1
  awk -F '\t' -v wanted="$wanted" '$1=="file" && $6==wanted { found=1 } END { exit !found }' "$manifest"
}

verify_manifest_files() {
  local manifest=$1 allow_missing=${2:-0}
  local kind sha mode uid gid logical target actual
  while IFS=$'\t' read -r kind sha mode uid gid logical; do
    [[ $kind == file ]] || continue
    validate_path 'manifest payload path' "$logical"
    target=$(rooted "$logical")
    reject_symlink_components "$target"
    if [[ ! -e $target ]]; then
      ((allow_missing)) && continue
      die "installed manifest file is missing: $target"
    fi
    [[ -f $target && ! -L $target ]] || die "installed target is not a regular file: $target"
    actual=$(sha256sum -- "$target" | awk '{print $1}')
    [[ $actual == "$sha" ]] || die "installed file was modified outside the installer: $target"
    [[ $(stat -Lc '%a' -- "$target") == "$mode" ]] || die "installed mode changed: $target"
    [[ $(stat -Lc '%u' -- "$target") == "$uid" ]] || die "installed owner changed: $target"
    [[ $(stat -Lc '%g' -- "$target") == "$gid" ]] || die "installed group changed: $target"
  done < <(manifest_rows "$manifest")
}

artifact_version() {
  "$1" --version | awk 'NR==1 { print $2; exit }'
}

verify_artifacts() {
  local verified=$REPO_ROOT/build/release/verified.manifest
  local expected version b built_bindir built_datadir
  [[ -f $verified && ! -L $verified ]] ||
    die 'verified release manifest is missing; run make test as the build user first'
  [[ $(sed -n '1p' "$verified") == pizarra-verified-artifacts-v2 ]] ||
    die 'verified release manifest has an unsupported format'
  if find "$REPO_ROOT/src" -type f -newer "$verified" -print -quit | grep -q .; then
    die 'source changed after make test; rebuild and verify before installing'
  fi
  (
    cd -- "$REPO_ROOT"
    tail -n +3 "$verified" | sha256sum -c --status
  ) || die 'a release artifact changed after make test'
  built_bindir=$(awk -F '\t' '$1 == "BINDIR" { print $2 }' \
    "$REPO_ROOT/build/install.paths")
  built_datadir=$(awk -F '\t' '$1 == "DATADIR" { print $2 }' \
    "$REPO_ROOT/build/install.paths")
  [[ $built_bindir == "$BINDIR" ]] ||
    die "verified binaries were built for BINDIR=$built_bindir, not $BINDIR; reconfigure and run make test"
  [[ $built_datadir == "$DATADIR" ]] ||
    die "verified binaries were built for DATADIR=$built_datadir, not $DATADIR; reconfigure and run make test"
  expected=$(sed -n '2s/^pizarra //p' "$verified")
  [[ -n $expected ]] || die 'verified release manifest has no suite version'
  for b in pizarra tiza pzweb; do
    [[ -x $REPO_ROOT/$b && ! -L $REPO_ROOT/$b ]] || die "verified binary is missing: $b"
    version=$(artifact_version "$REPO_ROOT/$b")
    [[ $version == "$expected" ]] || die "$b release $version differs from verified $expected"
  done
  "$REPO_ROOT/pizarra" --version | grep -q '^sqlite: [0-9]' ||
    die 'libsqlite3 is unavailable; the installed hub could not start'
  VERIFIED_MANIFEST=$verified
  PAYLOAD_VERSION=$expected
}

verified_source_sha() {
  local source=$1 relative expected
  [[ $source == "$REPO_ROOT"/* ]] || die "payload source escaped repository: $source"
  relative=${source#"$REPO_ROOT/"}
  expected=$(awk -v wanted="$relative" '$2 == wanted { print $1; found=1 }
    END { if (!found) exit 1 }' "$VERIFIED_MANIFEST") ||
    die "payload source was not certified by make test: $relative"
  [[ -n $expected ]] || die "certified payload has no hash: $relative"
  printf '%s\n' "$expected"
}

verify_private_copy() {
  local source=$1 copy=$2 expected actual
  expected=$(verified_source_sha "$source")
  actual=$(sha256sum -- "$copy" | awk '{print $1}')
  [[ $actual == "$expected" ]] ||
    die "payload source changed while it was copied: ${source#"$REPO_ROOT/"}"
}

stage_file() {
  local source=$1 logical=$2 mode=$3 target
  target=$STAGE$logical
  validate_path 'payload target' "$logical"
  install -D -m "$mode" -- "$source" "$target"
  verify_private_copy "$source" "$target"
}

render_path_file() {
  local source=$1 logical=$2 target private
  target=$STAGE$logical
  private=$WORK/unit-source/${source##*/}
  install -D -m 0600 -- "$source" "$private"
  verify_private_copy "$source" "$private"
  install -d -m 0755 -- "$(dirname -- "$target")"
  awk -v bindir="$BINDIR" -v datadir="$DATADIR" -v tmuxbin="$TMUX_BIN" '
    {
      gsub("/usr/local/bin", bindir)
      gsub("/usr/local/share/pizarra", datadir)
      gsub("/usr/bin/tmux", tmuxbin)
      print
    }
  ' "$private" >"$target"
  chmod "${3:-0644}" "$target"
}

build_stage() {
  local source base unit
  install -d -m 0700 "$STAGE"
  stage_file "$REPO_ROOT/pizarra" "$BINDIR/pizarra" 0755
  stage_file "$REPO_ROOT/tiza" "$BINDIR/tiza" 0755
  stage_file "$REPO_ROOT/pzweb" "$BINDIR/pzweb" 0755
  for source in "$REPO_ROOT"/web/apps/*; do
    [[ -f $source && ! -L $source ]] || die "unsafe web asset: $source"
    base=${source##*/}
    stage_file "$source" "$DATADIR/web/apps/$base" 0644
  done
  for source in "$REPO_ROOT"/examples/*.example; do
    [[ -f $source && ! -L $source ]] || die "unsafe example: $source"
    base=${source##*/}
    render_path_file "$source" "$DATADIR/examples/$base" 0644
  done
  stage_file "$REPO_ROOT/systemd/tmux.conf" "$DATADIR/systemd/tmux.conf" 0644
  for unit in pizarra.service pizarra-tmux.service tiza.service pzweb.service; do
    render_path_file "$REPO_ROOT/systemd/$unit" "$UNITDIR/$unit" 0644
  done
  : >"$DESIRED_PATHS"
  while IFS= read -r -d '' source; do
    printf '%s\n' "${source#"$STAGE"}" >>"$DESIRED_PATHS"
  done < <(find "$STAGE" -type f -print0 | sort -z)
  sort -u -o "$DESIRED_PATHS" "$DESIRED_PATHS"
}

preflight_payload() {
  local logical target
  [[ ! -f $CURRENT_MANIFEST ]] || verify_manifest_files "$CURRENT_MANIFEST" 0
  while IFS= read -r logical; do
    validate_path 'manifest payload path' "$logical"
    target=$(rooted "$logical")
    reject_symlink_components "$target"
    if [[ -e $target ]] && ! manifest_has_path "$CURRENT_MANIFEST" "$logical" &&
       [[ $MODE != adopt ]]; then
      die "refusing to overwrite an unowned installation file: $target"
    fi
    if [[ -e $target ]]; then
      [[ -f $target && ! -L $target ]] ||
        die "installation target is not a regular file: $target"
    fi
  done <"$DESIRED_PATHS"
}

collect_union_paths() {
  cp -- "$DESIRED_PATHS" "$UNION_PATHS"
  if [[ -f $CURRENT_MANIFEST ]]; then
    manifest_rows "$CURRENT_MANIFEST" | awk -F '\t' '{ print $6 }' >>"$UNION_PATHS"
  fi
  sort -u -o "$UNION_PATHS" "$UNION_PATHS"
}

backup_payload() {
  local logical target backup
  install -d -m 0700 "$BACKUP_DIR/payload"
  : >"$BACKUP_DIR/payload-present"
  while IFS= read -r logical; do
    target=$(rooted "$logical")
    if [[ -f $target && ! -L $target ]]; then
      backup=$BACKUP_DIR/payload$logical
      install -d -m 0700 -- "$(dirname -- "$backup")"
      cp -a -- "$target" "$backup"
      printf '%s\n' "$logical" >>"$BACKUP_DIR/payload-present"
    fi
  done <"$UNION_PATHS"
  [[ ! -f $CURRENT_MANIFEST ]] || cp -a -- "$CURRENT_MANIFEST" "$BACKUP_DIR/manifest-before"
}

atomic_publish_payload() {
  local source logical target parent mode tmp old_sha old_mode old_uid old_gid
  while IFS= read -r -d '' source; do
    logical=${source#"$STAGE"}
    target=$(rooted "$logical")
    parent=$(dirname -- "$target")
    reject_symlink_components "$parent"
    install -d -m 0755 -- "$parent"
    reject_symlink_components "$target"
    mode=$(stat -Lc '%a' -- "$source")
    tmp=$target.pizarra-install-$$
    [[ ! -e $tmp && ! -L $tmp ]] || die "stale install temporary exists: $tmp"
    install -m "$mode" -- "$source" "$tmp"
    [[ -n $DESTDIR ]] || chown 0:0 -- "$tmp"
    sync -d -- "$tmp"
    mv -f -- "$tmp" "$target"
    sync -f -- "$parent"
  done < <(find "$STAGE" -type f -print0 | sort -z)

  # Prune only entries owned by the preceding manifest and absent from the new
  # payload. The full old payload was verified and backed up before this point.
  if [[ -f $CURRENT_MANIFEST ]]; then
    while IFS=$'\t' read -r _ old_sha old_mode old_uid old_gid logical; do
      grep -Fxq -- "$logical" "$DESIRED_PATHS" && continue
      target=$(rooted "$logical")
      [[ ! -e $target ]] || rm -f -- "$target"
    done < <(manifest_rows "$CURRENT_MANIFEST")
  fi
}

remove_tree_exact() {
  local target=$1 logical=$2
  [[ $target == "$(rooted "$logical")" ]] || die "internal unsafe tree target: $target"
  [[ ! -L $target ]] || die "refusing linked system tree: $target"
  [[ ! -d $target ]] || find "$target" -depth -mindepth 1 -delete
  [[ ! -d $target ]] || rmdir "$target"
}

snapshot_system_tree() {
  local logical target backup
  install -d -m 0700 "$BACKUP_DIR/system"
  : >"$BACKUP_DIR/system-present"
  for logical in "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"; do
    target=$(rooted "$logical")
    if [[ -e $target ]]; then
      [[ -d $target && ! -L $target ]] || die "canonical path is not a real directory: $target"
      backup=$BACKUP_DIR/system$logical
      install -d -m 0700 -- "$(dirname -- "$backup")"
      cp -a -- "$target" "$backup"
      printf '%s\n' "$logical" >>"$BACKUP_DIR/system-present"
    fi
  done
}

restore_system_tree() {
  local logical target source failed
  for logical in "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"; do
    target=$(rooted "$logical")
    source=$BACKUP_DIR/system$logical
    if [[ -e $target ]]; then
      failed=$BACKUP_DIR/failed-system$logical
      install -d -m 0700 -- "$(dirname -- "$failed")"
      [[ -e $failed ]] || cp -a -- "$target" "$failed"
      remove_tree_exact "$target" "$logical"
    fi
    if grep -Fxq -- "$logical" "$BACKUP_DIR/system-present"; then
      install -d -m 0755 -- "$(dirname -- "$target")"
      cp -a -- "$source" "$target"
    fi
  done
}

restore_payload() {
  local logical target source
  while IFS= read -r logical; do
    target=$(rooted "$logical")
    [[ ! -e $target ]] || rm -f -- "$target"
    if grep -Fxq -- "$logical" "$BACKUP_DIR/payload-present"; then
      source=$BACKUP_DIR/payload$logical
      install -d -m 0755 -- "$(dirname -- "$target")"
      cp -a -- "$source" "$target"
    fi
  done <"$UNION_PATHS"
}

declare -A WAS_ACTIVE=()
declare -A WAS_ENABLED=()
SERVICES=(pizarra.service tiza.service pzweb.service pizarra-tmux.service)

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
    section == tolower(wanted_section) {
      pos=index($0, "=")
      if (!pos) next
      key=tolower(trim(substr($0, 1, pos-1)))
      if (key == tolower(wanted_key)) {
        print trim(substr($0, pos+1))
        exit
      }
    }
  ' "$file"
}

validate_adopt_layout() {
  local file path mode owner unit sessions expected normalized_actual normalized_expected
  [[ -z $DESTDIR ]] || return 0
  for file in "$ROOT_CONFIG_DIR/pizarra.conf" "$ROOT_CONFIG_DIR/tiza.conf"; do
    [[ -f $file && ! -L $file ]] || die "adoption requires a real canonical config: $file"
    mode=$(stat -Lc '%a' -- "$file")
    owner=$(stat -Lc '%u' -- "$file")
    [[ $mode == 600 && $owner == 0 ]] ||
      die "adoption requires root-owned mode-0600 config: $file"
  done
  for path in "$ROOT_STATE_DIR" "$ROOT_LOG_DIR"; do
    [[ -d $path && ! -L $path ]] || die "adoption requires a real canonical directory: $path"
    [[ $(stat -Lc '%a' -- "$path") == 700 ]] ||
      die "adoption requires mode 0700: $path"
  done
  [[ $(ini_value "$ROOT_CONFIG_DIR/pizarra.conf" store dir) == "$STATE_DIR" ]] ||
    die "adoption requires [store] dir=$STATE_DIR"
  [[ $(ini_value "$ROOT_CONFIG_DIR/pizarra.conf" log path) == "$LOG_DIR/pizarra.log" ]] ||
    die "adoption requires [log] path=$LOG_DIR/pizarra.log"
  [[ $(ini_value "$ROOT_CONFIG_DIR/pizarra.conf" server releases) == "$STATE_DIR/releases" ]] ||
    die "adoption requires [server] releases=$STATE_DIR/releases"
  for unit in "${SERVICES[@]}"; do
    [[ ${WAS_ACTIVE[$unit]} == 0 && ${WAS_ENABLED[$unit]} == 0 ]] ||
      die "adoption requires the unmanaged/partial unit to be stopped and disabled: $unit"
  done
  if "$REPO_ROOT/tiza" --config "$ROOT_CONFIG_DIR/tiza.conf" --health >/dev/null 2>&1; then
    die 'adoption requires the old hub to be stopped; authenticated health still succeeds'
  fi

  sessions=$($TMUX_BIN list-sessions -F '#{session_name}' 2>/dev/null || true)
  if [[ -n $sessions ]]; then
    [[ -n $ADOPT_TMUX_SESSIONS ]] ||
      die "tmux sessions exist; review them and repeat with PIZARRA_ADOPT_TMUX_SESSIONS=name,...: ${sessions//$'\n'/, }"
    if printf '%s\n' "$sessions" | grep -Fxq -e pizarra -e pzweb; then
      die 'the old pizarra/pzweb tmux service session still exists; stop only that reviewed service session before adoption'
    fi
    normalized_actual=$WORK/adopt-actual.sessions
    normalized_expected=$WORK/adopt-expected.sessions
    printf '%s\n' "$sessions" | sed '/^[[:space:]]*$/d' | sort -u >"$normalized_actual"
    printf '%s\n' "$ADOPT_TMUX_SESSIONS" | tr ',' '\n' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' | sort -u >"$normalized_expected"
    cmp -s "$normalized_actual" "$normalized_expected" ||
      die "live tmux inventory differs from PIZARRA_ADOPT_TMUX_SESSIONS; actual: ${sessions//$'\n'/, }"
  elif [[ -n $ADOPT_TMUX_SESSIONS ]]; then
    die 'PIZARRA_ADOPT_TMUX_SESSIONS was supplied but no tmux server/session exists'
  fi
}

record_service_state() {
  local unit
  for unit in "${SERVICES[@]}"; do
    if "$SYSTEMCTL" is-active --quiet "$unit"; then WAS_ACTIVE[$unit]=1; else WAS_ACTIVE[$unit]=0; fi
    if "$SYSTEMCTL" is-enabled --quiet "$unit"; then WAS_ENABLED[$unit]=1; else WAS_ENABLED[$unit]=0; fi
  done
}

write_service_state() {
  local unit
  : >"$BACKUP_DIR/service-state"
  for unit in "${SERVICES[@]}"; do
    printf '%s\t%s\t%s\n' "$unit" "${WAS_ACTIVE[$unit]}" "${WAS_ENABLED[$unit]}" >>"$BACKUP_DIR/service-state"
  done
}

restore_service_state() {
  local unit active enabled
  [[ -z $DESTDIR ]] || return 0
  "$SYSTEMCTL" daemon-reload || return 1
  while IFS=$'\t' read -r unit active enabled; do
    if [[ $unit == pizarra-tmux.service ]] && ((PRESERVE_TMUX_BOUNDARY)); then
      "$SYSTEMCTL" enable "$unit" >/dev/null || return 1
      continue
    fi
    if ((enabled)); then "$SYSTEMCTL" enable "$unit" >/dev/null || return 1
    else "$SYSTEMCTL" disable "$unit" >/dev/null 2>&1 || true
    fi
  done <"$BACKUP_DIR/service-state"
  # The tmux boundary precedes every component that may connect to it.
  while IFS=$'\t' read -r unit active enabled; do
    [[ $unit == pizarra-tmux.service ]] || continue
    if ((active || PRESERVE_TMUX_BOUNDARY)); then
      "$SYSTEMCTL" start "$unit" || return 1
    fi
  done <"$BACKUP_DIR/service-state"
  for unit in pizarra.service tiza.service pzweb.service; do
    active=${WAS_ACTIVE[$unit]:-0}
    if ((active)); then "$SYSTEMCTL" start "$unit" || return 1; fi
  done
}

rollback_transaction() {
  local rc=0 sessions
  say "rolling back incomplete $ROLLBACK_KIND transaction from $BACKUP_DIR"
  if [[ -z $DESTDIR ]]; then
    "$SYSTEMCTL" stop pzweb.service tiza.service pizarra.service \
      >/dev/null 2>&1 || true
    if [[ ${WAS_ACTIVE[pizarra-tmux.service]:-0} == 0 ]]; then
      sessions=$($TMUX_BIN list-sessions -F '#{session_name}' 2>/dev/null || true)
      if [[ -n $sessions ]]; then
        PRESERVE_TMUX_BOUNDARY=1
        say "rollback is preserving the tmux boundary because sessions exist: ${sessions//$'\n'/, }"
      else
        "$SYSTEMCTL" stop pizarra-tmux.service >/dev/null 2>&1 || true
      fi
    fi
  fi
  if ((SYSTEM_SNAPSHOT_READY)); then
    restore_system_tree || rc=1
  fi
  restore_payload || rc=1
  if [[ -f $BACKUP_DIR/manifest-before ]]; then
    install -d -m 0700 "$ROOT_INSTALL_STATE"
    cp -a -- "$BACKUP_DIR/manifest-before" "$CURRENT_MANIFEST"
  else
    rm -f -- "$CURRENT_MANIFEST"
  fi
  restore_service_state || rc=1
  if [[ -z $DESTDIR && $ROLLBACK_KIND == upgrade && ${WAS_ACTIVE[pizarra.service]:-0} == 1 ]]; then
    "$ROOT_BINDIR/tiza" --config "$ROOT_CONFIG_DIR/tiza.conf" --health --wait 30 || rc=1
  fi
  if ((rc)); then
    printf '%s: CRITICAL: rollback needs manual completion; preserve %s\n' "$PROGRAM" "$BACKUP_DIR" >&2
    return 1
  fi
  say 'rollback completed; previous payload, durable state, and service state restored'
  if ((PRESERVE_TMUX_BOUNDARY)); then
    say 'tmux boundary intentionally remains enabled/active; existing team sessions were not touched'
  fi
}

cleanup() {
  local status=$?
  trap - EXIT
  if ((ROLLBACK_NEEDED)); then
    rollback_transaction || status=1
  fi
  remove_private_work
  exit "$status"
}
trap cleanup EXIT

failpoint() {
  local step=$1
  [[ $FAIL_STEP != "$step" ]] || die "injected failure at $step"
}

write_manifest() {
  local tmp=$ROOT_INSTALL_STATE/current.manifest.new-$$
  local source logical target sha mode uid gid
  install -d -m 0700 "$ROOT_INSTALL_STATE"
  {
    printf 'pizarra-install-manifest-v1\n'
    printf 'meta\tversion\t%s\n' "$PAYLOAD_VERSION"
    printf 'meta\tbindir\t%s\n' "$BINDIR"
    printf 'meta\tdatadir\t%s\n' "$DATADIR"
    printf 'meta\tunitdir\t%s\n' "$UNITDIR"
    while IFS= read -r logical; do
      target=$(rooted "$logical")
      sha=$(sha256sum -- "$target" | awk '{print $1}')
      mode=$(stat -Lc '%a' -- "$target")
      uid=$(stat -Lc '%u' -- "$target")
      gid=$(stat -Lc '%g' -- "$target")
      printf 'file\t%s\t%s\t%s\t%s\t%s\n' "$sha" "$mode" "$uid" "$gid" "$logical"
    done <"$DESIRED_PATHS"
  } >"$tmp"
  chmod 0600 "$tmp"
  sync -d -- "$tmp"
  mv -f -- "$tmp" "$CURRENT_MANIFEST"
  sync -f -- "$ROOT_INSTALL_STATE"
}

install_mode() {
  local stamp fresh=0 unit
  verify_artifacts
  build_stage
  prepare_install_state
  preflight_payload
  collect_union_paths
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
  install -d -m 0700 "$ROOT_INSTALL_STATE/backups"
  BACKUP_DIR=$ROOT_INSTALL_STATE/backups/$stamp
  install -d -m 0700 "$BACKUP_DIR"

  if [[ -f $CURRENT_MANIFEST ]]; then
    [[ $MODE != adopt ]] || die 'adopt is only for the first manifest-backed cutover; use install for upgrades'
    ROLLBACK_KIND=upgrade
  elif [[ $MODE == adopt ]]; then
    ROLLBACK_KIND=adopt
  else
    ROLLBACK_KIND=fresh-install
    fresh=1
  fi

  if [[ -z $DESTDIR ]]; then
    record_service_state
    if [[ $ROLLBACK_KIND == adopt ]]; then
      validate_adopt_layout
    elif ((fresh)); then
      for unit in "${SERVICES[@]}"; do
        [[ ${WAS_ACTIVE[$unit]} == 0 && ${WAS_ENABLED[$unit]} == 0 ]] ||
          die "fresh install refuses existing service state: $unit"
      done
      [[ ! -e $ROOT_CONFIG_DIR && ! -e $ROOT_STATE_DIR && ! -e $ROOT_LOG_DIR ]] ||
        die 'canonical config/state/log already exist; use the reviewed migration/upgrade path instead of fresh install'
      if "$TMUX_BIN" show-options -gv exit-empty >/dev/null 2>&1; then
        die 'a tmux server already exists for this service account; migrate it explicitly before installing the session boundary'
      fi
    else
      [[ ${WAS_ACTIVE[pizarra.service]} == 1 && ${WAS_ENABLED[pizarra.service]} == 1 ]] ||
        die 'transactional upgrade requires the previously installed hub to be enabled and healthy'
      "$ROOT_BINDIR/tiza" --config "$ROOT_CONFIG_DIR/tiza.conf" --health ||
        die 'previous hub failed strict health; repair it before upgrade'
      if [[ ${WAS_ACTIVE[pizarra-tmux.service]} == 0 ]] &&
         "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
        die 'existing tmux sessions are not owned by pizarra-tmux.service; migrate them before upgrade'
      fi
    fi
    write_service_state
  else
    for unit in "${SERVICES[@]}"; do WAS_ACTIVE[$unit]=0; WAS_ENABLED[$unit]=0; done
    write_service_state
  fi

  backup_payload
  # A failed stop or snapshot must still restore the pre-transaction service
  # state. Durable trees are restored only after the complete snapshot marker
  # below has been published.
  ROLLBACK_NEEDED=1
  if [[ -z $DESTDIR && $ROLLBACK_KIND == upgrade ]]; then
    "$SYSTEMCTL" stop pzweb.service tiza.service pizarra.service
  fi
  snapshot_system_tree
  SYSTEM_SNAPSHOT_READY=1
  MUTATION_STARTED=1

  atomic_publish_payload
  failpoint after-payload

  if [[ -n $DESTDIR ]]; then
    write_manifest
    failpoint after-manifest
    ROLLBACK_NEEDED=0
    say "staged verified Pizarra $PAYLOAD_VERSION below $DESTDIR; no host service, config, state, process, or session was touched"
    return
  fi

  "$ROOT_BINDIR/pizarra" --migrate-only
  failpoint after-migrate
  "$SYSTEMCTL" daemon-reload
  failpoint after-daemon-reload
  "$SYSTEMCTL" enable pizarra-tmux.service pizarra.service >/dev/null
  "$SYSTEMCTL" start pizarra-tmux.service
  "$SYSTEMCTL" restart pizarra.service
  failpoint after-start
  "$ROOT_BINDIR/tiza" --config "$ROOT_CONFIG_DIR/tiza.conf" --health --wait 30

  # Restore only optional components that were active before the transaction.
  for unit in tiza.service pzweb.service; do
    if [[ ${WAS_ENABLED[$unit]:-0} == 1 ]]; then "$SYSTEMCTL" enable "$unit" >/dev/null; fi
    if [[ ${WAS_ACTIVE[$unit]:-0} == 1 ]]; then "$SYSTEMCTL" start "$unit"; fi
  done
  failpoint after-optional-start
  write_manifest
  failpoint after-manifest
  ROLLBACK_NEEDED=0
  say "PASS: Pizarra $PAYLOAD_VERSION installed and authenticated health is ready"
  say 'enabled: pizarra-tmux.service, pizarra.service; optional tiza/pzweb units remain disabled unless they were previously active'
  say "rollback evidence retained at $BACKUP_DIR"
}

uninstall_mode() {
  local stamp archive kind sha mode uid gid logical target unit sessions
  if [[ ! -e $ROOT_INSTALL_STATE && ! -L $ROOT_INSTALL_STATE ]]; then
    say 'already uninstalled: no installer state exists'
    return
  fi
  prepare_install_state
  if [[ ! -f $CURRENT_MANIFEST ]]; then
    say 'already uninstalled: no current installer manifest exists'
    return
  fi
  [[ $(sed -n '1p' "$CURRENT_MANIFEST") == pizarra-install-manifest-v1 ]] ||
    die 'current installer manifest has an unsupported format'
  verify_manifest_files "$CURRENT_MANIFEST" 1

  if [[ -z $DESTDIR ]]; then
    sessions=$($TMUX_BIN list-sessions -F '#{session_name}' 2>/dev/null || true)
    [[ -z $sessions ]] || die "managed tmux sessions still exist; stop/review them before uninstall: ${sessions//$'\n'/, }"
    BACKUP_DIR=$WORK/uninstall-service-state
    install -d -m 0700 "$BACKUP_DIR"
    record_service_state
    write_service_state
    if ! "$SYSTEMCTL" stop pzweb.service tiza.service pizarra.service; then
      restore_service_state || true
      die 'could not stop every Pizarra process; payload remains installed'
    fi
    for unit in pzweb.service tiza.service pizarra.service; do
      if "$SYSTEMCTL" is-active --quiet "$unit"; then
        restore_service_state || true
        die "service remained active after stop: $unit"
      fi
    done
    sessions=$($TMUX_BIN list-sessions -F '#{session_name}' 2>/dev/null || true)
    if [[ -n $sessions ]]; then
      restore_service_state || true
      die "managed sessions appeared during uninstall; restored service state: ${sessions//$'\n'/, }"
    fi
    if ! "$SYSTEMCTL" stop pizarra-tmux.service ||
       "$SYSTEMCTL" is-active --quiet pizarra-tmux.service; then
      restore_service_state || true
      die 'tmux boundary did not stop cleanly; payload remains installed'
    fi
    if ! "$SYSTEMCTL" disable pzweb.service tiza.service pizarra.service \
         pizarra-tmux.service >/dev/null; then
      restore_service_state || true
      die 'could not disable every installed unit; payload remains installed'
    fi
    for unit in pzweb.service tiza.service pizarra.service pizarra-tmux.service; do
      if "$SYSTEMCTL" is-enabled --quiet "$unit"; then
        restore_service_state || true
        die "service remained enabled after disable: $unit"
      fi
    done
  fi

  while IFS=$'\t' read -r kind sha mode uid gid logical; do
    [[ $kind == file ]] || continue
    validate_path 'manifest payload path' "$logical"
    target=$(rooted "$logical")
    [[ ! -e $target ]] || rm -f -- "$target"
  done < <(manifest_rows "$CURRENT_MANIFEST")

  [[ -n $DESTDIR ]] || "$SYSTEMCTL" daemon-reload
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
  archive=$ROOT_INSTALL_STATE/uninstalled-$stamp.manifest
  mv -- "$CURRENT_MANIFEST" "$archive"
  sync -f -- "$ROOT_INSTALL_STATE"
  for target in "$ROOT_DATADIR/web/apps" "$ROOT_DATADIR/examples" "$ROOT_DATADIR/systemd" \
                "$ROOT_DATADIR/web" "$ROOT_DATADIR" "$ROOT_BINDIR" "$ROOT_UNITDIR"; do
    [[ ! -d $target || -L $target ]] || rmdir "$target" 2>/dev/null || true
  done
  say 'uninstalled only unchanged manifest-owned payload and units'
  say "preserved configuration, state, logs, backups, shared/NFS references, and audit manifest $archive"
}

if [[ $MODE == install || $MODE == adopt ]]; then
  install_mode
else
  uninstall_mode
fi
