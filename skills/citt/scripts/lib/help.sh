#!/usr/bin/env bash
# lib/help.sh: the --help synopsis of every command (DESIGN-11 "Command reference").
# shellcheck shell=bash disable=SC2034

help_auth() {
  cat <<'EOF'
citt auth [--start | --wait | --status] [--file]

Checks the stored token with GET /usage; when there is none or it expired, runs the device
flow: prints a link to open in a browser, then waits for the approval (600 s at most).
  --start   print the link and return
  --wait    wait for the approval of the link printed by --start
  --status  report whether a token is stored and where it is read from, without a request
  --file    keep the token only in the 0600 file ~/.config/citt/device_token, not in the
            system keyring: for a host without a desktop session, whose keyring is locked
            (a capture-sync timer). Every command then reads that file before the keyring.
EOF
}

help_whoami() {
  cat <<'EOF'
citt whoami [--json]

The signed-in account: email, user type, analysis track and plan, then the research
entitlement and the number of projects you own (GET /me). --json adds that body as
"research".
EOF
}

help_logout() {
  cat <<'EOF'
citt logout

Removes the stored token (keyring item and file) and the record of a --file sign-in.
EOF
}

help_submit() {
  cat <<'EOF'
citt submit (--project NAME | --project-id N) (--csv FILE | --apps A[,B...] | PACKAGE...)
            [--deep] [--fresh] [--rescan] [--prompt TEXT | --prompt-file FILE] [--idempotency-key KEY] [--json]
citt submit PACKAGE [--json]

Adds apps to the project (created when the name is new) and queues their scans.
Without a project, a Pay as you go account rule-scans one Android app into its project
"Free scans" (3 a day and 30 a month in the plan, then from the prepaid balance).
Packages are Android package ids, Google Play URLs, App Store URLs or numeric App Store ids
(the last two are iOS apps).
A plain submit of an app already in the project queues nothing.
  --deep     also prepare the decompiled code; counted as deep_scan only while the loaded rule pack
             has deep rules, otherwise as the same scan without --deep (citt usage says which)
  --fresh    download the app again and scan it, also when it is already in the project (usage counted)
  --rescan   scan apps already in the project again from their stored APK with the current rule pack;
             no download, no usage counted; apps already scanned with it are listed as up to date;
             with --deep, prepare the decompiled code from the stored APK; deep_scan per app queued
             only while the rule pack has deep rules, otherwise free
  --prompt   run a custom prompt after the scan (implies --deep)
EOF
}

help_projects() {
  cat <<'EOF'
citt projects [--json]

Your projects with app counts by status and active jobs.
EOF
}

help_status() {
  cat <<'EOF'
citt status [--project NAME | --project-id N] [--wait] [--timeout SEC] [--json]

Apps by status, jobs by kind and status, and failures. --wait polls until no job is active
(default timeout 540 s, then exit 12 with the command to re-run).
Without a project, a Pay as you go account's "Free scans".
EOF
}

help_apps() {
  cat <<'EOF'
citt apps [--project NAME | --project-id N] [--status S] [--family F] [--severity S]
          [--regime R [--regime-status S]] [--q TEXT] [--json | --csv]

The apps of a project with a summary of their key findings.
Without a project, a Pay as you go account's "Free scans".
EOF
}

help_app() {
  cat <<'EOF'
citt app [--project NAME | --project-id N] PACKAGE [--platform android|ios] [--out FILE] [--json]

The per-app JSON of the app's latest scan. --out writes it byte for byte.
Without a project, a Pay as you go account's "Free scans".
EOF
}

help_findings() {
  cat <<'EOF'
citt findings (--project NAME | --project-id N) [--rule ID] [--family F] [--severity S[,S...]]
              [--source rule|llm_prompt] [--app PACKAGE] [--verdict V|none] [--limit N] [--all]
              [--json | --csv]

Findings ordered by severity, app, rule and subject; subjects are printed as found.
--all follows every page.
EOF
}

help_scrutinize() {
  cat <<'EOF'
citt scrutinize FINDING_ID... [--project NAME | --project-id N] [--prompt TEXT]
                [--wait] [--timeout SEC] [--job-id N[,N...]]
                [--as-typed | --accept-suggested] [--json]

Queues LLM scrutiny of the findings. --wait polls until each finding has the verdict of its
job. --job-id waits for jobs queued earlier without queueing new ones.
--prompt TEXT goes to the free check POST /questions/check first: a suggested change prints the
suggested instruction, queues no job and exits 15. --accept-suggested queues the suggested
instruction, --as-typed the instruction as typed.
EOF
}

