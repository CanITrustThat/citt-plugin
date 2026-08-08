#!/usr/bin/env python3
"""Mock CITT API server for the citt rescan harness.

Serves:
  POST /api/rescan                              — trigger a fresh scan
  GET  /api/apps/{package_id}/rescan-eligibility — read-only affordance probe

Behaviour is keyed on package_id so the harness can drive each branch:
  com.forbidden.app  -> 403 (not authorized)
  com.overquota.app  -> 429 (monthly limit reached)
  <anything else>    -> 200 queued (eligibility: can_rescan true)

Auth: Bearer token must equal CITT_MOCK_TOKEN, else 401.
Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
import urllib.parse

MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_rescan_mocktoken456")
LOG = os.environ.get("CITT_MOCK_LOG")

FORBIDDEN_PKG = "com.forbidden.app"
OVERQUOTA_PKG = "com.overquota.app"


def _log(kind, body):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps({"kind": kind, "body": body}) + "\n")
    except OSError:
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _bearer(self):
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return None

    def _require_auth(self):
        if self._bearer() != MOCK_TOKEN:
            self._send(401, {"detail": "unauthorized"})
            return False
        return True

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        # /api/apps/{pkg}/rescan-eligibility
        if path.startswith("/api/apps/") and path.endswith("/rescan-eligibility"):
            _log("eligibility", {"path": path})
            if not self._require_auth():
                return
            pkg = urllib.parse.unquote(path[len("/api/apps/"):-len("/rescan-eligibility")])
            if pkg == FORBIDDEN_PKG:
                self._send(200, {
                    "can_rescan": False, "reason": "not_owner", "is_owner": False,
                    "plan_id": "developer", "rescans_used": 0, "rescans_limit": 4,
                    "upgrade_target": None,
                })
            elif pkg == OVERQUOTA_PKG:
                self._send(200, {
                    "can_rescan": False, "reason": "quota_exceeded", "is_owner": True,
                    "plan_id": "free", "rescans_used": 1, "rescans_limit": 1,
                    "upgrade_target": "developer",
                })
            else:
                self._send(200, {
                    "can_rescan": True, "reason": "ok", "is_owner": True,
                    "plan_id": "developer", "rescans_used": 2, "rescans_limit": 4,
                    "upgrade_target": None,
                })
            return
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode()) if raw else {}
        except (json.JSONDecodeError, ValueError):
            body = {}

        if path == "/api/rescan":
            _log("rescan", {"body": body})
            if not self._require_auth():
                return
            pkg = (body.get("package_id") or "").strip()
            if not pkg:
                self._send(400, {"detail": "package_id is required"})
                return
            if pkg == FORBIDDEN_PKG:
                self._send(403, {"detail": (
                    "Rescans are for the app's developer. If you build this app, "
                    "log in as the developer to rescan; to scan apps you don't own, "
                    "see Research plans."
                )})
                return
            if pkg == OVERQUOTA_PKG:
                self._send(429, {"detail": "Monthly rescan limit reached (1/1). Upgrade to the Developer plan for more."})
                return
            self._send(200, {
                "scan_id": "scan_rescan_0001",
                "package_id": pkg,
                "scan_number": 3,
                "status": "queued",
                "status_url": "/api/scan-status/scan_rescan_0001",
                "submitted_at": "2026-08-07T12:00:00Z",
            })
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
