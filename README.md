# Postcard

Postcard lets a model search, read, retrieve documents from, and post to Slack
through the account of the person it is working with. Messages carry an
attribution such as "Member's Codex, via Postcard."

The implementation uses Zsh, zshctl, curl, and jq. Directory choices and
dependencies are explicit. Users can adapt their own copies as they would
dotfiles.

The CLI provides `login`, `whoami`, `search`, `post`, and exact `read`. The Slack
app is defined by [the manifest](slack-manifest.json). Local tests exercise
fictional Slack responses, including empty search results and DM matches.

Run it directly from the working copy. Dependencies are `zshctl`, `curl`, `jq`,
`openssl`, and `python3` on PATH. Python's standard library provides the
temporary callback listener; OAuth exchange, renewal, and commands are in Zsh.
Browser opening uses `open` on macOS and `xdg-open` on Linux.

```zsh
cd postcard
bin/postcard login --client-id YOUR_PUBLIC_CLIENT_ID
bin/postcard whoami
```

Complete the consent page in the browser. Login reports the verified account,
workspace, granted scopes, and lifetime as JSON. Later `bin/postcard login`
invocations reuse the Client ID saved with the grant. `--no-browser` prints
the URL and waits for you to open it yourself. The listener lasts at most five
minutes and closes after the callback, denial, timeout, or interruption.

Search one page with an exact query string:

```zsh
bin/postcard search --query 'splendid'
bin/postcard search --query 'splendid' --count 5 --page 2
bin/postcard search --query='-excluded term'
```

Supply `--query` exactly once, quoted as one argument. Empty or whitespace-only
queries and positional arguments are rejected. Query text is sent unchanged,
including Unicode, leading hyphens, delimiters, and newlines. `--count` defaults
to 20 and `--page` to 1; both accept only decimal integers from 1 through 100,
without leading zeros, signs, or fractional notation.

Each invocation makes one `search.messages` request, plus a credential refresh
if needed. It sorts by timestamp descending and disables highlights. Repeat
the query with another explicit page to continue. Search does not automatically
retry, fetch more pages, or look up profiles for the result's senders. The bound
is a number of matches, not a byte or model-token budget.

The JSON envelope looks like this (all identities and text here are fictional):

```json
{
  "team": {"id": "T123ABC", "name": "Workshop"},
  "user": {"id": "U123ABC", "name": "Robin", "username": "robin"},
  "query": "splendid",
  "requested_query": "splendid",
  "text_format": "slack",
  "sort": "timestamp",
  "sort_dir": "desc",
  "pagination": {
    "page": 1, "per_page": 20, "returned": 1, "total": 1, "pages": 1,
    "has_more": false, "next_page": null
  },
  "matches": [{
    "channel": "D123ABC",
    "channel_name": "U456DEF",
    "ts": "1700000000.000002",
    "thread_ts": null,
    "sender": "U456DEF",
    "permalink": "https://workshop.slack.com/archives/D123ABC/p1700000000000002",
    "text": "Splendid &amp; <@U456DEF> *Slack text*",
    "type": "im",
    "subtype": null,
    "bot_id": null,
    "app_id": null
  }]
}
```

`team` and `user` describe the stored authorization context, without a fresh
identity lookup. `requested_query` is the exact input; `query` is Slack's echo
and is null if Slack supplies no usable string. Each match requires a C, D, or
G conversation ID and an exact timestamp. Optional absent or unusable values
are null. `text` stays literal Slack text inside JSON: there is no entity
decoding, Markdown rendering, mention enrichment, or card classification.

`per_page` uses Slack's `pagination.per_page` when supplied, otherwise the
requested count. The legacy `paging.count` is not treated as capacity: an
empty result can report it as zero while `pagination.per_page` is five.
`returned` is the actual matches length. Reported total, page, and page-count
fields are reconciled across Slack's response shapes; conflicting values or
invalid metadata fail the whole result. Unknown totals and page counts remain
null. `has_more` and `next_page` are null when metadata does not establish
continuation; page 100 has no `next_page` even if more results are reported.
Empty results succeed. Malformed matches or more matches than requested fail
without printing partial JSON.

Use a match's `channel` and `ts` as the operands to `read`. An explicit
`thread_ts` can be passed as `--thread PARENT_TIMESTAMP`. A null `thread_ts`
means unknown parentage, so a reply may need its parent address before exact
read can retrieve it. Search does not infer parents from permalinks or scan
conversations to find them. Search is discovery, not a complete transcript:
Slack's [search documentation](https://docs.slack.dev/reference/methods/search.messages/)
notes that user search filters affect results and nearby matches may be grouped.

When ready to send a first message, open your self-DM in Slack and run:

```zsh
print -r -- 'First contact.' | bin/postcard post --model Codex self
```

