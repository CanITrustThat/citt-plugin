---
description: Show an app's atlas profile (detected SDKs and owner/key clusters)
argument-hint: PACKAGE [--sdks | --clusters] [--all] [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt atlas-app $ARGUMENTS` and relay the result.

See the citt skill for every option and the exit codes. Needs an atlas-enabled account. Never read or print the token.
