#!/usr/bin/env bash
# Assigning an application to a project must work.
#
# It did not, for every assignment, since the re-check under the config lock was
# written as FindProject(FCfg, Prj_.Name, Prj_) - passing a field of the very
# record the function fills. An `out` record parameter is finalized on entry in
# FPC, so the key was already empty when the callee read it, the lookup missed,
# and the hub reported a live project as removed. Reported by an application
# owner whose project was listed and intact while every assignment was refused.
#
# No tmux server is involved: the teams here are inbox-only.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
HUB_BIN=${PIZARRA_TEST_HUB_BIN:-$REPO_ROOT/pizarra-debug}
TIZA_BIN=${PIZARRA_TEST_TIZA_BIN:-$REPO_ROOT/tiza-debug}
TEST_ROOT=$(mktemp -d /tmp/pizarra-appproj.XXXXXXXX)
HUB_PID=''

fail() { printf 'not ok: %s\n' "$*" >&2; [[ -f $TEST_ROOT/hub.out ]] && tail -20 "$TEST_ROOT/hub.out" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
cleanup() {
  [[ -n ${HUB_PID:-} ]] && kill "$HUB_PID" 2>/dev/null || true
  case ${TEST_ROOT:-} in /tmp/pizarra-appproj.*) rm -rf "$TEST_ROOT" 2>/dev/null || true ;; esac
}
trap cleanup EXIT
[[ -x $HUB_BIN && -x $TIZA_BIN ]] || fail 'debug binaries missing; run make debug'

port_open() { (: <>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
choose_port() { local a c; for a in {1..300}; do c=$((20000 + ((BASHPID + RANDOM + a) % 30000))); port_open "$c" || { printf '%s\n' "$c"; return 0; }; done; return 1; }
PORT=$(choose_port) || fail 'no free port'
install -d -m 0700 "$TEST_ROOT/store"

printf '%s\n' '[server]' 'listen = 127.0.0.1' "port = $PORT" 'secret = synthetic' \
  '[registry]' 'authority = sqlite' '[store]' "dir = $TEST_ROOT/store" \
  '[log]' "path = $TEST_ROOT/pizarra.log" \
  '[team:1]' 'name = builder' 'speciality = synthetic member' 'tmux_session = -' \
  > "$TEST_ROOT/hub.conf"
printf '%s\n' '[pizarra]' 'host = 127.0.0.1' "port = $PORT" 'secret = synthetic' 'self = console' \
  > "$TEST_ROOT/c.conf"
chmod 0600 "$TEST_ROOT/hub.conf" "$TEST_ROOT/c.conf"

"$HUB_BIN" --config "$TEST_ROOT/hub.conf" >"$TEST_ROOT/hub.out" 2>&1 &
HUB_PID=$!
for _ in {1..100}; do port_open "$PORT" && break; sleep 0.1; done
port_open "$PORT" || fail 'hub did not listen'
T() { "$TIZA_BIN" --config "$TEST_ROOT/c.conf" "$@" 2>&1 || true; }

T project boss demo builder >/dev/null
[[ $(T project list | grep -c demo) == 1 ]] || fail 'the project was not created'
T app add widget --team builder >/dev/null
ok 'project and application exist'

OUT=$(T app project widget demo --role "does the thing")
[[ $OUT != *"project was removed"* ]] \
  || fail 'the hub still reports a live project as removed'
ok 'assigning to a live project is not refused'

T app show widget | grep -q 'demo' || fail 'the application was not linked to the project'
ok 'the application is linked to the project'

T app show widget | grep -q 'does the thing' || fail 'the role text was not stored'
ok 'the role text is stored'

# unassign / reassign must both work, which is the loop the reporter was stuck in
T app unproject widget demo >/dev/null
T app show widget | grep -q 'demo' && fail 'unproject did not unlink'
ok 'unproject unlinks'

OUT=$(T app project widget demo --role "second time")
[[ $OUT != *"project was removed"* ]] || fail 'reassignment after unproject is refused'
T app show widget | grep -q 'second time' || fail 'the new role text was not stored'
ok 'reassignment after unproject works and updates the role'

OUT=$(T app project widget nosuchproject --role "x")
[[ $OUT == *"unknown project"* ]] || fail 'an unknown project should be refused by name'
ok 'a genuinely unknown project is still refused, and says so'

printf '\nall app-project assignment checks passed\n'
