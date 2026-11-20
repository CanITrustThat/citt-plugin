---
description: Describe, check, start, follow and pull a campaign of capture runs that CITT books and reviews until a deadline
argument-hint: <draft|check|create|list|show|pause|resume|stop|edit|app|review-run|report|pull|watch> [args...] [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt campaign $ARGUMENTS` and relay the result.

To describe a campaign, ask the user for each required field that `citt campaign draft` lists on exit 2, with the description the line gives, and fill none in by guessing; then run `citt campaign check FILE` and show the refusals and the latest start before `citt campaign create FILE --start-now`. Follow a campaign with `citt campaign watch ID` and run the printed `re-run:` line on exit 12. See the citt skill for every option and the exit codes. Never read or print the token.
