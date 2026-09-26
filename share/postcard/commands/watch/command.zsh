function :help:watch {
    heredoc -v help <<'    EOF'
        # desc
        Ring once per successful reader look when an aliased thread has new messages.
        # opt alias -- name
        Account-local thread alias. Required.
        # opt cursor -- reader
        Initialized reader for this exact thread. Required.
        # opt interval -- seconds
        Positive whole seconds between probes or local cursor checks. Default 30.
        # opt help
        Display help for `watch`.
        # man
        ## SYNOPSIS
        ```synopsis
        --alias ALIAS --cursor READER [--interval SECONDS]
        ```
        ## DESCRIPTION
        First initialize with `thread --alias ALIAS --cursor READER --after TS`.
        Watch prints one LF-terminated instruction naming the selected account,
        alias and cursor when Slack has a message after the saved timestamp.
        It prints no Slack content, resolves no profiles, and changes no cursor.
        It follows pagination only until it finds a qualifying message or the end.

        A hint suppresses further Slack probes until a successful cursor read,
        including an empty read, changes this thread's look count. Other threads
        do not release the hint. Restarting watch forgets the last look rung and
        may repeat a hint. An accepted hint that was never acted on can be
        recovered by restarting watch. There is no reminder timer.

        Transport failures and temporary Slack server errors defer the next
        probe. Rate limiting honors Retry-After, with a 60-second fallback.
        Invalid responses, inaccessible threads, bad state or identity, and
        uncertain OAuth renewal terminate. Diagnostics stay on stderr.

        Watch stays in the foreground. INT, TERM and HUP stop its workers.
        Locks cover grant use and state changes, never output or waiting between
        probes. Sleep/resume catches up from the saved position after resuming;
        this command does not wake a sleeping computer or restart itself.

        `muster monitor --slug workshop -- postcard --account widgets watch --alias planning --cursor workshop`
        forwards its records as nudges to a standing window. Own Slack posts are
        activity too. Edits and deletions of older messages are not new messages.
        ## OPTIONS
        > options
    EOF
}

function :args:watch {
    typeset o_request parsed
    if [[ $zshctl[args:mode] != (help|completion) ]]; then
        o_request=$(python3 "$postcard[root]/share/postcard/thread.py" options watch "$@") || return
    fi
    parsed=$(args -bx h,help -s ,alias ,cursor ,interval -- "$@") || return
    eval "$parsed"
}

function :execute:watch {
    exec python3 "$postcard[root]/share/postcard/runtime.py" "$postcard[root]" watch "$o_request" "${postcard[account]:-}"
}
