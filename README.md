# Postcard

Postcard lets a model search, read, retrieve documents from, and post to Slack
through the account of the person it is working with. Messages carry an
attribution such as "Member's Codex, via Postcard."

The implementation uses Zsh, zshctl, curl, and jq. Directory choices and
dependencies are explicit. Users can adapt their own copies as they would
dotfiles.

The first CLI provides `login`, `whoami`, `post`, and `read`. The Slack app is
defined by [the manifest](slack-manifest.json). Local tests use fictional Slack
responses.

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
sender; it refuses a nearby message when the exact timestamp is absent. Search,
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
reads. They send no Slack messages and require no credentials. Linux and real
Slack behavior still need to be exercised on the participants' machines.

Slack documents the [manifest format](https://docs.slack.dev/reference/app-manifest/),
[manifest creation workflow](https://docs.slack.dev/app-manifests/configuring-apps-with-app-manifests/),
and [PKCE behavior](https://docs.slack.dev/authentication/using-pkce/).
