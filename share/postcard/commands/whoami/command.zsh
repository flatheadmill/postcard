function :help:whoami {
    heredoc -v help <<'    EOF'
        # desc
        Check your Slack identity and report grant metadata as JSON.
        # opt help
        Display help for `whoami`.
    EOF
}

function :args:whoami {
    eval "$(args -bx h,help -- "$@")"
}

function :execute:whoami {
    (( $# == 0 )) || abend 'fatal: whoami takes no arguments'
    postcard_session postcard_whoami
}
