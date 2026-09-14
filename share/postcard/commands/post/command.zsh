function :help:post {
    heredoc -v help <<'    EOF'
        # desc
        Send standard input as a carded message to an exact Slack address.
        # opt model
        Name of the composing model, for example Codex. Required.
        # opt thread
        Parent message timestamp when replying in a thread.
        # opt help
        Display help for `post`.
        # man
        ## SYNOPSIS
        postcard post --model Codex [--thread TIMESTAMP] CHANNEL_ID < message.txt
        ## DESCRIPTION
        The destination is a conversation ID, user ID, or `self`. The card's
        owner comes from Slack. Outputs the posted address and permalink as
        JSON. A successful post is never retried automatically.
        ## OPTIONS
        > options
    EOF
}

function :args:post {
    eval "$(args -bx h,help -s ,model -s ,thread -- "$@")"
}

function :execute:post {
    (( $# == 1 )) || abend 'fatal: post needs one conversation ID, user ID, or self'
    [[ -n ${o_model:-} ]] || abend 'fatal: post requires --model'
    postcard_address "$1" || return
    [[ -z ${o_thread:-} ]] || postcard_timestamp "$o_thread" || return
    [[ ! -t 0 ]] || abend 'fatal: provide the message on standard input'
    typeset message
    message=$(cat) || return
    [[ -n $message ]] || abend 'fatal: message is empty'
    postcard_session postcard_post "$1" "$o_model" "${o_thread:-}" "$message"
}
