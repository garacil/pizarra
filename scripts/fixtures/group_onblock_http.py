#!/usr/bin/env python3
"""Strict loopback fixture for the group on-block Chromium regression.

It serves only the fixture and the repository's real manage.js.  The mutation
endpoint accepts one exact request, making a browser PASS evidence about the
HTTP method, path, JSON bytes, and the two headers emitted by manage.js.
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


EXPECTED_PATH = "/api/group/builders/onblock"
EXPECTED_BODY = b'{"onblock":"default"}'


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--manage-js", type=Path, required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    fixture = args.fixture.read_bytes()
    manage_js = args.manage_js.read_bytes()
    capture = {"count": 0}

    class Handler(BaseHTTPRequestHandler):
        server_version = "PizarraOnblockFixture/1"

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
            self.send_bytes(status, "application/json", body)

        def do_GET(self):
            if self.path == "/":
                self.send_bytes(200, "text/html; charset=utf-8", fixture)
                return
            if self.path == "/manage.js":
                self.send_bytes(200, "text/javascript; charset=utf-8", manage_js)
                return
            if self.path == "/api/teams":
                self.send_json(200, {"ok": True, "data": {"teams": []}})
                return
            if self.path == "/api/groups":
                current_policy = "default" if capture["count"] else "log"
                group = {
                    "name": "builders",
                    "project": "atlas",
                    "boss": "agent-main",
                    "members": ["agent-main", "agent-review"],
                    "member_ids": [1, 2],
                    "excluded": [],
                    "on_idle": "off",
                    "on_block": current_policy,
                    "all_idle": False,
                    "any_blocked": False,
                }
                self.send_json(200, {"ok": True, "data": {"groups": [group]}})
                return
            if self.path == "/test/result":
                if capture["count"] != 1:
                    self.send_json(409, {"ok": False, "error": "exact POST not captured"})
                    return
                self.send_json(200, {"ok": True, "data": capture})
                return
            if self.path == "/favicon.ico":
                self.send_bytes(204, "image/x-icon", b"")
                return
            self.send_json(404, {"ok": False, "error": "unexpected GET " + self.path})

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "-1"))
            except ValueError:
                length = -1
            body = self.rfile.read(length) if length >= 0 else b""
            content_type = self.headers.get("Content-Type", "")
            x_pizarra = self.headers.get("X-Pizarra", "")
            exact = (
                self.path == EXPECTED_PATH
                and body == EXPECTED_BODY
                and content_type == "application/json"
                and x_pizarra == "1"
                and capture["count"] == 0
            )
            if not exact:
                self.send_json(400, {"ok": False, "error": "unexpected mutation contract"})
                return
            capture.update({
                "method": "POST",
                "path": self.path,
                "body": body.decode("ascii"),
                "content_type": content_type,
                "x_pizarra": x_pizarra,
                "count": 1,
            })
            self.send_json(200, {"ok": True, "data": {"onblock": "default"}})

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
