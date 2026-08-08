#!/usr/bin/env python3
"""Mock CITT API server for the citt status harness.

Serves GET /api/status/{package_id} with optional ?scan_id / ?scan_number,
mirroring the real endpoint's behaviour:

  * plain (no selector): returns the last COMPLETED scan. For com.example.app a
    rescan is "running", so current_scan_status is "analyzing" (the in-flight
    scan is NOT surfaced as the top-level status — you must poll it by id).
  * ?scan_id=<id> / ?scan_number=<n>: returns THAT scan's live status, including
    queued/analyzing. Unknown selector -> 404.
  * A private scan (scan_private_9) needs a valid Bearer token -> 403 otherwise.
  * com.notfound.app -> 404 package not found.

Auth is OPTIONAL (public scorecards are anonymous). If an Authorization header is
present it must equal CITT_MOCK_TOKEN, else 401 (the CLI then retries anonymously).

Logs each request (path + whether an Authorization header was sent) to CITT_MOCK_LOG
so the harness can assert selector pass-through and auth behaviour.
Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
import urllib.parse

MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_status_mocktoken456")
LOG = os.environ.get("CITT_MOCK_LOG")

NOTFOUND_PKG = "com.notfound.app"


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

    # completed scan skeleton
    def _completed(self, pkg, scan_id, score, current_scan_status=None, is_private=False):
        return {
            "id": scan_id,
            "package_id": pkg,
            "app_name": "Example App",
            "status": "completed",
            "scan_type": "full",
            "platform": "android",
            "is_private": is_private,
            "overall_score": score,
            "security_score": score,
            "privacy_score": score,
            "public_report_url": f"/reports/{pkg}.md",
            "submitted_at": "2026-02-11T19:00:00Z",
            "completed_at": "2026-02-11T19:31:47.046458Z",
            "current_scan_status": current_scan_status,
            "current_stage": None,
            "queue_position": None,
            "progress_message": None,
            "total_findings_count": 18,
            "critical_findings_count": 2,
            "high_findings_count": 5,
            "medium_findings_count": 6,
            "low_findings_count": 3,
            "info_findings_count": 2,
            "recommendation": "use_with_caution",
        }

    def _inflight(self, pkg, scan_id, status, stage=None, qpos=None):
        return {
            "id": scan_id,
            "package_id": pkg,
            "app_name": "Example App",
            "status": status,
            "scan_type": "full",
            "platform": "android",
            "is_private": False,
            "overall_score": None,
            "public_report_url": None,
            "submitted_at": "2026-08-07T12:00:00Z",
            "completed_at": None,
            "current_scan_status": status,
            "current_stage": stage,
            "queue_position": qpos,
            "progress_message": ("Decompiling APK" if stage else None),
            "total_findings_count": None,
            "critical_findings_count": None,
            "high_findings_count": None,
            "medium_findings_count": None,
            "low_findings_count": None,
            "info_findings_count": None,
            "recommendation": None,
        }

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)
        scan_id = (qs.get("scan_id") or [None])[0]
        scan_number = (qs.get("scan_number") or [None])[0]
        has_auth = self._bearer() is not None
        _log("status", {"path": self.path, "scan_id": scan_id,
                        "scan_number": scan_number, "has_auth": has_auth})

        # Scans list — lets a plain status call auto-resolve the in-flight scan id.
        if path.startswith("/api/apps/") and path.endswith("/scans"):
            pkg = urllib.parse.unquote(path[len("/api/apps/"):-len("/scans")])
            self._send(200, {
                "package_id": pkg,
                "total": 3,
                "scans": [
                    {"scan_id": "scan_inflight_1", "scan_number": 3, "status": "analyzing",
                     "scan_type": "full", "is_private": False, "overall_score": None},
                    {"scan_id": "scan_done_old", "scan_number": 2, "status": "completed",
                     "scan_type": "full", "is_private": False, "overall_score": 22},
                    {"scan_id": "scan_failed_0", "scan_number": 1, "status": "failed",
                     "scan_type": "full", "is_private": False, "overall_score": None},
                ],
            })
            return

        if not path.startswith("/api/status/"):
            self._send(404, {"error": "not_found"})
            return

        # If a token is presented it must be valid; absent is fine (anonymous).
        tok = self._bearer()
        if tok is not None and tok != MOCK_TOKEN:
            self._send(401, {"detail": "invalid token"})
            return
        authed = tok == MOCK_TOKEN

        pkg = urllib.parse.unquote(path[len("/api/status/"):])

        if pkg == NOTFOUND_PKG:
            self._send(404, {"detail": "Package not found"})
            return

        if scan_id is not None:
            if scan_id == "scan_inflight_1":
                self._send(200, self._inflight(pkg, scan_id, "analyzing", stage="decompiling"))
            elif scan_id == "scan_queued_1":
                self._send(200, self._inflight(pkg, scan_id, "queued", qpos=2))
            elif scan_id == "scan_done_2":
                self._send(200, self._completed(pkg, scan_id, 80))
            elif scan_id == "scan_private_9":
                if not authed:
                    self._send(403, {"detail": "Access denied to private scan"})
                else:
                    self._send(200, self._completed(pkg, scan_id, 65, is_private=True))
            else:
                self._send(404, {"detail": "Scan not found"})
            return

        if scan_number is not None:
            if scan_number == "3":
                self._send(200, self._inflight(pkg, "scan_inflight_1", "analyzing", stage="decompiling"))
            else:
                self._send(404, {"detail": "Scan not found"})
            return

        # Latest: com.example.app has a background rescan running.
        if pkg == "com.example.app":
            self._send(200, self._completed(pkg, "scan_done_old", 22, current_scan_status="analyzing"))
        else:
            self._send(200, self._completed(pkg, "scan_done_old", 70))


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
