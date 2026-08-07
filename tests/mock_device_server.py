#!/usr/bin/env python3
"""Tiny mock CITT device-flow server for the citt-auth.sh harness (CITT-267).

Serves canned /api/device/code and /api/device/token responses on 127.0.0.1.
The poll-transition sequence for /api/device/token is scripted via the
CITT_MOCK_SCRIPT env var: a comma-separated list of states consumed one per
poll, e.g. "authorization_pending,slow_down,success". Recognised tokens:

    authorization_pending  -> HTTP 400 {"error":"authorization_pending"}
    slow_down              -> HTTP 400 {"error":"slow_down"}
    access_denied          -> HTTP 400 {"error":"access_denied","message":..,...}
    expired_token          -> HTTP 400 {"error":"expired_token"}
    success                -> HTTP 200 {"access_token":"citt_<id>_<secret>",...}

Prints its chosen "http://127.0.0.1:<port>" base URL to stdout on the first line
and stays in the foreground. It also records every request body it received to
CITT_MOCK_LOG (if set) so the harness can assert what was / was not sent.
"""
import http.server
import json
import os
import sys
import threading

SCRIPT = [s.strip() for s in os.environ.get("CITT_MOCK_SCRIPT", "success").split(",") if s.strip()]
LOG = os.environ.get("CITT_MOCK_LOG")
# The exact token the mock hands out on success. The harness asserts this value
# is what ends up (only) in the token file, and never in the script's stdout.
MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_tokid123_supersecretvalue456")

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

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode() if length else ""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {"_unparsed": raw}

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
                    "message": ("Batch submission needs the Developer ($20/mo) or "
                                "Research ($299/mo) plan — upgrade at "
                                "canitrustthat.com/pricing."),
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
