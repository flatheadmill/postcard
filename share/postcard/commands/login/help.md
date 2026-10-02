# desc
Open Slack authorization in your browser.
# opt client-id
The Slack app's public Client ID.
# opt help
Display help for `login`.
# man
## DESCRIPTION
Open Slack's consent page in the default browser and wait for one
callback at `http://localhost:8765/auth`.

The callback must return the state sent to Slack and exactly one authorization
code or error. This command currently verifies the callback only. Token
exchange and saving the grant are not yet implemented.
## OPTIONS
> options
