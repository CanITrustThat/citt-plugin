#!/usr/bin/env python3
"""Mock CITT API server for the citt-result harness (CITT-C2).

Endpoint served (mirrors src/api.py custom-scan result, api.py:6703):
  GET /api/scan/{scan_id}/result
    - 200 JSON custom-scan result (completed)   [scenario "ok"]
    - 404 JSON {"detail":"..."} not ready yet    [scenario "notready"]
    - 403 JSON {"detail":"..."} not authorized    [scenario "forbidden"]
    - The endpoint REQUIRES auth → 401 without a valid bearer, or when the
      scenario is forced to "unauth".

Auth model (mirrors the real API's skill-token gate):
  - Every request must carry  Authorization: Bearer <token>
  - Bearer value must match CITT_MOCK_TOKEN (default: citt_res_mocktoken789)
  - Any other / missing token → 401 {"detail": "unauthorized"}

Scenario is selected by the scan_id in the URL (so one running mock serves
every case), OR forced via CITT_MOCK_SCENARIO:
  scan_ok<...>        → 200 completed custom-scan JSON        [scenario "ok"]
  scan_notready<...>  → 404 not ready yet (still processing)  [scenario "notready"]
  scan_forbidden<...> → 403 not authorized                    [scenario "forbidden"]
  scan_unauth<...>    → 401 (simulate expired/invalid token)  [scenario "unauth"]

Environment:
  CITT_MOCK_TOKEN     — expected bearer token (default: citt_res_mocktoken789)
  CITT_MOCK_SCENARIO  — optional force override (else keyed off scan_id)
  CITT_MOCK_LOG       — optional path to append JSON request logs

Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
from urllib.parse import urlparse, unquote

LOG = os.environ.get("CITT_MOCK_LOG")
MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_res_mocktoken789")
FORCE_SCENARIO = os.environ.get("CITT_MOCK_SCENARIO", "")


def _log(kind, body):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps({"kind": kind, "body": body}) + "\n")
    except OSError:
        pass


def _scenario_for(scan_id):
    """Resolve the scenario for a scan_id (FORCE_SCENARIO wins)."""
    if FORCE_SCENARIO:
        return FORCE_SCENARIO
    if scan_id.startswith("scan_notready"):
        return "notready"
    if scan_id.startswith("scan_forbidden"):
        return "forbidden"
    if scan_id.startswith("scan_unauth"):
        return "unauth"
    return "ok"


def _result_for(scan_id):
    return {
        "scan_id": scan_id,
        "package_id": "com.foo.bar",
        "prompt": "does it leak location?",
        "status": "completed",
        "result": {"answer": "no evidence of location exfiltration"},
    }


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
        auth_ok = self._auth_ok()

        _log("request", {"method": "GET", "path": path,
                         "query": parsed.query, "auth_ok": auth_ok})

        if not auth_ok:
            self._send_json(401, {"detail": "unauthorized"})
            return

        # GET /api/scan/{scan_id}/result
        if path.startswith("/api/scan/") and path.endswith("/result"):
            scan_id = unquote(path[len("/api/scan/"):-len("/result")])
            scenario = _scenario_for(scan_id)
            _log("result_request", {"scan_id": scan_id, "scenario": scenario})

            if scenario == "notready":
                self._send_json(404, {"detail": "Scan result not ready"})
                return
            if scenario == "forbidden":
                self._send_json(403, {"detail": "Not authorized to view this scan"})
                return
            if scenario == "unauth":
                self._send_json(401, {"detail": "unauthorized"})
                return

            # ok: 200 completed custom-scan JSON.
            self._send_json(200, _result_for(scan_id))
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
