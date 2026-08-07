#!/usr/bin/env python3
"""Tiny mock CITT submit/status/search server for the citt-submit.sh harness
(CITT-268).

Serves canned /api/submit, /api/status/{package_id}, and /api/search-apps
responses on 127.0.0.1, mirroring the EXACT request/response shapes read out of
src/api.py (SubmitRequest / SubmitResponse / StatusResponse / search-apps).

It is a scriptable state machine so the harness can drive dedup, resilience,
tier-gating, name-resolution, and auth scenarios deterministically:

  * Auth: EVERY request must carry `Authorization: Bearer citt_...`. Missing /
    non-`citt_` bearer -> 401. A bearer equal to CITT_MOCK_BAD_TOKEN -> 401
    (models a revoked/expired skill token, matching validate_skill_token -> None
    -> get_current_user None -> submit's 401).

  * /api/status/{pkg}: returns a StatusResponse-shaped body. The per-package
    behavior is seeded from CITT_MOCK_STATUS (JSON map: pkg -> config), e.g.
      {
        "com.fresh.app":   {"pre": "fresh"},        # fresh <90d completed scan
        "com.stale.app":   {"pre": "stale"},        # old completed scan (>90d)
        "com.new.app":     {"pre": "missing"},      # 404 -> needs submit
        "com.stuck.app":   {"pre": "missing", "poll": ["queued","analyzing","analyzing"]},
        "com.ok.app":      {"pre": "missing", "poll": ["queued","completed"]},
      }
    `pre` governs the FIRST status GET (the dedup pre-check). `poll` is a list of
    statuses returned on subsequent GETs (post-submit polling), consumed one per
    call, last value sticky. A "completed" poll/pre yields scores so the summary
    can rank it.

  * /api/submit: 403 (tier) if pkg in CITT_MOCK_TIER_DENY. Otherwise 200 with a
    SubmitResponse; every submit is recorded to CITT_MOCK_LOG so the harness can
    assert which packages were (not) submitted.

  * /api/search-apps: resolves ?q= via CITT_MOCK_SEARCH (JSON map: query-lower ->
    results list) into the {"results":[...], "total":N, "has_more":bool} shape.

Prints its "http://127.0.0.1:<port>" base URL to stdout on the first line and
stays in the foreground. Records each request (method, path, pkg, auth-ok,
body) to CITT_MOCK_LOG (if set).
"""
import http.server
import json
import os
import threading
import time
from urllib.parse import urlparse, parse_qs

LOG = os.environ.get("CITT_MOCK_LOG")

STATUS_CFG = json.loads(os.environ.get("CITT_MOCK_STATUS", "{}"))
SEARCH_CFG = json.loads(os.environ.get("CITT_MOCK_SEARCH", "{}"))
TIER_DENY = set(
    p for p in os.environ.get("CITT_MOCK_TIER_DENY", "").split(",") if p.strip()
)
BAD_TOKEN = os.environ.get("CITT_MOCK_BAD_TOKEN", "")

# Fresh vs stale completion timestamps (ISO Z). Fresh = 5 days ago, stale = 200
# days ago, so the client's <90d dedup window bisects them.
_now = time.time()
FRESH_TS = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_now - 5 * 86400))
STALE_TS = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_now - 200 * 86400))

_lock = threading.Lock()
# Per-package poll cursor for the post-submit polling sequence.
_poll_cursor = {}


