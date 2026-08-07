#!/usr/bin/env python3
"""Mock CITT search server for the citt search harness (CITT-338).

Serves GET /api/search-apps with scripted fixtures, mirroring the exact
response shape from src/api.py:search_apps_endpoint (verified at ~line 2389).

Response shape:
  {
    "results": [
      {
        "package_id": str,
        "app_name": str,
        "developer": str,
        "icon_url": str,
        "rating": float | null,
        "downloads": str | null,
        "store_url": str,
        "platform": "android" | "ios",
        "scanned": bool,
        "overall_score": int | null,
        "status": str | null,
        "app_description": str | null,
        "recommendation": str | null,
        "critical_findings_count": int | null,
        "high_findings_count": int | null,
        "medium_findings_count": int | null,
        "low_findings_count": int | null,
      },
      ...
    ],
    "total": int,
    "has_more": bool,
  }

Query params honored: q, platform (android|ios), limit (1..50), offset.
  - "xyzzy_no_match_zzzz" or any unknown query -> empty results (fixture)
  - "my app" (space-containing query) -> empty results (tests URL-encoding)
  - "signal" + platform=android -> multi-result android fixture
  - "signal" + platform=ios -> ios fixture
  - Any q + limit=N -> at most N results returned

Auth: this is a PUBLIC endpoint; no Authorization header is required. A token
present in the request is silently ignored (never reflected). This models the
real endpoint which accepts `get_current_user` as optional.

Prints "http://127.0.0.1:<port>" to stdout on start (ephemeral free port).
"""
import http.server
import json
import sys
from urllib.parse import urlparse, parse_qs, unquote_plus

# ---------------------------------------------------------------------------
# Static fixtures — modelled on real api.py response shape
# ---------------------------------------------------------------------------
_ANDROID_RESULTS = [
    {
        "package_id": "org.thoughtcrime.securesms",
        "app_name": "Signal Private Messenger",
        "developer": "Signal Foundation",
        "icon_url": "https://example.com/signal.png",
        "rating": 4.6,
        "downloads": "100M+",
        "store_url": "https://play.google.com/store/apps/details?id=org.thoughtcrime.securesms",
        "platform": "android",
        "scanned": True,
        "overall_score": 91,
        "status": "completed",
        "app_description": "Simple, powerful privacy",
        "recommendation": "Very Secure",
        "critical_findings_count": 0,
        "high_findings_count": 0,
        "medium_findings_count": 1,
        "low_findings_count": 2,
    },
    {
        "package_id": "com.whatsapp",
        "app_name": "WhatsApp Messenger",
        "developer": "WhatsApp LLC",
        "icon_url": "https://example.com/whatsapp.png",
        "rating": 4.1,
        "downloads": "5B+",
        "store_url": "https://play.google.com/store/apps/details?id=com.whatsapp",
        "platform": "android",
        "scanned": True,
        "overall_score": 62,
        "status": "completed",
        "app_description": "Free messaging and video calling",
        "recommendation": "Use With Caution",
        "critical_findings_count": 0,
        "high_findings_count": 3,
        "medium_findings_count": 4,
        "low_findings_count": 5,
    },
    {
        "package_id": "com.telegram.messenger",
        "app_name": "Telegram",
        "developer": "Telegram FZ-LLC",
        "icon_url": "https://example.com/telegram.png",
        "rating": 4.5,
        "downloads": "1B+",
        "store_url": "https://play.google.com/store/apps/details?id=com.telegram.messenger",
        "platform": "android",
        "scanned": False,
        "overall_score": None,
        "status": None,
        "app_description": "Fast and secure messaging",
        "recommendation": None,
        "critical_findings_count": None,
        "high_findings_count": None,
        "medium_findings_count": None,
        "low_findings_count": None,
    },
]

_IOS_RESULTS = [
    {
        "package_id": "874139669",
        "app_name": "Signal Private Messenger",
        "developer": "Signal Foundation",
        "icon_url": "https://example.com/signal-ios.png",
        "rating": 4.7,
        "downloads": None,
        "store_url": "https://apps.apple.com/us/app/signal-private-messenger/id874139669",
        "platform": "ios",
        "scanned": False,
        "overall_score": None,
        "status": None,
        "app_description": "Simple, powerful privacy",
        "recommendation": None,
        "critical_findings_count": None,
        "high_findings_count": None,
        "medium_findings_count": None,
        "low_findings_count": None,
    },
]


def _make_response(results, limit, offset):
    """Apply limit/offset pagination mirroring api.py behavior."""
    total = len(results)
    page = results[offset:offset + limit] if limit else results[offset:]
    return {
        "results": page,
        "total": total,
        "has_more": (offset + limit) < total if limit else False,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # silence default logging

    def _send(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/search-apps":
            self._send(404, {"detail": "not_found"})
            return

        qs = parse_qs(parsed.query)

        # Extract params (mirroring api.py Query() defaults)
        q_raw = (qs.get("q", [""])[0] or "").strip()
        q = unquote_plus(q_raw).lower()

        platform = (qs.get("platform", ["android"])[0] or "android").strip()

        try:
            limit = int(qs.get("limit", ["20"])[0])
        except (ValueError, IndexError):
            limit = 20

        try:
            offset = int(qs.get("offset", ["0"])[0])
        except (ValueError, IndexError):
            offset = 0

        # Clamp limit to api.py constraints (ge=1, le=50)
        limit = max(1, min(50, limit))
        offset = max(0, offset)

        # Route to fixture based on query + platform
        if not q or q in ("xyzzy_no_match_zzzz",) or ("xyzzy" in q and "no_match" in q):
            self._send(200, _make_response([], limit, offset))
            return

        # Space-containing query that tests URL-encoding: return empty
        if q == "my app":
            self._send(200, _make_response([], limit, offset))
            return

        if platform == "ios":
            if "signal" in q:
                self._send(200, _make_response(_IOS_RESULTS, limit, offset))
            else:
                self._send(200, _make_response([], limit, offset))
            return

        # Default: android
        if "signal" in q:
            self._send(200, _make_response(_ANDROID_RESULTS, limit, offset))
        else:
            self._send(200, _make_response([], limit, offset))

    def do_POST(self):
        self._send(405, {"detail": "method_not_allowed"})


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
