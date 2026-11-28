---
description: Answer a bring-me-in help request of a capture run by text
argument-hint: REQUEST "TEXT"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt help-answer $ARGUMENTS` with the text the user gave, and relay the lines; on exit 5 tell the user the printed reason and, when a Live page link is printed, give them the link to take over.

With `--type "TEXT"` the phone types the text into the input field on screen (an email address, a phone number, a name, a code). The text is typed exactly as you give it, phone numbers and email addresses included; what you type is your responsibility. Send only text the user gave. When the phone does not type it, the request stays open and takes another answer; `citt help-requests` prints the reason (`answer_refusal` in `--json`) as one of these sentences with its next step, which you tell the user:

| `answer_refusal` | Sentence | Next step |
|---|---|---|
| `no_field` | The phone found no input field on screen, so nothing was typed. | Open the field on the Live page, then send the text again, or type it there yourself. |
| `dump_failed` | The phone could not read the screen, so nothing was typed. | Open the field on the Live page, then send the text again, or type it there yourself. |
| `focus_denied` | The phone was not showing the app under test (another app or a system window was in front, or the focus could not be read), so nothing was typed. | Open the field on the Live page, then send the text again, or type it there yourself. |
| `send_failed` | The phone could not send the text to the field, so nothing was typed. | Open the field on the Live page, then send the text again, or type it there yourself. |
| `not_in_field` | The text was sent, and the field did not show it afterwards. | Send it again, or type it on the Live page. |
| `screen_changed` | The screen changed while the text was being typed, so the text may have been typed before the change. | Check the screen on the Live page, and send the text again if it is missing. |
| `underage_value_refused` | The text is an age or birth date under the lowest age a session enters (18, or 25 for a dating app), so it was not typed. | Send an adult age or birth date. |
| `credential_mismatch_refused` | This run signs up with its own address, and the text is another address, so it was not typed. | Send the text for another field, or type on the Live page. |
| `phone_number_refused` | A phone number was not typed by this phone's software version. Phone numbers are typed as given once the phone has the current version. | Send the text again, or type it on the Live page. |
| `card_number_refused` | The text is a payment card number, or the field asks for one, so it was not typed. | Send the text for another field. |
| `other` | The phone typed nothing. | Open the field on the Live page, then send the text again, or type it there yourself. |

See the citt skill for every option and the exit codes. Never read or print the token.
