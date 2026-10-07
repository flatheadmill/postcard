#!/usr/bin/env zsh

emulate -L zsh -o pipefail
setopt no_bgnice
zmodload zsh/datetime zsh/system

typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.login.XXXXXX) || exit 1
integer failures=0

source $root/share/postcard/commands/login/command.zsh
mkdir -p $fixture/bin
ln -s $root/test/browser.zsh $fixture/bin/open
ln -s $root/test/curl.zsh $fixture/bin/curl

function check {
    typeset description=$1
    shift
    if "$@"; then
        print -r -- "ok: $description"
    else
        print -r -- "FAIL: $description"
        (( failures++ ))
    fi
}

function not_contains {
    ! grep -Fq -- "$1" "$2"
}

function exercise {
    typeset description=$1
    shift
    if ! "$@"; then
        print -r -- "FAIL: $description could not run"
        (( failures++ ))
    fi
}

function at_least {
    (( $1 >= $2 ))
}

function less_than {
    (( $1 < $2 ))
}

function parse_case {
    typeset mode=$1 expected_status=$2
    typeset request file=$fixture/$mode.request
    typeset -a reply=()
    integer connection exit_status

    case $mode in
        (valid)
            request=$'GET /auth?state=fixture-state&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (encoded)
            request=$'GET /auth?st%61te=fixture-state&co%64e=fixture-code HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (denied)
            request=$'GET /auth?state=fixture-state&error=access_denied HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (unknown-field)
            request=$'GET /auth?state=fixture-state&scope=users%3Aread&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (wrong-state)
            request=$'GET /auth?state=wrong&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (duplicate-state)
            request=$'GET /auth?state=fixture-state&st%61te=fixture-state&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (both-outcomes)
            request=$'GET /auth?state=fixture-state&code=fixture-code&error=access_denied HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (empty-code)
            request=$'GET /auth?state=fixture-state&code= HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (malformed-escape)
            request=$'GET /auth?state=fixture-state&code=%GG HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (control-byte)
            request=$'GET /auth?state=fixture-state&code=%0A HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (missing-host)
            request=$'GET /auth?state=fixture-state&code=fixture-code HTTP/1.1\r\n\r\n'
            ;;
        (duplicate-host)
            request=$'GET /auth?state=fixture-state&code=fixture-code HTTP/1.1\r\nHost: localhost\r\nHost: localhost\r\n\r\n'
            ;;
        (http-1.0)
            request=$'GET /auth?state=fixture-state&code=fixture-code HTTP/1.0\r\n\r\n'
            ;;
        (request-body)
            request=$'GET /auth?state=fixture-state&code=fixture-code HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nx'
            ;;
        (fragment)
            request=$'GET /auth?state=fixture-state&code=fixture-code#fragment HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (oversized-line)
            request=$'GET /auth?state=fixture-state&code='${(l:1100::x:)}$' HTTP/1.1\r\nHost: localhost\r\n\r\n'
            ;;
        (*) return 1 ;;
    esac

    print -rn -- "$request" > $file
    sysopen -r -o cloexec -u connection $file || return
    postcard_callback_read $connection fixture-state
    exit_status=$?
    exec {connection}<&-

    check "$mode parser status" test $exit_status -eq $expected_status
    case $mode in
        (valid|encoded|unknown-field|http-1.0)
            check "$mode returns the code" test "$reply[1]" = fixture-code
            check "$mode returns no error" test -z "$reply[2]"
            ;;
        (denied)
            check 'denied returns no code' test -z "$reply[1]"
            check 'denied returns the error' test "$reply[2]" = access_denied
            ;;
    esac
}

function timeout_case {
    typeset fifo=$fixture/timeout.fifo
    typeset -a reply=()
    integer connection writer exit_status
    float started elapsed

    mkfifo $fifo || return
    {
        integer output
        sysopen -w -u output $fifo || return
        sleep 3
        exec {output}>&-
    } &
    writer=$!
    sysopen -r -u connection $fifo || return
    started=$EPOCHREALTIME
    postcard_callback_read $connection fixture-state
    exit_status=$?
    elapsed=$(( EPOCHREALTIME - started ))
    exec {connection}<&-
    wait $writer

    check 'timeout parser status' test $exit_status -eq 1
    check 'timeout observes the overall deadline' at_least $elapsed 1.5
    check 'timeout does not wait for the peer to close' less_than $elapsed 2.8
}

function listener_case {
    typeset out=$fixture/listener.out err=$fixture/listener.err
    typeset response=$fixture/listener.response url=$fixture/listener.url
    integer exit_status attempt

    : > $response
    print -r -- '{"ok":true,"team":{"id":"T_FIXTURE"},"authed_user":{"id":"U_FIXTURE","token_type":"user","access_token":"fixture-access-token","scope":"chat:write"}}' > $fixture/slack.json
    POSTCARD_TEST_RESPONSE=$response \
    POSTCARD_TEST_URL=$url \
    POSTCARD_TEST_REQUEST=$fixture/exchange \
    POSTCARD_TEST_SLACK_RESPONSE=$fixture/slack.json \
    XDG_CONFIG_HOME=$fixture/config \
    XDG_STATE_HOME=$fixture/state \
    PATH=$fixture/bin:$PATH \
        $root/bin/postcard --account fixture login --client-id 123.456 \
        > $out 2> $err
    exit_status=$?

    for attempt in {1..100}; do
        [[ -s $response ]] && break
        sleep 0.01
    done

    check 'listener exits successfully' test $exit_status -eq 0
    check 'listener returns HTTP success' grep -Fq -- 'HTTP/1.1 200 OK' $response
    check 'listener explains verification' grep -Fq -- \
        'Authorization callback received. Check the terminal for the login result.' \
        $response
    check 'listener reports installed login' grep -Fxq -- 'Logged in to account fixture.' $out
    check 'listener stores the user token' jq -e \
        '.access_token == "fixture-access-token" and .team_id == "T_FIXTURE" and .user_id == "U_FIXTURE"' \
        $fixture/config/postcard/accounts/fixture/credentials.json
    check 'listener does not print the code' not_contains fixture-code $err
    check 'authorization URL uses Slack OAuth' grep -Fq -- \
        'https://slack.com/oauth/v2/authorize?' $url
    check 'authorization URL includes PKCE S256' grep -Fq -- \
        'code_challenge_method=S256' $url
    check 'authorization URL does not include the verifier' \
        not_contains code_verifier $url
}

{
    exercise valid parse_case valid 0
    exercise encoded parse_case encoded 0
    exercise denied parse_case denied 0
    exercise unknown-field parse_case unknown-field 0

    typeset mode
    for mode in wrong-state duplicate-state both-outcomes empty-code \
        malformed-escape control-byte missing-host duplicate-host request-body \
        fragment oversized-line; do
        exercise $mode parse_case $mode 1
    done

    exercise http-1.0 parse_case http-1.0 0
    exercise timeout timeout_case
    exercise listener listener_case
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}

if (( failures )); then
    print -r -- "login: $failures failure(s)"
    exit 1
fi
print -r -- 'login: PASS'
