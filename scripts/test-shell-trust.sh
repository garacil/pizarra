#!/usr/bin/env bash
# Integration test for the `tiza shell` trust model.
#
# It proves that [server] shell_trust is its OWN grant, separate from
# attach_trust: with shell_trust = all any authenticated team opens a shell
# with its own credential and the hub records the real identity; with only
# attach_trust set, that same team attaches but is refused a shell; and the
# named-list form admits exactly the identities it names.
# Only pztest-* sessions are created or removed, always by exact name.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-shell-trust.XXXXXXXX)
HUB_PID=''

unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export TMUX_SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
export TMUX_CONF="$TEST_ROOT/tmux.conf"
install -d -m 0700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$(id -u)"
printf '%s\n' 'set -g status off' 'set -g window-size manual' >"$TMUX_CONF"
tmux() {
  if [[ ${1:-} == send-keys ]]; then
    shift
    command tmux -S "$TMUX_SOCK" -f "$TMUX_CONF" send-keys -c pztest-no-client "$@"
  else
    command tmux -S "$TMUX_SOCK" -f "$TMUX_CONF" "$@"
  fi
}
export -f tmux

fail() {
  printf 'not ok: %s\n' "$*" >&2
  for f in hub.out log/pizarra.log; do
    [[ -f $TEST_ROOT/$f ]] && { printf -- '--- %s ---\n' "$f" >&2; tail -25 "$TEST_ROOT/$f" >&2 || true; }
  done
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }
contains() { [[ $1 == *"$2"* ]] || fail "$3 (missing '$2' in: ${1:0:400})"; }
wait_file() { local f=$1 p=$2 s=$3 i; for ((i=0;i<s*10;i++)); do [[ -f $f ]] && grep -q -- "$p" "$f" && return 0; sleep 0.1; done; return 1; }
wait_cmd()  { local s=$1 i; shift; for ((i=0;i<s*10;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
port_open() { (: <>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
stop_hub() {
  local a
  [[ -n ${HUB_PID:-} ]] || return 0
  if kill -0 "$HUB_PID" 2>/dev/null; then
    kill "$HUB_PID" 2>/dev/null || true
    for a in {1..100}; do kill -0 "$HUB_PID" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$HUB_PID" 2>/dev/null && kill -KILL "$HUB_PID" 2>/dev/null || true
  fi
  HUB_PID=''
}
cleanup() {
  stop_hub
  local s
  for s in pztest-host pztest-keep pztest-t1 pztest-t2 pztest-t3 pztest-t4; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  case ${TEST_ROOT:-} in
    /tmp/pizarra-shell-trust.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT

for t in tmux grep sleep mktemp find id; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"; done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'

# The account the shell opens as. Named nowhere in this file on purpose: a real
# account name is operational data. Unprivileged, the only account we can log in
# as is our own, which takes the direct login-shell branch. As root, discover any
# ordinary account with a real login shell so the production `su - <account>`
# branch is what runs. PIZARRA_TEST_SHELL_USER overrides either.
pick_account() {
  local line name uid sh
  if [[ -n ${PIZARRA_TEST_SHELL_USER:-} ]]; then
    printf '%s\n' "$PIZARRA_TEST_SHELL_USER"
    return 0
  fi
  if [[ $(id -u) != 0 ]]; then
    id -un
    return 0
  fi
  while IFS= read -r line; do
    name=${line%%:*}
    uid=$(printf '%s' "$line" | cut -d: -f3)
    sh=${line##*:}
    [[ $name == root ]] && continue
    [[ $uid =~ ^[0-9]+$ ]] || continue
    ((uid >= 1000 && uid < 60000)) || continue
    case $sh in
      */nologin | */false | '') continue ;;
    esac
    [[ -x $sh ]] || continue
    printf '%s\n' "$name"
    return 0
  done < <(getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null)
  return 1
}
ACCT=$(pick_account) || fail 'no usable account; set PIZARRA_TEST_SHELL_USER'
ok "shell account for this run: $ACCT"

choose_port() {
  local a c
  for a in {1..300}; do c=$((20000 + ((BASHPID + RANDOM + a) % 30000))); port_open "$c" || { printf '%s\n' "$c"; return 0; }; done
  return 1
}
PORT=$(choose_port)
SEC=synthetic-master-secret
ASEC=synthetic-alpha-secret
BSEC=synthetic-beta-secret
STORE=$TEST_ROOT/store; LOG=$TEST_ROOT/log
install -d -m 0700 "$STORE" "$LOG"

tmux new-session -d -s pztest-keep -x 80 -y 24 'exec /bin/sh' || fail 'no bystander'

# write_hub_conf <attach_trust> <shell_trust>
write_hub_conf() {
  {
    printf '%s\n' '[server]' 'listen = 127.0.0.1' "port = $PORT" \
      "secret = $SEC" 'master_console_only = on' \
      'attach_local = on' 'shell_local = on' "shell_user = $ACCT"
    [[ -z $1 ]] || printf 'attach_trust = %s\n' "$1"
    [[ -z $2 ]] || printf 'shell_trust = %s\n' "$2"
    printf '\n%s\n' '[registry]' 'authority = sqlite'
    printf '\n%s\n' '[store]' "dir = $STORE"
    printf '\n%s\n' '[log]' "path = $LOG/pizarra.log"
    printf '\n%s\n' '[team:1]' 'name = box' \
      'speciality = the local host every shell here targets' \
      'tmux_session = pztest-keep'
    printf '\n%s\n' '[team:2]' 'name = alpha' \
      'speciality = an ordinary team with its own credential' \
      "secret = $ASEC" 'tmux_session = -'
    printf '\n%s\n' '[team:3]' 'name = beta' \
      'speciality = an ordinary team NOT named in any trust list' \
      "secret = $BSEC" 'tmux_session = -'
  } >"$TEST_ROOT/hub.conf"
  chmod 0600 "$TEST_ROOT/hub.conf"
}
mkconf() {   # mkconf FILE SELF SECRET
  cat >"$1" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = $3
self = $2
EOF
  chmod 0600 "$1"
}
mkconf "$TEST_ROOT/console.conf" console "$SEC"
mkconf "$TEST_ROOT/alpha.conf"   alpha   "$ASEC"
mkconf "$TEST_ROOT/beta.conf"    beta    "$BSEC"

start_hub() {
  rm -f "$TEST_ROOT/hub.out"
  tmux kill-session -t =pztest-host 2>/dev/null || true
  wait_cmd 5 bash -c "! tmux has-session -t pztest-host 2>/dev/null" || true
  tmux new-session -d -s pztest-host -x 100 -y 30 \
    "exec '$HUB_BIN' --config '$TEST_ROOT/hub.conf' >'$TEST_ROOT/hub.out' 2>&1" || fail 'no hub session'
  wait_cmd 10 "$TIZA_BIN" --config "$TEST_ROOT/console.conf" --health --wait 1 || fail 'hub not healthy'
  HUB_PID=$(pgrep -f -- "--config $TEST_ROOT/hub.conf" | head -1 || true)
  [[ -n $HUB_PID ]] || fail 'could not find the hub pid'
}

# run_as SESS CONF VERB ARGS...
run_as() {
  local sess=$1 conf=$2; shift 2
  local IFS=' '; local args="$*"
  rm -f "$TEST_ROOT/$sess.err"
  case $sess in
    pztest-*) tmux kill-session -t "=$sess" 2>/dev/null || true ;;
    *) fail "refusing a non-pztest session name: $sess" ;;
  esac
  tmux new-session -d -s "$sess" -x 90 -y 28 \
    "'$TIZA_BIN' --config '$conf' $args 2>'$TEST_ROOT/$sess.err'; echo CX=\$? >>'$TEST_ROOT/$sess.err'; sleep 3" \
    || fail "could not start $sess"
}

# 1. shell_trust = all: an ordinary team opens a shell with its OWN credential.
write_hub_conf '' all
start_hub
run_as pztest-t1 "$TEST_ROOT/alpha.conf" shell box
wait_file "$TEST_ROOT/pztest-t1.err" 'tiza shell:' 15 ||
  fail 'a trusted ordinary team could not open a shell'
contains "$(<"$TEST_ROOT/pztest-t1.err")" "$ACCT@" 'banner names the account'
tmux send-keys -t pztest-t1 'id -un' Enter
wait_cmd 15 bash -c "tmux capture-pane -p -t pztest-t1 | grep -q '^$ACCT\$'" ||
  fail 'the shell did not answer id -un'
tmux send-keys -t pztest-t1 'exit' Enter
wait_file "$TEST_ROOT/pztest-t1.err" 'shell closed:' 10 || fail 'shell did not close'
grep -q 'shell opened: alpha -> box (local' "$LOG/pizarra.log" ||
  fail 'the hub did not record the REAL identity of the caller'
ok 'shell_trust = all lets a team open a shell with its own credential, logged as itself'

# 2. attach_trust alone must NOT grant a shell.
write_hub_conf all ''
start_hub
run_as pztest-t2 "$TEST_ROOT/alpha.conf" attach box
wait_file "$TEST_ROOT/pztest-t2.err" 'tiza attach:' 15 ||
  fail 'attach_trust = all did not let alpha attach'
tmux send-keys -t pztest-t2 C-] q
wait_file "$TEST_ROOT/pztest-t2.err" 'attach closed:' 10 || true
ok 'attach_trust = all lets alpha attach'

run_as pztest-t3 "$TEST_ROOT/alpha.conf" shell box
wait_file "$TEST_ROOT/pztest-t3.err" 'CX=' 15 || fail 'shell probe did not exit'
OUT=$(<"$TEST_ROOT/pztest-t3.err")
contains "$OUT" 'shell_trust' 'the refusal should name shell_trust'
contains "$OUT" 'CX=1' 'the refused shell exits 1'
ok 'attach_trust alone does NOT grant a shell'

# 3. The named-list form admits exactly what it names.
write_hub_conf '' alpha
start_hub
run_as pztest-t4 "$TEST_ROOT/beta.conf" shell box
wait_file "$TEST_ROOT/pztest-t4.err" 'CX=' 15 || fail 'beta probe did not exit'
contains "$(<"$TEST_ROOT/pztest-t4.err")" 'shell_trust' 'beta should be refused'
ok 'a team not named in shell_trust is refused'

run_as pztest-t1 "$TEST_ROOT/alpha.conf" shell box
wait_file "$TEST_ROOT/pztest-t1.err" 'tiza shell:' 15 ||
  fail 'alpha should be admitted by the named list'
tmux send-keys -t pztest-t1 'exit' Enter
wait_file "$TEST_ROOT/pztest-t1.err" 'shell closed:' 10 || true
ok 'a team named in shell_trust is admitted'

tmux has-session -t pztest-keep 2>/dev/null || fail 'the bystander session did not survive'
ok 'no tmux session was harmed'

printf '\nall shell trust checks passed\n'
