---
description: Fetch a custom scan's answer by its scan id
argument-hint: <scan-id>
allowed-tools: Bash
---

Fetch the answer from a custom-prompt scan.

Scan id: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt result <scan-id>`. When the scan is done it prints the result JSON; relay the answer to the user. A 404 means the scan is still processing, so wait 30 to 60 seconds and try again rather than treating it as an error. A 401 means the user needs to run `/citt:auth`.
