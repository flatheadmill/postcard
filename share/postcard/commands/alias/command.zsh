function :help:alias {
    heredoc -v help <<'    EOF'
        # desc
        Name an exact Slack thread within the selected account.
        # opt permalink -- url
        Bind to a message permalink's `thread\_ts`, or its asserted parent timestamp.
        # opt channel -- id
        Exact conversation ID. Requires --ts.
        # opt ts -- timestamp
        Exact parent timestamp. Requires --channel.
        # opt delete
        Remove the named alias.
        # opt help
        Display help for `alias`.
        # man
        ## SYNOPSIS
        ```synopsis
        [ALIAS] [--permalink URL | --channel ID --ts TS | --delete]
        ```
        ## DESCRIPTION
        With no name, list aliases. With a name alone, inspect it. Supply an
        address to bind or replace that name, or --delete to remove it.
        Names use lowercase letters, numbers, dots, underscores and hyphens,
        starting with a letter or number. Results are contextual JSON.

        Aliases live in the selected account's aliases.json. They store exact
        channel/parent coordinates and never search Slack, refresh a grant,
        or select another account. A permalink without `thread\_ts` asserts
        that its message is the parent; reading the thread checks that claim
        against the messages actually fetched.
        ## OPTIONS
        > options
    EOF
}

function :args:alias {
    typeset o_request parsed
    if [[ $zshctl[args:mode] != (help|completion) ]]; then
        o_request=$(python3 "$postcard[root]/share/postcard/thread.py" options alias "$@") || return
    fi
    parsed=$(args -@ -bx h,help -b ,delete -s ,permalink ,channel ,ts -- "$@") || return
    eval "$parsed"
}

function :execute:alias {
    postcard_session postcard_alias "$o_request"
}
