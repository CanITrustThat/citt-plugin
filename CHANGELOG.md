# Changelog

## 2.31.0

- `citt atlas-app PACKAGE`, `citt atlas-sdk NAME`, `citt atlas-cluster ID` and `citt atlas-search QUERY` read the research atlas corpus through the backend (`/api/research/v1/atlas/*`). `citt atlas-app` prints an app's detected SDKs grouped by category and its owner/key config-ID clusters (raw values, hidden-network clusters first); `citt atlas-sdk` prints an SDK's build and app counts, and `--apps` the apps carrying it, filterable by `--category` and `--installs-min`; `citt atlas-cluster` prints one cluster's counts, raw value, hidden-network flag and member apps, and `--hidden-network` the hidden-network family; `citt atlas-search` searches the app corpus by package, title or developer. Every list pages with `--limit`, `--cursor` and `--all`, and `--json` prints the backend envelope. The commands reuse the stored token and inherit the backend's atlas-enabled gate: an account without atlas access gets `atlas is not enabled for this account; contact support to request access` (exit 3), and an unavailable backend prints `atlas data unavailable, try again shortly` rather than a dead end. No new credential is stored (NP-1481).

## 2.30.0

- `citt capture-watch` and `citt capture-start --wait` name a phone-disconnected gap when a run ends `done_with_gaps`: a session whose phone was disconnected keeps its own state, so a run can end with gaps and no failed session. The stderr line then reads `run N ended done_with_gaps: phone disconnected in session S for N s` (one clause per session), or `1 of 3 sessions failed; phone disconnected in session S for N s` when a session also failed (exit 13 in both cases) (NP-1414).

## 2.29.0

- `citt inbox` and `citt mailbox show` print a field only when it has the type the server sends: a code, sender, subject, source, time, cursor or flag that arrives as a number, object or list prints as null or not at all, in tables and in `--json`. With `--json`, an `error` code holding a digit reads `http_error` (NP-1368).

## 2.28.0

- `citt inbox --json` and `citt mailbox show --json` (also `citt inbox ADDRESS|CRED_ID|PHONE_ID --json`) print only the fields they name: an address row's linked numbers (`numbers[]`) as their last 4 digits, the numbers of an address (`phones[]`) as their last 4 digits with the length of the newest code, the sessions of an address (`sessions[]`), and no field the server adds later, also inside a nested object (the app is its id, label and package id). In `citt inbox` and `citt mailbox`, an error prints no `unknown_apps` value and, with `--json`, an `error` code that is not a plain code reads `http_error`. No phone number, code, password, text or email body reaches stdout (NP-1358).

## 2.27.0

- `citt capture-start --location LAT,LNG --location-always` books the "Allow all the time" location permission (background location) for every session of the run: the request body contains `location_permission: "all_the_time"`, and the app is granted location while in use and in the background at the session start. Android phones only. `--location-always` without `--location` exits 2 before any request. The start line and the `citt capture-watch` run line end `, location permission all the time` (NP-1354).

## 2.26.0

- `citt inbox` lists the lab addresses and phone numbers of the account, newest first: kind, state, the app and persona each signed up, the newest message or text time and whether it has a code. `citt inbox <address|phone id>` prints one address or number with its messages or texts, newest first (NP-924).
- `citt mailbox show` and `citt inbox` print no message bodies, snippets, links or codes on stdout. The table and `--json` give metadata only: received time, masked sender and subject, `has_code` with the code's length, `has_link` and the length of the message. Each run of 4 or more digits in a sender or subject prints as `[code, N digits]`, or `[number, N digits]` over 8 digits (NP-924).
- `--reveal` on `citt mailbox show` and `citt inbox` writes the codes, links and snippets to a mode-600 file, or to the clipboard, and prints only where they went (NP-924).
- A phone number prints as `•••• NNNN`, its last 4 digits, for every token (NP-924).

## 2.25.0

- `citt capture-options` and `citt capture-start` take an iOS bundle id of one segment, with a hyphen or with a segment that starts with a digit, such as `pinterest`, `LiveScore`, `com.mwm.sampler-app` and `com.gramgames.1010`; the id starts with a letter or digit, holds letters, digits, `_`, `-` and `.` with no empty segment, and is at most 240 characters. An App Store number exits 2 with `<number> is an App Store number, not a bundle id; give the app's bundle id with --platform ios (citt apps lists it)` and no request (NP-1341).
- `citt submit` of an iOS app by App Store number or App Store link lists the app under its bundle id when the App Store lookup finds it; the number is kept in the row as `app_store_id` (NP-1341, a change of the service).
- `citt submit` lists, after the not-found lines, each iOS app kept under its App Store number because its bundle id was not found: `Queued under the App Store number, bundle id not found (N):`, then one line per number with `the App Store lists no app with this number` or `the App Store could not be asked; submit the app again later to list it under its bundle id` (NP-1341).

## 2.24.0

- `citt capture-options` marks an exit country that takes no run with `(unavailable)` on its region line and prints `Unavailable: <reason>`: the lab's connect attempts of the last 7 days in that country passed none and every recorded failure was the country check (the exit is placed in another country, such as JO servers that exit in FR); the reason names the failure, the count, when the country is offered again and the time of the reading. A country whose every server failed within the last 900 s prints `Exit country <CC> may fail its first session: <reason>`, and a country whose attempts measured under the 5 MB/s floor prints `Exit country <CC> is slow: <reason>` with the measured speed and the attempt counts (it stays available: a slow server is still used inside a run). `citt capture-start --country <CC>` of an unavailable country exits 4 with the reason and sends no start request; a 422 `exit_country_unavailable` from the start exits 4 with its message; a start answer with `exit_warning` prints `Warning: <text>` (NP-1339).

