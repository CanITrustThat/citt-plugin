---
description: Check if an app's scan is done and see its score
argument-hint: <package-id> [--scan-id <id> | --scan-number <n>]
allowed-tools: Bash
---

Check the scan status for one app. Works anonymously for public scorecards; sends your token when you have one so private and in-flight scans you own are visible too.

Arguments: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt status $ARGUMENTS`. It prints compact JSON with id, status, current_scan_status, overall score, letter grade, and finding counts. If status is not completed, tell the user where the scan is using the progress fields. Use this as a quick check before a heavier `/citt:results` or `/citt:report`.

Polling a rescan: plain `citt status <pkg>` returns the last COMPLETED scan while a rescan runs (it sets `current_scan_status` to queued/analyzing to flag the in-flight scan). To watch the NEW scan, poll it by id: `citt status <pkg> --scan-id <scan_id>` using the id `/citt:rescan` printed.
