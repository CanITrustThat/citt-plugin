---
description: Run a full trust analysis and return the scorecard and grade
argument-hint: <package-id | store-url | apps.csv> [more apps...]
allowed-tools: Bash, Read
---

Submit one or more apps for a full trust analysis. Use this when the user wants the complete scorecard, scores, and letter grade rather than a single answer.

Apps to submit: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt submit <args>`. It accepts bare package ids, Google Play or App Store URLs, or a path to a CSV with a `package_id` column. It deduplicates against scans completed in the last 90 days and prints a ranked summary of scores, trust bands, and deep links to canitrustthat.com. Relay that summary to the user and note any apps skipped as recent duplicates.

Important: submit REUSES any scan completed in the last 90 days rather than re-running it. If the user wants fresh results for an app that already has a recent scan, use `/citt:rescan <package-id>` instead, which always runs a new scan. Do not pass flags like `--help` to submit and do not read the submit script to discover behavior; the arguments are exactly package ids, store URLs, or a CSV path.

Submitting needs a Developer or Researcher account. If the user is not connected, run `/citt:auth` first. A 403 means the plan is too low (relay the upgrade link it prints). See the `citt` skill for the CSV format and full detail.
