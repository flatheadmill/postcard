function :help:thread {
    heredoc -v help <<'    EOF'
        # desc
        Read an exact Slack thread projection as structured JSON.
        # opt alias -- name
        Account-local thread alias. Replaces the other address options.
        # opt permalink -- url
        Slack permalink. Uses `thread\_ts` when supplied, otherwise asserts a parent.
        # opt channel -- id
        Exact conversation ID. Requires --ts.
        # opt ts -- timestamp
        Exact parent timestamp. Requires --channel.
        # opt all
        Return every unique message fetched from the thread.
        # opt around -- timestamp
        Exact anchor timestamp; show its nearest reply neighbors.
        # opt from -- timestamp
        Inclusive range start.
        # opt through -- timestamp
        Inclusive range end.
        # opt window -- count
        Replies at each end or on either side of an anchor. Default 8; range 1–100.
        # opt after -- timestamp
        Return every fetched message strictly newer than this exact timestamp.
        # opt cursor -- reader
        Read after this reader's saved position. Initialize with --after.
        # opt help
        Display help for `thread`.
        # man
        ## SYNOPSIS
        ```synopsis
        --alias ALIAS [--after TIMESTAMP]
        --alias ALIAS --cursor READER [--after INITIAL_TIMESTAMP]
        --permalink URL [--around TS --window N | --from TS --through TS | --all]
        --channel ID --ts PARENT_TS [--window N]
        ```
        ## DESCRIPTION
        The default is the parent plus the first and last 8 replies. An ends
        omission records the exact adjacent visible timestamps and count.
        --around includes the anchor and up to N replies on either side;
        the parent body appears only when the parent is the anchor. Range
        endpoints are inclusive, so following an omission repeats its bookends.

        These four context views fetch all cursor pages before projecting.
        They bound output, not Slack calls. --after instead paginates only
        the newer range, excluding the exact boundary locally as well. The
        boundary need not still exist. Empty results succeed with an empty
        messages array. Keep the supplied timestamp after an empty or failed
        read; otherwise advance to the last returned message's ts, never to
        wall-clock time. Older edits, reactions and deletions do not qualify.

        --all, --around, --from/--through and --after are mutually exclusive.
        An explicit --window applies only to ends and around. Timestamps keep
        all six fractional digits. An observed reply used as the parent is
        refused with its exact parent address; there is no extra lookup.

        JSON identifies the account, stored workspace/user, channel, parent
        ts and projection. `fetched\_count` counts unique fetched messages for
        context views and qualifying newer messages for --after. `shown\_count`,
        omission and summary describe the selection. Reaching the terminal
        cursor describes this fetched collection, not an atomic Slack snapshot.
        messages are ascending, with literal Slack text/blocks and sender,
        application, edit and file facts. Duplicate timestamps retain the
        last whole observed payload, without claiming it is the newest edit.
        Selected senders have profiles in the people array; cards are not
        classified as attribution. A failed later page or invalid projection
        emits no partial JSON.

        ## READER CURSORS
        --cursor reads from one saved position for this exact channel and
        parent. The first read requires an explicit --after boundary; an empty
        first read still saves it. Later reads omit --after. Other projections
        cannot be combined with --cursor and do not change reader progress.

        State lives under ~/.local/state/postcard/accounts/ACCOUNT/cursors/READER.json,
        bound to the saved Slack client, team and user IDs. Each exact thread
        has start\_after, after and looks. Cursor names use 1–64 lowercase ASCII
        letters, digits, dots, underscores or hyphens, starting with a letter
        or digit. The cursor object in output names the reader and its starting
        position for this invocation; it does not claim a commit already happened.

        After writing the result successfully, the read retains the greatest
        delivered timestamp and increments the current look count, even on an
        empty result. Concurrent completed reads each count, without moving the
        position backwards. Grant use is serialized, but stdout holds no lock.
        A save failure or interruption after output may repeat messages on the
        next read. Successful stdout does not prove downstream comprehension.
        An entry removed during a read is not recreated. Different explicit
        initial boundaries cannot be merged.
        ## OPTIONS
        > options
    EOF
}

function :args:thread {
    typeset o_request parsed
    if [[ $zshctl[args:mode] != (help|completion) ]]; then
        o_request=$(python3 "$postcard[root]/share/postcard/thread.py" options thread "$@") || return
    fi
    parsed=$(args -bx h,help -b ,all -s ,alias ,permalink ,channel ,ts ,around ,from ,through ,window ,after ,cursor -- "$@") || return
    eval "$parsed"
}

function :execute:thread {
    if [[ -n ${o_cursor:-} ]]; then
        exec python3 "$postcard[root]/share/postcard/runtime.py" "$postcard[root]" read "$o_request" "${postcard[account]:-}"
    fi
    postcard_session postcard_thread "$o_request"
}
