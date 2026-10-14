# desc
Send one Markdown card to an exact Slack address.
# opt channel -- < id >
An exact C, D or G conversation ID. Select this or --user.
# opt user -- < id >
An exact U or W user ID whose direct conversation will be opened.
# opt ts -- < parent >
An asserted parent timestamp. Requires --channel and a history preflight.
# opt model -- < name >
Required composing-model label for the card's attribution.
# opt help
Display help for `post`.
# man
## DESCRIPTION
Read the message body from stdin and send one card using the selected Slack
user grant. Exactly one of --channel and --user is required. Names, aliases,
permalinks and positional destinations are not accepted.

The body is UTF-8 Markdown, from 1 through 12,000 characters, without NUL.
Trailing newlines are preserved. The model label is 1 through 64 letters,
numbers, spaces, dots, slashes, underscores or hyphens, beginning with a
letter or number. The context and escaped fallback must also fit Slack's
3,000- and 40,000-character limits. Oversized content is rejected, not split.

The command checks auth.test against the saved workspace and user, then
looks up that sender's profile. Its display name, real name, username or
finally user ID supplies the card name. This name and the model label are
presentation, not authority. A context line and dividers frame a Markdown
block; the plain-text fallback includes the same body and attribution.

--user deliberately opens a DM and verifies its recipient. --channel uses
the supplied conversation directly. With --ts, one conversations.replies
request must return the asserted parent itself with no conflicting parent.
An empty page, a reply address or an unavailable parent stops the write;
the command never substitutes another destination. This preflight requires
history access for the conversation. It does not prevent changes at Slack
between the check and the send.

Select an account before the command. With no selector, exactly one saved
credentials entry must exist. All requests use the same complete grant
snapshot. Post never renews a token, writes credentials or retries a request.
## OUTPUT
Success returns one JSON receipt with account, team\_id, user\_id, channel,
ts, thread\_ts, sender and permalink. The outer identity is the live-checked
saved grant; sender is Slack's returned message user or null when absent.
The actual channel and timestamp are validated, along with any returned
message identity and timestamp facts. A reply must confirm its thread parent;
a top-level post has null thread\_ts.

One best-effort permalink lookup follows a confirmed send. Failure returns
success with permalink null and a warning. A missing permalink is never a
reason to send the message again. Failures before a confirmed receipt leave
stdout empty; no raw Slack or transport error is printed.
## EXIT STATUS
0 means a validated send receipt. 1 means a failure before sending or a
known Slack rejection. The argument parser also uses nonzero statuses for
invalid arguments. 4 means delivery is uncertain or Slack reported a post
whose receipt could not be confirmed. Inspect Slack before repeating it.

There is at most one chat.postMessage attempt. A timeout, lost response,
malformed receipt, or unfamiliar write failure may follow delivery. Slack's
internal\_error and fatal\_error can follow partial success as well. A safe
returned channel and timestamp are included in disputed-receipt diagnostics
when available. No failure causes a retry or a fallback destination.
## EXAMPLES
```sh
printf '%s\n' 'The review is ready.' | \
    postcard --account widgets post --model Codex --user U012ABC3456

printf '%s\n' 'The shipment is confirmed.' | \
    postcard --account widgets post --model Codex \
        --channel C0123456789 --ts 1700000000.000000
```
## OPTIONS
> options
