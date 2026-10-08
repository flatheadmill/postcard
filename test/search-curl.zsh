#!/bin/zsh -f

# A fictional search endpoint. No branch forwards traffic to the network.
setopt pipefail
print -r -- request >> $POSTCARD_TEST_SEARCH/calls
printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' > $POSTCARD_TEST_SEARCH/argv.json
cat > $POSTCARD_TEST_SEARCH/header
[[ $@[-1] == https://slack.com/api/search.messages ]] || exit 99

# Replace the saved file only after the request has arrived. The returned page
# must still name the identity belonging to the token in that request.
if [[ -n $POSTCARD_TEST_REPLACEMENT ]]; then
    cp $POSTCARD_TEST_REPLACEMENT $POSTCARD_TEST_CREDENTIALS.next || exit
    mv $POSTCARD_TEST_CREDENTIALS.next $POSTCARD_TEST_CREDENTIALS || exit
fi
(( ${POSTCARD_TEST_CURL_STATUS:-0} == 0 )) || exit $POSTCARD_TEST_CURL_STATUS
cat $POSTCARD_TEST_SEARCH/response.json
