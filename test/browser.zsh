#!/bin/zsh -f

emulate -L zsh
setopt no_bgnice nomultibyte

typeset url=$1
typeset state=${url#*state=}
state=${state%%\&*}
print -rn -- "$url" > $POSTCARD_TEST_URL
if [[ -n $POSTCARD_TEST_BROWSER_GATE ]]; then
    : > $POSTCARD_TEST_BROWSER_GATE.ready
    for attempt in {1..500}; do
        [[ -e $POSTCARD_TEST_BROWSER_GATE ]] && break
        sleep 0.01
    done
fi
[[ $POSTCARD_TEST_BROWSER_FAILURE == 1 ]] && exit 1

function send_request {
    zmodload zsh/net/tcp zsh/system

    integer connection=-1
    typeset request response='' chunk

    ztcp 127.0.0.1 ${POSTCARD_TEST_PORT:-8765} || return
    connection=$REPLY

    case $POSTCARD_TEST_CALLBACK in
        (denied) request="state=$state&error=access_denied" ;;
        (invalid) request='state=wrong&code=fixture-code' ;;
        (*) request="state=$state&code=fixture-code" ;;
    esac
    request=$'GET /auth?'${request}$' HTTP/1.1\r\nHost: localhost\r\n\r\n'
    print -rn -u $connection -- "$request"
    if [[ $POSTCARD_TEST_DISCONNECT == 1 ]]; then
        # Leave one byte of the driver's probe unread so close resets TCP.
        sysread -i $connection -s 1 -t 5 chunk || return
        ztcp -c $connection
        return
    fi
    while sysread -i $connection -s 4096 -t 5 chunk; do
        response+=$chunk
    done
    print -rn -- "$response" > $POSTCARD_TEST_RESPONSE
    ztcp -c $connection
}

send_request &!
exit 0