The result contains the actual conversation ID, timestamp, sender, card, and
permalink. Use that conversation ID and timestamp to read it back:

```zsh
bin/postcard read D0123456789 1700000000.000002
```

These are example addresses; use the values returned by your post. `post`
also accepts an exact conversation ID or a user's Slack ID. `self` looks up
the existing self-DM by its participant ID. If Slack does not list it, use its
exact conversation ID. Add `--thread PARENT_TIMESTAMP` to either `post` or
`read` for a reply. Messages begin with the verified profile name and model,
for example `Robin's Codex, via Postcard`. The card is attribution, not proof
of who composed the text.

This first post command accepts plain text, escapes Slack's control characters,
disables formatting and unfurls, and limits the message plus card to 4,000
characters. `read` returns Slack's message fields as JSON, including the actual
sender; it refuses a nearby message when the exact timestamp is absent. Bounded
thread navigation, aliases, document pickup, and richer rendering follow later.

The CLI never retries a post automatically. A lost response may mean the message
was sent; inspect Slack before repeating it. If posting succeeds but permalink
lookup fails, the command still returns the posted address and a null permalink.

To create the Slack application:

1. Open [Your Apps](https://api.slack.com/apps) and choose **Create New App**,
   then **From a manifest**.
2. Select the workspace in which we will collaborate.
3. Choose JSON, paste `slack-manifest.json`, review the settings, and create
   the app.
4. Record the **Client ID** from **Basic Information**. This is a public
   identifier that the login command uses. The PKCE flow does
   not require putting a Slack client secret on the workstation.

The manifest registers `http://localhost:8765/auth`. Login starts a listener
bound to `127.0.0.1:8765` before opening Slack's authorization page. The callback
checks the path and state. Creating the Slack app does not complete a login.

The requested permissions cover the intended command surface:

| User scopes | Purpose |
| --- | --- |
| `search:read` | Search messages. |
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | Read public channels, private channels, direct messages, and group direct messages through the user's grant. |
| `channels:read`, `groups:read`, `im:read`, `mpim:read` | Resolve and describe conversation addresses. |
| `users:read`, `usergroups:read` | Resolve author identities and mentions. |
| `chat:write` | Post messages as the authorizing user. |
| `im:write` | Open or resume direct conversations. |
| `files:read`, `files:write` | Inspect, retrieve, upload, and share documents. |

These scopes are requested configuration. Successful authorization and live
operations still have to prove the installed grant. Each participant will
authorize their own account.

PKCE is enabled, and only user scopes are requested. Slack treats this
localhost redirect as a desktop redirect, which cannot request bot scopes.
Enabling PKCE marks the Slack app as a public client; changing it back requires
Slack support. Use this manifest for the new Postcard app.

The initial manifest leaves token rotation off. Login preserves the actual
expiry and refresh fields. If Slack returns an expiring grant, a command renews
it when fewer than two minutes remain. A file lock serializes credential use
across CLI processes, and complete records are replaced atomically. An
interrupted or uncertain renewal requires a new login. The provider exchange
and local save cannot be one transaction; reauthorization is the recovery path.

The initial credential location is `~/.config/postcard/credentials.json`, in a
mode-0700 directory with a mode-0600 file. Local plaintext storage is the
accepted starting point. DLS, OpenPGP storage, and a persistent local agent can
follow when they are useful.

`POSTCARD_DIRECTORY` selects a different credential directory when needed;
the tests use it to keep their fictional grants isolated. Credentials, refresh
tokens, and callback codes are passed to subprocesses over pipes. Ordinary
output contains only account/grant metadata and requested message data.

Run the local tests with:

```zsh
python3 -m unittest discover -s test -v
```

The tests use a fake browser and fake curl, a real loopback callback, and
fictional Slack identities. They cover PKCE exchange, consent denial, mismatched
state, timeout, interrupted login, preserved credentials, account mismatch,
concurrent renewal, uncertain renewal, self-DM discovery, posting, and exact
reads. Search acceptance cases cover form encoding, local validation, both
paging shapes, unknown and capped continuation, literal text, nullable fields,
atomic failures, and the one-search-request boundary even when renewing a grant.
`test/fixtures/search_empty.json` and `search_dm.json` retain the observed Slack
response structures with fictional IDs and text. The tests require no real
credentials and contact only the temporary loopback callback; fake curl handles
every Slack request. Passing them does not establish live renewal, live
post/read behavior, or compatibility on other systems.

Slack documents the [manifest format](https://docs.slack.dev/reference/app-manifest/),
[manifest creation workflow](https://docs.slack.dev/app-manifests/configuring-apps-with-app-manifests/),
and [PKCE behavior](https://docs.slack.dev/authentication/using-pkce/).
