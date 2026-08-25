#!/usr/bin/env python3
"""Serve the real Pizarra web console with deterministic showcase data.

The fixture changes neither the application HTML nor its JavaScript.  It only
injects a small capture driver after the production scripts and implements the
read-only API responses needed by the Structure and Workflows views.
"""

import argparse
import json
import mimetypes
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


TEAMS = [
    {
        "id": 1,
        "name": "atlas-lead",
        "speciality": "Coordinates architecture, delivery, and release decisions.",
        "parent": "",
        "open_tasks": 3,
        "slave": False,
        "workdir": "/srv/atlas/lead",
        "host": "control-01",
    },
    {
        "id": 2,
        "name": "platform",
        "speciality": "Builds the service boundary and durable data layer.",
        "parent": "atlas-lead",
        "open_tasks": 5,
        "slave": False,
        "workdir": "/srv/atlas/platform",
        "host": "builder-01",
    },
    {
        "id": 3,
        "name": "interface",
        "speciality": "Owns the operator console and accessible interactions.",
        "parent": "atlas-lead",
        "open_tasks": 4,
        "slave": False,
        "workdir": "/srv/atlas/interface",
        "host": "builder-02",
    },
    {
        "id": 4,
        "name": "quality",
        "speciality": "Verifies contracts, migrations, and failure recovery.",
        "parent": "atlas-lead",
        "open_tasks": 2,
        "slave": False,
        "workdir": "/srv/atlas/quality",
        "host": "runner-01",
    },
    {
        "id": 5,
        "name": "operations",
        "speciality": "Runs staging, observability, and safe deployment checks.",
        "parent": "atlas-lead",
        "open_tasks": 1,
        "slave": False,
        "workdir": "/srv/atlas/operations",
        "host": "ops-01",
    },
    {
        "id": 6,
        "name": "reviewer",
        "speciality": "Read-only review agent for independent release evidence.",
        "parent": "quality",
        "open_tasks": 0,
        "slave": True,
        "workdir": "/srv/atlas/reviewer",
        "host": "runner-02",
    },
]

GROUPS = [
    {
        "name": "delivery",
        "project": "atlas",
        "boss": "atlas-lead",
        "members": ["atlas-lead", "platform", "interface", "quality", "operations"],
        "member_ids": [1, 2, 3, 4, 5],
        "excluded": [],
        "on_idle": "boss",
        "on_block": "alarm",
        "all_idle": False,
        "any_blocked": False,
    },
    {
        "name": "builders",
        "project": "atlas",
        "boss": "platform",
        "members": ["platform", "interface"],
        "member_ids": [2, 3],
        "excluded": [],
        "on_idle": "off",
        "on_block": "log",
        "all_idle": False,
        "any_blocked": False,
    },
    {
        "name": "release-guard",
        "project": "atlas",
        "boss": "quality",
        "members": ["quality", "operations", "reviewer"],
        "member_ids": [4, 5, 6],
        "excluded": ["reviewer"],
        "on_idle": "all",
        "on_block": "alarm",
        "all_idle": False,
        "any_blocked": True,
    },
    {
        "name": "incident-room",
        "project": "continuity",
        "boss": "operations",
        "members": ["atlas-lead", "platform", "operations"],
        "member_ids": [1, 2, 5],
        "excluded": [],
        "on_idle": "operations",
        "on_block": "alarm",
        "all_idle": False,
        "any_blocked": False,
    },
    {
        "name": "experience",
        "project": "console",
        "boss": "interface",
        "members": ["interface", "quality"],
        "member_ids": [3, 4],
        "excluded": [],
        "on_idle": "off",
        "on_block": "log",
        "all_idle": False,
        "any_blocked": False,
    },
    {
        "name": "evidence",
        "project": "continuity",
        "boss": "quality",
        "members": ["quality", "reviewer"],
        "member_ids": [4, 6],
        "excluded": [],
        "on_idle": "boss",
        "on_block": "alarm",
        "all_idle": False,
        "any_blocked": False,
    },
]

PROJECTS = [
    {"name": "atlas", "boss": "atlas-lead"},
    {"name": "console", "boss": "interface"},
    {"name": "continuity", "boss": "operations"},
]

APPS = [
    {
        "name": "atlas-hub",
        "team": "platform",
        "purpose": "Routes durable team messages and enforces authority.",
        "hasdoc": True,
    },
    {
        "name": "atlas-console",
        "team": "interface",
        "purpose": "Presents activity, structure, tasks, and workflow maps.",
        "hasdoc": True,
    },
    {
        "name": "release-orchestrator",
        "team": "operations",
        "purpose": "Coordinates verified staging and production transitions.",
        "hasdoc": True,
    },
    {
        "name": "contract-suite",
        "team": "quality",
        "purpose": "Exercises wire contracts and migration invariants.",
        "hasdoc": True,
    },
    {
        "name": "signal-monitor",
        "team": "operations",
        "purpose": "Reports service health without mutating runtime state.",
        "hasdoc": False,
    },
    {
        "name": "evidence-vault",
        "team": "reviewer",
        "purpose": "Keeps independent read-only release evidence.",
        "hasdoc": True,
    },
]

