function :help:read {
    heredoc -v help <<'    EOF'
        # desc
        Read one exact Slack message as JSON.
        # opt thread
        Parent timestamp, required when the addressed message is a reply.
        # opt help
        Display help for `read`.
        # man
        ## SYNOPSIS
        postcard read [--thread PARENT_TIMESTAMP] CHANNEL_ID TIMESTAMP
        ## DESCRIPTION
        Returns the exact message, including the actual Slack sender and
        text, alongside the selected account and stored workspace/user.
        Does not substitute a nearby message if the address is absent.
        ## OPTIONS
        > options
    EOF
}

function :args:read {
    typeset parsed
    parsed=$(args -bx h,help -s ,thread -- "$@") || return
    eval "$parsed"
}

function :execute:read {
    (( $# == 2 )) || abend 'fatal: read needs a conversation ID and timestamp'
    [[ $1 == [CDG]* ]] || abend 'fatal: read needs a conversation ID'
    postcard_address "$1" && postcard_timestamp "$2" || return
    [[ -z ${o_thread:-} ]] || postcard_timestamp "$o_thread" || return
    postcard_session postcard_read "$1" "$2" "${o_thread:-}"
}
