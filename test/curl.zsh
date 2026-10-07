#!/bin/zsh -f

# Fictional OAuth endpoint. Never forward a request to the network.
emulate -L zsh
typeset form=$(cat)
print -r -- exchange >> $POSTCARD_TEST_REQUEST.calls
print -rl -- "$@" > $POSTCARD_TEST_REQUEST.argv
print -rn -- "$form" > $POSTCARD_TEST_REQUEST
if [[ -n $POSTCARD_TEST_EXCHANGE_GATE ]]; then
    : > $POSTCARD_TEST_EXCHANGE_GATE.ready
    for attempt in {1..500}; do
        [[ -e $POSTCARD_TEST_EXCHANGE_GATE ]] && break
        sleep 0.01
    done
fi
[[ $POSTCARD_TEST_TRANSPORT_FAILURE == 1 ]] && exit 28
cat $POSTCARD_TEST_SLACK_RESPONSE