help_verdict() {
  cat <<'EOF'
citt verdict FINDING_ID --verdict confirmed|false_positive|cleared --reason TEXT
             [--cite PATH[#LOCATOR]]... [--cite capture:SESSION/REQUEST]...
             [--project NAME | --project-id N] [--json]

Records a Researcher verdict on the finding in the project: no model run, nothing charged.
It is the current verdict of the finding over any scrutiny until cleared; --verdict cleared
hands the current verdict back to the latest scrutiny. The project is needed only when the
finding is in several of your projects. A request equal to the latest Researcher verdict
writes nothing and prints "Already recorded".
  --reason  the record of the decision, 1 to 2000 characters
  --cite    a file of the build's prepared tree, with an optional locator after the last #
            (src/a.java#38), or a captured request of the app (capture:12/34); repeatable
EOF
}

help_feedback() {
  cat <<'EOF'
citt feedback TEXT | --file PATH | - [--json]

Sends feedback to the CITT team from the signed-in account, as one body of free text.
Markdown is recommended. Give the body one way: TEXT (every word given, joined by one space), --file PATH
(the file's full content, any extension) or - (stdin). The body is UTF-8 text, not empty, at most
1,048,576 bytes (1 MiB), sent unchanged. Any account may send feedback, at most 20 in 24 hours;
nothing is charged. Prints "Feedback sent (id N). Thank you."
  --file  read the body from a file
  --json  print the response {id, created_at}
  --      end the options: every word after it is TEXT, even one that starts with -
EOF
}

help_prompt() {
  cat <<'EOF'
citt prompt TARGET "QUESTION" [--platform android|ios] [--schema FILE] [--native] [--wait] [--timeout SEC]
            [--as-typed | --accept-suggested] [--json]
citt prompt --thread N ["QUESTION"] [--schema FILE] [--native] [--wait] [--timeout SEC]
            [--as-typed | --accept-suggested] [--json]
citt prompt (--project NAME | --project-id N) --apps all|A[,B...] (TEXT | --file FILE) [--native] [--older]
            [--as-typed | --accept-suggested] [--json]

TARGET is a build file (an existing .apk, .xapk, .apks, .apkm or .ipa), a store link, or a
package id. A file is uploaded in 32 MiB chunks; a re-run after an interruption resumes the
upload from the server's offset. Prints the thread id; --wait prints the answer, its citations,
findings and data.
  --platform  the platform of a package id (default android)
  --thread    ask a follow-up in thread N; with --wait and no question, wait for its last turn
  --schema    a JSON Schema file; the answer then carries data matching it
  --native    decompile the build's native binaries first (citt native); the question waits
              for that run and its answer reads the output
  --wait      poll until the turn is answered (default timeout 540 s, then exit 12)
The project form runs a prompt over a project's decompiled apps; answers become findings with
source llm_prompt.
A question reads the captures that are in the database, newest first, and the answer states the
date range of the sessions it read and how many older sessions it left out. --older (project
form) first restores the apps' older captures from the archive, which takes longer the first
time, and then queues the question.

Every question goes to the free check POST /questions/check first, which costs nothing and
suggests a wording a static reading can answer. A suggested change prints the suggested question
with `Q>` on every one of its lines, then one line per change, creates no job and exits 15. Its
header states how many lines the question is: take exactly that many lines after the header, strip
one `Q>` from each and join them with a newline to recover the question. Later `Q>` lines of the
output, in a re-run line or in an answer, are outside it.
  --accept-suggested  submit the suggested question in the same run
  --as-typed          submit the question as typed; the check is recorded, except with --thread,
                      whose turn route takes no check_id
A check that fails, times out, is over its daily limit or is not deployed, and a question over
4,000 characters, print one line and the question is submitted as typed.
EOF
}

help_export_results() {
  cat <<'EOF'
citt export-results (--project NAME | --project-id N) --apps all|A[,B...] [--out DIR] [--keep-zip]
                    [--export-id N] [--timeout SEC] [--json]

Writes <out>/results/<platform>/<package>.json and manifest.json, verified against the export
manifest. <out> defaults to ./citt-exports/<project>. --export-id resumes an export.
EOF
}

help_export_sources() {
  cat <<'EOF'
citt export-sources (--project NAME | --project-id N) --apps A[,B...] [--out DIR] [--keep-zip]
                    [--export-id N] [--timeout SEC] [--json]

Writes <out>/sources/<platform>/<package>/{app.json, <package>.apk, tree/}. List the apps:
sources exports can be several GB.
EOF
}

help_owners() {
  cat <<'EOF'
citt owners (--project NAME | --project-id N) [--add EMAIL]... [--remove EMAIL]... [--json]

Lists the owners, or adds and removes them in argument order.
EOF
}

help_usage() {
  cat <<'EOF'
citt usage [--json]

This month's usage and limits for rule scans, Deep scans and questions.
EOF
}

help_captures() {
  cat <<'EOF'
citt captures [--state S[,S...] | --state active] [--project NAME|ID]... [--mine] [--sort finished] [--limit N] [--cursor C] [--json]

The network capture runs of your projects, newest first: state, app, phone, sessions done of
planned, flags, the estimated end and who booked the run. States: queued, starting, running,
stopping, done, done_with_gaps, stopped, failed, imported; active is the first four.
  --mine   only the runs you booked
  --sort finished   the run that ended last first, then the runs that have not ended (newest id first); adds an Ended column in
                    your local time, a dash for a run not ended; --cursor takes the value the previous page printed
                    a run that ends while you page moves to the head and is on no page of that pass; a new listing
                    from the first page (no --cursor) shows it
EOF
}

help_capture_sync() {
  cat <<'EOF'
citt capture-sync [--dir DIR] [--project NAME|ID]... [--run KEY|ID]... [--session ID]... [--groups LIST]
                  [--exclude GLOB]... [--no-unpack] [--since DATE] [--parallel N] [--via api] [--limit-rate RATE]
                  [--dry-run | --verify] [--json]
citt capture-sync [--dir DIR] [options] --watch [--every 15m]
citt capture-sync [--dir DIR] [options] --install-timer [--every 15m]
citt capture-sync [--dir DIR] (--status | --uninstall-timer | --print-cron [--every 15m])

Downloads the capture sessions completed since the last sync into DIR/<run key>/<session>/,
with the run's README.md, run.json and checksums.sha256. Files come from presigned storage URLs,
or through the API when those are unavailable. Each file is checked against its sha256;
an interrupted file resumes on the next sync. Runs without a model or tokens.
A layout 2 session is stored as a few archives (core.tar.gz, large-bodies.tar, frames.tar,
video.mp4, raw.tar.gz) and manifest.json; each archive is one download, unpacked into the
session folder at the paths of a layout 1 session (network/session.har, data/frames/...).
  --dir           the sync folder (default $CITT_CAPTURE_DIR, else ./citt-captures)
  --project       only these projects; --run only these runs
  --session       only these sessions: an id, a key such as s0002 (with --run when several runs
                  have it) or a folder; repeat for more sessions
  --groups        layout 1 sessions: analysis,network,data,video (default all four);
                  layout 2 sessions: core,large-bodies,frames,video,raw,analysis (default
                  analysis,core); one list may name both, each session gets its layout's names
  --exclude       leave out session files whose path inside the session folder matches GLOB
                  (network/flows.mitm, 'data/frames/*'; * also matches /); repeat for more
                  patterns; layout 2: applied at unpack, an archive left with no file is skipped
  --no-unpack     keep layout 2 archives as downloaded, in the session folder
  --since         a date or UTC time for the first sync (default: every session)
  --parallel      files (layout 2: archives) downloaded at once, 1 to 32 (default 8); through the
                  API 1 to 4 (default 2)
  --via api       download every file through the API instead of its presigned storage URL
  --limit-rate    bandwidth cap passed to curl, such as 2M
  --dry-run       list the sessions, files and bytes to download; write nothing
  --verify        hash the local files of the synced sessions (of --run when given) again and download
                  any that differ (layout 2: the archive of a differing file); the cursor, filters and
                  recorded groups stay as they are. A plain sync hashes only files whose size or
                  modification time differ from the session's .citt-session.json
  --watch         sync every --every (5 min at least) until stopped
  --install-timer run this sync every --every from a systemd user timer (Linux) or a launchd agent
                  (macOS) with the plugin's sign-in; re-run after a plugin update
  --status        last run, sessions downloaded, failures and the timer
  --print-cron    print a crontab line for other systems
EOF
}

help_capture_options() {
  cat <<'EOF'
citt capture-options APP --project NAME|ID [--duration D] [--json]

What a capture run of APP (an Android package id or Google Play link in the project) can use:
whether the package is allowed, the lab phones with their device id, status and active runs,
the exit states and the exit countries (per NordVPN region) with their server counts, whether
the service takes --proxy-file (Proxy exit: available), the session lengths, the duration range, the default profile, whether the lab launcher is online, and the measured size per captured hour.
  --duration   also print the estimated download size of a run this long (90m, 3h, 2d)
EOF
}

help_capture_start() {
  cat <<'EOF'
citt capture-start APP --project NAME|ID --duration D (--state XX | --country CC | --proxy-file PATH|-) [--split S] [--phone NAME|ID]
                   [--age N] [--tracking allow|refuse] [--navigator independent|stuck|unsure [--help-wait MINUTES]]
                   [--state-fallback] [--passthrough HOST[,HOST...]] [--reset-gaid] [--language TAG] [--wait [--timeout SECONDS]] [--json]
                   [--goal TEXT] [--bring-me-in TEXT]... [--conclusion TEXT] | [--prompts-file FILE]

Starts a network capture run of APP (an Android package id or Google Play link in the project)
on a lab phone and prints the run id, run key, phone, state, planned sessions, estimated end and
the commands to follow, stop and download it. Durations take <n>m, <n>h or <n>d.
  --duration   run length, 1m to 7d
  --state      US exit state code, such as CA (see: citt capture-options); the run is captured in it or fails naming it
  --state-fallback  with --state: allow another state when the booked one connects nothing; the run then shows it
  --passthrough  hosts (DNS names or IPv4 addresses, at most 20) the proxy passes through unread: they are not decrypted and their
                 traffic content is not captured; no wildcard, port, scheme or path; repeatable
  --reset-gaid gives the phone a new advertising ID once, before the first session; the run page and run.json show the ID before and after
  --country    exit country code, such as SG (see: citt capture-options); a US exit needs --state
  --language   device language of the phone for every session, a tag such as zh-Hans-CN or es-US from the options'
               device_locales; independent of the exit, whose time zone stays (default: the exit's language)
  --proxy-file your own proxies as the exit, one per line: http://user:pass@host:port, socks5://user:pass@host:port or
               host:port:user:pass (http); - reads stdin; # comments and blank lines skipped; at most 100 entries; a literal
               {session} in the user is replaced with a new id each session. Each session tries the entries first to last and
               uses the first that passes the exit check and the leak test. Replaces --state, --country and --state-fallback
  --split      session length (default: the options' default, or the longest that fits)
  --phone      phone name or device id; without it the first free phone; a busy phone queues
  --age        persona age, 5 to 99 (default: the project's profile)
  --tracking   allow or refuse (default: the project's profile)
  --navigator  independent (never asks), stuck or unsure: the Visual LLM asks for a human
  --help-wait  minutes the Visual LLM waits for a human after asking, 0 to 30 (default 10)
  --wait       follow the run as citt capture-watch does, up to --timeout (default 540)
  --goal TEXT  orchestrated session: what the session is to reach, at most 4,000 characters; without --duration the run is one
               30-minute session
  --bring-me-in TEXT  orchestrated session: a situation in which the navigator stops and asks you, at most 300 characters;
               repeatable, at most 20
  --conclusion TEXT  orchestrated session: what the session conclusion is to answer, at most 4,000 characters
  --prompts-file FILE  the three prompts as JSON {"goal": text or null, "bring_me_in": [text], "conclusion": text or null},
               in place of --goal, --bring-me-in and --conclusion
  Any prompt makes the run an orchestrated session (staff accounts only in this release); its navigator asks when stuck
  unless --navigator is given, and the start line says "orchestrated: yes" with the number of bring-me-in bullets.
A re-run of the same command within 24 hours sends the same idempotency key and returns the
same run; any other command starts a new run.
EOF
  printf '%s\n' "$CITT_TRACKING_NOTE"
}

help_capture_watch() {
  cat <<'EOF'
citt capture-watch RUN [--timeout SECONDS] [--zero-on-end] [--json]

Follows a capture run (id or run key) and prints a line per state change and per finished
session, and one line with the reason for a session whose store the service retries (storage
pending, up to 72 hours after the run ends). Exits 0 on done, 13 on done_with_gaps, 14 on stopped, 8 on failed. After --timeout
(default 540) it exits 12 with re-run: citt capture-watch RUN; a re-run prints only sessions
not printed before. When the run needs a human it prints the reason, the screen, the deadline
and the Live page link and exits 16; a re-run does not stop again for the same request.
For a run started with --proxy-file, each ended session is preceded by one line per skipped
entry (  #2 skipped: 407 proxy auth (line 4)) and the exit line (  exit: proxy_ca.txt #1,
203.0.113.7, Denver, Colorado, US, AS7922 ... (ipinfo.io), registry US; 1.4 GB through your proxy).
  --zero-on-end   exit 0 once the run is in any ended state (done, done_with_gaps, stopped, failed, imported) after printing its
                  end record; 12 after --timeout, 16 on needs_human and 8 on a server error stay
EOF
}

help_help_requests() {
  cat <<'EOF'
citt help-requests [--state LIST] [--limit N] [--json]
citt help-requests --watch [--timeout SECONDS] [--json]

Lists the help requests of the capture runs you launched, newest first, with their state (open,
answered, missed, expired), deadline and, for open ones, the Live page link.
  --state      comma list of open, answered, missed, expired
  --limit      1 to 200 (default 50)
  --watch      poll every 15 s; print each new open request once with its link and exit 16;
               after --timeout (default 540) exit 12 with re-run: citt help-requests --watch
EOF
}

help_help_answer() {
  cat <<'EOF'
citt help-answer REQUEST "TEXT" [--json]
citt help-answer REQUEST --type "TEXT" [--json]

Sends a typed answer to an open bring-me-in help request (REQUEST is the Id from citt help-requests
or capture-watch): the session's orchestrator receives "Researcher instruction: TEXT" and acts on
it, for example "use the monthly plan", "skip this step" or "continue". 1 to 1000 characters.
With --type the phone types TEXT into the input field on screen (an email address, a name, a
code); no model receives it and the output prints only its length.
A request the Visual LLM opened on a fixed trigger is answered by take-over on the Live page.
Exit 5 when the request is closed, answered already or takes no typed answer; 4 when it is not
among your requests.
EOF
}

help_capture_stop() {
  cat <<'EOF'
citt capture-stop RUN [--json]

Stops a capture run (id or run key). A running run goes to stopping: the phone ends the current
session and uploads it. A queued run ends unstarted. A run that has ended prints its final state.
EOF
}

help_native() {
  cat <<'EOF'
citt native PACKAGE (--project NAME|ID | --project-id N) [--platform android|ios] [--wait] [--timeout SEC] [--json]
citt native PROJECT_APP_ID [--wait] [--timeout SEC] [--json]

Starts the native code run of the app's stored build: Binary Ninja decompiles its native
binaries (.so libraries, iOS frameworks and executables) into the build's sources. Prints the
task id, the binaries to decompile, the skipped ones with their reason, and the progress. A build
that already has a run (open, done or done with gaps) gets that run back; nothing new is queued.
  --platform  android or ios, when the package is in the project for both
  --wait      follow the run: a line per change (done of total, binaries being decompiled, place
              in the queue, estimated end, decompiler offline); exits 0 on done, 13 on done with
              gaps, 8 on failed, 14 on cancelled; after --timeout (default 540) exits 12 with a
              re-run: line
A number without --project is a project app id, as an answer's "citt native N" line gives it.
EOF
}

help_tasks() {
  cat <<'EOF'
citt tasks [--project NAME|ID | --project-id N] [--app PACKAGE [--platform P]] [--kind K[,K...]]
           [--running | --failed] [--mine] [--watch [--timeout SEC]] [--limit N] [--cursor C] [--json]

Submissions, newest first: one row per scan request, Ask, thread turn, kids check, capture run
or group, export, native code run or legacy scan, with its status and progress, who sent it and
from where (web, plugin, api), when (local time) and how long it took. Without a project: every
project of the account.
  --kind     rule_scan, deep_scan, question, thread_turn, kids_check, capture, capture_group,
             export, native_code, legacy_scan
  --running  queued and running tasks only;  --failed  failed tasks only;  --mine  your own
  --watch    after the table, a line per task that changes, until none is queued or running
             (default timeout 540 s, then exit 12)
EOF
}

help_task() {
  cat <<'EOF'
citt task ID [--cancel] [--watch [--timeout SEC]] [--json]

One task: kind, status with progress and queue place, who submitted it and from where, times in
local time, the reason of a failure with the next step, the result link on the dashboard, its
parts (apps, checklist parts, sessions, binaries) and its timeline.
  --cancel cancel the task first (a native code run, a capture or capture group, a question that
           waits for native code); work already done stays; with --watch, follow it to its end
  --watch  print new timeline events until the task ends; exits 0 on done, 13 on done with
           gaps, 8 on failed, 14 on cancelled, 12 after --timeout (default 540)
EOF
}
