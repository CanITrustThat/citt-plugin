#!/usr/bin/env python3
"""Mock CITT status/scans server for the citt-results/citt-status harness (CITT-335).

Serves:
  GET  /api/status/{package_id}    — StatusResponse-shaped body (api.py:637)
  GET  /api/apps/{package_id}/scans — ScanListResponse-shaped body (api.py:5842)

Fixtures (controlled by package_id):
  com.completed.app   — completed scan with full scorecard data
  com.pending.app     — in-progress (analyzing) scan
  com.queued.app      — queued scan (no results yet)
  com.failed.app      — failed scan
  com.notfound.app    — 404 Not Found on both endpoints
  Any other pkg       — 404

Auth: NONE required (public endpoints). Requests with any Authorization header
      are still served normally (the server ignores it — it's a public mock).

Prints "http://127.0.0.1:<port>" to stdout on start.
Stays in the foreground; kill with SIGINT/SIGKILL.

Modelled on citt-plugin/tests/mock_api_server.py (CITT-333).
"""
import http.server
import json
import os
import time
from urllib.parse import urlparse

_now = time.time()
FRESH_TS = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_now - 3 * 86400))   # 3 days ago
SUBMITTED_TS = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_now - 4 * 86400))

LOG = os.environ.get("CITT_MOCK_LOG")


def _log(entry):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# StatusResponse fixture bodies (mirrors real api.py fields at line 637+)
# ---------------------------------------------------------------------------

def _completed_status(pkg):
    """A completed scan — full public scorecard data."""
    return {
        "id": "scan_" + pkg.replace(".", "_"),
        "package_id": pkg,
        "app_name": pkg.split(".")[-1].title() + " App",
        "app_description": "A sample application for testing.",
        "developer_name": "Mock Developer LLC",
        "developer_support_email": None,
        "developer_alternative_email": None,
        "status": "completed",
        "scan_type": "full",
        "platform": "android",
        "analysis_depth": "full",
        "is_private": False,
        "overall_score": 72,
        "security_score": 70,
        "privacy_score": 74,
        "public_report_url": "/reports/%s.md" % pkg,
        "submitted_at": SUBMITTED_TS,
        "completed_at": FRESH_TS,
        "error_message": None,
        "error_code": None,
        "submission_count": 2,
        "version": "4.2.1",
        "analysis_date": FRESH_TS[:10],
        "classes_analyzed": 1842,
        "recommendation": "Use With Caution",
        "recommendation_message": "This app handles sensitive data but has some concerns.",
        "started_at": SUBMITTED_TS,
        "downloaded_at": SUBMITTED_TS,
        "decompiled_at": SUBMITTED_TS,
        "decompiled_file_count": 312,
        "current_stage": None,
        "estimated_completion_minutes": None,
        "eta_low_minutes": None,
        "eta_high_minutes": None,
        "queue_position": None,
        "progress_message": "Analysis complete - report available",
        # Severity counts: gated per CITT-56 — these are None for public callers.
        "critical_findings_count": None,
        "high_findings_count": None,
        "medium_findings_count": None,
        "low_findings_count": None,
        "info_findings_count": None,
        # total is public (api.py:2111-2117)
        "total_findings_count": 14,
        "security_issues_count": 8,
        "privacy_issues_count": 6,
        "top_security_issues": [
            "Unencrypted local storage of user credentials",
            "Weak TLS configuration (allows TLS 1.0)",
        ],
        "top_privacy_issues": [
            "Third-party analytics SDK shares device identifiers",
            "Location data collected without clear disclosure",
        ],
        "primary_concern": "Data handling and transmission security",
        "quick_verdict": {
            "best_for": "Users who need basic productivity features and accept moderate privacy trade-offs.",
            "avoid_if": "You require strict data privacy or handle sensitive personal information.",
        },
        "findings": None,   # gated — None for public callers
        "findings_by_category": [
            {"category": "network_security", "critical": 0, "high": 1, "medium": 2, "low": 1},
            {"category": "data_collection",  "critical": 0, "high": 0, "medium": 3, "low": 2},
            {"category": "authentication",   "critical": 0, "high": 1, "medium": 1, "low": 0},
            {"category": "cryptography",     "critical": 0, "high": 0, "medium": 2, "low": 1},
        ],
        "what_it_means_for_you": (
            "This app is broadly fine for everyday tasks like note-taking or calendaring, "
            "but it collects more data than strictly necessary and uses a third-party analytics "
            "SDK that shares your device ID. Avoid using it for anything involving passwords, "
            "medical details, or financial information."
        ),
        "third_party_services": ["Google Analytics", "Firebase Crashlytics", "Adjust"],
        "strengths": ["Certificate pinning enabled", "No hardcoded secrets detected"],
        "context_tags": ["productivity", "android", "analytics"],
        "current_scan_status": None,
        "custom_reports_count": None,
        "custom_reports_completed": None,
        "store_url": "https://play.google.com/store/apps/details?id=%s" % pkg,
        "prompt": None,
        "result": None,
        "stamps": [
            {
                "stamp_id": "no_data_broker_sharing",
                "state": "earned",
                "type": "positive",
                "label": "No Data Broker Sharing",
                "short_description": "No evidence of data broker SDK integration.",
                "evidence": "No Acxiom/LotAme/Criteo SDKs found in decompiled code.",
            }
        ],
        "red_flags": None,
        "stamps_version": "4.2.1",
        "stamps_status": "completed",
        "trust_verdict": {
            "trusted": False,
            "pillar_statuses": {
                "security": "warning",
                "privacy": "warning",
                "transparency": "pass",
            },
        },
        "artifact_sha256": None,
        "ruleset_version": None,
        "model_version": None,
        "prompt_version": None,
        "disclosure_status": "none",
        "developer_response": None,
        "notified_at": None,
        "embargo_until": None,
        "response_received_at": None,
        "corrections": [],
    }


