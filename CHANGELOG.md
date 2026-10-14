# Changelog

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
