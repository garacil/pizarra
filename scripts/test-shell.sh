#!/usr/bin/env bash
# Integration test for `tiza shell`: an interactive LOGIN SHELL on a team's
# HOST, relayed by the hub. This file covers the LOCAL route (the hub host's
# own machine); test-shell-routes.sh covers push and dial.
#
# It runs the real hub and the real client against loopback-only, disposable
# state. The hub is started INSIDE a tmux session on purpose - exactly the
# production shape - so the test proves the shell it spawns inherits no tmux
# environment at all. Only pztest-* tmux sessions are ever created or removed,
# and this feature creates none of its own: the shell is a private pty child.
#
# THE ACCOUNT. When the test runs as root it uses a real ordinary account and
# so exercises the production `su - <account>` path; otherwise it uses the
# account running the test, which takes the direct login-shell branch. Either
# way the real spawn path runs, and no assertion needs root.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-shell.XXXXXXXX)
HUB_PID=''
SESSIONS=(pztest-host pztest-sh1 pztest-sh2 pztest-sh3 pztest-sh4 pztest-sh5
          pztest-shx pztest-stty pztest-keep)

# ISOLATION. Identical to the attach harnesses and equally non-negotiable:
# tmux chooses its socket from $TMUX before TMUX_TMPDIR, so a pane's own
# variable would redirect every command to the LIVE server. Ignoring this once
# killed every session on the hub host.
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
  if [[ -f $TEST_ROOT/hub.out ]]; then
    printf '%s\n' '--- isolated hub output ---' >&2
    tail -40 "$TEST_ROOT/hub.out" >&2 || true
  fi
  if [[ -f $TEST_ROOT/log/pizarra.log ]]; then
    printf '%s\n' '--- isolated hub log ---' >&2
    tail -20 "$TEST_ROOT/log/pizarra.log" >&2 || true
  fi
  exit 1
}
ok() { printf 'ok: %s\n' "$*"; }
contains() {
  local value=$1 expected=$2 label=$3
  [[ $value == *"$expected"* ]] ||
    fail "$label (missing '$expected' in: ${value:0:400})"
}
lacks() {
  local value=$1 unexpected=$2 label=$3
  [[ $value != *"$unexpected"* ]] ||
    fail "$label (found '$unexpected' in: ${value:0:400})"
}
wait_file() {
  local file=$1 pat=$2 secs=$3 i
  for ((i = 0; i < secs * 10; i++)); do
    [[ -f $file ]] && grep -q -- "$pat" "$file" && return 0
    sleep 0.1
  done
  return 1
}
wait_cmd() {
  local secs=$1 i; shift
  for ((i = 0; i < secs * 10; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}
stop_hub() {
  local attempt
  [[ -n ${HUB_PID:-} ]] || return 0
  if kill -0 "$HUB_PID" 2>/dev/null; then
    kill "$HUB_PID" 2>/dev/null || true
    for attempt in {1..100}; do
      kill -0 "$HUB_PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -0 "$HUB_PID" 2>/dev/null && kill -KILL "$HUB_PID" 2>/dev/null || true
  fi
  HUB_PID=''
}
cleanup() {
  stop_hub
  local s
  for s in "${SESSIONS[@]}"; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  case ${TEST_ROOT:-} in
    /tmp/pizarra-shell.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

for tool in tmux stty pgrep ps grep sleep mktemp find id; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries are missing; run make debug'
for s in "${SESSIONS[@]}"; do
  tmux has-session -t "$s" 2>/dev/null && fail "stale session $s exists; another run in progress?"
done

# ---- choose the account the shell will open as -----------------------------
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
ACCT=$(pick_account) ||
  fail 'no ordinary account with a login shell available; set PIZARRA_TEST_SHELL_USER'
if [[ $(id -u) == 0 ]]; then
  ok "running as root: exercising the production su path as '$ACCT'"
else
  ok "running unprivileged: exercising the direct login-shell path as '$ACCT'"
fi

choose_port() {
  local attempt candidate
  for attempt in {1..200}; do
    candidate=$((20000 + ((BASHPID + RANDOM + attempt) % 30000)))
    if (: <>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
PORT=$(choose_port) || fail 'could not choose a free loopback port'
STORE=$TEST_ROOT/store
LOG_DIR=$TEST_ROOT/log
HUB_CONF=$TEST_ROOT/pizarra.conf
CONSOLE_CONF=$TEST_ROOT/console.conf
PLAIN_CONF=$TEST_ROOT/plain.conf
install -d -m 0700 "$STORE" "$LOG_DIR" "$TEST_ROOT/home"

# write_hub_conf <shell_local> <shell_user> [attach_local] [shell_trust]
write_hub_conf() {
  local slocal=$1 suser=$2 alocal=${3:-off} strust=${4:-}
  {
    printf '%s\n' '[server]' 'listen = 127.0.0.1' "port = $PORT" \
      'secret = synthetic-console-secret' 'master_console_only = on' \
      "attach_local = $alocal" "shell_local = $slocal"
    [[ -z $suser ]] || printf 'shell_user = %s\n' "$suser"
    [[ -z $strust ]] || printf 'shell_trust = %s\n' "$strust"
    printf '\n%s\n' '[registry]' 'authority = sqlite'
    printf '\n%s\n' '[store]' "dir = $STORE"
    printf '\n%s\n' '[log]' "path = $LOG_DIR/pizarra.log"
    printf '\n%s\n' '[team:1]' 'name = box' \
      'speciality = Synthetic local team naming this host' \
      'tmux_session = pztest-keep'
    printf '\n%s\n' '[team:2]' 'name = plain' \
      'speciality = Synthetic team with no shell authority' \
      'secret = synthetic-plain-secret' 'tmux_session = -'
  } >"$HUB_CONF"
  chmod 0600 "$HUB_CONF"
}
cat >"$CONSOLE_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-console-secret
self = console
EOF
cat >"$PLAIN_CONF" <<EOF
[pizarra]
host = 127.0.0.1
port = $PORT
secret = synthetic-plain-secret
self = plain
EOF
chmod 0600 "$CONSOLE_CONF" "$PLAIN_CONF"

# A bystander session that must survive every open and close in this file.
tmux new-session -d -s pztest-keep -x 80 -y 24 'exec /bin/sh' ||
  fail 'could not create the bystander session'
ok 'bystander session pztest-keep is up'

start_hub() {
  rm -f "$TEST_ROOT/hub.out"
  tmux new-session -d -s pztest-host -x 100 -y 30 \
    "exec '$HUB_BIN' --config '$HUB_CONF' >'$TEST_ROOT/hub.out' 2>&1" ||
    fail 'could not start the hub inside tmux'
  local ready=0 attempt
  for attempt in {1..100}; do
    if "$TIZA_BIN" --config "$CONSOLE_CONF" --health --wait 1 \
        >"$TEST_ROOT/health.out" 2>&1; then
      ready=1
      break
    fi
    sleep 0.05
  done
  ((ready == 1)) || fail 'isolated hub did not become healthy'
  HUB_PID=$(pgrep -f -- "--config $HUB_CONF" | head -1 || true)
  [[ -n $HUB_PID ]] || fail 'could not find the hub pid'
  grep -q '^TMUX=' <(tr '\0' '\n' <"/proc/$HUB_PID/environ") ||
    fail 'test premise broken: the hub does not carry TMUX in its environment'
}
restart_hub() {
  stop_hub
  tmux kill-session -t =pztest-host 2>/dev/null || true
  wait_cmd 5 bash -c "! tmux has-session -t pztest-host 2>/dev/null" || true
  start_hub
}

# run_client SESSION CONF COLSxROWS ARGS...
run_client() {
  local sess=$1 conf=$2 size=$3; shift 3
  local err=$TEST_ROOT/$sess.err
  local IFS=' '
  local args="$*"
  rm -f "$err"
  # Session names are reused across checks and a finished client lingers for a
  # moment. Clear this one by EXACT name first; it is always a pztest-* name.
  case $sess in
    pztest-*) tmux kill-session -t "=$sess" 2>/dev/null || true ;;
    *) fail "refusing to reuse a non-pztest session name: $sess" ;;
  esac
  tmux new-session -d -s "$sess" -x "${size%x*}" -y "${size#*x}" \
    "'$TIZA_BIN' --config '$conf' shell $args 2>'$err'; echo CLIENT_EXIT=\$? >>'$err'; sleep 3" ||
    fail "could not start client $sess"
}
# The pid the hub logged for the shell child - deterministic, unlike pgrep for
# a shell name, which on a developer box would match the tester's own shells.
shell_child_pid() {
  sed -n 's/.*shell opened:.*pid \([0-9][0-9]*\).*/\1/p' \
    "$LOG_DIR/pizarra.log" | tail -1
}

# --------------------------------------------------------------- assertions

# 1. Off by default: no shell_local key at all.
write_hub_conf off "$ACCT"
start_hub
run_client pztest-sh1 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh1.err" 'CLIENT_EXIT=' 10 ||
  fail 'client did not exit when shell_local is off'
OUT=$(<"$TEST_ROOT/pztest-sh1.err")
contains "$OUT" 'shell not enabled on this hub host' 'refusal names shell_local'
contains "$OUT" 'CLIENT_EXIT=1' 'refused client exits 1'
ok 'shell_local = off refuses even the console'

# 2. Enabled but no account configured.
write_hub_conf on ''
restart_hub
run_client pztest-sh2 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh2.err" 'CLIENT_EXIT=' 10 ||
  fail 'client did not exit when shell_user is unset'
OUT=$(<"$TEST_ROOT/pztest-sh2.err")
contains "$OUT" 'no account configured on the hub host' 'refusal names shell_user'
ok 'shell_local = on with no shell_user refuses rather than opening root'

# 3. A configured account that does not exist.
write_hub_conf on pztestnosuch
restart_hub
run_client pztest-sh3 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh3.err" 'CLIENT_EXIT=' 10 ||
  fail 'client did not exit for a nonexistent account'
OUT=$(<"$TEST_ROOT/pztest-sh3.err")
contains "$OUT" 'no account "pztestnosuch" on this host' 'refusal names the account'
ok 'a nonexistent shell_user is refused by name'

# 4. root is refused as an account, whatever the config says.
write_hub_conf on root
restart_hub
run_client pztest-sh4 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh4.err" 'CLIENT_EXIT=' 10 ||
  fail 'client did not exit for shell_user = root'
OUT=$(<"$TEST_ROOT/pztest-sh4.err")
contains "$OUT" 'must not be root' 'refusal explains sudo su'
ok 'shell_user = root is refused; the daemon never opens a root shell'

# 5. An unauthorised team credential, with the feature fully on.
write_hub_conf on "$ACCT"
restart_hub
run_client pztest-shx "$PLAIN_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-shx.err" 'CLIENT_EXIT=' 10 ||
  fail 'unauthorised client did not exit'
OUT=$(<"$TEST_ROOT/pztest-shx.err")
contains "$OUT" 'shell_trust' 'refusal names shell_trust'
contains "$OUT" 'CLIENT_EXIT=1' 'unauthorised client exits 1'
ok 'a team not in shell_trust cannot open a shell'

# 6. The happy path, at a non-default viewer size.
run_client pztest-sh5 "$CONSOLE_CONF" 100x30 box
wait_file "$TEST_ROOT/pztest-sh5.err" 'tiza shell:' 10 ||
  fail 'client never printed its banner'
OUT=$(<"$TEST_ROOT/pztest-sh5.err")
contains "$OUT" "$ACCT@" 'banner names the account'
contains "$OUT" '100x30' 'banner reports the viewer size'
ok "shell opened as $ACCT at the viewer's own size"

CHILD=$(shell_child_pid)
[[ -n $CHILD ]] || fail 'the hub did not log a shell child pid'
wait_cmd 5 test -d "/proc/$CHILD" || fail 'the logged shell child is not running'

# 7. The pty was created at the VIEWER's size (the inverse of attach).
SIZE=$(stty size <"/proc/$CHILD/fd/0" 2>/dev/null || echo '?')
[[ $SIZE == '30 100' ]] || fail "shell pty is $SIZE, expected 30 100"
ok 'the pty was created at the viewer size, not a session size'

# 8. Environment hygiene: no tmux of any kind, including TMUX_TMPDIR.
ENVV=$(tr '\0' '\n' <"/proc/$CHILD/environ")
lacks "$ENVV" 'TMUX=' 'shell child inherited TMUX'
lacks "$ENVV" 'TMUX_PANE=' 'shell child inherited TMUX_PANE'
lacks "$ENVV" 'TMUX_TMPDIR=' 'shell child inherited TMUX_TMPDIR'
contains "$ENVV" 'TERM=' 'shell child has TERM'
ok 'the shell child carries no tmux environment at all'

# 9. fd hygiene: the shell does not hold the hub's listening socket.
if command -v ss >/dev/null 2>&1; then
  LISTEN=$(ss -lntp 2>/dev/null | grep ":$PORT " || true)
  lacks "$LISTEN" "pid=$CHILD," 'the shell child holds the hub listener'
  ok 'the shell child does not hold the hub listening socket'
fi

# 10. It is a real interactive shell: a typed command runs and answers.
tmux send-keys -t pztest-sh5 'id -un' Enter
wait_cmd 10 bash -c \
  "tmux capture-pane -p -t pztest-sh5 | grep -q '^$ACCT\$'" ||
  fail 'the shell did not answer id -un with the configured account'
ok 'a typed command runs in the shell and its output comes back'

# 11. Ctrl-b is forwarded, not swallowed as an escape (unlike attach).
tmux send-keys -t pztest-sh5 C-b
sleep 0.3
tmux send-keys -t pztest-sh5 'echo CB_OK' Enter
wait_cmd 10 bash -c "tmux capture-pane -p -t pztest-sh5 | grep -q 'CB_OK'" ||
  fail 'the client did not survive a Ctrl-b, or dropped the following bytes'
grep -q 'shell closed:' "$TEST_ROOT/pztest-sh5.err" &&
  fail 'Ctrl-b closed the client; it must be an ordinary byte here'
ok 'Ctrl-b passes through: it is not an escape in a shell'

# 12. exit is the normal way out.
tmux send-keys -t pztest-sh5 'exit' Enter
wait_file "$TEST_ROOT/pztest-sh5.err" 'shell closed:' 10 ||
  fail 'the client did not report a close after exit'
wait_file "$TEST_ROOT/pztest-sh5.err" 'CLIENT_EXIT=0' 10 ||
  fail 'a cleanly exited shell did not exit 0'
wait_cmd 5 bash -c "! test -d /proc/$CHILD" || fail 'the shell child was not reaped'
[[ $(ps -o stat= -p "$CHILD" 2>/dev/null || true) != Z* ]] ||
  fail 'the shell child is a zombie'
grep -q 'shell opened: console -> box (local' "$LOG_DIR/pizarra.log" ||
  fail 'the hub did not log the open with identity and route'
grep -q 'shell closed: console -> box (local' "$LOG_DIR/pizarra.log" ||
  fail 'the hub did not log the close'
ok 'exit closes cleanly, the child is reaped, and both ends are logged'

# 13. Ctrl-] q is the emergency escape.
run_client pztest-sh1 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh1.err" 'tiza shell:' 10 ||
  fail 'second client never opened'
tmux send-keys -t pztest-sh1 C-] q
wait_file "$TEST_ROOT/pztest-sh1.err" 'shell closed:' 10 ||
  fail 'Ctrl-] q did not close the client'
ok 'Ctrl-] q closes a wedged shell'

# 14. Bounds: SHELL_MAX_PER_HOST is 2 for one host.
run_client pztest-sh2 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh2.err" 'tiza shell:' 10 || fail 'shell 1 did not open'
run_client pztest-sh3 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh3.err" 'tiza shell:' 10 || fail 'shell 2 did not open'
run_client pztest-sh4 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh4.err" 'CLIENT_EXIT=' 10 || fail 'shell 3 did not exit'
OUT=$(<"$TEST_ROOT/pztest-sh4.err")
contains "$OUT" 'shell limit reached' 'the third shell on one host is refused'
ok 'the per-host bound holds'
tmux send-keys -t pztest-sh2 'exit' Enter
wait_file "$TEST_ROOT/pztest-sh2.err" 'shell closed:' 10 || fail 'shell 1 did not close'
run_client pztest-sh4 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh4.err" 'tiza shell:' 10 ||
  fail 'a slot was not released when a shell closed'
ok 'closing a shell releases its slot'
tmux send-keys -t pztest-sh3 'exit' Enter
tmux send-keys -t pztest-sh4 'exit' Enter
sleep 1

# 15. Terminal mode is restored byte for byte.
tmux new-session -d -s pztest-stty -x 80 -y 24 \
  "stty -a >'$TEST_ROOT/stty.before' 2>&1; \
   '$TIZA_BIN' --config '$CONSOLE_CONF' shell box 2>'$TEST_ROOT/stty.err' & \
   sleep 3; \
   stty -a >'$TEST_ROOT/stty.after' 2>&1; sleep 2" ||
  fail 'could not start the stty probe'
wait_file "$TEST_ROOT/stty.err" 'tiza shell:' 10 || true
sleep 4
tmux send-keys -t pztest-stty C-] q
sleep 1
if [[ -s $TEST_ROOT/stty.before && -s $TEST_ROOT/stty.after ]]; then
  cmp -s "$TEST_ROOT/stty.before" "$TEST_ROOT/stty.after" ||
    fail 'the terminal mode was not restored'
  ok 'the terminal mode is restored after a session'
fi

# 16. attach and shell are independent, in both directions.
write_hub_conf off "$ACCT" on ''      # attach on, shell off
restart_hub
run_client pztest-sh5 "$CONSOLE_CONF" 80x24 box
wait_file "$TEST_ROOT/pztest-sh5.err" 'CLIENT_EXIT=' 10 || fail 'client did not exit'
contains "$(<"$TEST_ROOT/pztest-sh5.err")" 'shell not enabled' \
  'attach_local = on must not enable the shell'
ok 'enabling attach does not grant a shell'

write_hub_conf on "$ACCT" off ''      # shell on, attach off
restart_hub
rm -f "$TEST_ROOT/att.err"
tmux new-session -d -s pztest-shx -x 80 -y 24 \
  "'$TIZA_BIN' --config '$CONSOLE_CONF' attach box 2>'$TEST_ROOT/att.err'; \
   echo CLIENT_EXIT=\$? >>'$TEST_ROOT/att.err'; sleep 2" ||
  fail 'could not start the attach probe'
wait_file "$TEST_ROOT/att.err" 'CLIENT_EXIT=' 10 || fail 'attach probe did not exit'
contains "$(<"$TEST_ROOT/att.err")" 'attach not enabled' \
  'shell_local = on must not enable attach'
ok 'enabling the shell does not grant attach'

# 17. The bystander session survived everything.
tmux has-session -t pztest-keep 2>/dev/null ||
  fail 'the bystander tmux session did not survive'
ok 'no tmux session was harmed'

printf '\nall shell (local route) checks passed\n'
