function :help:account:list {
    heredoc -v help <<'    EOF'
        # desc
        List saved accounts and their local credential states as JSON.
        # opt help
        Display help for `account list`.
        # man
        ## DESCRIPTION
        Returns an accounts array with names, stored public identities and
        ready, expired, refresh-uncertain or error state. Ready describes the
        local record; it is not a live authentication check. Broken entries
        remain visible. Empty directories are ignored. No grant is refreshed.
        ## OPTIONS
        > options
    EOF
}

function :args:account:list {
    typeset parsed
    parsed=$(args -bx h,help -- "$@") || return
    eval "$parsed"
}

function :execute:account:list {
    (( $# == 0 )) || abend 'fatal: account list takes no arguments'
    postcard_session postcard_account_list
}
