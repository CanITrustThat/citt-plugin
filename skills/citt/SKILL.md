---
name: citt
description: Use when the user wants to submit apps for trust analysis, run a fast custom-prompt scan to answer a specific question about an app, fetch a custom-scan result, check scan status or results, fetch a detailed report, list their submitted apps, search the public app index, or claim ownership of an app via the CITT CLI.
allowed-tools: Bash, Read
---

# CITT CLI — full capability reference

The `citt` CLI is the plugin entrypoint. It lives at `scripts/citt` (relative to the plugin
root). Every subcommand routes through the dispatcher, which sources `scripts/lib/citt-common.sh`
before sourcing the relevant `scripts/lib/cmd-<name>.sh` and calling `citt_cmd_<name>`.

## Security note

The CLI owns the API token. The token is stored in the system keyring (macOS Keychain /
libsecret) or a 0600 file. It is never printed, never placed on shell argv, and never
written to stdout. Claude calls `citt <subcommand>` and reads stdout only. Never ask the
user for the token, never `cat` or `Read` the token file, and never pass a token as a
script argument.

---

## Connect an account first

Public commands (`search`, `status`, `results`) work with no account. Everything else
(`submit`, `scan`, `result`, `report`, `mine`, `claim`) needs a Developer or Researcher
account. Before running an account command, confirm the user is connected — run `citt whoami`.
If it exits non-zero (no token or a 401), the user is not connected: run `citt auth`, show them
the verification URL and code it prints, and wait for them to authorize in the browser before
continuing. To sign out, run `citt logout`.

The same actions are also slash commands in Claude Code, one per subcommand: `/citt:auth`,
`/citt:logout`, `/citt:whoami`, `/citt:scan`, `/citt:submit`, `/citt:rescan`, `/citt:result`,
`/citt:status`, `/citt:results`, `/citt:search`, `/citt:report`, `/citt:mine`, `/citt:claim`.
They are thin wrappers over the `citt` subcommands documented below — the full behavior of each
lives here.

---

## How to use this CLI (read this first)

This document is the complete, authoritative reference for every capability. To act, pick the
right subcommand below and run it — one command, then relay its output.

- Do NOT read the scripts in `scripts/` to figure out what is possible. Everything is here.
- Do NOT run a subcommand with `--help` to discover behavior, and do NOT probe with throwaway
  calls. The argument shapes are documented per subcommand below.
- Each subcommand prints machine-readable JSON (or a summary) to stdout and a human line to
  stderr, and uses a distinct exit code / HTTP status per outcome — act on those, documented
  under each command.

### Capability map — pick by intent

| The user wants… | Use | Needs auth |
|-----------------|-----|-----------|
| A specific question answered about an app | `citt scan "<question>" <app>` then `citt result <id>` | yes |
| The full scorecard + letter grade for an app not yet scanned | `citt submit <app>` | yes |
| FRESH results for an app that already has a recent scan | `citt rescan <app>` | yes |
| The public scorecard of any already-scanned app | `citt results <pkg>` | no |
| A quick status/score check | `citt status <pkg>` | no |
| Watch a running rescan's live progress | `citt status <pkg> --scan-id <scan_id>` | no |
| The full detailed report for an app they own (or any app as researcher) | `citt report <pkg>` | yes |
| Find an app's package id | `citt search "<name>"` | no |
| List their own submitted apps | `citt mine` | yes |
| Prove ownership of an app | `citt claim <pkg>` | yes |

---

## Choosing how to analyze an app

Three ways to analyze, by intent:

- **`citt scan "<prompt>" <app>`** — a fast custom-prompt scan. You write one focused
  question and get a targeted answer. It skips the full 7-stage pipeline, so it returns in
  minutes (once the app is decompiled). This is the **preferred** path whenever the user has
  a specific question: "does it leak location?", "which analytics and ad SDKs does it embed?",
  "is there a hardcoded API key?", "does it talk to any servers in country X?". Poll for the
  answer with `citt result <scan_id>`.
