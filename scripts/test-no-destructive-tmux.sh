#!/usr/bin/env bash
# Static guard: nothing shipped can end or replace a tmux session.
#
# The product creates a session only when it is absent and never touches an
# existing one. This check fails the suite if a destructive tmux verb is issued
# from the sources or the units, if a unit that may hold a tmux server in its
# control group lacks KillMode=process, or if any script contains kill-server.
# A harness on a private socket may remove the sessions it created, by exact
# name; ending a server is never needed (it was the 2026-09-07 outage).

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
cd -- "$REPO_ROOT"

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# 1) Pascal sources: no destructive verb as a string literal. A comment may
#    mention one; a literal is what would reach tmux's argument vector.
if grep -nE "'(kill-(server|session|window|pane)|respawn-(pane|window)|rename-(session|window))'" src/*.pas; then
  fail 'a destructive tmux verb is issued from the product sources'
fi
ok 'product sources issue no destructive tmux command'

# 2) Units and the shipped tmux configuration end nothing, and every unit that
#    may hold a tmux server in its control group confines a stop to itself.
if grep -nE 'kill-(server|session|window|pane)|respawn-|rename-session' systemd/*; then
  fail 'a unit or the shipped tmux configuration ends a session'
fi
for unit in systemd/pizarra.service systemd/pizarra-tmux.service systemd/tiza.service; do
  grep -qx 'KillMode=process' "$unit" ||
    fail "$unit lacks KillMode=process: a stop or restart would reach the tmux server"
done
ok 'units carry KillMode=process and end nothing'

# 3) No script anywhere runs kill-server. A comment may name it (the history
#    of why this guard exists); a line that is not a comment may not.
self=scripts/test-no-destructive-tmux.sh
if grep -rlE '^[^#]*kill-server' scripts Makefile configure --include='*.sh' \
     --include='*.pas' --include='*.py' --include=Makefile --include=configure 2>/dev/null |
   grep -vx "$self"; then
  fail 'a script runs kill-server'
fi
ok 'no script runs kill-server'

printf 'all destructive-tmux guard checks passed\n'
