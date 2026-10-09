#!/bin/zsh -f

# A fictional replies endpoint. Nothing in this transport contacts Slack.
setopt pipefail
print -r -- request >> $POSTCARD_TEST_THREAD/calls
printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' > $POSTCARD_TEST_THREAD/argv.json
cat > $POSTCARD_TEST_THREAD/header
[[ $@[-1] == https://slack.com/api/conversations.replies ]] || exit 99

# A concurrent login can install a new grant after our request starts. The
# returned identity must still belong to the token already used by this read.
if [[ -n $POSTCARD_TEST_REPLACEMENT ]]; then
    cp $POSTCARD_TEST_REPLACEMENT $POSTCARD_TEST_CREDENTIALS.next || exit
    mv $POSTCARD_TEST_CREDENTIALS.next $POSTCARD_TEST_CREDENTIALS || exit
fi
if (( ${POSTCARD_TEST_CURL_STATUS:-0} != 0 )); then
    [[ -z $POSTCARD_TEST_HTTP_STATUS ]] || print -ru2 -- "curl: (22) HTTP $POSTCARD_TEST_HTTP_STATUS"
    exit $POSTCARD_TEST_CURL_STATUS
fi
cat $POSTCARD_TEST_THREAD/response.json
