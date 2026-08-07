---
description: Ask one focused question about an app and get a fast answer
argument-hint: <question> <package-id-or-store-url>
allowed-tools: Bash, Read
---

Run a fast custom-prompt scan. This is the preferred path when the user has a specific question rather than wanting the whole scorecard.

The user's request: $ARGUMENTS

Steps:
1. If the app was given only by name, resolve it first with `${CLAUDE_PLUGIN_ROOT}/scripts/citt search "<name>"` and confirm the right package id with the user.
2. Write a precise, self-contained prompt that captures exactly what they want to know and asks for concrete evidence with code citations.
3. Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt scan "<your prompt>" <package-id-or-store-url>` and capture the scan_id it prints.
4. Poll `${CLAUDE_PLUGIN_ROOT}/scripts/citt result <scan_id>` every 30 to 60 seconds until status is completed, then relay the answer. A 404 means still processing, not a failure.

Custom scans need a Developer or Researcher account. A 403 means the app is one the user does not own and cross-app custom scans need the Researcher plan. See the `citt` skill for full detail.
