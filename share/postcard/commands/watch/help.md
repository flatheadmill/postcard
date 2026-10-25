# desc
Watch an existing reader and ring when its thread has new messages.
# opt reader -- < name >
An existing account-local reader. Watch never advances its progress.
# opt slug -- < name >
The watching window; ignore its exact locally recorded sends when ringing.
# opt interval -- < seconds >
Positive whole seconds between observations. Defaults to 15.
# opt help
Display help for `watch`.
# man
## DESCRIPTION
Watch a saved reader in the foreground. The first probe is immediate; later
probes follow the interval after the preceding observation finishes. Pages
request 100 messages. Empty continuations are followed; a complete validated
page containing a timestamp strictly beyond the reader boundary rings the bell.
Comparison uses the reader's exact decimal rules.

With --slug, a message proved by an exact local send receipt for that window
does not itself ring. Post must have supplied the same --slug. Distinct windows
sharing local state must use distinct names; reusing a name shares the
association. Names use post's 1–64-character, single-line UTF-8 spelling, with
no normalization. No slug means ordinary notifications. Neither the reader
name, environment, Slack card text nor --where supplies the association.

Watch follows all-own and empty pages to the end before staying quiet. Quiet
does not advance progress or set pending, and the next reader result includes
those messages. Ordinary polling continues from the unchanged boundary so
another window's reply can ring. Missing, malformed or late local proof may
cause an extra bell. A receipt arriving after a bell never retracts it or
releases its pending generation. There is no network-spanning receipt lock.

Stdout contains only LF-terminated instructions, for example:

    You have messages: `postcard --account widgets thread --reader workshop`.

After a bell, watch checks local state at the same interval and makes no more
Slack requests until a different reader generation is published. Even an empty
successful read advances generation. A failed read that leaves state unchanged
does not release the bell. Watch never locks or writes reader progress.

The selected account, client, workspace, user and thread address remain pinned.
Each probe reads a fresh same-binding grant and holds it through pagination.
Missing, malformed or retargeted state fails visibly. Watch does not renew
credentials. A publication during a probe discards that observation and takes
the ordinary delay. A later race can yield a stale hint and an empty read.

Restarts and concurrent watches may repeat notifications. There is no reminder,
durable pending flag or delivery acknowledgement. Muster can carry the bell:

    muster monitor --slug workshop -- postcard --account widgets watch --reader workshop --slug workshop

Cancellation and failed stdout stop owned work and remove private scratch.
Diagnostics go to stderr. Interval must fit the native centisecond timer.
Transport and throttling policy is still under shared-interface review; this
checkout currently propagates the existing page helper's failures.
## OPTIONS
> options
