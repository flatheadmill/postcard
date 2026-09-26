function :help:post {
    heredoc -v help <<'    EOF'
        # desc
        Send standard input as a carded message to an exact Slack address.
        # opt model -- name
        Name of the composing model, for example Codex. Required.
        # opt thread -- timestamp
        Parent message timestamp when replying in a thread.
        # opt alias -- name
        Account-local thread alias. Replaces the destination and --thread.
        # opt help
        Display help for `post`.
        # man
        ## SYNOPSIS
        ```synopsis
        --model MODEL [--thread TIMESTAMP] CHANNEL_ID
        --model MODEL --alias ALIAS
        ```
        ## DESCRIPTION
        The destination is a conversation ID, user ID, or `self`. The card's
        owner comes from the checked Slack display name. A context line names
        "Jane Doe's Codex, from Postcard" beside the open-mailbox mark, with
        dividers framing the Markdown body. An exact Slack user mention token
        in that body becomes a mention; `thread` reports the syntax and
        observed IDs through its `people` result and the README.
        An alias selects exact channel/parent coordinates within this account.
        Outputs the posted address and permalink as
        JSON, alongside the selected account and checked workspace/user.
        A successful post is never retried automatically.
        The message body is read from standard input.
        ## OPTIONS
        > options
    EOF
}

function :args:post {
    typeset o_request parsed
    if [[ $zshctl[args:mode] != (help|completion) ]]; then
        o_request=$(python3 "$postcard[root]/share/postcard/thread.py" options post "$@") || return
    fi
    parsed=$(args -@ -bx h,help -s ,model ,thread ,alias -- "$@") || return
    eval "$parsed"
}

function :execute:post {
    [[ ! -t 0 ]] || abend 'fatal: provide the message on standard input'
    typeset message
    message=$(cat) || return
    [[ -n $message ]] || abend 'fatal: message is empty'
    postcard_session postcard_post_request "$o_request" "$message"
}
