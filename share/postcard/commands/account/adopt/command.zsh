function :help:account:adopt {
    heredoc -v help <<'    EOF'
        # desc
        Move legacy credentials unchanged into a named account.
        # opt help
        Display help for `account adopt`.
        # man
        ## SYNOPSIS
        postcard account adopt NAME
        ## DESCRIPTION
        Takes the legacy and destination locks and renames credentials.json
        into accounts/NAME without rewriting its bytes or refreshing the
        grant. An occupied destination is refused. The move must be atomic;
        there is no copy fallback. The legacy lock file remains in place.
        ## OPTIONS
        > options
    EOF
}

function :args:account:adopt {
    typeset parsed
    parsed=$(args -bx h,help -- "$@") || return
    eval "$parsed"
}

function :execute:account:adopt {
    (( $# == 1 )) || abend 'fatal: account adopt needs one account name'
    postcard_account_name "$1" || return
    postcard_session postcard_account_adopt "$1"
}
