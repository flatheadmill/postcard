#!/bin/zsh -f

# The driver supplies distinct TCP ports and, when requested, a peer reset.
# The ordinary CLI is exercised separately; ports avoid native ztcp TIME_WAIT.
emulate -L zsh
typeset root=${ZSH_ARGZERO:A:h:h}
fpath=( ${commands[zshctl]:A:h:h}/share/zshctl/functions $fpath )
autoload -Uz abend warn
typeset -A zshctl=(argzero $root/bin/postcard)
typeset o_account=${1:-fixture} o_client_id=${2:-123.456}
source $root/share/postcard/commands/login/command.zsh

function ztcp {
    if [[ $1 == -l ]]; then
        builtin ztcp -l $POSTCARD_TEST_PORT
    else
        builtin ztcp "$@"
    fi
}

if [[ $POSTCARD_TEST_DISCONNECT == 1 ]]; then
    # After the real parser finishes, make the peer reset this real socket.
    # This synchronization lives entirely in the fixture, not the command.
    functions[postcard_test_callback_read]=$functions[postcard_callback_read]
    function postcard_callback_read {
        postcard_test_callback_read "$@"
        integer parsed=$?
        typeset ignored
        builtin printf 'xx' >&$1
        sysread -i $1 -s 1 -t 5 ignored
        return $parsed
    }
    function printf {
        builtin printf "$@"
        integer written=$?
        if [[ $1 == 'HTTP/1.1 %s'* ]]; then
            print -r -- $written > $POSTCARD_TEST_URL.ack-status
        fi
        return $written
    }
fi

:execute:login
