---
description: Check if an app's scan is done and see its score
argument-hint: <package-id>
allowed-tools: Bash
---

Check the scan status for one app. Public, so no account is needed.

Package id: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt status <package-id>`. It prints compact JSON with status, overall score, letter grade, and finding counts. If status is not completed, tell the user where the scan is using the progress fields. Use this as a quick check before a heavier `/citt:results` or `/citt:report`.
