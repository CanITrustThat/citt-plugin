#!/usr/bin/env python3
"""Mock CITT API server for the citt-report harness (CITT-336).

PRIMARY endpoint served (mirrors src/api.py:3293 `get_report`):
  GET /reports/{pkg}.md?report_type=detailed[&scan_id=<id>][&platform=…]
    - 200 text/markdown (owner/admin) with the detailed report body
    - 403 JSON {"detail":"Not authorized to view detailed report"} (non-owner)
    - 403 JSON {"detail":"Report not unlocked","unlock_required":true} (locked)
    - 404 JSON {"detail":"Report not found"} (no completed scan)
    - report_type=detailed REQUIRES auth → 401 without a valid bearer.

SECONDARY endpoint served (custom-scan JSON fallback, src/api.py:6703):
  GET /api/scan/{scan_id}/result → 200 JSON custom-scan result

Auth model (mirrors the real API's skill-token gate):
  - Every request must carry  Authorization: Bearer <token>
  - Bearer value must match CITT_MOCK_TOKEN (default: citt_rpt_mocktoken789)
  - Any other / missing token → 401 {"detail": "unauthorized"}

Scenario is selected by the package_id in the URL (so one running mock serves
every case), OR forced via CITT_MOCK_SCENARIO:
  com.owner.app       → 200 detailed markdown (owner)          [scenario "owner"]
  com.other.app       → 403 not-authorized (non-owner)         [scenario "forbidden"]
  com.locked.app      → 403 unlock_required                    [scenario "locked"]
  com.missing.app     → 404 report not found                   [scenario "notfound"]
  com.custom.app      → 404 detailed, but /result 200 (custom) [scenario "custom"]
  com.platform.app    → 200, echoes the platform query in body [scenario "owner"]

Environment:
  CITT_MOCK_TOKEN     — expected bearer token (default: citt_rpt_mocktoken789)
  CITT_MOCK_SCENARIO  — optional force override (else keyed off package_id)
  CITT_MOCK_LOG       — optional path to append JSON request logs

Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
from urllib.parse import urlparse, parse_qs, unquote

LOG = os.environ.get("CITT_MOCK_LOG")
MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_rpt_mocktoken789")
FORCE_SCENARIO = os.environ.get("CITT_MOCK_SCENARIO", "")

# ---------------------------------------------------------------------------
# Detailed-report markdown fixture (owner).
# ---------------------------------------------------------------------------
DETAILED_MD_OWNER = """# Detailed Security & Privacy Report — com.owner.app

**Overall score:** 78 / 100 (Solid)
**Security:** 80   **Privacy:** 72
**Scan ID:** scan_owner123   **Version:** 2.1.0

## Recommendation
Broadly safe for everyday use.

## Findings

### Network Security (HIGH)
- Weak certificate pinning on the payments host.
- HTTP fallback enabled for the analytics endpoint.

### Data Collection (MEDIUM)
- Third-party analytics SDK present (collects device identifiers).

## What This Means For You
This app is broadly safe for everyday use, with two items worth watching.
"""

# Custom-scan JSON fixture (secondary /api/scan/{id}/result).
CUSTOM_RESULT = {
    "scan_id": "scan_custom999",
    "package_id": "com.custom.app",
    "prompt": "Analyze GDPR compliance",
    "status": "completed",
    "result": {
        "summary": "No GDPR blockers found.",
        "markdown": "## GDPR\n\nData minimization looks acceptable.",
    },
}


def _log(kind, body):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps({"kind": kind, "body": body}) + "\n")
    except OSError:
        pass


def _scenario_for(pkg):
    """Resolve the scenario for a package_id (FORCE_SCENARIO wins)."""
    if FORCE_SCENARIO:
        return FORCE_SCENARIO
    mapping = {
        "com.owner.app": "owner",
        "com.platform.app": "owner",
        "com.other.app": "forbidden",
        "com.locked.app": "locked",
        "com.missing.app": "notfound",
        "com.custom.app": "custom",
    }
    return mapping.get(pkg, "owner")


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

    def _send_md(self, code, text):
        payload = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/markdown; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _bearer_token(self):
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return None

    def _auth_ok(self):
        tok = self._bearer_token()
        return bool(tok) and tok == MOCK_TOKEN

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        auth_ok = self._auth_ok()

        _log("request", {"method": "GET", "path": path, "query": parsed.query, "auth_ok": auth_ok})

        if not auth_ok:
            # detailed report requires auth → 401 without a valid token.
            self._send_json(401, {"detail": "unauthorized"})
            return

        # --- PRIMARY: /reports/{pkg}.md --------------------------------------
        if path.startswith("/reports/") and path.endswith(".md"):
            pkg = unquote(path[len("/reports/"):-len(".md")])
            report_type = (qs.get("report_type", ["public"])[0] or "public")
            scan_id = qs.get("scan_id", [""])[0]
            platform = qs.get("platform", [""])[0]
            scenario = _scenario_for(pkg)
            _log("reports_request", {
                "pkg": pkg, "report_type": report_type,
                "scan_id": scan_id, "platform": platform, "scenario": scenario,
            })

            # The client always requests report_type=detailed. Public would be
            # allowed unauthenticated, but citt report never uses it.
            if scenario == "notfound":
                self._send_json(404, {"detail": "Report not found"})
                return
            if scenario == "forbidden":
                self._send_json(403, {"detail": "Not authorized to view detailed report"})
                return
            if scenario == "locked":
                self._send_json(403, {"detail": "Report not unlocked", "unlock_required": True})
                return
            if scenario == "custom":
                # A custom scan carries no detailed scorecard → 404 here; the
                # client then falls back to /api/scan/{id}/result.
                self._send_json(404, {"detail": "Report not found"})
                return

            # owner: 200 markdown. Echo the platform / scan_id so those tests
            # can confirm the query params were forwarded.
            body = DETAILED_MD_OWNER
            if platform:
                body = body + f"\n<!-- platform: {platform} -->\n"
            if scan_id:
                body = body + f"\n<!-- scan_id: {scan_id} -->\n"
            self._send_md(200, body)
            return

        # --- SECONDARY: /api/scan/{scan_id}/result ---------------------------
        if path.startswith("/api/scan/") and path.endswith("/result"):
            scan_id = path[len("/api/scan/"):-len("/result")]
            _log("result_request", {"scan_id": scan_id})
            if scan_id == "scan_custom999":
                self._send_json(200, CUSTOM_RESULT)
                return
            self._send_json(404, {"detail": "Scan not found"})
            return

        self._send_json(404, {"error": "not_found"})


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
