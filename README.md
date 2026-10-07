# Postcard

<img src="artwork/icon.png" width="96" height="96" alt="A postcard">

Postcard uses a Slack user grant to search, read, and post from the command line. Posts begin with a visible attribution naming the account owner and composing model.

## Requirements

Run Postcard from a working copy; packaging is not supplied. It requires Zsh with [zshctl](https://github.com/flatheadmill/zshctl), plus `curl`, `jq`, `openssl`, and `python3` on PATH.

```sh
git clone https://github.com/flatheadmill/postcard.git
cd postcard
bin/postcard --help
```

## Slack App

In [Your Apps](https://api.slack.com/apps), choose **Create New App**, then **From a manifest**, select your workspace, and use [slack-manifest.json](slack-manifest.json). Copy the public **Client ID** from **Basic Information** for login. Postcard uses PKCE, so no client secret is stored on the workstation.

The manifest registers `http://localhost:8765/auth`. Login opens the consent page in your browser and waits for that callback. Review the requested scopes in the manifest and Slack's consent page.

## Example

In this fictional session, Jane Doe at Amalgamated Widgets saves her grant under the account name `widgets`, finds a shipment message, reads it, and sends herself a note. Replace the placeholder Client ID with yours and complete the browser consent. Use a message address returned by your search, and open your self-DM in Slack before posting.

```console
$ bin/postcard --account widgets login --client-id 0000000000.0000000000
$ bin/postcard account list
$ bin/postcard --account widgets whoami | jq -c '{account, team: .team.name, user: .user.name}'
{"account":"widgets","team":"Amalgamated Widgets","user":"Jane Doe"}

$ bin/postcard --account widgets search --query '"widget shipment"' --count 1 | jq -c '.matches[] | {channel, ts, text}'
{"channel":"C0123456789","ts":"1700000000.000002","text":"The widget shipment arrives Tuesday."}

$ bin/postcard --account widgets read C0123456789 1700000000.000002
$ printf '%s\n' 'Remember to check the widget shipment on Tuesday.' | bin/postcard --account widgets post --model Codex self
```

`account list` reads local records. `whoami` refreshes the grant if needed and checks the live Slack identity. Search returns one page of matches as literal Slack text, with the stored workspace and user as context.

## Find a Person

Message search finds messages, not people. To discover an exact Slack user ID
from profile names, search the selected account's directory:

```console
$ bin/postcard --account widgets people --query 'Casey Lee' |
    jq '.candidates[] | {id, username, display_name, real_name, matched}'
{"id":"U012ABC3456","username":"casey.lee","display_name":"Casey","real_name":"Casey Lee","matched":["real_name"]}
```

`people` traverses every cursor page returned by `users.list`, then performs a
Unicode-aware, case-insensitive match against username, display name and real
name. Exact field matches sort before partial matches. The default output bound
is 20 candidates; `--count N` accepts 1 through 100. `matched_count`, `returned`
and `truncated` distinguish the complete match set from the bounded candidates
array. No partial result is printed when a later directory page fails.

Candidates include exact IDs and Slack's deletion, bot, application and guest
status facts. No email field is requested or returned. The command never chooses
a candidate, opens a conversation or posts. Refine an ambiguous or truncated
query, inspect the returned facts, then pass the selected exact ID to `post`:

```sh
printf '%s\n' 'The review is ready.' | \
    bin/postcard --account widgets post --model Codex U012ABC3456
```

`post` opens the exact user's direct conversation through Slack. It does not
accept a profile name as a destination.

Before posting, Postcard checks the live identity and constructs a Block Kit
card. A compact context line names `Jane Doe's Codex, from Postcard` beside the
open-mailbox mark; dividers frame the Markdown body. The name comes from the
checked Slack display profile and the model comes from `--model`. It never
retries a post automatically. If the send result is lost, inspect Slack before
repeating the command.

## Thread Aliases

An alias names an exact channel and parent timestamp within one saved account. Binding, inspecting, listing and deleting aliases are local operations; they neither renew the grant nor search Slack. The same name can refer to different threads in different accounts. Select the account before the command, as with other Postcard operations.

```sh
bin/postcard --account widgets alias planning \
    --permalink 'https://widgets.slack.com/archives/C0123456789/p1700000000000002?thread_ts=1700000000.000000'
bin/postcard --account widgets alias planning
bin/postcard --account widgets alias
bin/postcard --account widgets thread --alias planning
printf '%s\n' 'The shipment is ready.' | bin/postcard --account widgets post --alias planning --model Codex
bin/postcard --account widgets alias planning --delete
```

Use `alias NAME --channel ID --ts PARENT_TS` to bind directly. Binding an existing name replaces its address. Names start with a lowercase letter or digit and contain lowercase letters, digits, dots, underscores or hyphens. A permalink uses its explicit `thread_ts` when present; otherwise its message timestamp is an assertion that the message is the parent. It never selects a different account. `post --alias` replaces both the destination and `--thread`.

## Notify a Person

Typing `@Casey Lee` as ordinary prose does not create a Slack mention. Read the
relevant thread first. Its `people` array maps the profile names observed in
the selected messages to their exact Slack member IDs:

```console
$ bin/postcard --account widgets thread --alias planning |
    jq '.people'
[
  {
    "id": "U012ABC3456",
    "username": "casey.lee",
    "name": "Casey Lee"
  }
]
```

Place that ID inside Slack's mention form in the Markdown body:

```sh
printf '%s\n' '<@U012ABC3456> The review is ready.' | \
    bin/postcard --account widgets post --alias planning --model Codex
```

Slack renders the token as `@Casey Lee` and notifies Casey according to their
Slack preferences. The angle brackets are significant. Take the ID from the
thread's `people` array rather than guessing from a display name.

## Thread Views

`thread` accepts one exact address: `--alias NAME`, `--permalink URL`, or `--channel ID --ts PARENT_TS`. Its JSON includes the selected account and stored workspace/user, the channel and parent `ts`, `projection`, `fetched_count`, `shown_count`, `omission`, `summary`, ascending `messages`, and a `people` directory for the user IDs observed in those messages. Message text and blocks remain literal Slack data, accompanied by sender, application, edit and file facts. Card-shaped text is not classified as attribution. `read` continues to return one exactly addressed message.

| View | Selection |
| --- | --- |
| Default, or `--window N` | Parent plus the first and last N replies, with overlaps removed. N defaults to 8 and ranges from 1 to 100. |
| `--around TS [--window N]` | Exact anchor plus its nearest N replies on either side. A parent anchor selects the parent and first N replies. A reply anchor excludes the parent body. |
| `--from TS [--through TS]`, or `--through TS` | Inclusive range. |
| `--all` | All fetched messages. |
| `--after TS` | Every fetched message strictly newer than TS. |

The first four views traverse the complete cursor-paginated thread before projecting it. They bound output, not Slack calls. `fetched_count` counts unique messages in that full collection even for a range; `shown_count` counts selected messages. Ends omissions include `after`, `before`, `before_index` and `count`, derived from the actual collection rather than Slack's `reply_count`. To recover the middle, pass the omission's `after` value as `--from` and its `before` value as `--through`. The inclusive range repeats the two visible bookends; deduplicate stitched results by exact timestamp.

```sh
bin/postcard --account widgets thread --alias planning --around 1700000000.000020 --window 3
bin/postcard --account widgets thread --alias planning --from 1700000000.000008 --through 1700000000.000030
bin/postcard --account widgets thread --alias planning --all
bin/postcard --account widgets thread --alias planning --after 1700000000.000030
```

`--after` asks Slack only for the newer range and follows every cursor, including those on short or empty pages. It also excludes the boundary locally. The timestamp is a lower bound and need not still exist. All qualifying messages are returned, even when a burst spans several pages, and `fetched_count` counts only those qualifying messages. No matches is a successful result with `messages: []` and `summary: "0 messages fetched after TIMESTAMP"`. After a nonempty success, continue from the last returned message's `ts`. After an empty result or failure, retain the supplied timestamp; do not advance to the wall clock. Edits, reactions and deletions to older messages do not qualify.

The modes are mutually exclusive, and an explicit `--window` applies only to ends or around. Timestamps preserve all six fractional digits. An observed reply supplied as a parent is refused with its exact parent address. Full traversal requires the parent; the bounded after view does not perform another lookup when the parent is absent from its response.

No partial result is printed if a later page fails. Duplicate timestamps retain the last whole observed payload, without merging copies or claiming which copy is the newest edit. Reaching the terminal cursor establishes the end of this invocation's fetched collection, not an atomic snapshot of a conversation Slack prevented from changing.

## Reader Cursors and Notifications

A reader names your progress in exact threads. Initialize it from the last
Slack timestamp whose earlier context you already have:

```sh
bin/postcard --account widgets thread --alias planning \
    --cursor workshop --after 1700000000.000030
```

This reads every message after the declared boundary before saving progress.
An empty first result still establishes that boundary. Later reads use the
saved position and omit `--after`:

```sh
bin/postcard --account widgets thread --alias planning --cursor workshop
```

Initialization is explicit: missing cursors require `--after`, and an existing
cursor refuses it. An initial `0.000000` deliberately reads all available
history. The ordinary ends view does not acknowledge its omitted middle.
Other projections and stateless `--after` reads never change reader progress.

Run the watcher in the foreground when you want a bell for that reader:

```sh
bin/postcard --account widgets watch --alias planning --cursor workshop
```

It emits a complete line such as:

```text
You have messages: `postcard --account widgets thread --alias planning --cursor workshop`.
```

Watch establishes that a newer unreceipted message exists. A successful Postcard send saves an exact installation-local receipt beneath `~/.local/state/postcard/sent`; a probe stays quiet when every newer message has such a receipt. A same-user message from another installation and a copied card still ring. Quiet probes do not advance the cursor or remove locally sent messages from its next read.

The watcher follows continuation through empty and locally receipted pages, stopping at the first unreceipted message or the terminal cursor. It does no profile lookup or content rendering. Its default interval is 30 seconds; `--interval SECONDS` selects a positive whole number. After ringing, it checks local progress instead of Slack until that thread has another successful read. An empty successful read counts as a look, which releases the bell even if the message that caused it has since disappeared. Reading another thread does not.

For a standing Codex window, the optional Muster adapter forwards these lines:

```sh
muster monitor --slug workshop -- \
    postcard --account widgets watch --alias planning --cursor workshop
```

Postcard works without Muster. The watcher owns polling and Slack failures;
the adapter owns forwarding records and the foreground child's lifetime.
Neither starts a hosted inbox. The watcher emits the resolved account name
even when only one account existed at startup. Its alias is resolved on each
check; rebinding it requires an initialized cursor for the new exact thread.

Transport failures, HTTP 5xx, and temporary Slack server errors defer the next
probe. HTTP 429 and Slack's `ratelimited` error honor `Retry-After`, falling back
to at least 60 seconds when no usable delay is supplied. Each retry starts a
fresh observation; partial pages are discarded. Malformed successes, unknown
API errors, inaccessible threads, invalid state or account identity, and
uncertain OAuth renewal terminate. OAuth and posting retain their existing
single-attempt behavior. Diagnostics stay on stderr.

INT, TERM and HUP stop the watcher and its owned workers. No account lock spans
output or a polling/retry sleep. An interrupted output does not commit a read.
After a successful output, saving may still fail; the next read may repeat it.
Successful stdout is not a promise of downstream retention or comprehension.
Two concurrent successful reads retain the greater delivered timestamp and
each add one look. An entry removed during a read is not recreated, and
different explicit initial boundaries cannot be merged.

The bell remembers only the last look it rang for. Restarting may ring again
for unread work, which also recovers a hint that was accepted but never acted
on. There is no reminder timer or automatic restart. A resumed laptop catches
up from the saved timestamp; the command does not wake a sleeping computer.
Locally receipted posts remain new activity and appear in cursor reads, but do not ring by themselves. A post without a usable local receipt rings normally; receipt failure never authorizes silence. Older edits and deletions are not new activity. The parent counts too when the starting boundary precedes it. A cursor read need not produce a Slack reply when none is called for.

## Why There Is No Channel Tail

`thread --after` is complete because the command already has the thread's
exact channel and parent timestamp. Slack can return every reply after the
boundary from that one addressed thread.

A channel-wide tail has no equivalent Slack Web API operation. Conversation
history returns the channel timeline, but ordinary replies to older threads
are retrieved separately and require each thread's parent timestamp. Reading
only history would silently omit those replies. Finding them on demand would
require traversing the channel's complete history to discover every old
parent, then inspecting each thread that may have changed. Search is useful
for discovery but is not a complete activity log.

Postcard therefore does not offer a `tail` command that only returns part of
the channel's activity. A truthful channel tail requires a prospective,
stateful Events API consumer that records top-level messages and thread
replies as Slack emits them. Such a service could promise everything observed
since one of its checkpoints; a stateless CLI cannot reconstruct that promise
for an arbitrary timestamp before observation began.

## Files

Each account's grant is stored in `~/.config/postcard/accounts/NAME/credentials.json`. Storage directories have mode 0700 and credential files have mode 0600; credentials are plaintext.

`XDG_CONFIG_HOME` can override the configuration root. Login holds a native Zsh
lock at `${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/NAME/login.lock`
from before browser authorization through credential installation. Another
login for that account fails as busy; the lock file remains after release.

Login saves the client, workspace and user IDs, user access token, and granted
scope string. Rotating grants also retain their refresh token and absolute
access-token expiry. Reauthorization must match the saved IDs. A failed login
before installation leaves the existing credentials unchanged; this cannot
reverse an exchange already performed by Slack. Installation uses a private
staging file in the account directory and an atomic rename. An uncatchable
termination can leave that staging file behind.

Aliases live beside the grant in `aliases.json`, with mode 0600. Updates use the selected account's lock and atomic replacement; credential renewal preserves this separate file.

Read progress lives separately in
`~/.local/state/postcard/accounts/ACCOUNT/cursors/READER.json`, with private
directories and mode-0600 atomic file replacement. Reader names use 1–64
lowercase ASCII letters, digits, dots, underscores or hyphens, starting with a
letter or digit. The account's existing lock also protects these state files.
A record binds itself to the Slack client, team and user IDs; refresh tokens
and changing profile names do not identify a reader. Each thread is keyed by
channel and parent timestamp, so two aliases for one thread share progress:

```json
{
  "version": 1,
  "binding": {"client_id": "123.456", "team_id": "T123ABC", "user_id": "U123ABC"},
  "threads": [
    {"channel": "C123ABC", "ts": "1700000000.000000",
     "start_after": "1700000000.000030", "after": "1700000000.000042", "looks": 2}
  ]
}
```

`start_after` keeps the explicit starting boundary, `after` names delivered
content, and `looks` counts successful outputs, including empty ones. The
`cursor` object in read output describes the starting state of that invocation;
the durable commit happens after writing that output successfully. Watch writes
none of these fields. Account lock acquisition waits interruptibly through
ordinary contention; grant renewal and Slack retrieval remain serialized.

`whoami`, `search`, `read`, `thread`, `watch`, `alias`, and `post` may omit `--account` only when exactly one saved account exists.

If renewal is interrupted or uncertain, authorize again with `bin/postcard --account widgets login`.

## Tests

```sh
zsh test/all.zsh
```

The Zsh tests use a fictional OAuth endpoint and local TCP callbacks. They
cover callback validation, PKCE exchange, credential installation, account
binding, lock contention, and storage failure boundaries without live Slack
authorization.

## See Also

[App manifest](slack-manifest.json), [zshctl](https://github.com/flatheadmill/zshctl), Slack's [manifest reference](https://docs.slack.dev/reference/app-manifest/) and [PKCE documentation](https://docs.slack.dev/authentication/using-pkce/).

```sh
bin/postcard --help
bin/postcard account --help
bin/postcard login --help
bin/postcard search --help
bin/postcard people --help
bin/postcard read --help
bin/postcard alias --help
bin/postcard thread --help
bin/postcard watch --help
bin/postcard post --help
```
