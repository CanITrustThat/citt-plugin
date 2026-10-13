---
description: Sign in to CITT with a browser link (device flow)
argument-hint: [--start | --wait | --status] [--file]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

With arguments, run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt auth $ARGUMENTS` and relay the output. Without, run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt auth --start` and show the printed link to the user. When they have approved it, run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt auth --wait`, which prints `authenticated`. If `--start` prints `authenticated`, the stored token is valid and nothing else is needed. On a host without a desktop session (a server running the `capture-sync` timer, whose keyring is locked), pass `--file` to `--start`: the token is then kept only in the 0600 file `~/.config/citt/device_token` and read before the keyring.

See the citt skill for every option and the exit codes. Never read or print the token.
