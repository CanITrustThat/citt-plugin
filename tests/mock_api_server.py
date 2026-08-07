#!/usr/bin/env python3
"""Mock CITT API server for the citt dispatcher harness (CITT-333).

Serves:
  POST /api/device/code           — device flow code (delegates to mock_device_server logic)
  POST /api/device/token          — device flow poll (scripted via CITT_MOCK_SCRIPT)
  GET  /api/me                    — authenticated whoami endpoint

Requires an Authorization: Bearer <token> header on /api/me:
  - if the token matches CITT_MOCK_TOKEN  -> 200 with user JSON
  - if the token is "bad_token"           -> 401 {"detail":"unauthorized"}
  - no token                              -> 401

Environment:
  CITT_MOCK_TOKEN   — expected bearer token (default: citt_disp_mocktoken123)
  CITT_MOCK_SCRIPT  — comma-separated poll transitions (default: "success")
  CITT_MOCK_LOG     — optional path to append JSON request logs

Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
import sys
import threading

SCRIPT = [s.strip() for s in os.environ.get("CITT_MOCK_SCRIPT", "success").split(",") if s.strip()]
LOG = os.environ.get("CITT_MOCK_LOG")
MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_disp_mocktoken123")

MOCK_USER = {
    "email": "test@example.com",
    "plan": "developer",
    "quota_remaining": 42,
}

_state_lock = threading.Lock()
_poll_index = {"i": 0}


def _log(kind, body):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps({"kind": kind, "body": body}) + "\n")
    except OSError:
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence default logging
        pass

    def _send(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode() if length else ""
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {"_unparsed": raw}

    def _bearer_token(self):
        """Extract bearer token from Authorization header, or None."""
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return None

    def do_GET(self):
        if self.path == "/api/me" or self.path.startswith("/api/me?"):
            _log("me_request", {"path": self.path})
            token = self._bearer_token()
            if not token or token == "bad_token":
                self._send(401, {"detail": "unauthorized"})
                return
            if token == MOCK_TOKEN:
                self._send(200, MOCK_USER)
                return
            # Unexpected token -> 401
            self._send(401, {"detail": "unauthorized"})
            return
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        body = self._read_body()

        if self.path == "/api/device/code":
            _log("device_code", body)
            self._send(200, {
                "device_code": "rawdevicecode_" + "a" * 40,
                "verification_uri_complete":
                    "https://canitrustthat.com/link?dc=rawdevicecode_" + "a" * 40,
                "expires_in": 900,
                "interval": 1,
            })
            return

        if self.path == "/api/device/token":
            _log("device_token", body)
            with _state_lock:
                i = _poll_index["i"]
                _poll_index["i"] = i + 1
            state = SCRIPT[i] if i < len(SCRIPT) else SCRIPT[-1]

            if state == "authorization_pending":
                self._send(400, {"error": "authorization_pending"})
            elif state == "slow_down":
                self._send(400, {"error": "slow_down"})
            elif state == "access_denied":
                self._send(400, {
                    "error": "access_denied",
                    "error_description": "tier",
                    "message": (
                        "Batch submission needs the Developer ($20/mo) or "
                        "Research ($299/mo) plan — upgrade at "
                        "canitrustthat.com/pricing."
                    ),
                    "upgrade_url": "https://canitrustthat.com/pricing",
                })
            elif state == "expired_token":
                self._send(400, {"error": "expired_token"})
            elif state == "success":
                self._send(200, {"access_token": MOCK_TOKEN, "token_type": "bearer"})
            else:
                self._send(400, {"error": "authorization_pending"})
            return

        self._send(404, {"error": "not_found"})


def main():
    httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    print(f"http://127.0.0.1:{port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