- **`citt submit <app>`** — a full trust analysis that produces the complete public scorecard,
  scores, and letter grade. Slower (the full pipeline). Use it only when the user actually
  wants the whole scorecard/grade, not a single answer. Submit REUSES any scan completed in
  the last 90 days instead of re-running it.
- **`citt rescan <app>`** — force a brand-new full scan of an app that already exists. Because
  `submit` reuses recent scans, rescan is the ONLY way to get fresh results for an app that
  was already scanned. It always creates a new scan. Who may rescan is enforced server-side
  (admin: any app; developer: apps they own; Research/custom plan: any app, metered), so just
  run it and relay the result.

Rule of thumb: a question → `citt scan`; "the scorecard/grade/full analysis" of a new app →
`citt submit`; "re-run it", "refresh", "it's outdated", "scan again" → `citt rescan`. A
first-ever scan of an app still has to download and decompile it before either can run (iOS
decompilation can take a few hours); custom is fast primarily on apps already in the corpus.

---

## Subcommand reference

### `citt auth`

Purpose: Authenticate with CITT using the RFC-8628 device-flow protocol.

```bash
citt auth
```

Flow:
1. The command prints a verification URL and a user code to stderr.
2. The user opens the URL in a browser, logs in with their CITT account, and clicks
   Authorize. An existing Developer or Research account is required; the authorization
   endpoint enforces this gate.
3. The script polls until the user completes the step, then stores the token in the keyring
   (macOS Keychain or libsecret) or, when no keyring is available, in a 0600 file at
   `$HOME/.config/citt/device_token` (override the directory with `CITT_STATE_DIR`). This
   path is fixed and does not depend on how citt is invoked.

On success the command exits 0 with no stdout. On timeout it prints a retry hint to stderr.

How Claude should use this: run `citt auth` first and wait for the user to complete the
browser step. Print the verification URL to the user so they know what to open. Do not
proceed with subcommands that require auth until `citt auth` exits 0.

---

### `citt whoami`

Purpose: Verify the stored token and show the authenticated user's identity and plan.

```bash
citt whoami
```

HTTP: `GET /api/me` (authenticated).

Response shape (JSON on stdout):

```json
{
  "id": "<uuid>",
  "email": "user@example.com",
  "user_type": "developer",
  "display_name": "Alice",
  "created_at": "2026-01-01T00:00:00Z",
  "last_login_at": "2026-08-01T10:00:00Z",
  "is_active": true,
  "analysis_track": "default",
  "subscription": {
    "plan_id": "developer",
    "status": "active",
    "billing_interval": "monthly",
    "current_period_end": "2026-09-01T00:00:00Z",
    "scans_used": 12,
    "scans_limit": 100,
    "submissions_used": 45,
    "submissions_limit": 250,
    "rescans_used": 3,
    "rescans_limit": 10
  },
  "team": null
}
```

Exits non-zero with a re-auth hint on 401 or if no token is stored.

How Claude should use this: run before auth-gated subcommands if you want to confirm the
token is valid and show the user which account is active. Check `subscription.plan_id` to
confirm the user has Developer or Research access before running `citt submit`.

---

### `citt submit`

Purpose: Submit one or more apps for trust analysis. Accepts bare package IDs, store URLs,
or a CSV file. Deduplicates against scans completed within the last 90 days.

```bash
citt submit <package_id|store_url> [<package_id|store_url> ...]
citt submit <path/to/apps.csv>
```

Examples:

```bash
citt submit com.example.app
citt submit com.a com.b
citt submit https://play.google.com/store/apps/details?id=com.example.app
citt submit apps.csv
```

Requires authentication (Developer or Research plan). If the user is on the wrong plan the
command prints an upgrade link to stderr.

CSV format — one app per row, at least one of these columns:

| Column | Format |
|--------|--------|
| `package_id` | `com.example.app` (preferred) |
| `store_url` | Google Play or App Store URL |
| `platform` | `android` (default) or `ios` |

