---
description: Record a Researcher verdict on a finding
argument-hint: FINDING_ID --verdict confirmed|false_positive|cleared --reason TEXT [--project NAME]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt verdict $ARGUMENTS`.

See the citt skill for every option and the exit codes. Never read or print the token.
