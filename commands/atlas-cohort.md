---
description: Select a cohort of apps by SDK or fact and export its full raw records
argument-hint: <count|preview|export|jobs|status|sdk-resolve> [selector...] [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt atlas-cohort $ARGUMENTS` and relay the result.

Subcommands: `count`, `preview`, `export`, `jobs`, `status`, `sdk-resolve`. The selector names a fact (`--sdk`, `--package-path`, `--host`, `--permission`, `--identifier`, `--cert-field`, `--manifest-attr`) or a boolean `--where` expression, narrowed by app-metadata filters. `export` submits a bulk job, polls it, and downloads one presigned gzip file; the exported data is raw and unmasked. See the citt skill for every option and the exit codes. Needs an atlas-enabled account. Never read or print the token.
