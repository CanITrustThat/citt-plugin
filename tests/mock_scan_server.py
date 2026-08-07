#!/usr/bin/env python3
"""Mock CITT API server for the citt-scan harness (CITT-C1).

Serves POST /api/submit for the `citt scan` custom-prompt command, mirroring the
real API's SubmitRequest / SubmitResponse shapes plus the custom-prompt gates.

Auth model (mirrors the real API's skill-token gate):
  - Every request must carry  Authorization: Bearer <token>
  - Bearer value must match CITT_MOCK_TOKEN (default: citt_scan_mocktoken789)
  - Any other / missing token → 401 {"detail": "unauthorized"}

Response status is parameterized so ONE mock instance can produce
200/202/400/401/403 across the test cases. Selection order:
  1. CITT_MOCK_STATUS env var (forces a fixed HTTP status for /api/submit), OR
  2. keyed off the package_id in the request body:
       com.ok.app        → 200 success
       com.accepted.app  → 202 accepted (same body shape)
       com.cross.app     → 403 CUSTOM_CROSS_APP_DETAIL (needs Research plan)
       com.bad.app       → 400 prompt rejected
     (default: 200)

Every submit body is recorded to CITT_MOCK_LOG (if set) so the harness can assert
exactly what was sent (scan_type, is_private, prompt, package_id, platform).

Prints "http://127.0.0.1:<port>" to stdout on the first line and stays foreground.
"""
import http.server
import json
import os
from urllib.parse import urlparse

LOG = os.environ.get("CITT_MOCK_LOG")
MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_scan_mocktoken789")
FORCE_STATUS = os.environ.get("CITT_MOCK_STATUS", "")

CUSTOM_CROSS_APP_DETAIL = (
    "Custom prompts on apps you don't own require the Research plan."
)


def _log(kind, obj):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps({"kind": kind, "body": obj}) + "\n")
    except OSError:
        pass


def _status_for(pkg):
    if FORCE_STATUS:
        try:
            return int(FORCE_STATUS)
        except ValueError:
            return 200
    mapping = {
        "com.ok.app": 200,
        "com.accepted.app": 202,
        "com.cross.app": 403,
        "com.bad.app": 400,
    }
    return mapping.get(pkg, 200)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # silence default access log

    def _send_json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _bearer_token(self):
        auth = self.headers.get("Authorization", "") or ""
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return None

    def _auth_ok(self):
        tok = self._bearer_token()
        return bool(tok) and tok == MOCK_TOKEN

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        auth_ok = self._auth_ok()
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode() if length else ""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {"_unparsed": raw}

        if path != "/api/submit":
            self._send_json(404, {"detail": "not_found"})
            return

        pkg = body.get("package_id", "")
        _log("submit", {
            "path": path, "pkg": pkg, "auth_ok": auth_ok, "body": body,
        })

        if not auth_ok:
            self._send_json(401, {"detail": "unauthorized"})
            return

        code = _status_for(pkg)

        if code == 403:
            self._send_json(403, {"detail": CUSTOM_CROSS_APP_DETAIL})
            return
        if code == 400:
            self._send_json(400, {"detail": "Prompt is empty or too long."})
            return
        if code == 401:
            self._send_json(401, {"detail": "unauthorized"})
            return

        # 200 or 202 success — SubmitResponse-shaped body.
        self._send_json(code, {
            "id": "sub_" + (pkg or "x"),
            "scan_id": "abc123",
            "package_id": pkg,
            "scan_type": "custom",
            "is_private": True,
            "status": "queued",
            "status_url": "/api/status/%s" % pkg,
        })

    def do_GET(self):
        self._send_json(404, {"detail": "not_found"})


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