def _pending_status(pkg, stage="analyzing"):
    """An in-progress scan — no results yet."""
    return {
        "id": "scan_" + pkg.replace(".", "_"),
        "package_id": pkg,
        "app_name": None,
        "app_description": None,
        "developer_name": None,
        "developer_support_email": None,
        "developer_alternative_email": None,
        "status": stage if stage in ("queued", "analyzing") else "analyzing",
        "scan_type": "full",
        "platform": "android",
        "analysis_depth": "full",
        "is_private": False,
        "overall_score": None,
        "security_score": None,
        "privacy_score": None,
        "public_report_url": None,
        "submitted_at": SUBMITTED_TS,
        "completed_at": None,
        "error_message": None,
        "error_code": None,
        "submission_count": 1,
        "version": None,
        "analysis_date": None,
        "classes_analyzed": None,
        "recommendation": None,
        "recommendation_message": None,
        "started_at": SUBMITTED_TS,
        "downloaded_at": SUBMITTED_TS,
        "decompiled_at": SUBMITTED_TS,
        "decompiled_file_count": None,
        "current_stage": "analyzing - stage 2: reviewing network calls",
        "estimated_completion_minutes": 5,
        "eta_low_minutes": 3,
        "eta_high_minutes": 10,
        "queue_position": None,
        "progress_message": "Analyzing: reviewing network calls",
        "critical_findings_count": None,
        "high_findings_count": None,
        "medium_findings_count": None,
        "low_findings_count": None,
        "info_findings_count": None,
        "total_findings_count": None,
        "security_issues_count": None,
        "privacy_issues_count": None,
        "top_security_issues": None,
        "top_privacy_issues": None,
        "primary_concern": None,
        "quick_verdict": None,
        "findings": None,
        "findings_by_category": None,
        "what_it_means_for_you": None,
        "third_party_services": None,
        "strengths": None,
        "context_tags": None,
        "current_scan_status": None,
        "custom_reports_count": None,
        "custom_reports_completed": None,
        "store_url": None,
        "prompt": None,
        "result": None,
        "stamps": None,
        "red_flags": None,
        "stamps_version": None,
        "stamps_status": None,
        "trust_verdict": None,
        "artifact_sha256": None,
        "ruleset_version": None,
        "model_version": None,
        "prompt_version": None,
        "disclosure_status": "none",
        "developer_response": None,
        "notified_at": None,
        "embargo_until": None,
        "response_received_at": None,
        "corrections": [],
    }


