# desc
Search one page of Slack messages.
# opt query -- < query >
The required Slack search query, passed unchanged. Quote it as one shell argument.
# opt count -- < number >
Results per page, from 1 through 100. Defaults to 20.
# opt page -- < number >
Page number, from 1 through 100. Defaults to 1.
# opt help
Display help for `search`.
# man
## DESCRIPTION
Search the selected account with newest messages first. The command makes one
request and returns one JSON page. It does not continue to later pages or look
up profiles and channels. Highlighting is disabled so message text stays literal.

Select an account with `postcard --account NAME search`. With no selector,
exactly one saved account must exist. Broken and expired credential files still
count as accounts; unfinished directories without credentials do not.

Search reads one complete credential snapshot without taking the login lock.
It never changes credentials or renews tokens. An expired grant requires login
again; the error prints the command with the saved client ID.
## OUTPUT
The result contains `account`, `team\_id`, `user\_id`, `query`, `paging`, and
`matches`. The outer identifiers come from the stored grant. Paging contains
`count`, `page`, `pages`, and `total`, as reported by Slack.

Each match contains `channel`, `ts`, `thread\_ts`, and `text`. Timestamps stay
strings, text is unchanged, and an absent thread parent is null. An empty search
has an empty matches array. Request and validation failures leave stdout empty.

Search results reflect Slack's search behavior and filters; they are not an
exhaustive conversation history. More results may exist beyond this page.
## OPTIONS
> options
