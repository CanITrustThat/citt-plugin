#!/usr/bin/env bash
# lib/help.sh: the --help synopsis of every command (DESIGN-11 "Command reference").
# shellcheck shell=bash disable=SC2034

help_auth() {
  cat <<'EOF'
citt auth [--start | --wait | --status]

Checks the stored token with GET /usage; when there is none or it expired, runs the device
flow: prints a link to open in a browser, then waits for the approval (600 s at most).
  --start   print the link and return
  --wait    wait for the approval of the link printed by --start
  --status  report whether a token is stored, without a request
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

Removes the stored token (keyring item and file).
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
                [--wait] [--timeout SEC] [--job-id N[,N...]] [--json]

Queues LLM scrutiny of the findings. --wait polls until each finding has the verdict of its
job. --job-id waits for jobs queued earlier without queueing new ones.
EOF
}

help_prompt() {
  cat <<'EOF'
citt prompt TARGET "QUESTION" [--platform android|ios] [--schema FILE] [--wait] [--timeout SEC] [--json]
citt prompt --thread N ["QUESTION"] [--schema FILE] [--wait] [--timeout SEC] [--json]
citt prompt (--project NAME | --project-id N) --apps all|A[,B...] (TEXT | --file FILE) [--json]

TARGET is a build file (an existing .apk, .xapk, .apks, .apkm or .ipa), a store link, or a
package id. A file is uploaded in 32 MiB chunks; a re-run after an interruption resumes the
upload from the server's offset. Prints the thread id; --wait prints the answer, its citations,
findings and data.
  --platform  the platform of a package id (default android)
  --thread    ask a follow-up in thread N; with --wait and no question, wait for its last turn
  --schema    a JSON Schema file; the answer then carries data matching it
  --wait      poll until the turn is answered (default timeout 540 s, then exit 12)
The project form runs a prompt over a project's decompiled apps; answers become findings with
source llm_prompt.
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
