# citt

A plugin for Claude Code and Codex that scans Android apps with [CanITrustThat](https://canitrustthat.com) and reports what each app contains: ad SDKs, analytics, attribution, data brokers, residential proxy SDKs, keys and secrets, known-vulnerable libraries, consent and children's signals, and store declarations. Each scan applies a versioned rule pack and returns findings with their evidence, facts (keys and account ids as found), and a compliance status per regime. Ask in plain language; the agent runs the `citt` script for you.

## Install

### Claude Code

```
/plugin marketplace add CanITrustThat/citt-plugin
/plugin install citt@citt
/reload-plugins
/citt:auth
```

From a terminal, the first two steps are `claude plugin marketplace add CanITrustThat/citt-plugin && claude plugin install citt@citt`.

Updating from 0.4: `claude plugin marketplace update citt`, then `claude plugin update citt@citt`. A token stored by 0.4 is used as is.

### Codex

```
codex plugin marketplace add CanITrustThat/citt-plugin
codex plugin add citt@citt
```

Then ask Codex to sign you in to citt. The script needs network access to canitrustthat.com. With Codex permission profiles, add a profile to `~/.codex/config.toml` that extends `:workspace` and allows only the CanITrustThat domains:

```toml
default_permissions = "citt"

[features]
network_proxy = true

[permissions.citt]
extends = ":workspace"

[permissions.citt.network]
enabled = true

[permissions.citt.network.domains]
"canitrustthat.com" = "allow"
"app.canitrustthat.com" = "allow"
```

With the older sandbox settings (`sandbox_mode = "workspace-write"`), set `network_access = true` under `[sandbox_workspace_write]` instead; that opens the network to every command.

## Sign in

`/citt:auth` in Claude Code (or "sign me in to citt" in Codex) prints a link. Open it, sign in with the code sent to your email, and approve. Any CanITrustThat account can sign in; an account is created on first sign-in at [app.canitrustthat.com](https://app.canitrustthat.com).

## What each plan includes

| | Pay as you go | Researcher, Deep Researcher, Custom |
|---|---|---|
| Scan one Android app (`citt submit PACKAGE`) | 3 a day and 30 a month, then from the prepaid balance | the plan's monthly count |
| Read an app's findings and facts (`citt app PACKAGE`) | yes | yes |
| Ask a question about an app's code (`citt prompt`) | from the prepaid balance | the plan's monthly count |
| Projects, CSV submits, findings across a project, scrutiny, exports, owners | | yes |
| iOS apps | | yes |

Rates and plans: [canitrustthat.com/pricing](https://canitrustthat.com/pricing). When a request is outside the plan or the balance is short, the command prints one line with the reason, what the account can do, and the pricing or top-up link.

## Commands

In Claude Code each command is also a slash command, `/citt:<command>`. In Codex, ask for the task; the skill names the command.

| Command | What it does |
|---|---|
| `auth`, `whoami`, `logout` | sign in, show the account and its plan, remove the stored token |
| `submit` | scan one app (Pay as you go), or add apps or a CSV to a project and queue their scans |
| `status` | scan progress; `--wait` polls until the scans settle |
| `apps`, `app` | the apps with their key findings; one app's findings, facts and compliance status |
| `prompt` | ask a question about one app: a package id, a store link, or an APK, XAPK, APKS, APKM or IPA file |
| `findings`, `scrutinize` | findings across a project; a model's review of a finding against the decompiled code |
| `projects`, `owners` | your projects; who owns a project |
| `export-results`, `export-sources` | per-app JSON; decompiled sources |
| `usage` | this month's counts and limits |

`citt <command> --help` prints each command's options. `--json` prints one JSON document, also on error.

## Exit codes

0 success; 2 usage; 3 not signed in or not in the plan (the line says which); 4 not found; 5 conflict or not ready; 6 limit reached or balance short; 7 rejected request; 8 server error; 9 network; 12 still running (re-run the printed command). The full table is in `skills/citt/SKILL.md`.

## Token and data

- The token is stored in the system keyring, or in the 0600 file `~/.config/citt/device_token` where no keyring is available. It is sent only to `https://canitrustthat.com`, in a curl configuration read from a pipe, and never printed, logged or placed on a command line.
- What the script sends: the package ids, store links and CSV rows you submit, your questions, and a build file when you pass one to `citt prompt`. Exports are written under `./citt-exports/` in the working directory.
- Requirements: bash 3.2 or later, curl, jq, unzip, and sha256sum or shasum.

## Support

hi@canitrustthat.com