def _queued_status(pkg):
    """A queued scan — waiting to start."""
    body = _pending_status(pkg, stage="queued")
    body["current_stage"] = None
    body["progress_message"] = "Queued for analysis"
    body["estimated_completion_minutes"] = 8
    body["eta_low_minutes"] = 5
    body["eta_high_minutes"] = 15
    body["queue_position"] = 3
    body["started_at"] = None
    body["downloaded_at"] = None
    body["decompiled_at"] = None
    return body


def _failed_status(pkg):
    """A failed scan."""
    body = _pending_status(pkg)
    body["status"] = "failed"
    body["current_stage"] = None
    body["progress_message"] = "Analysis failed: APK download failed"
    body["error_message"] = "APK download failed"
    body["error_code"] = "download_failed"
    body["estimated_completion_minutes"] = None
    body["eta_low_minutes"] = None
    body["eta_high_minutes"] = None
    body["queue_position"] = None
    return body


# ---------------------------------------------------------------------------
# ScanListResponse fixture bodies (api.py:5842)
# ---------------------------------------------------------------------------

def _scans_list(pkg, scans):
    """ScanListResponse shape."""
    return {
        "package_id": pkg,
        "scans": scans,
        "total": len(scans),
    }


def _scan_item(pkg, scan_id, scan_number, status, score, completed_at, version="4.2.1"):
    """ScanListItem shape (api.py:5842)."""
    return {
        "scan_id": scan_id,
        "scan_number": scan_number,
        "is_private": False,
        "status": status,
        "scan_type": "full",
        "overall_score": score,
        "security_score": (score - 5) if score is not None else None,
        "privacy_score": (score - 10) if score is not None else None,
        "version": version if status == "completed" else None,
        "analysis_date": FRESH_TS[:10] if status == "completed" else None,
        "submitted_at": SUBMITTED_TS,
        "completed_at": completed_at,
        "prompt": None,
        "output_schema": None,
    }


FIXTURES = {
    "com.completed.app": {
        "status": _completed_status("com.completed.app"),
        "scans": _scans_list("com.completed.app", [
            _scan_item("com.completed.app", "scan_com_completed_app_2", 2, "completed", 72, FRESH_TS),
            _scan_item("com.completed.app", "scan_com_completed_app_1", 1, "completed", 65, SUBMITTED_TS, "4.1.0"),
        ]),
    },
    "com.pending.app": {
        "status": _pending_status("com.pending.app"),
        "scans": _scans_list("com.pending.app", [
            _scan_item("com.pending.app", "scan_com_pending_app_1", 1, "analyzing", None, None),
        ]),
    },
    "com.queued.app": {
        "status": _queued_status("com.queued.app"),
        "scans": _scans_list("com.queued.app", [
            _scan_item("com.queued.app", "scan_com_queued_app_1", 1, "queued", None, None),
        ]),
    },
    "com.failed.app": {
        "status": _failed_status("com.failed.app"),
        "scans": _scans_list("com.failed.app", [
            _scan_item("com.failed.app", "scan_com_failed_app_1", 1, "failed", None, None),
        ]),
    },
}


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

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # GET /api/status/{package_id}
        if path.startswith("/api/status/"):
            pkg = path[len("/api/status/"):]
            _log({"method": "GET", "path": "status", "pkg": pkg})
            if pkg == "com.notfound.app" or pkg not in FIXTURES:
                self._send(404, {"detail": "Package not found"})
                return
            self._send(200, FIXTURES[pkg]["status"])
            return

        # GET /api/apps/{package_id}/scans
        if path.startswith("/api/apps/") and path.endswith("/scans"):
            # extract between /api/apps/ and /scans
            inner = path[len("/api/apps/"):-len("/scans")]
            pkg = inner
            _log({"method": "GET", "path": "scans", "pkg": pkg})
            if pkg == "com.notfound.app" or pkg not in FIXTURES:
                self._send(404, {"detail": "App not found"})
                return
            self._send(200, FIXTURES[pkg]["scans"])
            return

        self._send(404, {"detail": "not_found"})

    def do_POST(self):
        self._send(404, {"detail": "not_found"})


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
