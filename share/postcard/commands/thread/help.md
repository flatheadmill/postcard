# desc
Retrieve Slack thread pages or advance a named reader.
# opt alias -- < name >
An account-local exact thread alias. Replaces --channel and --ts.
# opt channel -- < id >
An exact conversation ID. Requires --ts.
# opt ts -- < parent >
A parent timestamp, passed as a decimal string. Requires --channel.
# opt count -- < number >
Requested messages per page, from 1 through 100. Defaults to 20.
# opt reader -- < name >
Read every continuation and save progress under an account-local name.
# opt cursor -- < token >
Slack's opaque pagination token. Cannot accompany --reader. An empty value is rejected.
# opt after -- < timestamp >
An exclusive lower timestamp bound. Required when creating a reader; omitted thereafter.
# opt help
Display help for `thread`.
# man
## DESCRIPTION
Retrieve a thread using the selected account's Slack user grant. Without
--reader, the command makes one request and returns one JSON object. Count
is a per-request bound; Slack may return fewer messages while still providing
a continuation. A reader follows every continuation before returning.

Select the account before the command with `postcard --account NAME thread`.
With no selector, exactly one saved credentials entry must exist, including
broken or expired entries. Thread quietly renews a due grant before taking
one access snapshot for its entire traversal. Only renewal takes the shared
login lock. Renewal trouble warns while unexpired access remains usable.
Thread requests are not retried.

Select exactly one address form: --alias, or --channel with --ts. An alias is
resolved once from the selected account's configuration. An existing reader
instead uses its saved address and rejects address arguments and --after.
The output always contains the resolved channel and parent timestamp.

The channel and parent timestamp are exact addresses. If a returned message
exposes a different nonempty parent timestamp, the command fails and reports
that parent. A filtered, empty, or continuation page may lack parent evidence.
A search result's `thread\_ts` is preferred; an absent value does not prove
that its message timestamp names a parent.
## OUTPUT
An ordinary page contains `account`, `team\_id`, `user\_id`, `channel`, `ts`,
`after`, `paging`, and `messages`. The outer identity comes from the saved grant.
After is null when omitted. Paging contains requested `count` and nullable
`cursor`, and Slack's `next\_cursor`, normalized to null at the end.

Messages retain their original objects, fields, order, and timestamp strings.
There is no profile lookup, rendering, sorting, deduplication, or inferred
total. The whole page is validated before output; request and validation
failures leave stdout empty.
## CONTINUATION
Repeat the same account, channel, parent, count, and any after boundary with
`--cursor` set to the returned `next\_cursor`. A short or empty messages array
can still have a next page. More data without a usable cursor is an error.
When the first invocation uses an alias, continue with the resolved account,
channel, and parent timestamp from its output rather than resolving the mutable
alias again.

A terminal cursor ends this query's reported continuation, not an atomic
snapshot of a conversation. Cursors expire and are not durable progress.
After alone selects one page and does not advance a checkpoint.
## DURABLE READERS
Create a reader with --reader NAME, an address and an explicit --after boundary
chosen from observed timestamps. Continue with just --reader NAME. Names use
1 through 64 lowercase letters, numbers, dots, underscores or hyphens, starting
with a letter or number. The name belongs to the selected account.

The reader saves the exact address and client, workspace and user binding.
Rebinding an alias cannot redirect it. There is no reset or retarget operation.
An initial failed traversal leaves no reader; retry with the initialization
arguments. Once its record exists, use the continuation form.

Every request uses one grant snapshot and the original lower boundary. Short
and empty continuing pages are followed; repeated cursors and malformed or
failed later pages refuse the whole traversal before output. Count remains
the page size, not a total cap. Traversal cost and final JSON assembly memory
can grow with the complete result.

Reader output contains `account`, `team\_id`, `user\_id`, `reader`, `channel`,
`ts`, `generation`, `after`, `through`, and `messages`. Generation is the
starting generation, zero on initialization. After is the input boundary.
Messages strictly exceed that boundary by exact decimal value, preserving
their complete objects, page order, duplicates and timestamp spelling.
Through is the first observed spelling of the maximum delivered timestamp,
or the unchanged input boundary for an empty result.

Each request also passes the original boundary as Slack's oldest with
inclusive=false. Exact local comparison governs returned objects and progress;
it does not independently establish Slack's own timestamp selection.

Progress lives at `$XDG_STATE_HOME/postcard/accounts/ACCOUNT/readers/NAME.json`,
defaulting to `~/.local/state` when the variable is unset. A stable sibling
NAME.lock serializes inspection, traversal, output and publication. Contention
fails promptly as busy. A blocked consumer holds only that reader's lock.

The complete output and candidate state are prepared privately before stdout.
Successful output permits atomic publication, increasing the generation even
for an empty read. Exit zero means output succeeded and progress was saved;
it does not prove downstream consumption. Failed output may be partial and
does not advance progress. Failed publication can follow useful complete
output: stderr reports unsaved progress and the command exits nonzero. Retrying
can repeat messages. Cancellation after publication may leave advanced state.
The output describes delivery and does not claim that publication succeeded.

Reader files use mode 0600 in private directories. Supported cancellation paths
remove working files. Uncatchable termination can leave ignored staging files.
Generations use exact JSON integers; exhausting that range refuses publication
before output. Slack pagination is an observed traversal, not an atomic snapshot;
later edits and newly visible messages behind the boundary are not recovered.
## OPTIONS
> options
