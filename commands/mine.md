---
description: List the apps you've submitted with their latest scores
allowed-tools: Bash
---

List the apps the user has submitted.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt mine`. It prints an array of the user's submitted apps with their latest scan id, status, and scores. Present it as a short table. This is the entry point for the "review my own apps" workflow: pair it with `/citt:report <package-id>` for any app worth a deeper look. Note that it lists submission-based ownership only, so apps owned by claim but submitted under another account may not appear. Needs an account, so run `/citt:auth` first if it fails.
