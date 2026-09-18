function :help:login {
    heredoc -v help <<'    EOF'
        # desc
        Authorize your Slack account in a browser.
        # opt client-id
        Public Slack Client ID. Later logins reuse the saved ID.
        # opt no-browser
        Print the authorization URL without opening a browser.
        # opt help
        Display help for `login`.
        # man
        ## DESCRIPTION
        Use `postcard --account NAME login [--client-id CLIENT_ID]`.
        Starts a temporary listener at http://localhost:8765/auth and waits
        up to five minutes. Login always needs an explicit name. A failed
        login preserves existing credentials. Reauthorization must retain
        the account's client ID, workspace ID and user ID.
        ## OPTIONS
        > options
    EOF
}

function :args:login {
    typeset parsed
    parsed=$(args -bx h,help -s ,client-id -b ,no-browser -- "$@") || return
    eval "$parsed"
}

function :execute:login {
    (( $# == 0 )) || abend 'fatal: login takes no positional arguments'
    postcard_session postcard_login "${o_client_id:-}" "$o_no_browser"
}
