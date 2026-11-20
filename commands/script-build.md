---
description: Build the image of a script version and report image_ready or the build failure with its log file
argument-hint: NAME@VERSION --project NAME
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt script-build $ARGUMENTS` and relay the lines; on exit 12 run the printed re-run: line.

See the citt skill for every option and the exit codes. Never read or print the token.
