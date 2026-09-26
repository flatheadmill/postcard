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

Before posting, Postcard checks the live identity and constructs the plain-text card, here `Jane Doe's Codex, from Postcard 📮`. The name comes from the checked Slack display profile and the model comes from `--model`. Mentions and formatting in the card or body remain literal. It never retries a post automatically. If the send result is lost, inspect Slack before repeating the command.

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

## Thread Views

`thread` accepts one exact address: `--alias NAME`, `--permalink URL`, or `--channel ID --ts PARENT_TS`. Its JSON includes the selected account and stored workspace/user, the channel and parent `ts`, `projection`, `fetched_count`, `shown_count`, `omission`, `summary`, and ascending `messages`. Message text and blocks remain literal Slack data, accompanied by sender, application, edit and file facts. Profile names are not fetched and card-shaped text is not classified as attribution. `read` continues to return one exactly addressed message.

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

Aliases live beside the grant in `aliases.json`, with mode 0600. Updates use the selected account's lock and atomic replacement; credential renewal preserves this separate file.

`whoami`, `search`, `read`, `thread`, `alias`, and `post` may omit `--account` only when exactly one saved account exists.

If renewal is interrupted or uncertain, authorize again with `bin/postcard --account widgets login`.

## Tests

```sh
python3 -m unittest discover -s test -v
```

Fake Slack handles every Slack request with fictional grants; the tests exercise the real loopback callback. Thread fixtures return earliest eligible messages first and cover long cursor traversals, account isolation, exact projection boundaries and failures after the first page.

## See Also

[App manifest](slack-manifest.json), [zshctl](https://github.com/flatheadmill/zshctl), Slack's [manifest reference](https://docs.slack.dev/reference/app-manifest/) and [PKCE documentation](https://docs.slack.dev/authentication/using-pkce/).

```sh
bin/postcard --help
bin/postcard account --help
bin/postcard login --help
bin/postcard search --help
bin/postcard read --help
bin/postcard alias --help
bin/postcard thread --help
bin/postcard post --help
```
