function :help:whoami {
    heredoc -v help <<'    EOF'
        # desc
        Check your Slack identity and report grant metadata as JSON.
        # opt help
        Display help for `whoami`.
    EOF
}

function :args:whoami {
    typeset parsed
    parsed=$(args -bx h,help -- "$@") || return
    eval "$parsed"
}

function :execute:whoami {
    (( $# == 0 )) || abend 'fatal: whoami takes no arguments'
    postcard_session postcard_whoami
}