WORKFLOW = {
    "name": "nebula-release",
    "group": "delivery",
    "state": "running",
    "strict": True,
    "etadef": 172800,
    "steps": [
        {"n": 1, "uid": 1001, "title": "Freeze the public contract", "team": "atlas-lead", "state": "done", "eta": 86400, "deps": [], "task": 101},
        {"n": 2, "uid": 1002, "title": "Build the service boundary", "team": "platform", "state": "done", "eta": 172800, "deps": [1], "task": 102},
        {"n": 3, "uid": 1003, "title": "Compose the operator console", "team": "interface", "state": "active", "eta": 172800, "deps": [2], "task": 103},
        {"n": 4, "uid": 1004, "title": "Verify accessibility paths", "team": "quality", "state": "active", "eta": 86400, "deps": [2], "task": 104},
        {"n": 5, "uid": 1005, "title": "Load-test message streams", "team": "quality", "state": "pending", "eta": 86400, "deps": [3], "task": 105},
        {"n": 6, "uid": 1006, "title": "Review the operator runbook", "team": "reviewer", "state": "pending", "eta": -1, "deps": [4], "task": 106},
        {"n": 7, "uid": 1007, "title": "Freeze the release candidate", "team": "atlas-lead", "state": "pending", "eta": 43200, "deps": [3, 4], "task": 107},
        {"n": 8, "uid": 1008, "title": "Deploy to staging", "team": "operations", "state": "pending", "eta": 21600, "deps": [5, 6, 7], "task": 108},
        {"n": 9, "uid": 1009, "title": "Exercise rollback", "team": "operations", "state": "pending", "eta": 14400, "deps": [8], "task": 109},
        {"n": 10, "uid": 1010, "title": "Publish signed artifacts", "team": "platform", "state": "pending", "eta": 7200, "deps": [9], "task": 110},
        {"n": 11, "uid": 1011, "title": "Observe the rollout", "team": "operations", "state": "pending", "eta": 21600, "deps": [10], "task": 111},
        {"n": 12, "uid": 1012, "title": "Close delivery evidence", "team": "reviewer", "state": "pending", "eta": -1, "deps": [11], "task": 112},
    ],
}


CAPTURE_DRIVER = r"""
(function () {
  'use strict';
  var query = new URLSearchParams(window.location.search);
  var capture = query.get('capture') || '';
  var token = query.get('token') || capture;

  function waitFor(read, description) {
    return new Promise(function (resolve, reject) {
      var attempts = 0;
      function poll() {
        var value = read();
        if (value) { resolve(value); return; }
        attempts += 1;
        if (attempts > 240) { reject(new Error('Timed out waiting for ' + description)); return; }
        window.setTimeout(poll, 25);
      }
      poll();
    });
  }

  function finish() {
    document.documentElement.dataset.showcaseReady = token;
    var request = new XMLHttpRequest();
    request.open('GET', '/fixture/ready?token=' + encodeURIComponent(token), false);
    request.send(null);
    if (request.status !== 200) { throw new Error('Could not confirm capture readiness'); }
    return Promise.resolve();
  }

  function fail(error) {
    var banner = document.createElement('pre');
    banner.style.cssText = 'position:fixed;inset:12px;z-index:10000;padding:24px;' +
      'white-space:pre-wrap;background:#7a1c1c;color:white;font:16px/1.5 monospace';
    banner.textContent = 'SHOWCASE CAPTURE FAILED\n' + (error && error.stack ? error.stack : String(error));
    document.body.appendChild(banner);
  }

  async function structure(kind) {
    var tab = document.querySelector('[data-registry="' + kind + '"]');
    if (!tab) { throw new Error('Missing registry tab: ' + kind); }
    if (kind !== 'teams') { tab.click(); }
    await waitFor(function () {
      var grid = document.getElementById('registry-grid');
      return grid && grid.getAttribute('aria-busy') === 'false' &&
        grid.querySelectorAll('.registry-card').length >= 6 && grid;
    }, kind + ' cards');
    window.scrollTo(0, 0);
    await new Promise(function (resolve) { requestAnimationFrame(function () { requestAnimationFrame(resolve); }); });
    await finish();
  }

  async function workflow() {
    var item = await waitFor(function () {
      return document.querySelector('[data-workflow-name="nebula-release"]');
    }, 'workflow list');
    item.click();
    var scroll = await waitFor(function () {
      var candidate = document.getElementById('workflow-scroll');
      var nodes = document.querySelectorAll('#workflow-columns .workflow-node');
      return candidate && nodes.length === 12 && candidate;
    }, 'wide workflow map');
    var fraction = Math.max(0, Math.min(1, Number(query.get('position') || '0') / 100));
    var canvas = document.getElementById('workflow-canvas');
    var distance = Math.max(0, canvas.scrollWidth - scroll.clientWidth);
    scroll.style.scrollBehavior = 'auto';
    scroll.scrollLeft = Math.round(Math.max(0, scroll.scrollWidth - scroll.clientWidth) * fraction);
    /* Some Chromium layouts give the max-content canvas its own full width,
       leaving no scroll range on the wrapper. Move that same real canvas for
       deterministic frames; its containing shell clips it exactly as the
       interactive scroller does. */
    if (scroll.scrollWidth <= scroll.clientWidth) {
      canvas.style.transform = 'translate3d(-' + Math.round(distance * fraction) + 'px,0,0)';
    }
    await new Promise(function (resolve) { requestAnimationFrame(function () { requestAnimationFrame(resolve); }); });
    await finish();
  }

  document.documentElement.classList.add('showcase-capture');
  if (capture === 'teams' || capture === 'groups' || capture === 'apps') {
    structure(capture).catch(fail);
  } else if (capture === 'workflow') {
    workflow().catch(fail);
  } else {
    fail(new Error('Unknown capture mode: ' + capture));
  }
})();
"""


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--web-root", required=True, type=Path)
    return parser.parse_args()


