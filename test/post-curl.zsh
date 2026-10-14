#!/bin/zsh -f

# All endpoints here are fictional. Capture the two pipes independently so
# tests can see the actual bearer header and JSON card, not just curl's argv.
setopt pipefail
typeset method=${${@[-1]}:t} argument body_file=''
print -r -- "$method" >> $POSTCARD_TEST_POST/calls
printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' > $POSTCARD_TEST_POST/$method.argv.json
cat > $POSTCARD_TEST_POST/$method.header
[[ $@[-1] == https://slack.com/api/$method ]] || exit 99
if [[ $method == chat.postMessage ]]; then
    for argument in "$@"; do
        [[ $argument != @/dev/fd/* ]] || body_file=${argument#@}
    done
    [[ -n $body_file ]] || exit 98
    cat $body_file > $POSTCARD_TEST_POST/body.json || exit
fi
if [[ $method == auth.test && -n $POSTCARD_TEST_REPLACEMENT ]]; then
    cp $POSTCARD_TEST_REPLACEMENT $POSTCARD_TEST_CREDENTIALS.next || exit
    mv $POSTCARD_TEST_CREDENTIALS.next $POSTCARD_TEST_CREDENTIALS || exit
fi
if [[ -f $POSTCARD_TEST_POST/$method.status ]]; then
    print -ru2 -- 'fixture-post-secret fixture-private-body transport detail'
    exit $(< $POSTCARD_TEST_POST/$method.status)
fi
cat $POSTCARD_TEST_POST/$method.json
