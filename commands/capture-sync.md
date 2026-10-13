---
description: Download completed network capture sessions into a folder, or install a timer that does it
argument-hint: [--dir DIR] [--install-timer | --status | --dry-run]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt capture-sync $ARGUMENTS` and relay the summary line and any `session N` lines on stderr. Never pass `--watch` here: it runs until stopped. To keep a folder in sync, run it with `--install-timer`; the timer then runs the script on its own, with no model and no tokens. `--status` shows the last run, the sessions downloaded, the failures and the timer.

See the citt skill for every option and the exit codes. Never read or print the token.
