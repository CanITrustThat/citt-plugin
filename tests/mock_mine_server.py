#!/usr/bin/env python3
"""Mock CITT API server for the citt mine harness (CITT-337).

Serves:
  GET  /api/me                              — authenticated user info
  GET  /api/apps?my_scans=true&...         — user-submitted apps listing
  GET  /api/me/claimed-apps                — NOT IMPLEMENTED (404) — documents gap

The server is configurable via environment variables so the harness can drive
different scenarios (happy path, empty list, 401, 404).

Environment:
  CITT_MOCK_TOKEN      — expected bearer token (default: citt_mine_mocktoken456)
  CITT_MOCK_APPS       — JSON array of app objects to return (default: see MOCK_APPS)
  CITT_MOCK_LOG        — optional path to append JSON request logs

Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
import sys
import threading
import urllib.parse

MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_mine_mocktoken456")
LOG = os.environ.get("CITT_MOCK_LOG")

MOCK_USER = {
    "id": "usr_test001",
    "email": "developer@example.com",
    "user_type": "developer",
    "display_name": "Test Developer",
}

DEFAULT_APPS = [
    {
        "package_id": "com.example.myapp",
        "app_name": "My App",
        "developer_name": "Example Corp",
        "overall_score": 82,
        "security_score": 85,
        "privacy_score": 79,
        "status": "completed",
        "completed_at": "2026-07-01T12:00:00Z",
        "platform": "android",
        "total_findings_count": 5,
        "critical_findings_count": 0,
        "high_findings_count": 1,
        "recommendation": "trustworthy",
    },
    {
        "package_id": "com.example.otherapp",
        "app_name": "Other App",
        "developer_name": "Example Corp",
        "overall_score": 61,
        "security_score": 58,
        "privacy_score": 64,
        "status": "completed",
        "completed_at": "2026-07-15T08:30:00Z",
        "platform": "android",
        "total_findings_count": 12,
        "critical_findings_count": 2,
        "high_findings_count": 3,
        "recommendation": "use_with_caution",
    },
]

MOCK_APPS_RAW = os.environ.get("CITT_MOCK_APPS")
if MOCK_APPS_RAW:
    try:
        MOCK_APPS = json.loads(MOCK_APPS_RAW)
    except (json.JSONDecodeError, ValueError):
        MOCK_APPS = DEFAULT_APPS
else:
    MOCK_APPS = DEFAULT_APPS


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

    def _bearer_token(self):
        """Extract bearer token from Authorization header, or None."""
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return None

    def _require_auth(self):
        """Check bearer token. Returns True if valid, sends 401 and returns False otherwise."""
        token = self._bearer_token()
        if not token or token != MOCK_TOKEN:
            self._send(401, {"detail": "unauthorized"})
            return False
        return True

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path == "/api/me":
            _log("me_request", {"path": self.path})
            if not self._require_auth():
                return
            self._send(200, MOCK_USER)
            return

        if path == "/api/apps":
            _log("apps_request", {"path": self.path, "qs": qs})
            if not self._require_auth():
                return
            # Return the configured list; honour limit/offset for realism
            limit = int(qs.get("limit", ["50"])[0])
            offset = int(qs.get("offset", ["0"])[0])
            sliced = MOCK_APPS[offset:offset + limit]
            self._send(200, {"apps": sliced, "total": len(MOCK_APPS)})
            return

        # /api/me/claimed-apps is NOT implemented — documents the backend gap.
        if path == "/api/me/claimed-apps":
            _log("claimed_apps_request", {"path": self.path})
            self._send(404, {"detail": "not_found"})
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
