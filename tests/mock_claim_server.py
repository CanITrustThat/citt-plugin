#!/usr/bin/env python3
"""Mock CITT claim server for the citt claim harness (CITT-339).

Serves the three claim endpoints on 127.0.0.1:<ephemeral-port>:

  POST /api/apps/{pkg}/claim         — initiate claim OTP flow
  POST /api/apps/{pkg}/claim/verify  — verify OTP code
  GET  /api/apps/{pkg}/claim-status  — read-only claim status

Auth: every request must carry `Authorization: Bearer citt_...`.
  - Missing / non-`citt_` bearer -> 401
  - CITT_MOCK_BAD_TOKEN value     -> 401

Environment:
  CITT_MOCK_TOKEN       — expected bearer (default: citt_claim_mocktoken456)
  CITT_MOCK_BAD_TOKEN   — a specific token value that should 401 (optional)
  CITT_MOCK_OTP_CODE    — OTP code to accept as correct (default: 1234)
  CITT_MOCK_LOG         — optional path to append JSON request logs

Scripted scenarios via CITT_MOCK_CLAIM_STATE (JSON, keyed by package_id):
  {
    "com.good.app":    {"eligible": true,  "already_claimed": false},
    "com.claimed.app": {"eligible": true,  "already_claimed": true},
    "com.noemail.app": {"eligible": false, "no_email": true},
    "com.notfound.app":{"not_found": true},
  }
  Defaults (for unknown packages): eligible=true, already_claimed=false.

Request/response shapes mirror api.py exactly:
  ClaimInitResponse:   {status, masked_email, expires_in_minutes}
  ClaimVerifyRequest:  {code}  (body field name is "code")
  ClaimVerifyResponse: {status}
  ClaimStatusResponse: {claimed_by_me, has_contact_email, claimable, masked_email}

Prints "http://127.0.0.1:<port>" to stdout on start.
"""
import http.server
import json
import os
import threading
from urllib.parse import urlparse

LOG = os.environ.get("CITT_MOCK_LOG")
MOCK_TOKEN = os.environ.get("CITT_MOCK_TOKEN", "citt_claim_mocktoken456")
BAD_TOKEN = os.environ.get("CITT_MOCK_BAD_TOKEN", "")
OTP_CODE = os.environ.get("CITT_MOCK_OTP_CODE", "1234")

_CLAIM_STATE_RAW = os.environ.get("CITT_MOCK_CLAIM_STATE", "{}")
try:
    CLAIM_STATE = json.loads(_CLAIM_STATE_RAW)
except json.JSONDecodeError:
    CLAIM_STATE = {}

# Track which packages have been claim-initiated and then verified in this run.
_lock = threading.Lock()
_pending_claims = {}   # pkg -> True if initiation was called
_verified_claims = {}  # pkg -> True if OTP verify succeeded


def _log(entry):
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def _pkg_state(pkg):
    """Return the scripted state for a package, with sane defaults."""
    return CLAIM_STATE.get(pkg, {"eligible": True, "already_claimed": False})


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence default stdout logging
        pass

    def _send(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode() if length else ""
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {"_unparsed": raw}

    def _bearer_ok(self):
        auth = self.headers.get("Authorization", "") or ""
        if not auth.startswith("Bearer "):
            return False
        tok = auth[len("Bearer "):].strip()
        if not tok.startswith("citt_"):
            return False
        if BAD_TOKEN and tok == BAD_TOKEN:
            return False
        return True

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        _log({"method": "GET", "path": path, "auth_ok": self._bearer_ok()})

        if not self._bearer_ok():
            self._send(401, {"detail": "Authentication required"})
            return

        # GET /api/apps/{pkg}/claim-status
        if path.startswith("/api/apps/") and path.endswith("/claim-status"):
            pkg = path[len("/api/apps/"):-len("/claim-status")]
            state = _pkg_state(pkg)
            if state.get("not_found"):
                self._send(404, {"detail": "App not found"})
                return
            has_email = not state.get("no_email", False)
            with _lock:
                already_claimed = state.get("already_claimed", False) or _verified_claims.get(pkg, False)
            claimable = has_email and not already_claimed
            masked = "d•••@example.com" if has_email else None
            self._send(200, {
                "claimed_by_me": already_claimed,
                "has_contact_email": has_email,
                "claimable": claimable,
                "masked_email": masked,
            })
            return

        self._send(404, {"detail": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._read_body()
        _log({"method": "POST", "path": path, "auth_ok": self._bearer_ok(), "body": body})

        if not self._bearer_ok():
            self._send(401, {"detail": "Authentication required"})
            return

        # POST /api/apps/{pkg}/claim/verify  (must match before /claim to avoid prefix ambiguity)
        if path.startswith("/api/apps/") and path.endswith("/claim/verify"):
            pkg = path[len("/api/apps/"):-len("/claim/verify")]
            state = _pkg_state(pkg)
            if state.get("not_found"):
                self._send(404, {"detail": "App not found"})
                return

            # Must have had claim initiated first.
            with _lock:
                pending = _pending_claims.get(pkg, False)
            if not pending:
                self._send(400, {"detail": "No pending claim to verify"})
                return

            submitted_code = body.get("code", "")
            if submitted_code != OTP_CODE:
                self._send(400, {"detail": "Invalid code"})
                return

            with _lock:
                _verified_claims[pkg] = True
            self._send(200, {"status": "verified"})
            return

        # POST /api/apps/{pkg}/claim
        if path.startswith("/api/apps/") and path.endswith("/claim"):
            pkg = path[len("/api/apps/"):-len("/claim")]
            state = _pkg_state(pkg)
            if state.get("not_found"):
                self._send(404, {"detail": "App not found"})
                return
            if state.get("no_email"):
                self._send(400, {
                    "detail": (
                        "No developer contact email is on file for this app, "
                        "so it can't be claimed by email yet."
                    )
                })
                return
            if state.get("already_claimed"):
                # Treat as 400: the claim is already verified.
                self._send(400, {"detail": "App is already claimed"})
                return

            with _lock:
                _pending_claims[pkg] = True
            self._send(200, {
                "status": "pending",
                "masked_email": "d•••@example.com",
                "expires_in_minutes": 15,
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