Implementation: the dispatcher detects whether the single argument is a readable file and
delegates directly to `scripts/citt-submit.sh`. For bare package IDs or store URLs it
builds a minimal temp CSV (0600) and delegates to the same script.

The script handles client-side deduplication (skips apps with completed scans younger than
90 days), per-app budget enforcement, and partial summary on timeout.

Output on stdout: a human-readable ranked summary — scores, trust bands, and deep links to
`canitrustthat.com/apps/{package_id}` for each submitted app. The summary is emitted even
when some submissions time out (partial summary).

How Claude should use this: relay the ranked summary to the user verbatim. Note which apps
were skipped as deduplicates. For a deeper look at any app, follow with `citt results
<package_id>` or `citt report <package_id>`. If the user wanted FRESH results for an app that
was skipped as a recent duplicate, use `citt rescan` instead.

---

### `citt rescan`

Purpose: Force a brand-new full scan of an app that already exists in CITT. Because `submit`
reuses any scan completed in the last 90 days, rescan is the ONLY way to get fresh results for
an already-scanned app. It always creates a new scan and runs the full pipeline.

```bash
citt rescan <package_id> [--platform android|ios] [--private]
citt rescan --check <package_id> [--platform android|ios]
```

Examples:

```bash
citt rescan com.example.app                 # refresh the public scorecard
citt rescan com.example.app --platform ios  # iOS app
citt rescan com.example.app --private       # private scan instead of a public refresh
citt rescan --check com.example.app         # read-only: am I allowed + quota left
```

HTTP: `POST /api/rescan` (authenticated). `--check` uses `GET
/api/apps/{package_id}/rescan-eligibility` (read-only, never starts a scan).

Who may rescan is enforced server-side — do NOT pre-judge or refuse on the user's behalf; run
the command and relay what comes back:

- Admin — any app, unlimited.
- Developer — apps they own (or can view), against a monthly rescan quota (free 1, developer 4,
  paid plans unlimited).
- Research / custom plan — any app, including ones they don't own, metered against their
  scan-others quota.

Flags: `--platform ios` for iOS apps (default `android`); `--private` creates a private scan
rather than refreshing the public scorecard (default is a public refresh, `is_private=false`);
`--check` only probes eligibility.

Response on success (stdout JSON):

```json
{
  "scan_id": "<uuid>",
  "package_id": "com.example.app",
  "scan_number": 3,
  "status": "queued",
  "status_url": "/api/scan-status/<uuid>",
  "submitted_at": "2026-08-07T12:00:00Z"
}
```

`--check` returns `{can_rescan, reason, is_owner, plan_id, rescans_used, rescans_limit,
upgrade_target}`; `reason` is one of `ok`, `ok_researcher`, `not_authenticated`, `not_owner`,
`quota_exceeded`, `app_not_found`. A `--check` that reports `can_rescan:false` still exits 0
(it is a probe, not a failure).

Outcomes and exit behavior:

- 200 — new scan queued. Tell the user it is running and poll `citt status <package_id>
  --scan-id <scan_id>` (use the `scan_id` from this response) for progress. This is a full scan,
  so it takes a while (a new binary can be hours; a re-run of an in-corpus app is faster).
  IMPORTANT: poll by `--scan-id`. Plain `citt status <package_id>` returns the last COMPLETED
  scan while a rescan runs, so it would show the OLD score, not the in-flight one.
- 401 — token missing/expired: run `citt auth`.
- 403 — the user's plan cannot rescan this app. Relay the message verbatim (it explains the
  developer-vs-research distinction); do not retry.
- 429 — monthly rescan (or scan-others) quota reached. Relay the upgrade hint.
- 400 — bad request (e.g. invalid package id or platform).

How Claude should use this: when the user says "rescan", "re-run", "refresh", "scan it again",
or "these results are old", run `citt rescan <package_id>` and relay the queued confirmation,
then offer to poll `citt status <package_id> --scan-id <scan_id>` (the id the rescan printed).
Do not fall back to `citt submit` for a re-run — submit would just return the stale reused scan.

---

### `citt scan`

