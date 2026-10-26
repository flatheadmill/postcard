# desc
Search, read, watch and send Slack messages.
# opt account -- < name >
Select the local account name.
# opt help
Display help for `postcard`.
# man
## DESCRIPTION
Postcard is machine-facing Slack tooling for programs and language models.
Login authorizes and saves a local Slack user grant. Search finds messages,
alias names exact account-local threads, and thread retrieves their messages.
Watch rings when a named reader has unread messages, without advancing it.
Post sends a Markdown card to an exact thread, conversation or user.
Retrievals return JSON pages; post returns the sent message's receipt using
your checked Slack identity.

Slack commands quietly renew due grants before taking their access snapshot.
Renewer performs one maintenance pass over saved accounts for a scheduler.
Watch reports credential-health changes and waits for same-account login
when access is unavailable, independently of unread-message notifications.

Slack remains the human interface. Postcard preserves literal message data
and exposes pagination for the caller to continue explicitly.
## OPTIONS
> options
## COMMANDS
> commands
