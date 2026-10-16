# desc
Name an exact Slack thread within the selected account.
# opt permalink -- < url >
Bind to a Slack message permalink's parent address.
# opt channel -- < id >
Exact conversation ID. Requires --ts.
# opt ts -- < parent >
Exact parent timestamp. Requires --channel.
# opt delete
Remove the named alias.
# opt help
Display help for `alias`.
# man
## DESCRIPTION
With no name, list aliases. With a name alone, inspect it. Supply either a
permalink or an exact channel and parent timestamp to bind or replace the
name. Supply --delete to remove it.

Names contain 1 through 64 lowercase ASCII letters, numbers, dots,
underscores or hyphens and begin with a letter or number. Aliases are local
configuration beneath the selected account. The file is bound to that
account's saved client, workspace and user identity.

Alias operations make no Slack request, require no unexpired token, renew no
grant and infer no address.
A permalink's thread_ts is preferred. Without one, the permalink's message
timestamp is stored as an asserted parent; thread and post check that claim
when Slack evidence is required.
## OUTPUT
Every result identifies the account, workspace and saved user. Listing returns
a name-sorted aliases array. Inspecting and binding return the exact name,
channel and parent timestamp. Deleting returns the removed address with
deleted set to true.

Updates are serialized with a stable private lock and replace aliases.json
atomically. Rebinding a name does not alter future reader progress, which is
separate runtime state keyed by exact thread address.
## EXAMPLES
```sh
postcard --account widgets alias planning \
    --permalink 'https://widgets.slack.com/archives/C0123456789/p1700000000000002?thread_ts=1700000000.000000'
postcard --account widgets alias planning
postcard --account widgets alias
postcard --account widgets alias planning --delete
```
## OPTIONS
> options
