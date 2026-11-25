---
description: Start a network capture run of an Android or iOS app on a lab device
argument-hint: APP --project NAME|ID --duration 3h --state CA [--language TAG] [--location LAT,LNG] [--location-always] [--mock-wifi] [--mock-wifi-private] [--mock-cell] [--grant-permissions] [--phone NAME|ID] [--wait]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt capture-start $ARGUMENTS` and relay the run line and the Next: commands.

APP may be a Google Play link with a `referrer` parameter (https, `market://` or `intent://` form); pass it in quotes. Each session of such a run installs the app from the Play Store with that install referrer in place of the scanned build; it runs on Android lab phones, without `--web-url` and `--no-play-fallback`.

See the citt skill for every option and the exit codes. Never read or print the token.
