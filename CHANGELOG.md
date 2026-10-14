# Changelog

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
