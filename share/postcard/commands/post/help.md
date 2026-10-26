# desc
Send one Markdown card to an exact Slack address.
# opt alias -- < name >
An account-local exact thread alias. Select this, --channel or --user.
# opt channel -- < id >
An exact C, D or G conversation ID. Select this, --alias or --user.
# opt user -- < id >
An exact U or W user ID whose direct conversation will be opened.
# opt ts -- < parent >
An asserted parent timestamp. Requires --channel and a history preflight.
# opt model -- < name >
Required composing-model label for the card's attribution.
# opt slug -- < name >
Optional composing window, displayed on the card and recorded for watch.
# opt where -- < name >
Optional conversational name for the computer, supplied explicitly.
# opt attach -- < path >
Attach a readable regular file. Repeat for multiple attachments.
# opt help
Display help for `post`.
# man
## DESCRIPTION
Read the message body from stdin and send one card using the selected Slack
user grant. Exactly one of --alias, --channel and --user is required. An alias
resolves an account-local exact thread. Human names, permalinks and positional
destinations are not accepted.

The body is UTF-8 Markdown, from 1 through 12,000 characters, without NUL.
With attachments it may be empty; file-only invocations use </dev/null.
Trailing newlines are preserved. The model label is 1 through 64 letters,
numbers, spaces, dots, slashes, underscores or hyphens, beginning with a
letter or number. The context and escaped fallback must also fit Slack's
3,000- and 40,000-character limits. Oversized content is rejected, not split.

The command checks auth.test against the saved workspace and user, then
looks up that sender's profile. Its display name, real name, username or
finally user ID supplies the card name. This name and the model label are
presentation, not authority. A context line and dividers frame a Markdown
block; the plain-text fallback includes the same body and attribution.

--slug and --where preserve which window and machine spoke when rereading
an inter-machine conversation. Where is the computer's casual pet name,
such as harbor, rather than its DNS or fully qualified hostname. Neither
label is discovered from the environment or required.

Both options add a quiet, non-bold aside after the mailbox: “— in workshop
on harbor”. Slug alone gives “— in workshop”; where alone gives “— on harbor”.
The aside is upright plain text so underscores and markup-shaped names
remain literal. The existing bold attribution and dividers are preserved;
with neither option, the card is unchanged. The fallback includes the same
origin information. A confirmed local receipt also records --slug so a watch
with that same --slug can avoid ringing solely for this window's own posts.
Distinct windows sharing local state must supply distinct names. Reusing a
name shares the association. --where and labels observed in Slack never
establish local send evidence. Without a slug, the post remains eligible to
ring. Suppression does not remove any message from reader results.

Each supplied label must be valid UTF-8, contain 1 through 64 characters,
and occupy one line without control characters. Spelling is preserved.

--user deliberately opens a DM and verifies its recipient. --channel uses
the supplied conversation directly. --alias supplies both the channel and
asserted parent from local configuration. With a parent, one
conversations.replies request must return the asserted parent itself with no
conflicting parent.
An empty page, a reply address or an unavailable parent stops the write;
the command never substitutes another destination. This preflight requires
history access for the conversation. It does not prevent changes at Slack
between the check and the send.

Select an account before the command. With no selector, exactly one saved
credentials entry must exist. Due renewal happens before posting, under the
shared login lock. All subsequent requests use the same complete grant
snapshot without that lock. Renewal trouble warns while unexpired access
remains usable. No message request is retried.

Attachments also require files:write. Every input is opened and measured
before allocating uploads. Original bytes go directly from those descriptors
to curl; callers must not change files in place during the command. Input
names must be valid UTF-8 and are sent literally. After every byte upload is
confirmed, exactly one files.completeUploadExternal request shares all IDs
with the attributed card's blocks. There is no separate chat.postMessage or
initial_comment. A file-only card omits the empty Markdown body block.

Preparation or upload failure never shares a subset. Bytes may already have
reached Slack before a pre-completion failure. An uncertain completion names
the known IDs on stderr and stops, without retry or rollback deletion.
Each byte upload has a five-minute total timeout; allocation and completion
requests each have a sixty-second timeout. A slow or large transfer can reach
that bound. Uncatchable termination may leave private postcard.upload.*
scratch under the temporary directory.
Curl's --data-binary reads each original into memory before sending; a large
attachment therefore also needs enough memory for curl's request body.
Slack generates message text from these blocks; the completion endpoint does
not expose the chat endpoint's independent fallback and unfurl controls.
## OUTPUT
Success returns one JSON receipt with account, team\_id, user\_id, channel,
ts, thread\_ts, sender and permalink. The outer identity is the live-checked
saved grant; sender is Slack's returned message user or null when absent.
The actual channel and timestamp are validated, along with any returned
message identity and timestamp facts. A reply must confirm its thread parent;
a top-level post has null thread\_ts.

Attachment receipts additionally contain requested:{channel,thread_ts} and
files:[{id,name,size}]. Confirming the full uploaded ID set establishes success
even when Slack omits share coordinates. Actual channel, ts, thread_ts and
sender are null unless every file has exactly one share in the requested
channel, by the checked sender, with the requested parent and one common ts.
Requested coordinates are never substituted for that evidence. Only proven
coordinates earn a local send record and best-effort permalink lookup.

Every send with checked exact coordinates saves a private immutable receipt under the XDG state
root's postcard/sent directory, before permalink lookup and stdout. It contains
only the checked sending binding, exact message and parent coordinates, and
optional window name. Account aliases do not divide the evidence. Records are
retained across reads and restarts; there is no pruning or receipt command.
An unavailable local record warns without invalidating the confirmed send.
Slack may expose a message before its receipt is saved; an extra bell is
acceptable, while a missing receipt never hides content or advances progress.

One best-effort permalink lookup follows a confirmed send. Failure returns
success with permalink null and a warning. A missing permalink is never a
reason to send the message again. Failures before a confirmed receipt leave
stdout empty; no raw Slack or transport error is printed.
## EXIT STATUS
0 means a validated send receipt. 1 means a failure before sending or a
known Slack rejection. The argument parser also uses nonzero statuses for
invalid arguments. 4 means delivery is uncertain or Slack reported a post
whose receipt could not be confirmed. Inspect Slack before repeating it.

Text-only posting makes at most one chat.postMessage attempt. Attachment
posting makes at most one files.completeUploadExternal attempt. A timeout, lost response,
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

printf '%s\n' 'The shipment is confirmed.' | \
    postcard --account widgets post --model Codex --alias planning

printf '%s\n' 'The review is ready.' | \
    postcard --account widgets post --model Codex --alias planning \
        --slug workshop --where harbor

printf '%s\n' 'The report and data are attached.' | \
    postcard --account widgets post --model Codex --alias planning \
        --attach report.pdf --attach measurements.csv

postcard --account widgets post --model Codex --alias planning \
    --attach report.pdf </dev/null
```
## OPTIONS
> options
