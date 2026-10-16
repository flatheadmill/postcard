# desc
Retrieve one page of a Slack thread.
# opt alias -- < name >
An account-local exact thread alias. Replaces --channel and --ts.
# opt channel -- < id >
An exact conversation ID. Requires --ts.
# opt ts -- < parent >
A parent timestamp, passed as a decimal string. Requires --channel.
# opt count -- < number >
Requested messages per page, from 1 through 100. Defaults to 20.
# opt cursor -- < token >
Slack's opaque pagination token. An explicitly empty value is rejected.
# opt after -- < timestamp >
An exclusive lower timestamp bound for this page. Repeat it when continuing.
# opt help
Display help for `thread`.
# man
## DESCRIPTION
Retrieve one page using the selected account's Slack user grant. The command
makes one request and returns one JSON object. Count is a requested bound;
Slack may return fewer messages while still providing a continuation.

Select the account before the command with `postcard --account NAME thread`.
With no selector, exactly one saved credentials entry must exist, including
broken or expired entries. Thread reads one grant snapshot without taking the
login lock. It never renews tokens, writes credentials, or retries a request.

Select exactly one address form: --alias, or --channel with --ts. An alias is
resolved once from the selected account's configuration before the request.
The output always contains the resolved channel and parent timestamp.

The channel and parent timestamp are exact addresses. If a returned message
exposes a different nonempty parent timestamp, the command fails and reports
that parent. A filtered, empty, or continuation page may lack parent evidence.
A search result's `thread\_ts` is preferred; an absent value does not prove
that its message timestamp names a parent.
## OUTPUT
The result contains `account`, `team\_id`, `user\_id`, `channel`, `ts`, `after`,
`paging`, and `messages`. The outer identity comes from the saved grant. After
is null when omitted. Paging contains requested `count` and nullable `cursor`,
and Slack's `next\_cursor`, normalized to null at the end.

Messages retain their original objects, fields, order, and timestamp strings.
There is no profile lookup, rendering, sorting, deduplication, or inferred
total. The whole page is validated before output; failures leave stdout empty.
## CONTINUATION
Repeat the same account, channel, parent, count, and any after boundary with
`--cursor` set to the returned `next\_cursor`. A short or empty messages array
can still have a next page. More data without a usable cursor is an error.
When the first invocation uses an alias, continue with the resolved account,
channel, and parent timestamp from its output rather than resolving the mutable
alias again.

A terminal cursor ends this query's reported continuation, not an atomic
snapshot of a conversation. Cursors expire and are not durable progress.
After selects one page and does not advance a checkpoint. The name `--reader`
is reserved for future durable progress and is not accepted here.
## OPTIONS
> options
