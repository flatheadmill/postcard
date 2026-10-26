# desc
Renew due Slack grants in one pass.
# opt help
Display help for `renewer`.
# man
## DESCRIPTION
Visit every saved account, or only the root `--account` selection. Renew grants
with less than one hour remaining. Nonrotating and not-due grants are no-ops.
Successful renewal is quiet. An empty inventory also succeeds quietly.

Failures are reported on stderr without preventing other accounts from being
visited. Exit nonzero when any account still needs maintenance. A busy login
is not waited out. Uncertain refresh outcomes require a new checked login;
the old refresh token is never replayed.

Cron or launchd may invoke this command every fifteen minutes. This command
does not install a schedule or remain running. PKCE refresh tokens expire
after thirty days; a machine left unused may need login again.
## OPTIONS
> options