Purpose: Run a fast custom-prompt scan. You write a focused question and the backend runs a
targeted analysis that skips the full 7-stage pipeline. Results come back in minutes once the
app is decompiled, versus the much longer full scan. This is the preferred command for a
specific question about an app.

```bash
citt scan "<prompt>" <package_id|store_url> [--platform android|ios]
```

Examples:

```bash
citt scan "Does this app send precise location to third parties? Cite the code paths." com.example.app
citt scan "List every analytics and advertising SDK and what each one collects." com.example.app --platform android
citt scan "Is any API key or secret hardcoded in the binary?" https://play.google.com/store/apps/details?id=com.example.app
```

HTTP: `POST /api/submit` with body `{"package_id": "...", "platform": "...", "scan_type":
"custom", "prompt": "...", "is_private": true}` (authenticated). The `platform` key is omitted
when `--platform` is not given. The prompt travels inside a `0600` request-body file — never on
argv, never in stdout.

Constraints:
- The prompt is required and must be 5000 characters or fewer (rejected client-side otherwise).
- The app must be an unambiguous package ID or store URL. Name resolution is not done here — if
  the user gave only an app name, run `citt search` first to resolve the `package_id`.

Output: the new `scan_id` on stdout, plus a hint on stderr: `→ citt result <scan_id>`. The scan
runs asynchronously; fetch the answer with `citt result`.

Tier scoping:

| Case | Requirement |
|------|-------------|
| Custom prompt on an app you own (uploaded or claimed), or a brand-new target | Developer or Research |
| Custom prompt on an existing app you do not own | Research plan (cross-app custom) |

Error responses:

| HTTP | Meaning | Claude action |
|------|---------|---------------|
| 400 | Prompt empty or over 5000 chars | Shorten or supply the prompt and retry |
| 401 | Token expired or absent | Run `citt auth`, then retry |
| 403 | Cross-app custom needs the Research plan | Tell the user; offer a full `submit`, or a Research upgrade for cross-app custom prompts |

Custom scans are always private. There is no public scorecard or letter grade for them; the
answer is the focused JSON returned by `citt result`.

How Claude should use this: prefer this over `citt submit` when the user asks a specific
question. Write a precise, self-contained prompt that asks for concrete evidence and code
citations. Run `citt scan`, capture the `scan_id`, then poll `citt result` until it is ready.
Reserve `citt submit` for when the user wants the complete scorecard and grade.

---

### `citt result`

Purpose: Fetch the result of a custom-prompt scan created by `citt scan`.

```bash
citt result <scan_id>
```

HTTP: `GET /api/scan/{scan_id}/result` (authenticated).

Output on stdout when the scan is complete (JSON):

```json
{
  "scan_id": "<uuid>",
  "package_id": "com.example.app",
  "prompt": "Does this app send precise location to third parties?",
  "status": "completed",
  "result": { "answer": "..." }
}
```

While the scan is still running the endpoint returns 404, and the command prints a friendly
`scan <scan_id> is not ready yet (still processing). Try again shortly.` to stderr and exits
non-zero. This is expected, not a failure — poll again after a short wait.

Error responses:

| HTTP | Meaning | Claude action |
|------|---------|---------------|
| 404 | Not ready yet (still processing) | Wait and retry; custom scans typically finish in a few minutes on an already-decompiled app |
| 401 | Token expired or absent | Run `citt auth`, then retry |
| 403 | Not authorized to view this scan | The scan belongs to another account |

How Claude should use this: after `citt scan` returns a `scan_id`, poll `citt result` on a
gentle cadence (for example every 30 to 60 seconds) until `status` is `completed`, then relay
the answer to the user. Do not hammer the endpoint; a custom scan still takes minutes, and a
first-ever scan of an app must download and decompile it first.

---

### `citt status`

Purpose: Fetch the concise scan status for a single app. Works anonymously for public
scorecards; sends your token when you have one so you can also see private and in-flight scans
you own.

