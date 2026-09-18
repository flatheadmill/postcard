function :help:account {
    heredoc -v help <<'    EOF'
        # desc
        List local accounts or adopt legacy credentials.
        # opt help
        Display help for `account`.
        # man
        ## DESCRIPTION
        These commands perform no Slack requests and take no --account option.
        ## OPTIONS
        > options
        ## COMMANDS
        > commands
    EOF
}

function :args:account {
    typeset parsed
    parsed=$(args -UC -bx h,help -- "$@") || return
    eval "$parsed"
}

function :execute:account {
    delegate "$@"
}
