#!/usr/bin/env bash
# Focused browser regression for the group permission-block policy editor.
# Uses Chromium directly: no Node, npm, Playwright, or external JS runtime.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
FIXTURE=$SCRIPT_DIR/fixtures/group-onblock-browser.html
SERVER=$SCRIPT_DIR/fixtures/group_onblock_http.py
MANAGE_JS=$REPO_ROOT/web/apps/manage.js
CHROMIUM_BIN=${PIZARRA_TEST_CHROMIUM_BIN:-chromium}

for tool in find grep mktemp python3 rmdir sleep tail; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'not ok: required command is missing: %s\n' "$tool" >&2
    exit 1
  }
done
command -v "$CHROMIUM_BIN" >/dev/null 2>&1 || {
  printf 'not ok: Chromium is missing: %s\n' "$CHROMIUM_BIN" >&2
  exit 1
}
[[ -f $FIXTURE && -f $SERVER && -f $MANAGE_JS ]] || {
  printf 'not ok: browser fixture, server, or manage.js is missing\n' >&2
  exit 1
}

TEST_ROOT=$(mktemp -d /tmp/pizarra-group-onblock-browser.XXXXXXXX)
DOM=$TEST_ROOT/dom.html
BROWSER_LOG=$TEST_ROOT/chromium.log
SERVER_LOG=$TEST_ROOT/server.log
SERVER_PID=''

cleanup() {
  local pid=${SERVER_PID:-}
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  case ${TEST_ROOT:-} in
    /tmp/pizarra-group-onblock-browser.*)
      [[ ! -d $TEST_ROOT ]] || find "$TEST_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $TEST_ROOT ]] || rmdir "$TEST_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'not ok: %s\n' "$*" >&2
  if [[ -s $DOM ]]; then
    printf '%s\n' '--- Chromium DOM result ---' >&2
    grep -A12 -B2 'browser-result' "$DOM" >&2 || true
  fi
  if [[ -s $BROWSER_LOG ]]; then
    printf '%s\n' '--- Chromium diagnostics ---' >&2
    tail -40 "$BROWSER_LOG" >&2 || true
  fi
  if [[ -s $SERVER_LOG ]]; then
    printf '%s\n' '--- fixture server diagnostics ---' >&2
    tail -40 "$SERVER_LOG" >&2 || true
  fi
  exit 1
}

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

PORT=$(choose_port) || fail 'could not find a free loopback port'
python3 "$SERVER" --port "$PORT" --fixture "$FIXTURE" --manage-js "$MANAGE_JS" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

READY=0
for attempt in {1..200}; do
  if (: <>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    READY=1
    break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || fail 'fixture server exited before listening'
  sleep 0.05
done
[[ $READY == 1 ]] || fail 'fixture server did not become ready'

if ! "$CHROMIUM_BIN" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --disable-component-update \
    --disable-sync \
    --no-first-run \
    --no-default-browser-check \
    --user-data-dir="$TEST_ROOT/chromium-profile" \
    --virtual-time-budget=8000 \
    --dump-dom "http://127.0.0.1:$PORT/" \
    >"$DOM" 2>"$BROWSER_LOG"; then
  fail 'Chromium headless execution failed'
fi

grep -q 'id="browser-result" data-status="pass"' "$DOM" ||
  fail 'browser assertions did not reach PASS'
grep -q 'card=when blocked: log only' "$DOM" ||
  fail 'browser result omitted the log-only card assertion'
grep -q 'options=default,alarm,log' "$DOM" ||
  fail 'browser result omitted the exact policy options'
grep -q 'post=/api/group/builders/onblock {"onblock":"default"}' "$DOM" ||
  fail 'browser result omitted the exact POST contract'

printf '%s\n' 'ok: Chromium rendered log-only, selected onblock/default, and emitted the exact POST'
