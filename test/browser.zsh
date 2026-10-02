#!/usr/bin/env zsh

emulate -L zsh
setopt no_bgnice nomultibyte

typeset url=$1
typeset state=${url#*state=}
state=${state%%\&*}
print -rn -- "$url" > $POSTCARD_TEST_URL

function send_request {
    zmodload zsh/net/tcp zsh/system

    integer connection=-1
    typeset request response='' chunk

    ztcp 127.0.0.1 8765 || return
    connection=$REPLY

    request=$'GET /auth?state='${state}$'&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n\r\n'
    print -rn -u $connection -- "$request"
    while sysread -i $connection -s 4096 chunk; do
        response+=$chunk
    done
    print -rn -- "$response" > $POSTCARD_TEST_RESPONSE
    ztcp -c $connection
}

send_request &!
exit 0
