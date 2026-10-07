# desc
Authorize and save a Slack user account.
# opt client-id
The Slack app's public Client ID.
# opt help
Display help for `login`.
# man
## DESCRIPTION
Open Slack's consent page in the default browser and wait for one
callback at `http://localhost:8765/auth`.

The callback must return the state sent to Slack and exactly one authorization
code or error. Postcard exchanges the code using PKCE and saves a workspace
user grant. Check the terminal for the final result after the browser callback.

Login requires `--account NAME` before the command. Names contain 1–64 ASCII
letters, digits, dots, underscores or hyphens and start with a letter or digit.
Reauthorizing an existing name must preserve its client, workspace and user IDs.
An incomplete or unrecognized credential file is left untouched.

One login may run per account. The account is locked before opening the browser
and stays locked through credential installation; another login fails as busy.
Failures before installation preserve the existing credential file. They cannot
undo an authorization or exchange already performed by Slack.
## FILES
Credentials are plaintext in `~/.config/postcard/accounts/NAME/credentials.json`.
Set `XDG\_CONFIG\_HOME` to override the `~/.config` root.
Postcard uses private directories and a mode-0600 staging file in the account
directory, then atomically renames the staging file over the credentials.
An uncatchable termination can leave the private staging file behind.

The stable lock file is `~/.local/state/postcard/accounts/NAME/login.lock`.
Set `XDG\_STATE\_HOME` to override the `~/.local/state` root.
It remains in place after the lock is released.
## OPTIONS
> options
