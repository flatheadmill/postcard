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
        Starts a temporary listener at http://localhost:8765/auth and waits
        up to five minutes. A failed login preserves existing credentials.
        ## OPTIONS
        > options
    EOF
}

function :args:login {
    eval "$(args -bx h,help -s ,client-id -b ,no-browser -- "$@")"
}

function :execute:login {
    (( $# == 0 )) || abend 'fatal: login takes no positional arguments'
    postcard_session postcard_login "${o_client_id:-}" "$o_no_browser"
}