## 2.23.0

- `citt captures` and the `citt capture-watch` run line state the cause of a failed app install before the reason: `failed (CITT side): ...` for a failure on the CITT side (the install helper, the lab's network route or store accounts, the stored build), `failed (device side): ...` for the device's storage or a device that stopped answering, `failed (app side): ...` for a paid app, an app the store does not offer or an app with no build for the device. A failure with no stated cause shows no word. With `--json`, each run has `failure_cause` (`service`, `device`, `app` or null). A run whose install failed on the CITT side is queued once more on the phone it was booked on; one that failed on the device side is queued once more on a free phone of the same model, and fails when there is none (NP-1336).

## 2.21.0

- `citt capture-options` prints `<phone>: This phone is offline for a fault on our side; runs booked on it wait until it is back.` for a phone that is offline for a fault on the lab side; runs queued on it start once it is back (NP-1335).
- The `Active runs` cell of `citt capture-options` states the running and the queued runs, such as `3 (1 running, 2 queued)`; `citt capture-start --phone` on a busy phone states `is busy (1 running, 2 queued)`, and the no-free-phone line gives the same counts. With a service that does not state the two counts, the cell is the number as before (NP-1335).
- `citt capture-start --phone` on a phone offline for a fault on the lab side prints the sentence above once; the run is queued on it (NP-1335).

## 2.20.0

- `citt search --hosts-file FILE` searches a list of domains, one per line (`#` comments and blank lines allowed; a leading `*.`, a trailing `.` and upper case folded; repeats once), as `domain:(a.com OR b.com ...)`, which includes subdomains, joined with any `--query` by AND; up to 500 domains. A search of rows reads at most 500 hosts: over that it exits 2 with the number of hosts, without repeating the list, and with `try:` commands for `--export` and `--counts host,app`, which have no limit of hosts. A line that is not a domain exits 2 with `line N of FILE: "TEXT" is not a domain; ...` and no request; printed commands name `--hosts-file FILE`, not the list (TASK-642).
- A `--query` is at most 8,000 characters (1,000 before). A search or count whose request would be longer than 7,000 bytes is sent in the request body, past the address limits of the network in front of the service; shorter ones are sent as before (TASK-642).
- `citt search --query Q --counts host|app|host,app` counts every group of the match exactly, with no rows: requests, sessions and apps per host, requests, sessions and hosts per app, or requests and sessions per host and app pair, every page of groups. Up to 50 groups print as a table, more go to a `citt-counts-*.csv` file (or `--out FILE.csv`); the last line is `Counted exactly: N requests in S sessions of A apps and H hosts; G groups.` A search with a condition on request contents over 150,000 matches exits 2 with a `try:` command that counts without it; `--json` prints one `citt.plugin.search-counts/1` document (TASK-642).
- `citt search --query Q --export FILE.csv.gz [--order newest|oldest]` writes every matching row through an export on the server, with progress every 15 s, then downloads the gzip CSV (the CSV columns), resumes a lost download and checks its SHA-256. Running the same command again follows or downloads the same export (`FILE.csv.gz.citt-export`); exit 12 after `--timeout`, exit 130 after Ctrl-C and exit 143 after a TERM leave the export running with the command that follows it. Another running export of the account exits 5 with `--export-id N` and `--cancel-export N` commands; an export cut at 5,000,000 rows exits 13 with the command for the rest of the range. A failed export with rows keeps them: the file is downloaded and checked, and the command exits 13 with the reason and the command for the rest; a failed export with no file exits 8 with the reason. The notes on what a file leaves out print on stderr; sessions in the archive add a `--load-older` command, the last line states that the file is not complete, and the exit is 13; a pause of the export on the server is stated once on the progress line; the note of sessions that arrive later and `already holds` add a `try:` command for a fresh export in another file; a FILE that exists or is recorded for another search is not replaced (exit 5, with a `try:` command naming a free file); progress reads past their retries state that the export keeps running and name the same command; `--export-id` prints its commands with the query, range and projects of the export; `--load-older` with `--export` starts a new export after the restore (TASK-642).
- A page of a CSV walk, a `--counts` page, and an export progress read or download that meets no connection or a gateway error is asked again after 1, 2, 4, 8, 15, 15, 15 and 15 s (75 s, longer than a service restart) with `trying again in N s` on stderr, before the walk stops early; the next-rows commands of a walk keep `--max-rows` (TASK-642).

## 2.19.0

- A GET that gets no answer or a 5xx is asked again for up to 100 s: waits of 1, 2, 4, 8, 16, 30 and 30 s, each drawn from 80 to 120 % of its length, and a `Retry-After` in seconds on the answer is the wait of that retry; requests of other methods that are asked again keep 3 retries. `CITT_RETRY_BUDGET` (0 to 600 seconds) sets another budget (NP-1340).
- Past the retries the line names the failure in plain words and the retries, exit 9: `the service could not be reached (the connection timed out; retried 7 times); check the network connection and try again`. The words are `name lookup failed`, `could not connect`, `the connection timed out`, `the connection was reset`, `the connection closed with no answer` and `the answer stopped after 2.0 MB`. With `--json`, the error document has `curl_exit` and `retries` beside `error: "network"` and `http_status: null` (NP-1340).
- A 503 `service_restarting` (the service restarting during a deploy) prints `the service is restarting; try again in a minute`, exit 8, after the retries (NP-1340).
- `citt capture-sync` records a session whose file list or files got no answer as failed with a 60 s wait (`exit` 9, `curl_exit` and `curl_message` in the state and the log line) and goes on with the next session and the run files; it stops after 3 such failures in a row (`the service could not be reached 3 times in a row (...); the sync stopped; the next sync continues`). A success resets the count. The exit code is 9 when any network failure was recorded (NP-1340).
- In the wait loops (`citt status --wait`, `citt tasks --watch`, `citt task --watch`, `citt help-requests --watch`, `citt capture-watch`, `citt capture-start --wait` and the native, prompt, export and scrutinize waits) the retries of each poll stop at the time left, so a wait ends within its timeout; a poll that gets no answer or a 5xx at the end prints the wait's `re-run:` line, exit 12 (NP-1340).
- A resumed download that gets an answer other than 200 or 206 keeps the part file at its size before that attempt, so the next attempt resumes from the right byte (NP-1340).
- `citt capture-sync` keeps `runs_pending` in the state: a run whose sessions were downloaded stays there until a sync fetches all its run files (README.md, run.json, citations.jsonl, app.json, the schemas); every later sync fetches the files of each pending run, even when none of its sessions changed. Before, a sync that lost the connection on `run.json` left the run without it until the run changed on the server. Each log line holds `network_errors` (what, class, retries, curl's exit code and message) and `runs_pending` (NP-1340).

## 2.18.0

- `citt mailbox create` makes a new lab address on `pelmu.me` by default; `--domain pinegrovemail.com` puts it on the older domain, and the request body contains `domain`. Addresses made before 2026-11-03 are on `pinegrovemail.com` and keep receiving. Messages name the address on the domain asked for (NP-928).

## 2.17.0

- `citt capture-start --location LAT,LNG` sets the phone location of every session of the run to that point, in decimal degrees (latitude -90 to 90, longitude -180 to 180, at most 6 decimals), such as `--location 39.7392,-104.9903`; the request body contains `device_location: {"lat": 39.7392, "lng": -104.9903}`. Any other form or a value out of range exits 2 with `--location takes LAT,LNG in decimal degrees, such as 39.7392,-104.9903` and no request. The start line ends `; location 39.7392,-104.9903`; `citt captures` and the `citt capture-watch` run line show the location; each `citt capture-watch` session line states `location 39.7392,-104.9903 verified on the phone` or `not verified`, or `location not set: <reason>` for a session in which the phone's real location was readable by apps. `citt capture-options` prints the accepted form. Apps can detect the location as simulated; the time zone stays the exit's (NP-981).

## 2.16.0

- `citt search --query 'QUERY'` searches with field conditions in place of TEXT (`host:`, `app:`, `sent:`, `recipient:`, `param[name]:`, `status:4xx` and the other fields of `citt search --fields`, combined with `AND`, `OR`, `NOT`, `-` and parentheses). The range is optional (the last 30 days ending now), and `--from` and `--to` also take `now` and `now-7d`; `--days N` sends `from=now-Nd`. The first stdout line is the range searched. TEXT and `--query` together exit 2 with `Give the text as TEXT or as --query, not both.`; `citt search TEXT` sends the same request as 2.15.2 (TASK-609).
- Warnings of a query print on stderr as `citt search: <sentence>` with `  try: citt search --query '<fixed>' ...` when the service has a fix; a query that mixes `AND` and `OR` without parentheses exits 2 with one `try:` command per reading; a refused query exits 2 with the service's sentence (TASK-609).
- `--facet FIELD` (repeatable, up to 5) prints after the rows the top values of the field (`--top N`, default 10) with their apps and requests, and a last line that states what the counts cover (`Counted over all 4,120 matching requests.`, `Ranked from 64 of 6,130 sessions; no counts.`); `--json` adds `facets` (TASK-609).
- `citt search --fields` lists the search fields with their other names, a description and an example (TASK-609).
- `--inside-words TEXT` with `--query` adds `contains:"TEXT"` to the query (TASK-609).
- A `--query` page that ends at the server's time limit before it reads every session exits 13 with `Searched N of M sessions; the next rows: <command> --cursor C`; a CSV keeps the rows fetched (TASK-609).
- The CSV `matched` column holds each matched part of a `--query` row as `res.body at 26347: <snippet>` (TASK-609).

## 2.15.2

- `citt capture-options` and `citt capture-start` take an iOS app: APP is an Android package id, an iOS bundle id or a Google Play link, and `--platform android|ios` picks the app of an id the project holds for both platforms; an iOS run goes to an iOS lab device with the same exit, language, proxy file and navigator options, and `--reset-gaid` is refused for it. An App Store link exits 2 with the line naming the bundle id to give instead (NP-634).
- A capture run of an app no lab device takes names the platform and the reason: every device of that platform reserved for other accounts, captures on that platform not open yet, or no device of that platform registered; exit 7 (NP-951).
- `citt search` keeps the rows of a CSV walk whose later page fails in any way after its retries (a server error, a busy server, no connection, the time limit twice): the CSV holds the rows written, and `Stopped early after N rows: <reason>. The next rows: <command> --cursor C --out FILE-2.csv; try it again shortly.` gives the reason in plain words; exit 13. A page refused for a sign-in or a usage limit keeps the rows too, prints its own sentence in that line and exits 3 or 6 (TASK-602).
- `citt search` creates no CSV file when it fails before any row was fetched, and leaves an existing file as it was (TASK-602).
- An answer `citt search` cannot read (a body that is not JSON, a field of another type) prints `unexpected response from the server` once and exits 1, also while it follows an inside-words search; before, each poll printed a parser error line (TASK-602).
- The older-sessions notice, the restoring notice and the inside-words progress lines group their counts by thousands, with the singular for 1 (`1,200 older sessions (48,210 requests, ...)`, `1 older session (1 request, ...) was not searched`) (TASK-602).
- Every command prints a failed answer as one plain sentence, with no host, API path, HTTP status, API error code or API version: `the service could not be reached; check the network connection and try again` (exit 9), `the server could not answer this request; try again shortly` (exit 8), `this server does not offer this command yet; update the plugin, or try again later` (exit 10); a refusal keeps the service's reason when it names no internal. With `--json`, `error` and `http_status` keep the API code and the status, and `message` is the plain sentence (TASK-597).
- With the plugin pointed at a local gateway in test mode, the dashboard links (the CSV `open_url` column, billing and task links) go to the dashboard the gateway names (`gateway.py --app`); production links are unchanged (TASK-602).

## 2.15.1

- `citt search` reads the CSV of a result in pages of 50 rows (200 before): a page of 200 rows of a common text over 30 days could pass the server's time limit (TASK-598).
- A page that passes the server's time limit is asked again once (`citt search: the search passed the server's time limit; trying once more`). A later page of a CSV walk that passes it twice ends the walk: the CSV keeps the rows written, the command prints `Stopped early after N rows: the search of the next rows passed the server's time limit twice. The next rows: <command> --cursor C --out FILE-2.csv; or narrow the range or the projects.` and exits 13. A first page that passes it twice exits 8, as before (TASK-598).
- The refusal of an inside-words range over the service's limit states `at most 1 day` in the singular and the sessions and requests grouped by thousands (`1,356 sessions and 4,724,516 requests`) (TASK-598).

## 2.15.0

- `citt search TEXT (--days N | --from DATE [--to DATE])` finds captured requests across every capture session of your projects whose capture started in the range (`GET /capture-search`), newest session first; `--project NAME|ID` (repeatable) narrows it. The range is required: without one the command exits 2 with no request and names `--days 30` (`--days 1` with `--inside-words`). A result of one page (`--limit`, default 50) prints inline as a table of capture time, project, app, run key, session, method, status, host and the URL cut to 100 characters; a larger result is written to a CSV file in the working directory (every match up to `--max-rows`, default 5000, with the full URL and the dashboard link that opens the request in its session video), and the command prints the path, the row count, the columns and the first 5 rows. `--inline` prints one page with the `Next page:` and `Whole result as CSV:` commands; `--out FILE.csv` writes the CSV whatever the size; `--json` prints one `citt.plugin.search/1` document. Sessions of the range whose requests are in the archive are counted on stderr with the estimated restore time; `--load-older` restores them, follows the restore every 15 s and searches again. `--inside-words` finds a fragment inside longer words through a search on the service, with progress on stderr every 15 s; a range over the service's limit exits 2 with the limit. Both exit 12 after `--timeout` (default 540 s) with the re-run command (TASK-593).
- `citt search` waits out a server that is briefly unavailable while older data is being moved: it prints `trying again in N s`, waits the seconds the server asks and asks again up to 3 times, then exits 8 with `try again shortly` (TASK-593).
- An answer a command cannot read prints `unexpected response from the server`, with no API path (TASK-593).
- `citt search` prints a plain sentence for every failed answer of its routes (a server error, a server without the route, no connection, a removed inside-words search, a refused range or cursor), with one sentence for any other answer; no host, API route, HTTP status or API error code is printed. With `--json`, `error` keeps the API error code and `message` is the sentence. A busy answer to a progress read waits at most the time left before `--timeout` (TASK-593).

## 2.14.0

- `citt mailbox email EMAIL_ID --html FILE` saves an email's HTML part (`GET /lab-mail/emails/{id}/html`; a message without one is its text part in a minimal HTML document) to the new file FILE, mode 600, with a Content-Security-Policy meta tag first in its head that blocks remote images and tracking pixels when the file is opened; the body is never printed. `citt mailbox show` prints the command with the newest email's id (NP-903).

## 2.13.1

- `citt capture-options` prints one line per phone whose worker refused its model settings, `<phone>: This phone is unavailable: its model settings are being fixed by the CITT team`; `citt capture-start --phone` on such a phone prints the same sentence with `; the run queues until it is fixed`, and the no-free-phone listing names it (NP-890).

## 2.13.0

- `citt mailbox create [--local PART] [--project ID] [--app PACKAGE] [--run ID] [--session ID] [--note TEXT] [--password-stdin | --no-password]` makes a lab mail address on `pinegrovemail.com` by hand (`POST /lab-mail/addresses`): a generated `first.last[n]` name without `--local`, links to a run, session, project or app, and a generated 16-character password stored sealed (or your own from stdin, or none). It prints the address and its credential id, never the password (NP-867).
- `citt mailbox list` prints every lab address of the account with its kind, app, run, session, email count and last email time; `citt mailbox show ADDRESS|CREDENTIAL_ID` prints one address with its links and its emails (received time, time after the session, sender, subject, code, verification link) (NP-865, NP-867).
- `citt mailbox show ... --reveal` reads the address's password for this request and copies it to the clipboard (`pbcopy`, `wl-copy`, `xclip`) or writes it to the mode-600 file `~/.config/citt/revealed/CREDENTIAL_ID.txt`; the password is never printed, and each reveal is recorded with the account's user id (NP-867).
- `citt capture-start --allow-signup` lets an orchestrated session with a goal create an account on the app with a generated lab address and password; payment stays off. The request body contains `allow_signup: true` and the start line ends `; sign-up allowed`; without a goal it exits 2, and an account the service has not turned sign-up sessions on for exits 3 with `Sign-up sessions are not available on this account; contact support to turn them on` (NP-862).
- Orchestrated sessions (`--goal`, `--bring-me-in`, `--conclusion`, `--prompts-file`), sign-up sessions (`--allow-signup`) and `citt mailbox` are open to every account; the refusals read `... are not available on this account; contact support to turn them on`.

## 2.12.0

- `citt capture-start --language TAG` sets the phone's device language for every session of the run, independent of the exit, for example a Colorado exit with the phone in Mandarin (`--state CO --language zh-Hans-CN`); the time zone stays the exit's. The request body contains `device_locale`; a tag outside the form `ll-CC` or `ll-Ssss-CC` exits 2 with no request, and the service refuses a tag outside the options' `device_locales` with 422. The start line ends `; device language zh-Hans-CN`, `citt captures` and the `citt capture-watch` run line show the language, each `citt capture-watch` session line states `Phone locale zh-Hans-CN (set by the run) · time zone America/Denver` (or `(set by the exit)`), and `citt capture-options` lists the device languages (NP-878).

## 2.11.0

- `citt capture-start --proxy-file PATH|-` makes the run exit through the customer's own proxies in place of a NordVPN state or country: up to 100 entries, one per line, as `http://user:pass@host:port`, `socks5://user:pass@host:port` or `host:port:user:pass` (http), with `#` comments and blank lines skipped and a literal `{session}` in the user replaced with a new id each session. A bad line exits 2 before any request with `--proxy-file line <n>: <what is wrong>`, never printing the line, the user or the password; a host given as a private, loopback, link-local, CGNAT, multicast, documentation, reserved or unspecified IP address is refused; `--proxy-file` with `--state`, `--country` or `--state-fallback` exits 2. The request body contains `proxy_entries` and `proxy_file_name`, assembled from files so no entry is on a command line or in the `bash -x` trace; the idempotency key covers the SHA-256 of the file. The start line is `Exit: your proxies from proxy_ca.txt, 10 entries, first entry first each session`, and a service without the proxy exit refuses with exit 7 `request rejected: the proxy exit is not available on this service yet` (NP-874).
- `citt capture-watch` prints, before each ended session of a proxy run, one line per skipped entry (`  #2 skipped: 407 proxy auth (line 4)`) and the exit of the session (`  exit: proxy_ca.txt #1, 203.0.113.7, Denver, Colorado, US, AS7922 Comcast Cable Communications, LLC (ipinfo.io), registry US; 1.4 GB through your proxy`) (NP-874).
- `citt capture-options` prints `Proxy exit: available` or `Proxy exit: not available` (NP-874).

## 2.10.0

- `citt capture-start --goal TEXT`, `--bring-me-in TEXT` (repeatable) and `--conclusion TEXT` give the run its session prompts; `--prompts-file FILE` gives the three as JSON (`{"goal": text or null, "bring_me_in": [text], "conclusion": text or null}`) in place of the flags, and both together exit 2. Limits: 4,000 characters for the goal and the conclusion, 20 bullets of at most 300 characters. Any prompt makes the run an orchestrated session: its navigator asks when stuck unless `--navigator` is given, and a goal without `--duration` is one 30-minute session. In this release the service accepts prompts from staff accounts only; another account exits 3 with `Orchestrated sessions are limited to staff in this release` (NP-800).
- `citt capture-watch` and `citt help-requests --watch` print a bring-me-in request (opened by the session orchestrator when one of the researcher's bullets matches the screen) with its reason, the bullet, the Live page link and the line `Answer by text: citt help-answer ID "<your instruction>"` (NP-803).
- `citt help-answer REQUEST "TEXT"` sends a typed instruction of 1 to 1000 characters to an open bring-me-in request; the session sends `Researcher instruction: TEXT` to its orchestrator and the request then reads `answered`. Exit 5 when the request has closed, already has an answer, or was opened on a fixed trigger (answered by take-over only, with the Live page link); exit 4 for a request outside the account; exit 2 for a missing id or a bad text (NP-803).
- `citt help-answer REQUEST --type "TEXT"` sends text for the phone to type into the input field on screen (an email address, a name, a one-time code): the loop types it, the orchestrator receives only the field name and the length, the service clears the text once the phone has it, and the plugin prints the length, never the text. When the phone finds no input field, the request stays open and `citt help-requests` shows the reason (NP-832).

## 2.9.0

- `citt capture-start --reset-gaid` gives the phone a new advertising ID once, before the first session: the request body contains `reset_gaid: true`, and `run.json` `run.ad_id` states `reset`, `before` and `after` (CF-W12).

## 2.8.0

- `citt capture-start --state XX` captures the run through a NordVPN server in the booked state, or the run fails naming the state. `--state-fallback` allows another state when the booked one connects nothing: the request body contains `exit_fallback: "any_state"` and the start line is `Exit state CA (another state is allowed when CA connects nothing)`. `--state-fallback` with `--country` exits 2. `citt captures` adds `; captured in NE (booked WA: <reason>)` and the states tried to the state column of a run captured in another state than the one booked (CF-W3).
- `citt capture-start --passthrough HOST[,HOST...]`, repeatable, passes those hosts through the proxy unread: they are not decrypted and their traffic content is not captured. Hosts are DNS names or IPv4 addresses, at most 20, each matched as the exact name the app connects to (no wildcard, port, scheme or path); a bad host exits 2 naming it, with no start request. The start line ends `; passed through unread, not decrypted and not captured: <hosts>`, and the run page and `run.json` state `Passed through unread at the researcher's request: <hosts>` (CF-W11).
- `citt captures --sort finished` lists the run that ended last first, then the runs that have not ended, and adds an `Ended` column in local time. Its `--cursor` has the form `<finished_at>,<id>` or `null,<id>`; a cursor of the other sort is refused. A run that ends while you page moves to the head of the list and is on no page of that pass; a new listing from the first page shows it (CF-W13).
- `citt capture-watch --zero-on-end` exits 0 on every ended state (`done`, `done_with_gaps`, `stopped`, `failed`, `imported`) after the same end record and stderr line; exit 12 after `--timeout`, exit 16 on `needs_human` and exit 8 on a server error stay (CF-W13).
- `citt capture-watch` prints one line per session whose store the service retries (progress status `owed`), with the reason, for example `Session 2 of 3: uploaded and verified, storage pending (attempt 2, next attempt at 14:05 CDT); the service retries the store for up to 72 hours after the run ends; a session still not stored then is marked failed and support replays it`. The session's `ingested` or `failed` line follows when the store ends (CF-W6).
- `citt capture-options`, `citt capture-start --help`, the reference and the skill state what `--tracking` changes: `--tracking` is the answer the bot gives to consent and tracking prompts inside the app; `refuse` taps reject or turns every toggle off, and a prompt with no refusal option is accepted and recorded as `consent_no_refuse_option`. Without `--reset-gaid`, CITT changes no ad setting on the phone (CF-W12).
- `citt prompt` states the limits of native code in an answer: `The answer read no native code: Binary Ninja output of N binaries were available (native run R) and the answer cites none of it.`, and for a native run that found no library `The answer read no native code: native run R found none of the build's N libraries.` (CF-W2). An answer about a build with PairIP code virtualization adds `N classes of this build are PairIP-virtualized; their code was not read.` (`1 class ... is ...` for one) (CF-W14).
- `citt capture-sync` files `connections.jsonl` and `dns.jsonl` of a layout 1 session under `network/`, with the other network captures (CF-W9, CF-W10).
- Empty option lists are expanded in the guarded form `${a[@]+"${a[@]}"}`, so a command whose repeatable option is not given no longer stops with `unbound variable` under bash 3.2 (the macOS system bash); the lint test rejects the unguarded form (CF-W15).

## 2.7.1

- Every request names the agent running the plugin: `X-CITT-Client: citt-plugin <version> (claude-code)` under Claude Code, `(codex)` under Codex, `(unknown)` otherwise; the sign-in link page shows the same label. The CITT team sees which agent an account works from (TASK-583).
- `citt capture-start --navigator independent|stuck|unsure [--help-wait MINUTES]` sets how the Visual LLM that plays the app handles a screen it cannot pass: `stuck` asks a human when it is stuck, `unsure` also when it is not sure; `--help-wait` (0 to 30 minutes, default 10) is how long it waits for the human. `citt capture-watch` stops with exit 16 on a run that asks for a human and prints the reason, the screen, the deadline and the Live page link; `citt help-requests` lists the help requests of the account's capture runs, and `--watch` exits 16 on each new one (NP-691).
- `citt prompt --project NAME --apps ... --older` first restores the older captures of the apps from the archive, prints the sessions restored of the total, and then queues the question; exit 12 after 1800 s, exit 8 when a restore stopped after 5 attempts (TASK-537).

## 2.7.0

- `citt capture-sync --verify` checks only the sessions of the runs given with `--run`, and leaves `high_water`, `runs_high_water` and the stored filters in `state.json` as they were, also after a verify that stops early (TASK-544).
- A session synced with all groups and then synced or verified with fewer `--groups` keeps every group and file in `state.json` and `.citt-session.json`; the files of the other groups are no longer named as kept, and the next sync downloads nothing. `README.md` and `run.json` are requested for the groups on disk (TASK-544).
- `citt capture-sync --exclude GLOB`, repeatable, leaves out the session files whose path inside the session folder matches GLOB (`*` also matches `/`), for example `--exclude network/flows.mitm --exclude network/flows.jsonl`. Excluded files are neither downloaded nor reported as missing or kept; the patterns are part of the stored filters, and a later sync without them downloads only the files they left out. `--watch`, `--install-timer` and `--print-cron` repeat each `--exclude` (TASK-545).
- `citt capture-sync --session ID`, repeatable, limits a sync to the named sessions, with any `--groups`, for example `--run 14 --groups video --session s0002` for the video of one session. ID is the session id, the session key or the session folder; a key without `--run` is resolved from the feed, and a key that several runs have exits 5 with their session ids. An unknown session exits 4. The session list is part of the stored filters; `--watch`, `--install-timer` and `--print-cron` repeat each `--session` (TASK-546).
- `citt capture-sync` reads layout 2 sessions, stored as a few archives and `manifest.json` in place of thousands of single files (TASK-553). The layout 2 groups are the archive names: `core` (`core.tar.gz`: `session.har`, `flows.jsonl`, the event, ad and bid files, `ads/*.zip` and the small data files), `large-bodies` (bodies over 1 MB), `frames` (`frames/*`, `escalate/*`), `video`, `raw` (`flows.mitm` and the logs), and `analysis` as before; a layout 2 session without `--groups` gets `analysis,core`. Each archive is one download with `Range` resume and a sha256 check (`--parallel` counts archives), and is unpacked into the session folder at the paths of a layout 1 session (`network/session.har`, `data/frames/...`, `video/video.mp4`), each file checked against its sha256 in `manifest.json`. Layout 2 does not store the `bodies/<sha256>` files of layout 1; their bytes are the request and response bodies in `session.har`. `--groups` takes the names of both layouts in one list, and each session gets the names of its layout; layout 1 sessions keep their groups and per-file downloads, so a folder can hold both.
- `citt capture-sync --no-unpack` keeps layout 2 archives as downloaded. `--exclude` matches the unpacked paths of a layout 2 session and skips an archive all of whose files it excludes. `--verify` checks each unpacked file against `manifest.json` and downloads the archive of a file that differs (TASK-553).
- `citt capture-sync` hashes a local file only when its size or modification time differs from the session's `.citt-session.json`; `--verify` hashes every file (TASK-553).
- `citt captures` prints who booked each run (`Booked by`: user id and name, never an email address), and `--mine` lists only the runs your account booked (TASK-553).

## 2.6.0

- `citt feedback TEXT | --file PATH | - [--json]` sends feedback to the CITT team from any signed-in account (`POST /feedback` with `{"body": ...}`, EPIC-18): one body of free text, Markdown recommended. The body is TEXT (every word given, joined by one space), the full content of `--file PATH` (any extension) or stdin with `-`, sent unchanged; it is UTF-8 text, not empty, at most 1,048,576 bytes (1 MiB). An empty, oversized, unreadable or non-UTF-8 body, two sources or none exit 2 with no request. It prints `Feedback sent (id N). Thank you.`; `--json` prints the response. The 21st feedback of an account in 24 hours exits 6 with a line saying the daily feedback limit is reached; a refusal by the service exits 7 with its reason. The request is sent once and never retried, so a feedback is never stored twice.

## 2.5.0

- `citt verdict FINDING_ID --verdict confirmed|false_positive|cleared --reason TEXT [--cite PATH[#LOCATOR] | --cite capture:SESSION/REQUEST]... [--project NAME | --project-id ID] [--json]` records a Researcher verdict on a finding by hand, with no model run and no charge (TASK-528). It prints "Recorded researcher verdict false positive on FINDING_ID in project N (event E).", "Already recorded: ..." for a verdict equal to the latest one, or "Cleared the researcher verdict ..."; `--json` prints the response; a refusal prints the service's sentence and exits 7; a missing `--verdict` or `--reason` exits 2.
- `citt findings` prints the current verdict: a Researcher verdict before the latest scrutiny, as `false_positive (Researcher, user 42)`, where 42 is the user id of the account that recorded it (TASK-528, TASK-529). `--csv` ends with `verdict_by` (`Researcher` or `Scrutiny`) and `verdict_recorded_by` (that user id, empty otherwise).

## 2.4.1

- The plugin version is checked by the plugin test suite: the top entry of this changelog and the versions of the Claude Code and Codex manifests are one version, and a release whose version differs from them is refused before it is built. The commands, options, output and exit codes are those of 2.4.0.

## 2.4.0

- `citt capture-sync` downloads each missing file from its presigned storage URL, listed per session by `GET /capture-runs/{id}/download-list?sessions=`, with up to 32 downloads at once (`--parallel`, 1 to 32, default 8). These requests are sent without the sign-in and the API is used only for listing, so a capture archive of 20 GB and more is pulled as fast as the link allows.
- Each presigned file resumes with `Range`, is checked against the listed size and sha256 before its final name, and its list is fetched again before `expires_at` or after the storage host refuses a URL.
- The API stays the fallback: a session whose presigned list is unavailable, and the rest of a session whose storage host fails 5 times or refuses a URL from a fresh list, are downloaded through the API with at most 4 at once, with one line naming the session. `--via api` downloads every file through the API.
- The folder layout, `.citt-session.json`, `checksums.sha256`, `state.json`, `--status` and the exit codes are unchanged.

## 2.3.1

- The `Q>` block of a printed question states how many lines the question is, and the recovery rule is scoped to that count: the question is the next N lines, and recovery takes exactly N lines, strips one `Q>` from each and joins them with a newline. The first rule said only that a `Q>` line is question text, and stdout holds `Q>` lines outside the question in two cases: the two re-run lines hold the typed question verbatim, and `--wait` prints the answer after the block, so a typed line or an answer line starting with `Q>` was recovered as part of the question.
- A `check_id` larger than 9223372036854775807 is dropped, as a `check_id` that is not a number already was, and the changes still gate the question. `check_id` is `Option<i64>` on the job create routes, so a wider digit string is a body the route rejects.
- Every question of `citt prompt`, and `--prompt TEXT` of `citt scrutinize`, goes to the free check `POST /questions/check` before the job is created, and the job records the check. The check returns a suggested version of the question that states what a static reading can show, with one reason per change, so a question whose wording would make every answer be refused no longer costs the account model work.
- A suggested change creates no job, charges nothing and exits 15 (new). Its stdout holds the suggested question with the prefix `Q>` on every one of its lines, which collides with no question text, under the rule that recovers it (strip one `Q>` per `Q>` line, join with a newline), then one line per change with each field as a JSON string, and under `--json` one document with `check_id`, `suggested`, `changes` and `proof_note` in the field names of the `POST /questions/check` response, ready to be resubmitted.
- A suggested question equal to the typed one is no change: the job is created with the `check_id`, so a caller that resubmits `suggested` terminates. A CR in the suggested question is deleted once, so stdout, `--json` and the text `--accept-suggested` submits are the same bytes; a trailing newline is kept. A `check_id` that is not a non-negative integer is dropped and the changes still gate the question. An empty or whitespace-only suggested question is not submitted by `--accept-suggested`.
- `--accept-suggested` submits the suggested question in the same run; `--as-typed` submits the question as typed. Both record the check.
- A check that fails, times out, is over its daily limit or is not deployed, and a question over the check's 4,000-character limit, print one line and the question is submitted as typed, as before the check existed.

## 2.3.0

- `citt native PACKAGE --project NAME` starts the native code run of an app's build: Binary Ninja decompiles the build's native binaries (Android `.so` libraries of one CPU type, iOS executables and frameworks from the stored bundle) into its sources. It prints the task id, the binaries to decompile and the skipped ones with their reason; a build that already has a run gets that run back. `--wait` prints a line per change (done of total, binaries being decompiled, binaries ahead in the queue, estimated end, decompiler offline) and exits 0 on done, 13 on done with gaps, 8 on failed, 14 on cancelled, 12 at the timeout.
- `citt tasks` lists submissions (scans, questions, thread turns, kids checks, captures, exports, native code, legacy scans) of a project, an app or every project, with status and progress, who submitted them from where, the local submit time and the duration; `--running`, `--failed`, `--kind`, `--mine`, `--watch`.
- `citt task ID` prints one task with its parts, timeline, reason and next step, and the result link on the dashboard; `--watch` follows it to its end.
- `citt prompt --native` (both forms and follow-ups) decompiles the build's native binaries first; the question waits for the run and reads its output. A waiting turn prints `waiting for native code`; an answer without native output names the `citt native` command.
- `citt export-sources` unpacks the native code of a build (`native-<sha>.tar.gz`, role `native_code`) into `<package>/native/binja_output/`, checked like the tree, and counts its binaries in the `Wrote` line.
- Every request sends `X-CITT-Client: citt-plugin <version>`, so the service records plugin submissions as `plugin` in Tasks.
- Times in `citt native`, `citt tasks` and `citt task` print in the machine's time zone with its abbreviation; `--json` keeps ISO UTC.

## 2.2.0

- `citt capture-start` starts a network capture run of an Android app of a project on a lab phone: duration, exit state, session length, phone (the first free one by default), persona age and tracking. It prints the run id and key, the phone, the planned sessions, the estimated end and the commands that follow, stop and download the run. A re-run of the same command after a network failure returns the run the first call created.
- `citt capture-watch` follows a run to its end with a line per state change and per finished session; it exits 0 on `done`, 13 on `done_with_gaps`, 14 on `stopped`, 8 on `failed`, and 12 with a `re-run:` line after `--timeout` (default 540 s). `citt capture-start --wait` does the same after the start.
- `citt capture-stop` stops a running run (the phone ends the current session and uploads it) or ends a queued one.
- `citt capture-options` prints what a run of an app can use: the phones with their status and active runs, the exit states with server counts, the session lengths, the duration range, the default profile and the measured size per captured hour.
- Exit codes 13 and 14 are new; the skill tells an agent to follow a run with `capture-watch` and its timeout.

## 2.1.1

- `citt captures` prints the phone name in the Phone column (`device_name` from the research API, for example "Pixel 6a #1", or the name staff set) in place of the phone model or its adb serial.

## 2.1.0

- `citt capture-sync` downloads completed network capture sessions into a folder through the research API, incrementally: each run downloads only sessions that are new or changed since the last one, resumes an interrupted file, and checks every file against its sha256. `--install-timer` runs it every 15 minutes from a systemd user timer (Linux) or a launchd agent (macOS) with the plugin's sign-in, without a model; `--status` shows the last run, the sessions downloaded and the failures.
- `citt captures` lists the network capture runs of every project with their state, progress and estimated end.
- `citt auth --file` saves the token only in the 0600 file `~/.config/citt/device_token` and never calls the system keyring, for a host without a desktop session whose keyring is locked (a `capture-sync` timer on a server). After such a sign-in every command reads that file before the keyring; a later sign-in to the keyring restores the keyring-first order. `citt logout` removes both. When `--install-timer` finds no usable token in the timer's environment, it names `citt auth --file` as the fix.
- `citt auth --status` names where the token is read from: the keyring, the token file or `CITT_TOKEN`.

## 2.0.1

- `citt whoami` names the plan the research service reports (`GET /me` `plan`), so an account on a plan without a billing subscription (Custom) is no longer shown as Pay as you go.

## 2.0.0

- Rewritten for the CanITrustThat research API (`/api/research/v1`): scans by a versioned rule pack with findings, evidence, facts and a compliance status per regime.
- Every account can use the plugin. A Pay as you go account scans one Android app at a time (`citt submit PACKAGE`) and asks questions about an app (`citt prompt`); projects, CSV submits, findings across a project, scrutiny, exports, owners and iOS scans are on the Researcher, Deep Researcher and Custom plans.
- New commands: `projects`, `status`, `apps`, `app`, `findings`, `scrutinize`, `prompt`, `export-results`, `export-sources`, `owners`, `usage`.
- Removed: the 0.4 commands `search`, `results`, `claim`, `mine`, `report`, `scan`, `result` and `rescan`, whose routes were retired in October 2026. A question about one app is `citt prompt`; a rescan is `citt submit --rescan` in a project.
- Codex: the same repository is a Codex plugin marketplace (`codex plugin marketplace add CanITrustThat/citt-plugin`).
- The token stored by 0.4 is used as is.

## 0.4.5 and earlier

See the git history of this repository.
