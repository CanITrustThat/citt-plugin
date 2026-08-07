---
description: Get the detailed private report for an app you own
argument-hint: <package-id> [--scan <scan-id>]
allowed-tools: Bash
---

Fetch the full detailed report for an app the user owns (or any app when signed in as a researcher).

Package id: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt report <package-id>`, adding `--scan <scan-id>` if the user wants a specific scan. It returns the detailed report as markdown. Do not dump the whole thing back at the user: summarize the critical and high findings and the recommendation, then offer the full text on request. A 403 means they do not own the app or the report is locked; a 404 means no completed full scan exists yet; a 401 means run `/citt:auth`.