```bash
citt status <package_id>                       # latest scan (see the rescan caveat below)
citt status <package_id> --scan-id <id>        # poll a SPECIFIC scan's live status
citt status <package_id> --scan-number <n>     # poll scan #n for the package
```

HTTP: `GET /api/status/{package_id}[?scan_id=<id>|?scan_number=<n>]`. The token is sent when
present (needed for private/in-flight scans); otherwise the request is anonymous. On a 401 from
a stale token, the CLI retries once anonymously so public scorecards still resolve.

IMPORTANT — polling a rescan: plain `citt status <pkg>` returns the last COMPLETED scan. While
a rescan is running the server keeps showing the old completed result so the scorecard never
goes blank, and it sets `current_scan_status` to `queued`/`analyzing` to signal a scan is in
flight. To watch the NEW scan's progress you MUST poll it by id: `citt status <pkg> --scan-id
<scan_id>` (the id `citt rescan` printed). With `--scan-id`/`--scan-number` the top-level
`status` IS that scan's live status.

Response shape (compact JSON on stdout):

```json
{
  "id": "<scan_uuid>",
  "package_id": "com.example.app",
  "status": "completed",
  "current_scan_status": null,
  "overall_score": 82,
  "letter_grade": "B",
  "completed_at": "2026-08-01T10:00:00Z",
  "platform": "android",
  "scan_type": "full",
  "progress_message": null,
  "total_findings_count": 14,
  "critical_findings_count": 0,
  "high_findings_count": 2,
  "medium_findings_count": 7,
  "low_findings_count": 4,
  "info_findings_count": 1,
  "recommendation": "trustworthy",
  "current_stage": null,
  "queue_position": null
}
```

`id` is the scan this row describes. `current_scan_status` is non-null on a plain (no-selector)
call when a rescan is running in the background: it means "a fresh scan is `queued`/`analyzing`,
poll it with `--scan-id`".

The `letter_grade` field is computed client-side by the CLI (it is not returned by the API):

| Score | Grade |
|-------|-------|
| 90-100 | A |
| 80-89 | B |
| 70-79 | C |
| 55-69 | D |
| 0-54 | F |

When the scan is not yet complete, `overall_score` and severity counts are `null`;
`progress_message` and `current_stage` describe where the scan is. `queue_position` is set
while the job is waiting.

On 404, emits `{"error":"not_found","package_id":"..."}` and exits non-zero.

How Claude should use this: use for a quick "is this app done?" check before investing a
heavier `citt results` or `citt report` call. If `status` is not `completed`, tell the user
the scan is still in progress and show `progress_message`. Right after a `citt rescan`, poll
`citt status <pkg> --scan-id <scan_id>` (not the bare form) so you report the NEW scan's
progress and its fresh score when it finishes — comparing it against the old score if useful.

---

### `citt results`

Purpose: Fetch the full public scorecard data for an app — verdict, summaries, top issues,
scores, and scan history. Public — no authentication needed.

```bash
citt results <package_id>
```

HTTP (two calls, both unauthenticated):
- `GET /api/status/{package_id}` — primary scorecard data
- `GET /api/apps/{package_id}/scans` — scan history (non-fatal; empty list on failure)

Response shape (compact JSON on stdout). All fields come directly from the API:

```json
{
  "package_id": "com.example.app",
  "app_name": "Example App",
  "developer_name": "Example Inc",
  "status": "completed",
  "platform": "android",
  "overall_score": 82,
  "letter_grade": "B",
  "security_score": 85,
  "privacy_score": 79,
  "completed_at": "2026-08-01T10:00:00Z",
  "submitted_at": "2026-07-30T08:00:00Z",
  "progress_message": null,
  "current_stage": null,
  "recommendation": "trustworthy",
  "what_it_means_for_you": "Suitable for everyday use...",
  "quick_verdict": {
    "best_for": "General productivity users",
    "avoid_if": "You require a fully offline workflow"
  },
  "top_security_issues": ["Insecure local storage of session tokens"],
  "top_privacy_issues": ["Analytics SDK sends device identifiers to third parties"],
  "findings_by_category": [
    {"category": "data_storage", "critical": 0, "high": 1, "medium": 2, "low": 1}
  ],
  "total_findings_count": 14,
  "primary_concern": "data_storage",
  "third_party_services": ["Firebase Analytics", "Crashlytics"],
  "strengths": ["Certificate pinning enabled", "No location tracking"],
  "context_tags": ["finance", "productivity"],
  "stamps": [],
  "red_flags": [],
  "stamps_status": null,
  "trust_verdict": null,
  "store_url": "https://play.google.com/store/apps/details?id=com.example.app",
  "public_report_url": "/reports/com.example.app.md",
  "version": "4.2.1",
  "analysis_date": "2026-08-01",
  "disclosure_status": null,
  "scans": [
    {
      "scan_id": "<uuid>",
      "scan_number": 3,
      "status": "completed",
      "scan_type": "full",
      "overall_score": 82,
      "version": "4.2.1",
      "analysis_date": "2026-08-01",
      "submitted_at": "2026-07-30T08:00:00Z",
      "completed_at": "2026-08-01T10:00:00Z",
      "is_private": false
    }
  ]
}
```

Access control note: raw per-severity counts and detailed `findings[]` are owner-only for
completed scans. Public callers receive `total_findings_count` and `findings_by_category`.
This command uses only public calls and surfaces exactly what the API returns to an
anonymous reader.

On 404, emits `{"error":"not_found","package_id":"..."}` and exits non-zero.

How Claude should use this: this is the primary command for understanding an app's trust
posture without needing to own it. Extract `quick_verdict`, `top_security_issues`,
`top_privacy_issues`, and `findings_by_category` to summarize risks. Use `scans` to show
history. Point the user to `canitrustthat.com/apps/{package_id}` for the rendered
scorecard.

---

### `citt report`

Purpose: Fetch the full detailed report (markdown) for an app the user owns, or for any
app when authenticated as a researcher. Authentication required.

```bash
citt report <package_id>
citt report <package_id> --scan <scan_id>
citt report <package_id> --platform android|ios
```

HTTP: `GET /reports/{package_id}.md?report_type=detailed[&scan_id=<id>][&platform=<p>]`
(authenticated).

Without `--scan`, the endpoint auto-resolves the latest completed full scan for that
package. Custom scans never shadow full scans at this endpoint. Passing a bare UUID-like
string as the main argument is rejected with a clear hint: the endpoint is package-keyed,
and a scan ID alone cannot identify a package without an additional lookup.

Output: the full detailed report as markdown on stdout. A human summary (package name,
scan ID if given, and a note on what was fetched) goes to stderr.

Fallback for custom scans: if `--scan <id>` points to a custom scan (which has no
scorecard/detailed report), the command falls back to `GET /api/scan/{scan_id}/result` and
emits the custom-scan JSON result on stdout.

Error responses:

| HTTP | Meaning | Claude action |
|------|---------|---------------|
| 401 | Token expired or absent | Run `citt auth`, then retry |
| 403 | Not the owner, or report locked | Inform the user; they must own the app or have researcher access |
| 404 | No completed full scan exists yet | Inform the user the scan is not ready |
| 410 | Report type no longer available | Inform the user |

How Claude should use this: call after `citt mine` to get the full report for each app the
user submitted. Parse the markdown for findings, scores, and recommendations. Do not dump
the full markdown back at the user unless asked — summarize critical and high findings, then
offer the full text on request.

---

### `citt mine`

Purpose: List the apps the authenticated user has submitted, with their latest scan summary
and a `scan_id` pointer usable by `citt report`.

```bash
citt mine
```

HTTP: `GET /api/apps?my_scans=true&scan_type=full&limit=100&offset=<n>` (authenticated,
paginated until all pages are retrieved).

Output (JSON array on stdout, newest-scan-first):

```json
[
  {
    "package_id": "com.example.app",
    "app_name": "Example App",
    "scan_id": "<uuid>",
    "status": "completed",
    "overall_score": 82,
    "security_score": 85,
    "privacy_score": 79,
    "recommendation": "trustworthy",
    "completed_at": "2026-08-01T10:00:00Z",
    "platform": "android"
  }
]
```

`scan_id` maps to the `id` field returned by the list endpoint (the latest scan for that
app). Pass it to `citt report <package_id> --scan <scan_id>` to pin to that exact scan.

Known limitation (documented honestly): this command lists apps where the user submitted at
least one full scan. Apps that the user owns by email-domain match or by a verified claim
(`citt claim`) where a different account originally submitted the scan are not listed. A
dedicated `GET /api/me/apps` backend endpoint does not yet exist. The command prints a note
about this to stderr on every run.

How Claude should use this: use as the entry point for the "analyze my own apps" workflow.
Iterate over the returned array, call `citt report <package_id>` for each completed app,
then summarize and compare results across apps.

---

### `citt search`

Purpose: Search the public app index by name or package ID. No authentication required.

```bash
citt search <query> [--platform android|ios] [--limit N]
```

Flags:

| Flag | Values | Default |
|------|--------|---------|
| `--platform` | `android`, `ios` | `android` |
| `--limit` | 1-50 | 20 |

HTTP: `GET /api/search-apps?q=<encoded_query>&platform=<p>&limit=<n>&offset=0` (public).

Query constraints from `api.py`: `q` is required, min length 1, max length 200. `limit` is
clamped to 1-50 by the API; the CLI validates and rejects out-of-range values before
making the request. Pagination beyond `--limit` is not supported; use a more specific query
or increase `--limit`. When the API returns `has_more: true`, the CLI prints a note on
stderr.

The API returns `{"results":[...], "total": N, "has_more": bool}`. The CLI emits only the
`results` array on stdout.

Each result item:

```json
{
  "package_id": "com.example.app",
  "app_name": "Example App",
  "developer": "Example Inc",
  "icon_url": "https://...",
  "rating": 4.3,
  "downloads": "10,000,000+",
  "store_url": "https://play.google.com/...",
  "platform": "android",
  "scanned": true,
  "overall_score": 82,
  "status": "completed",
  "app_description": "An example productivity app.",
  "recommendation": "trustworthy",
  "critical_findings_count": 0,
  "high_findings_count": 2,
  "medium_findings_count": 7,
  "low_findings_count": 4
}
```

How Claude should use this: use to find a `package_id` when the user provides only an app
name. Confirm the correct match with the user (there may be multiple results), then call
`citt results <package_id>` for the full scorecard data.

---

### `citt claim`

Purpose: Claim ownership of an app via OTP sent to the app's store-listed contact email.
Authentication required.

Warning: running `citt claim <package_id>` sends an email to the store-listed contact
address for that app. Tell the user this before proceeding.

```bash
citt claim <package_id>           # Initiate claim: sends OTP email, prompts for code
citt claim --status <package_id>  # Read-only: show current claim status
```

Flow for `citt claim <package_id>`:

1. `POST /api/apps/{package_id}/claim` — triggers an OTP email to the store contact.
   Response (`ClaimInitResponse`):
   ```json
   {"status": "pending", "masked_email": "d***@example.com", "expires_in_minutes": 15}
   ```
2. The command prints a notice to stderr that the email has been sent (with the masked
   address and expiry). Relay this to the user before asking them to enter the code.
3. The user enters the OTP code at the stdin prompt (the prompt appears on stderr). The
   code is read into a 0600 temp file and never appears on argv or stdout.
4. `POST /api/apps/{package_id}/claim/verify` with body `{"code": "<otp>"}`. The request
   body field name is `code` (from `ClaimVerifyRequest` in `api.py`).
   On success, emits `{"status": "verified"}` on stdout.

Flow for `citt claim --status <package_id>`:

1. `GET /api/apps/{package_id}/claim-status`
   Response (`ClaimStatusResponse`):
   ```json
   {
     "claimed_by_me": false,
     "has_contact_email": true,
     "claimable": true,
     "masked_email": "d***@example.com"
   }
   ```

Error handling for the verify step:

| Condition | Error text in stderr | Action |
|-----------|----------------------|--------|
| Wrong code | "invalid verification code" | Ask user to check email and retry |
| Expired | "verification code has expired" | Run `citt claim <pkg>` again to restart |
| Too many attempts | "too many failed attempts" | Run `citt claim <pkg>` for a new challenge |
| No pending claim | "no pending claim found" | Run `citt claim <pkg>` to initiate |

How Claude should use this: always warn the user that an email will be sent before running
`citt claim <package_id>`. After the OTP notice appears on stderr, relay the masked address
and expiry to the user and ask them to enter the code from the email. Do not store or
repeat the OTP code.

---

### `citt logout`

Purpose: Remove the stored authentication token from the keyring and/or 0600 file.

```bash
citt logout
```

No HTTP call. Exits 0 regardless of whether a token was found.

How Claude should use this: run when the user wants to sign out or before switching
accounts. After logout, any subsequent auth-gated subcommand will fail with a re-auth hint
until `citt auth` is run again.

---

## Worked flows

### Flow 1: analyze my own apps

Use this when the user asks to review the trust posture of apps they have submitted.

```bash
# 1. Confirm authentication.
citt whoami

