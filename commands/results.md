---
description: Pull the full public scorecard for any app
argument-hint: <package-id>
allowed-tools: Bash
---

Fetch the full public scorecard data for an app. Public, so no account is needed.

Package id: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt results <package-id>`. It returns the verdict, plain-language summary, top security and privacy issues, scores, findings by category, and scan history. Summarize the trust posture for the user: lead with the quick verdict (best for / avoid if), then the scores and the main issues. Point them to canitrustthat.com/apps/<package-id> for the rendered scorecard.