def _log(entry):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def _status_body(pkg, status, completed_ts=None, score=None):
    """A StatusResponse-shaped dict (only the fields the client reads, plus a
    realistic spread). Unknown fields are fine; the client extracts scalars."""
    body = {
        "id": "scan_" + pkg,
        "package_id": pkg,
        "app_name": pkg.split(".")[-1].title(),
        "app_description": None,
        "developer_name": "Mock Dev",
        "developer_support_email": None,
        "developer_alternative_email": None,
        "status": status,
        "scan_type": "full",
        "platform": "android",
        "is_private": False,
        "overall_score": score,
        "security_score": (score - 5) if score is not None else None,
        "privacy_score": (score - 10) if score is not None else None,
        "public_report_url": ("/reports/%s.md" % pkg) if status == "completed" else None,
        "submitted_at": FRESH_TS,
        "completed_at": completed_ts,
        "error_message": None,
        "error_code": None,
        "recommendation": "Solid" if score else None,
        "current_stage": None if status == "completed" else status,
        "critical_findings_count": 0 if score else None,
        "high_findings_count": (1 if (score and score < 80) else 0) if score is not None else None,
        "top_security_issues": (["Weak TLS config"] if (score and score < 80) else []) if score is not None else None,
        "top_privacy_issues": (["Ad SDK present"] if (score and score < 80) else []) if score is not None else None,
        "findings_by_category": (
            [
                {"category": "network_security", "critical": 0, "high": 1 if (score and score < 80) else 0, "medium": 1, "low": 0},
                {"category": "data_collection", "critical": 0, "high": 0, "medium": 2, "low": 1},
            ]
            if status == "completed" else None
        ),
        "what_it_means_for_you": ("This app is broadly fine for everyday use." if status == "completed" else None),
        "store_url": "https://play.google.com/store/apps/details?id=%s" % pkg,
    }
    return body


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

    def _auth_ok(self):
        auth = self.headers.get("Authorization", "") or ""
        if not auth.startswith("Bearer "):
            return False
        tok = auth[len("Bearer "):].strip()
        if not tok.startswith("citt_"):
            return False
        if BAD_TOKEN and tok == BAD_TOKEN:
            return False
        return True

    # --- GET: status + search ---------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        auth_ok = self._auth_ok()

        if path.startswith("/api/status/"):
            pkg = path[len("/api/status/"):]
            _log({"method": "GET", "path": "status", "pkg": pkg, "auth_ok": auth_ok})
            if not auth_ok:
                self._send(401, {"detail": "Authentication required"})
                return
            cfg = STATUS_CFG.get(pkg, {"pre": "missing"})
            with _lock:
                seen = _poll_cursor.get(pkg)
                first = seen is None
                if first:
                    _poll_cursor[pkg] = 0
                else:
                    _poll_cursor[pkg] = seen + 1
                idx = _poll_cursor[pkg]

            if first:
                pre = cfg.get("pre", "missing")
                if pre == "missing":
                    self._send(404, {"detail": "Package not found"})
                    return
                if pre == "fresh":
                    self._send(200, _status_body(pkg, "completed", FRESH_TS, cfg.get("score", 82)))
                    return
                if pre == "stale":
                    self._send(200, _status_body(pkg, "completed", STALE_TS, cfg.get("score", 60)))
                    return
                # otherwise fall through as if in-progress
                self._send(200, _status_body(pkg, pre))
                return

            # Post-submit polling: walk the `poll` sequence.
            seq = cfg.get("poll", ["completed"])
            i = min(idx - 1, len(seq) - 1)
            st = seq[i]
            if st == "completed":
                self._send(200, _status_body(pkg, "completed", FRESH_TS, cfg.get("score", 75)))
            elif st == "failed":
                b = _status_body(pkg, "failed")
                b["error_message"] = "analysis failed"
                self._send(200, b)
            else:
                self._send(200, _status_body(pkg, st))
            return

        if path == "/api/search-apps":
            qs = parse_qs(parsed.query)
            q = (qs.get("q", [""])[0] or "").lower().strip()
            _log({"method": "GET", "path": "search", "q": q, "auth_ok": auth_ok})
            if not auth_ok:
                self._send(401, {"detail": "Authentication required"})
                return
            results = SEARCH_CFG.get(q, [])
            self._send(200, {"results": results, "total": len(results), "has_more": False})
            return

        self._send(404, {"detail": "not_found"})

    # --- POST: submit ------------------------------------------------------
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

        if path == "/api/submit":
            pkg = body.get("package_id", "")
            _log({"method": "POST", "path": "submit", "pkg": pkg,
                  "auth_ok": auth_ok, "body": body})
            if not auth_ok:
                self._send(401, {"detail": "Authentication required"})
                return
            if pkg in TIER_DENY:
                self._send(403, {
                    "detail": {
                        "status": "denied_tier",
                        "message": ("Batch submission needs the Developer ($20/mo) or "
                                    "Research ($299/mo) plan — upgrade at "
                                    "canitrustthat.com/pricing."),
                        "upgrade_url": "https://canitrustthat.com/pricing",
                    }
                })
                return
            self._send(200, {
                "id": "sub_" + pkg,
                "scan_id": "scan_" + pkg,
                "package_id": pkg,
                "status": "queued",
                "scan_number": 1,
                "status_url": "/api/status/%s" % pkg,
                "submitted_at": FRESH_TS,
            })
            return

        self._send(404, {"detail": "not_found"})


def main():
    httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    print("http://127.0.0.1:%d" % port, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
