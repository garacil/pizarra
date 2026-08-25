#!/usr/bin/env bash
# Rebuild the public Structure screenshots and the scrolling workflow GIF.
# The production HTML/CSS/JS is rendered by Chromium against synthetic data.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
WEB_ROOT=$REPO_ROOT/web/apps
SERVER=$SCRIPT_DIR/fixtures/web_showcase_http.py
GIF_SPEC_WRITER=$SCRIPT_DIR/fixtures/ppm_frames_to_gifbuild.py
OUTPUT_DIR=${1:-$REPO_ROOT/screenshots}
CHROMIUM_BIN=${PIZARRA_CAPTURE_CHROMIUM_BIN:-chromium}

for tool in find gifbuild grep mktemp png2pnm python3 rmdir sleep; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'not ok: required command is missing: %s\n' "$tool" >&2
    exit 1
  }
done
command -v "$CHROMIUM_BIN" >/dev/null 2>&1 || {
  printf 'not ok: Chromium is missing: %s\n' "$CHROMIUM_BIN" >&2
  exit 1
}
[[ -f $WEB_ROOT/index.html && -f $SERVER && -f $GIF_SPEC_WRITER ]] || {
  printf '%s\n' 'not ok: web source or showcase fixture is missing' >&2
  exit 1
}
[[ -d $OUTPUT_DIR ]] || {
  printf 'not ok: output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
  exit 1
}

CAPTURE_ROOT=$(mktemp -d /tmp/pizarra-web-showcase.XXXXXXXX)
SERVER_LOG=$CAPTURE_ROOT/server.log
SERVER_PID=''

cleanup() {
  local pid=${SERVER_PID:-}
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  case ${CAPTURE_ROOT:-} in
    /tmp/pizarra-web-showcase.*)
      [[ ! -d $CAPTURE_ROOT ]] || find "$CAPTURE_ROOT" -depth -mindepth 1 -delete 2>/dev/null || true
      [[ ! -d $CAPTURE_ROOT ]] || rmdir "$CAPTURE_ROOT" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'not ok: %s\n' "$*" >&2
  [[ ! -s $SERVER_LOG ]] || tail -40 "$SERVER_LOG" >&2
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
python3 "$SERVER" --port "$PORT" --web-root "$WEB_ROOT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

READY=0
for attempt in {1..200}; do
  if (: <>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    READY=1
    break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || fail 'showcase server exited before listening'
  sleep 0.05
done
[[ $READY == 1 ]] || fail 'showcase server did not become ready'

check_ready() {
  local token=$1
  python3 - "$PORT" "$token" <<'PY'
import json
import sys
from urllib.request import urlopen

port, token = sys.argv[1:]
with urlopen(f"http://127.0.0.1:{port}/fixture/status?token={token}", timeout=2) as response:
    payload = json.load(response)
if payload != {"ready": True, "token": token}:
    raise SystemExit("capture fixture did not report ready")
PY
}

check_png() {
  local image=$1 expected_width=$2 expected_height=$3
  python3 - "$image" "$expected_width" "$expected_height" <<'PY'
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
data = path.read_bytes()
if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
    raise SystemExit(f"not a valid PNG: {path}")
actual = struct.unpack(">II", data[16:24])
if actual != expected:
    raise SystemExit(f"wrong PNG dimensions for {path}: {actual} != {expected}")
PY
}

capture_png() {
  local mode=$1 token=$2 width=$3 height=$4 target=$5 position=${6:-0}
  local profile=$CAPTURE_ROOT/profile-$token
  local log=$CAPTURE_ROOT/chromium-$token.log
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
      --force-device-scale-factor=1 \
      --user-data-dir="$profile" \
      --window-size="$width,$height" \
      --virtual-time-budget=7000 \
      --screenshot="$target" \
      "http://127.0.0.1:$PORT/?capture=$mode&token=$token&position=$position#$([[ $mode == workflow ]] && printf workflows || printf structure)" \
      >"$log" 2>&1; then
    tail -40 "$log" >&2 || true
    fail "Chromium failed while capturing $token"
  fi
  check_ready "$token" || {
    tail -40 "$log" >&2 || true
    fail "the real UI was not ready for $token"
  }
  check_png "$target" "$width" "$height"
}

for registry in teams groups apps; do
  target=$OUTPUT_DIR/web-structure-$registry.png
  capture_png "$registry" "$registry" 1440 960 "$target"
  printf 'ok: %s\n' "$target"
done

POSITIONS=(0 12 25 37 50 62 75 87 100)
PPM_FRAMES=()
for index in "${!POSITIONS[@]}"; do
  position=${POSITIONS[$index]}
  token=$(printf 'workflow-%02d' "$index")
  png=$CAPTURE_ROOT/$token.png
  ppm=$CAPTURE_ROOT/$token.ppm
  capture_png workflow "$token" 1280 800 "$png" "$position"
  png2pnm "$png" >"$ppm"
  PPM_FRAMES+=("$ppm")
done

GIF_SPEC=$CAPTURE_ROOT/workflow-scroll.spec
python3 "$GIF_SPEC_WRITER" --delay 15 --end-delay 80 "${PPM_FRAMES[@]}" >"$GIF_SPEC"
gifbuild "$GIF_SPEC" >"$OUTPUT_DIR/web-workflow-scroll.gif"

python3 - "$OUTPUT_DIR/web-workflow-scroll.gif" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
if len(data) < 1024 or data[:6] not in {b"GIF87a", b"GIF89a"} or data[-1:] != b";":
    raise SystemExit(f"not a complete GIF: {path}")
if data.count(b"\x2c") < 9:
    raise SystemExit(f"animated GIF has fewer than nine image descriptors: {path}")
if b"NETSCAPE2.0" not in data:
    raise SystemExit(f"animated GIF has no loop extension: {path}")
PY

printf 'ok: %s\n' "$OUTPUT_DIR/web-workflow-scroll.gif"
chmod 0644 \
  "$OUTPUT_DIR/web-structure-teams.png" \
  "$OUTPUT_DIR/web-structure-groups.png" \
  "$OUTPUT_DIR/web-structure-apps.png" \
  "$OUTPUT_DIR/web-workflow-scroll.gif"
