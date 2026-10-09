# Postcard

<img src="artwork/icon.png" width="96" height="96" alt="A postcard">

Postcard searches Slack messages and retrieves thread pages through your own Slack user grant. Commands return JSON for programs and language models; Slack remains the human interface.

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

Each page is a separate observation. A terminal cursor ends that query's reported continuation; it does not establish an atomic snapshot of the thread. Slack cursors expire, so they are temporary continuations rather than durable reading positions. `--after` retrieves one page and never advances saved progress. The name `--reader` is reserved for a future durable checkpoint and is not accepted by this command.

`--ts` asserts the parent; it does not ask Postcard to discover one. If a returned message has a different nonempty `thread_ts`, the command fails and reports that actual parent. A filtered, empty, or continuation page may lack evidence confirming the assertion. Thread requires the direct channel and parent address; permalink parsing and aliases are not part of this interface.

## Accounts and Credentials

Search and thread may omit `--account` only when exactly one saved credentials entry exists. Broken and expired files still count; unfinished directories without credentials do not. Each invocation reads one complete grant without taking the login lock. A concurrent login replacement does not change that invocation's token or identity. Neither command writes credentials, renews a token, or retries a request. An expired or rejected grant produces a login command with the saved account and client ID.

Thread's required history scope depends on the conversation. A Slack scope error requires authorizing the needed access; the command does not require every history scope before making the request.

## Files

Each account's grant is stored in `~/.config/postcard/accounts/NAME/credentials.json`. Storage directories have mode 0700 and credential files have mode 0600; credentials are plaintext.

`XDG_CONFIG_HOME` can override the configuration root. Login holds a native Zsh lock at `${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/NAME/login.lock` from before browser authorization through credential installation. Another login for that account fails as busy; the lock file remains after release.

Login saves the client, workspace and user IDs, user access token, and granted scope string. Rotating grants also retain their refresh token and absolute access-token expiry. Reauthorization must match the saved IDs. A failed login before installation leaves the existing credentials unchanged; this cannot reverse an exchange already performed by Slack. Installation uses a private staging file in the account directory and an atomic rename. An uncatchable termination can leave that staging file behind.

If a grant expires or Slack rejects it, authorize again with `bin/postcard --account widgets login --client-id 0000000000.0000000000`, using the saved account's client ID.

## Planned Commands

The following fictional people and posting examples describe planned commands. The current checkout provides login, search, and thread; it does not yet provide these directory and posting operations.

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
    bin/postcard --account widgets post --model Codex U012ABC3456
```

`post` opens the exact user's direct conversation through Slack. It does not accept a profile name as a destination.

Before posting, Postcard checks the live identity and constructs a Block Kit card. A compact context line names `Jane Doe's Codex, from Postcard` beside the open-mailbox mark; dividers frame the Markdown body. The name comes from the checked Slack display profile and the model comes from `--model`. It never retries a post automatically. If the send result is lost, inspect Slack before repeating the command.

## Tests

```sh
zsh test/all.zsh
```

The Zsh tests use fictional Slack endpoints and local TCP callbacks. They cover login, account selection, credential snapshots, literal search and thread results, pagination, parent assertions, expiry, request failures, and secret handling. No live Slack authorization is needed.

## See Also

[App manifest](slack-manifest.json), [zshctl](https://github.com/flatheadmill/zshctl), Slack's [manifest reference](https://docs.slack.dev/reference/app-manifest/) and [PKCE documentation](https://docs.slack.dev/authentication/using-pkce/).

```sh
bin/postcard --help
bin/postcard login --help
bin/postcard search --help
bin/postcard thread --help
```
