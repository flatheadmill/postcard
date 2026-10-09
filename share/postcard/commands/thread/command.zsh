function :help:thread {
    help=$(<${functions_source[:help:thread]:A:h}/help.md)
}

function :args:thread {
    typeset o_count=20
    eval "$(args -r ,channel -r ,ts -d ,count -d ,cursor -d ,after -bx h,help -- "$@")"
}

function :execute:thread {
    setopt localoptions pipefail
    (( $# == 0 )) || abend 'thread takes no positional arguments'
    [[ -n $o_channel && $o_channel != *[[:cntrl:]]* ]] || abend 'invalid channel ID'
    [[ $o_ts == <->.<-> ]] || abend 'parent timestamp must be a decimal string'
    [[ ! -v o_after || $o_after == <->.<-> ]] || abend 'after timestamp must be a decimal string'
    [[ ! -v o_cursor || -n $o_cursor ]] || abend 'cursor must not be empty'
    [[ $o_count == <1-100> ]] || abend 'count must be an integer from 1 through 100'
    integer count=$(( 10#$o_count ))

    typeset account response output
    typeset -a fields=() request=(
        --data-urlencode "channel=$o_channel" --data-urlencode "ts=$o_ts"
        --data-urlencode "limit=$count"
    )
    postcard_account_read || return
    # A history scope depends on the conversation type. Let Slack decide that
    # access without a channel lookup or requiring every possible history scope.
    [[ ! -v o_cursor ]] || request+=( --data-urlencode "cursor=$o_cursor" )
    [[ ! -v o_after ]] || request+=( --data-urlencode "oldest=$o_after" --data-urlencode 'inclusive=false' )

    # The bearer header travels on stdin. Each cursor and address is one value
    # for curl to encode, never an assembled query string. One invocation owns
    # one request; any continuation belongs to the caller's next invocation.
    response=$(printf 'Authorization: Bearer %s\n' "$fields[4]" |
        curl -q --silent --show-error --fail --proto '=https' \
            --connect-timeout 10 --max-time 30 --header @- --get \
            "${request[@]}" https://slack.com/api/conversations.replies) || {
        warn 'Slack thread request failed'; return 1
    }

    # jq validates the whole page before stdout. Capture its diagnostic stream
    # too: status 13 carries only a validated parent timestamp. Other errors
    # receive fixed diagnostics so a parser failure cannot print response data.
    output=$(print -rn -- "$response" | jq -ces \
        --arg account "$account" --arg team "$fields[2]" --arg user "$fields[3]" \
        --arg channel "$o_channel" --arg ts "$o_ts" --arg after "${o_after-}" \
        --arg cursor "${o_cursor-}" --argjson count $count \
        -f ${functions_source[:execute:thread]:A:h}/response.jq 2>&1)
    case $? in
        (0) print -r -- "$output" ;;
        (10) warn 'Slack rejected the grant; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"; return 1 ;;
        (11) warn 'Slack thread request is rate limited; try again later'; return 1 ;;
        (12) warn 'Slack requires history access for this conversation; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"; return 1 ;;
        (13) warn 'requested timestamp is not the returned thread parent; use --ts %s' "$output"; return 1 ;;
        (14) warn 'Slack rejected the pagination cursor; start a new query'; return 1 ;;
        (*) warn 'Slack thread request failed or returned invalid data'; return 1 ;;
    esac
}