# 2. List all submitted apps with their latest scores.
citt mine

# 3. For each app with status=completed in the mine output, fetch the full report.
citt report com.example.app

# 4. Summarize findings across apps.
```

Guidance:
- Pull `scan_id` from the `citt mine` output and pass it to `citt report <pkg> --scan
  <scan_id>` to pin to the exact scan shown in the list.
- Summarize critical and high findings per app, then compare overall scores.
- If an app is still scanning (`status != completed`), note it and offer to check back.
- Remind the user that `citt mine` shows submission-based ownership only; apps owned by
  email-domain match but not personally submitted will not appear.

### Flow 2: compare two public apps

Use this when the user wants to compare trust scores or risk profiles across apps they do
not own.

```bash
# 1. Find each app's package_id if unknown.
citt search "Signal" --platform android
citt search "Telegram" --platform android

# 2. Fetch the public scorecard for each.
citt results com.example.signal
citt results org.example.telegram

# 3. Compare and contrast.
```

Guidance:
- Use `quick_verdict.best_for` and `quick_verdict.avoid_if` as the top-line comparison.
- Compare `overall_score`, `security_score`, and `privacy_score` numerically.
- Contrast `top_security_issues` and `top_privacy_issues` to highlight where each app
  differs in risk profile.
- When scores differ significantly, inspect `findings_by_category` to explain which domain
  drives the gap.
- Point the user to `canitrustthat.com/apps/{package_id}` for each app for the full
  rendered scorecard.

### Flow 3: answer one specific question fast (custom scan)

Use this when the user asks a pointed question about a single app rather than for a full
scorecard. It is the fastest path.

```bash
# 1. Resolve the package_id if the user gave only a name.
citt search "Example App" --platform android

# 2. Write a focused prompt and launch a custom scan.
citt scan "Does this app send precise location to any third-party domain? Cite code." com.example.app

# 3. Poll for the answer using the scan_id printed by step 2.
citt result <scan_id>
```

Guidance:
- Write the prompt yourself, tightly scoped to exactly what the user asked, and ask for
  concrete evidence and code citations.
- After `citt scan` prints the `scan_id`, poll `citt result <scan_id>` every 30 to 60
  seconds. A 404 means "still processing" — keep waiting, do not treat it as an error.
- If `citt scan` returns 403, the app is one the user does not own and cross-app custom
  prompts need the Research plan. Offer either a full `citt submit` (public scorecard) or a
  Research upgrade.
- Relay the `result` JSON's answer to the user. There is no public page for a custom scan.

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | API error, auth error, or not found (see stderr) |
| 2 | Usage error (bad arguments) |
| 10 | Subcommand not yet implemented in this build |

On 401 from any authenticated subcommand, the CLI prints `re-authenticate — run: citt auth`
to stderr and exits 1. Run `citt auth` and retry.
