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

Before posting, Postcard checks the live identity and constructs the card, here `Jane Doe's Codex, via Postcard`. It never retries a post automatically. If the send result is lost, inspect Slack before repeating the command.

## Files

Each account's grant is stored in `~/.config/postcard/accounts/NAME/credentials.json`. Storage directories have mode 0700 and credential files have mode 0600; credentials are plaintext. `POSTCARD_DIRECTORY` changes the storage root, not the selected account.

`whoami`, `search`, `read`, and `post` may omit `--account` only when exactly one saved account exists.

If renewal is interrupted or uncertain, authorize again with `bin/postcard --account widgets login`.

## Tests

```sh
python3 -m unittest discover -s test -v
```

Fake Slack handles every Slack request with fictional grants; the tests exercise the real loopback callback.

## See Also

[App manifest](slack-manifest.json), [zshctl](https://github.com/flatheadmill/zshctl), Slack's [manifest reference](https://docs.slack.dev/reference/app-manifest/) and [PKCE documentation](https://docs.slack.dev/authentication/using-pkce/).

```sh
bin/postcard --help
bin/postcard account --help
bin/postcard login --help
bin/postcard search --help
bin/postcard read --help
bin/postcard post --help
```
