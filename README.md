# Postcard

<img src="artwork/icon.png" width="96" height="96" alt="A postcard">

Postcard searches Slack messages, retrieves thread pages, remembers thread progress, watches for unread replies, and sends Markdown cards through your own Slack user grant. Retrieval and posting commands return JSON for programs and language models; watch emits read instructions. Slack remains the human interface.

## Requirements

Run Postcard from a working copy; packaging is not supplied. It requires Zsh with [zshctl](https://github.com/flatheadmill/zshctl), plus `curl`, `jq`, and `openssl` on PATH.

```sh
git clone https://github.com/flatheadmill/postcard.git
cd postcard
bin/postcard --help
```

## Slack App

In [Your Apps](https://api.slack.com/apps), choose **Create New App**, then **From a manifest**, select your workspace, and use [slack-manifest.json](slack-manifest.json). Copy the public **Client ID** from **Basic Information** for login. Postcard uses PKCE, so no client secret is stored on the workstation.

The manifest registers `http://localhost:8765/auth`. Login opens the consent page in your browser and waits for that callback. Review the requested scopes in the manifest and Slack's consent page.

## Example

In this fictional session, Jane Doe at Amalgamated Widgets saves her grant under the account name `widgets`, finds a shipment message, and retrieves a page from its thread. Replace the placeholder Client ID with yours and complete the browser consent. Use the channel and parent timestamp from your own result.

```console
$ bin/postcard --account widgets login --client-id 0000000000.0000000000
$ bin/postcard --account widgets search --query '"widget shipment"' --count 1 | jq -c '.matches[] | {channel, ts, thread_ts, text}'
{"channel":"C0123456789","ts":"1700000000.000002","thread_ts":"1700000000.000000","text":"The widget shipment arrives Tuesday."}

$ bin/postcard --account widgets thread --channel C0123456789 --ts 1700000000.000000
```

A search result's `thread_ts` is the preferred parent address. When it is absent, the result's `ts` is not proof that the message is a parent. Thread accepts a caller's parent assertion and reports a conflicting parent when the returned messages expose one.

## Search Messages

```sh
bin/postcard --account widgets search --query '"widget shipment"' --count 20 --page 1
```

Search makes one `search.messages` request using the saved user's `search:read` grant. `--query` is required and passes through unchanged. Count defaults to 20 and page to 1; both accept integers from 1 through 100. Results are requested newest first with highlighting disabled. The command does not follow later pages, sort or deduplicate matches locally, or look up profiles and channels.

The result is one JSON object:

```json
{
  "account": "widgets",
  "team_id": "T0123456789",
  "user_id": "U0123456789",
  "query": "\"widget shipment\"",
  "paging": {"count": 20, "page": 1, "pages": 1, "total": 1},
  "matches": [
    {"channel": "C0123456789", "ts": "1700000000.000002", "thread_ts": null,
     "text": "The widget shipment arrives Tuesday."}
  ]
}
```

The outer team and user IDs come from the saved grant. Message text and timestamp strings remain literal; an absent thread parent becomes null. Paging comes from Slack's `messages.paging`, or the corresponding fields in `messages.pagination` when paging is absent. Conflicting pagination facts or malformed matches fail the entire page with no stdout. No matches is successful with `matches: []`. Slack's search behavior and filters determine the results; this page is not an exhaustive conversation history.

## Thread Pages

```sh
bin/postcard --account widgets thread --channel C0123456789 \
    --ts 1700000000.000000 --count 20
```

Thread makes one `conversations.replies` request for an exact channel and asserted parent timestamp. Count defaults to 20 and accepts integers from 1 through 100. It is a requested page bound, not a promised result count. Optional `--after TIMESTAMP` selects messages strictly newer than that boundary within this page. Timestamps remain decimal strings with their fractional digits intact.

The output carries the saved account and identity, the requested address and boundary, request paging parameters, and Slack's original message objects:

```json
{
  "account": "widgets",
  "team_id": "T0123456789",
  "user_id": "U0123456789",
  "channel": "C0123456789",
  "ts": "1700000000.000000",
  "after": null,
  "paging": {"count": 20, "cursor": null, "next_cursor": "opaque-slack-token"},
  "messages": [
    {"type": "message", "user": "U0123456789", "ts": "1700000000.000000",
     "text": "Shipment planning.", "reply_count": 3}
  ]
}
```

Message order and every returned field are preserved, including text, blocks, files, edits, and user, bot, and app identifiers. A returned parent remains an ordinary message in the array. Thread does not render a transcript, look up names, sort, deduplicate, or infer totals. The entire page is validated before output; a malformed response or request failure leaves stdout empty.

`--cursor TOKEN` passes Slack's opaque continuation token unchanged. `paging.next_cursor` is null when Slack returns an empty, null, or absent continuation; otherwise it names the next page. An explicitly empty input cursor is an error. A short or empty messages array can still have a continuation. A response claiming more data without a usable cursor is rejected.

To continue, repeat the account, address, count, and any `--after` boundary with the returned cursor. This example makes a first request and a second only when a continuation exists:

```zsh
bin/postcard --account widgets thread --channel C0123456789 \
    --ts 1700000000.000000 --count 20 --after 1700000000.000010 > first-page.json
cursor=$(jq -r '.paging.next_cursor // empty' first-page.json)
if [[ -n $cursor ]]; then
    bin/postcard --account widgets thread --channel C0123456789 \
        --ts 1700000000.000000 --count 20 --after 1700000000.000010 \
        --cursor "$cursor" > second-page.json
fi
```

Each page is a separate observation. A terminal cursor ends that query's reported continuation; it does not establish an atomic snapshot of the thread. Slack cursors expire, so they are temporary continuations rather than durable reading positions. `--after` alone retrieves one page without saving progress. Use `--reader` for complete traversal with a saved boundary, as described in [Remember Thread Progress](#remember-thread-progress).

`--ts` asserts the parent; it does not ask Postcard to discover one. If a returned message has a different nonempty `thread_ts`, the command fails and reports that actual parent. A filtered, empty, or continuation page may lack evidence confirming the assertion. Use either the direct channel and parent address or an account-local alias.

## Name a Thread

```sh
bin/postcard --account widgets alias planning \
    --permalink 'https://widgets.slack.com/archives/C0123456789/p1700000000000002?thread_ts=1700000000.000000'
bin/postcard --account widgets alias planning
bin/postcard --account widgets thread --alias planning
```

An alias names one exact channel and parent timestamp within one saved account. `alias NAME --channel ID --ts PARENT` binds the address directly; a Slack message permalink uses its `thread_ts` when present and otherwise asserts that the linked message is the parent. Binding an existing name replaces its address. `alias` lists names, `alias NAME` inspects one and `alias NAME --delete` removes it.

An alias is resolved afresh for each invocation. When continuing through thread pages, use the account, channel and parent timestamp returned by the first invocation rather than resolving the mutable alias again.

Names contain 1 through 64 lowercase ASCII letters, numbers, dots, underscores or hyphens and begin with a letter or number. Alias operations are local: they require a structurally valid saved account but not an unexpired token, make no Slack request and neither renew nor modify credentials. The versioned `aliases.json` is bound to the selected account's saved client, workspace and user, written with mode 0600 and replaced atomically under a stable local lock. Rebinding does not move reader progress; readers track exact addresses independently.

## Remember Thread Progress

```sh
bin/postcard --account widgets thread --alias planning \
    --reader workshop --after 1700000000.000010

bin/postcard --account widgets thread --reader workshop
```

Initialize a named reader with an exact address, using either `--alias` or `--channel ID --ts PARENT`, and an explicit `--after` boundary chosen from observed message timestamps. Later invocations supply only the reader name and any page-size preference. Reader names use the alias name grammar and belong to the selected account. An existing reader rejects address arguments and `--after`; there is no reset or retarget operation. Its saved client, workspace and user binding must still match the account. Rebinding an alias does not redirect a reader.

A reader follows every reported continuation, including short and empty intermediate pages, using one grant snapshot and the original boundary throughout. `--count` remains the requested page size, default 20 and range 1–100; it does not cap the complete result. `--cursor` cannot accompany `--reader`. Repeated cursors, failed requests and malformed later pages refuse the complete traversal before output. There is no aggregate traversal deadline or result cap, and final JSON assembly can hold the whole result in memory.

The reader returns one document:

```json
{
  "account": "widgets",
  "team_id": "T0123456789",
  "user_id": "U0123456789",
  "reader": "workshop",
  "channel": "C0123456789",
  "ts": "1700000000.000000",
  "generation": 0,
  "after": "1700000000.000010",
  "through": "1700000000.000012",
  "messages": [
    {"ts": "1700000000.000012", "thread_ts": "1700000000.000000",
     "text": "The shipment has arrived."}
  ]
}
```

`generation` is the starting generation, zero for initialization. `after` is the input boundary. Messages strictly exceed it by exact decimal value and retain their complete objects, page order, duplicates and timestamp spelling. `through` is the maximum delivered timestamp, retaining its first observed spelling when values tie; an empty result retains the exact input boundary. Every request also sends the original boundary as Slack's `oldest` with `inclusive=false`; exact local comparison governs returned objects and progress, not Slack's own selection. This describes the observed traversal, not an atomic Slack snapshot. Later edits and newly visible messages behind the boundary are not recovered.

The complete output and candidate state are prepared before stdout. Successful output permits atomic publication, increasing the generation even for an empty read. Exit zero means output succeeded and progress was saved; it does not prove downstream consumption. Failed output can be partial and leaves progress unchanged. A failed publication can follow useful complete output, reports unsaved progress on stderr and exits nonzero; retrying can repeat those messages. Cancellation after publication can leave advanced state despite a nonzero exit. The output describes delivery and does not claim that publication succeeded.

A failed initialization before publication leaves no reader, so retry with the address and boundary. Once the record exists, use the continuation form. One stable per-reader lock covers state inspection, traversal, stdout and publication. Contention fails promptly as busy. A blocked consumer holds only that reader's lock; other readers and credential replacement remain independent.

## Watch a Reader

```sh
bin/postcard --account widgets watch --reader workshop --interval 15
```

Watch requires an existing named reader and runs in the foreground. It probes immediately, then waits the interval after each completed observation. The interval is a positive whole number of seconds, defaults to 15, and must fit the native centisecond timer. Each request asks for 100 messages. Watch follows empty or nonqualifying continuation pages and stops at the first completely validated page containing a timestamp strictly newer than the reader's boundary, using the reader's exact decimal comparison.

Add `--slug workshop` to avoid ringing solely for messages sent by that window with `post --slug workshop`. Exact local receipts establish which messages were sent; Slack card text, the Slack user, `--where`, the reader name and the environment do not. Distinct windows sharing local state must supply distinct slugs; reusing a slug shares the association. Names preserve the same 1–64-character single-line UTF-8 spelling accepted by post, without normalization. Omit the slug for ordinary notifications.

With a slug, watch follows pages containing only proven own messages and empty continuing pages until it reaches an eligible outside message or the terminal page. A quiet observation leaves progress and pending unchanged and continues polling from the saved boundary. The next reader result still includes own messages. Missing, malformed or late receipts can cause extra bells, never omitted content; a receipt arriving after a bell does not retract it or release pending. Receipt publication and Slack visibility have no shared lock. Repeated traversal of an own-message backlog continues until a real read advances progress.

A qualifying observation writes one LF-terminated stdout line:

```text
You have messages: `postcard --account widgets thread --reader workshop`.
```

After successfully writing the bell, watch checks local reader state at the same interval without making more Slack requests. A changed published generation permits another probe at that inspection. An empty successful read advances generation and therefore rearms watch; a failed read that leaves the record unchanged does not. Cancellation after a reader has published can rearm watch despite that read's nonzero exit. Watch never takes a reader lock or writes progress.

The selected account, client, workspace, user and exact thread address stay pinned. A probe takes a fresh grant for that same identity and holds it and the original boundary through pagination. Adding another account cannot change an implicit initial selection; rebinding an alias cannot redirect watch. Missing, malformed or retargeted reader state fails visibly. Credentials are not renewed.

A reader publication during a probe discards its observation and takes the ordinary delay. Publication can still race notification output, so a bell may lead to an empty read. The pending generation always belongs to the completed probe. Restarts and concurrent watches may repeat bells; there is no persistent pending flag, reminder or delivery acknowledgement.

Muster can carry the foreground bell to a standing window. Use this instead of starting a separate watch:

```sh
muster monitor --slug workshop -- \
    postcard --account widgets watch --reader workshop --slug workshop
```

Stdout carries bells only; diagnostics go to stderr. Supported cancellation and failed output stop and reap owned work and remove private scratch. The transport and throttling policy is still under shared-interface review; this checkout currently propagates existing page-helper failures. Cross-machine acceptance remains open until the shipped command has been exercised in both directions.

## Post a Card

```sh
printf '%s\n' 'The review is ready.' | \
    bin/postcard --account widgets post --model Codex --user U012ABC3456

printf '%s\n' 'The shipment is confirmed.' | \
    bin/postcard --account widgets post --model Codex \
        --channel C0123456789 --ts 1700000000.000000

printf '%s\n' 'The shipment is confirmed.' | \
    bin/postcard --account widgets post --model Codex --alias planning
```

Post reads its body from stdin and requires exactly one destination: `--alias` resolves an exact saved thread, `--channel` names an exact conversation ID and `--user` names an exact user ID and deliberately opens that person's DM. It accepts no human names, permalinks or positional destinations. The required `--model` label is 1 through 64 letters, numbers, spaces, dots, slashes, underscores or hyphens, starting with a letter or number.

Before sending, `auth.test` must confirm the saved workspace and user. Post then reads that sender's profile for a presentation name, using display name, real name, username or finally user ID. A context line such as `Jane Doe's Codex, from Postcard` sits beside an open-mailbox mark, with dividers around a [Markdown block](https://docs.slack.dev/reference/block-kit/blocks/markdown-block/). These labels are attribution, not authority. The body must be valid UTF-8, contain 1 through 12,000 characters and contain no NUL. Trailing newlines remain intact. The escaped context and fallback must also fit Slack's 3,000- and 40,000-character limits; oversized content is rejected rather than split. The fallback carries the body and attribution for notifications and screen readers.

Optional `--slug` and `--where` labels preserve which window and machine spoke when rereading an inter-machine conversation. Slug names the composing window. Where is the computer's conversational pet name, such as `harbor`, rather than a DNS or fully qualified hostname; it is never taken automatically from the environment or hostname.

```sh
printf '%s\n' 'The review is ready.' | \
    bin/postcard --account widgets post --model Codex --alias planning \
        --slug workshop --where harbor
```

Both labels add “— in workshop on harbor” after the mailbox; either alone gives “— in workshop” or “— on harbor”. The aside is quiet, upright, non-bold plain text, preserving literal underscores and markup-shaped names. The existing bold attribution and dividers remain intact. With neither option, the card is unchanged. The accessible fallback includes the same origin information. Each explicit label must contain 1–64 valid UTF-8 characters on one line without control characters. The local invocation's `--slug` also associates its confirmed receipt with that window for watch; `--where` remains presentation.

For a user destination, `conversations.open` must return a DM with that exact recipient. A channel destination needs no conversation lookup unless `--ts` supplies a thread parent. Then one bounded `conversations.replies` request must return that parent itself, without a conflicting `thread_ts`. An empty page, reply timestamp, unavailable parent or missing history scope stops the write. Post never corrects an address and writes somewhere else. This check cannot prevent the parent from changing at Slack between validation and sending.

Post makes at most one `chat.postMessage` attempt. A confirmed send returns a receipt with the checked account identity, actual message address, nullable thread parent, returned sender and permalink:

```json
{
  "account": "widgets",
  "team_id": "T0123456789",
  "user_id": "U0123456789",
  "channel": "C0123456789",
  "ts": "1700000000.000003",
  "thread_ts": "1700000000.000000",
  "sender": "U0123456789",
  "permalink": "https://widgets.slack.com/archives/C0123456789/p1700000000000003?thread_ts=1700000000.000000&cid=C0123456789"
}
```

The complete send response is checked before stdout. Returned message identity and timestamp facts must agree; a reply must include its confirmed parent. `sender` is null when Slack omits the message user. A top-level post has `thread_ts: null`. One best-effort `chat.getPermalink` lookup follows the confirmed send. If it fails, the command still succeeds with `permalink: null` and a warning. A missing permalink is never a reason to repost.

Before permalink lookup or stdout, every confirmed send publishes a private immutable local record under `${XDG_STATE_HOME:-$HOME/.local/state}/postcard/sent/`. It records the checked sending client/workspace/user, exact channel/message/parent coordinates, and optional slug, without the grant, body or card. Evidence is independent of account aliases and retained across reads and restarts. A window may watch through another account in the same workspace. Receipt preparation or publication failure warns on stderr while preserving the ordinary confirmed-send result; missing proof may cause an own-post bell. There is no automatic retry, receipt management command or pruning policy.

Exit status 0 means a validated receipt; 1 means a failure before sending or a known Slack rejection. Status 4 means delivery is uncertain or Slack reported a post whose receipt could not be confirmed. Failures leave stdout empty. A transport failure, malformed response, or unfamiliar write error may follow delivery; Slack also documents possible partial success for `internal_error` and `fatal_error`. Inspect Slack before repeating a status-4 command. No request is retried automatically. See Slack's [chat.postMessage contract](https://docs.slack.dev/reference/methods/chat.postMessage/).

## Accounts and Credentials

Search, thread, post and watch may omit `--account` only when exactly one saved credentials entry exists. Broken and expired files still count; unfinished directories without credentials do not. Search, thread and post read one complete grant per invocation without taking the login lock; watch reads one per probe. A concurrent login replacement does not change an in-flight observation's token or identity. These commands do not write credentials or renew tokens. An expired or rejected grant produces a login command with the saved account and client ID. Search, thread and post do not retry requests; watch's transport policy remains under review.

Thread's required history scope depends on the conversation. A Slack scope error requires authorizing the needed access; the command does not require every history scope before making the request.

## Files

Each account's grant is stored in `~/.config/postcard/accounts/NAME/credentials.json`. Its aliases are stored beside it in `aliases.json`. Storage directories have mode 0700 and both files have mode 0600; credentials are plaintext.

`XDG_CONFIG_HOME` can override the configuration root. Login holds a native Zsh lock at `${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/NAME/login.lock` from before browser authorization through credential installation. Another login for that account fails as busy; the lock file remains after release.

Readers store versioned records at `${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/ACCOUNT/readers/NAME.json`, with stable sibling `NAME.lock` files. Records use mode 0600 in private directories and contain the exact address, identity binding, delivered-through timestamp and generation. Staging is private and removed on ordinary returns and supported cancellation paths. Uncatchable termination can leave ignored staging files; they do not establish a reader. Generations use exact JSON integers; exhausting that range refuses the read before output.

Login saves the client, workspace and user IDs, user access token, and granted scope string. Rotating grants also retain their refresh token and absolute access-token expiry. Reauthorization must match the saved IDs. A failed login before installation leaves the existing credentials unchanged; this cannot reverse an exchange already performed by Slack. Installation uses a private staging file in the account directory and an atomic rename. An uncatchable termination can leave that staging file behind.

If a grant expires or Slack rejects it, authorize again with `bin/postcard --account widgets login --client-id 0000000000.0000000000`, using the saved account's client ID.

## Planned Commands

The current checkout provides login, search, alias, thread, watch and post. Directory search remains planned; the following fictional example describes that future operation.

### Find a Person

Message search finds messages, not people. To discover an exact Slack user ID from profile names, search the selected account's directory:

```console
$ bin/postcard --account widgets people --query 'Casey Lee' |
    jq '.candidates[] | {id, username, display_name, real_name, matched}'
{"id":"U012ABC3456","username":"casey.lee","display_name":"Casey","real_name":"Casey Lee","matched":["real_name"]}
```

`people` traverses every cursor page returned by `users.list`, then performs a Unicode-aware, case-insensitive match against username, display name and real name. Exact field matches sort before partial matches. The default output bound is 20 candidates; `--count N` accepts 1 through 100. `matched_count`, `returned` and `truncated` distinguish the complete match set from the bounded candidates array. No partial result is printed when a later directory page fails.

Candidates include exact IDs and Slack's deletion, bot, application and guest status facts. No email field is requested or returned. The command never chooses a candidate, opens a conversation or posts. Refine an ambiguous or truncated query, inspect the returned facts, then pass the selected exact ID to `post`:

```sh
printf '%s\n' 'The review is ready.' | \
    bin/postcard --account widgets post --model Codex --user U012ABC3456
```

`post` opens the exact user's direct conversation through Slack. It does not accept a profile name as a destination.

## Tests

```sh
zsh test/all.zsh
```

The Zsh tests use fictional Slack endpoints and local TCP callbacks. They cover login, account selection, credential snapshots, alias storage and resolution, literal search and thread results, durable-reader traversal, decimal boundaries, per-reader locks, watch cadence and pending generations, publication and credential races, blocked and broken stdout, output and publication failures, cancellation, parent assertions, card construction, posting identity, uncertain delivery, expiry, request failures, and secret handling. No live Slack authorization or posting is needed.

## See Also

[App manifest](slack-manifest.json), [zshctl](https://github.com/flatheadmill/zshctl), Slack's [manifest reference](https://docs.slack.dev/reference/app-manifest/) and [PKCE documentation](https://docs.slack.dev/authentication/using-pkce/).

```sh
bin/postcard --help
bin/postcard login --help
bin/postcard search --help
bin/postcard alias --help
bin/postcard thread --help
bin/postcard watch --help
bin/postcard post --help
```
