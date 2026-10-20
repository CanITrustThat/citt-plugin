# Changelog

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