def main():
    args = parse_args()
    web_root = args.web_root.resolve(strict=True)
    index_path = web_root / "index.html"
    if not index_path.is_file():
        raise SystemExit("index.html is missing from the web root")

    index = index_path.read_text(encoding="utf-8")
    marker = "</body>"
    if index.count(marker) != 1:
        raise SystemExit("index.html does not have one closing body tag")
    capture_style = (
        "<style>.showcase-capture *, .showcase-capture *::before, "
        ".showcase-capture *::after{animation:none!important;transition:none!important}</style>"
    )
    index = index.replace(
        marker,
        capture_style + '<script src="/showcase-capture.js"></script>' + marker,
    ).encode("utf-8")
    ready = set()
    lock = threading.Lock()

    api = {
        "/api/help": {"ok": True, "data": {"ayuda": []}},
        "/api/teams": {"ok": True, "data": {"teams": TEAMS}},
        "/api/groups": {"ok": True, "data": {"groups": GROUPS}},
        "/api/projects": {"ok": True, "data": {"projects": PROJECTS}},
        "/api/apps": {"ok": True, "data": {"apps": APPS}},
        "/api/workflows": {
            "ok": True,
            "data": {
                "workflows": [
                    {"name": "nebula-release", "group": "delivery", "state": "running", "done": 2, "steps": 12},
                    {"name": "console-audit", "group": "experience", "state": "draft", "done": 0, "steps": 5},
                    {"name": "continuity-drill", "group": "incident-room", "state": "done", "done": 7, "steps": 7},
                ]
            },
        },
        "/api/workflow/nebula-release": {"ok": True, "data": {"workflow": WORKFLOW}},
    }

    class Handler(BaseHTTPRequestHandler):
        server_version = "PizarraShowcaseFixture/1"

        def log_message(self, pattern, *values):
            return

        def send_bytes(self, status, content_type, body):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, status, value):
            body = json.dumps(value, separators=(",", ":")).encode("utf-8")
            self.send_bytes(status, "application/json; charset=utf-8", body)

        def do_GET(self):
            parsed = urlsplit(self.path)
            path = unquote(parsed.path)
            query = parse_qs(parsed.query)

            if path == "/":
                self.send_bytes(200, "text/html; charset=utf-8", index)
                return
            if path == "/showcase-capture.js":
                self.send_bytes(200, "text/javascript; charset=utf-8", CAPTURE_DRIVER.encode("utf-8"))
                return
            if path == "/fixture/ready":
                token = query.get("token", [""])[0]
                if token:
                    with lock:
                        ready.add(token)
                self.send_json(200, {"ok": bool(token)})
                return
            if path == "/fixture/status":
                token = query.get("token", [""])[0]
                with lock:
                    present = token in ready
                self.send_json(200 if present else 409, {"ready": present, "token": token})
                return
            if path in api:
                self.send_json(200, api[path])
                return
            if path == "/api/feed":
                self.send_bytes(200, "text/event-stream; charset=utf-8", b"event: bye\ndata: {}\n\n")
                return

            relative = path.lstrip("/")
            if "/" not in relative and relative and relative == Path(relative).name:
                candidate = web_root / relative
                if candidate.is_file():
                    content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
                    if content_type.startswith("text/") or content_type in {
                        "application/javascript",
                        "image/svg+xml",
                    }:
                        content_type += "; charset=utf-8"
                    self.send_bytes(200, content_type, candidate.read_bytes())
                    return
            if path in {"/favicon.ico", "/robots.txt"}:
                self.send_bytes(204, "application/octet-stream", b"")
                return
            self.send_json(404, {"ok": False, "error": "fixture route not found"})

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
