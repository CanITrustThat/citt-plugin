---
description: Remove the stored CITT token
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt logout $ARGUMENTS`. It removes the token from the keyring and the token file.

See the citt skill for every option and the exit codes. Never read or print the token.
