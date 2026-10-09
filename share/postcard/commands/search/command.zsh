function :help:search {
    help=$(<${functions_source[:help:search]:A:h}/help.md)
}

function :args:search {
    typeset o_count=20 o_page=1
    eval "$(args -r ,query -d ,count -d ,page -bx h,help -- "$@")"
}

function :execute:search {
    setopt localoptions pipefail
    (( $# == 0 )) || abend 'search takes no positional arguments'
    [[ -n $o_query ]] || abend 'query must not be empty'
    [[ $o_count == <1-100> && $o_page == <1-100> ]] ||
        abend 'count and page must be integers from 1 through 100'
    integer count=$(( 10#$o_count )) page=$(( 10#$o_page ))

    typeset account response output
    typeset -a fields=()
    postcard_account_read || return
    [[ ,$fields[6], == *,search:read,* ]] ||
        abend 'grant lacks search:read; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"

    # A builtin writes the bearer header to curl's stdin: no secret argument,
    # temporary header file, or grant JSON passed through jq's argv. The query
    # is one data value for URL encoding, including any Slack search operators.
    response=$(printf 'Authorization: Bearer %s\n' "$fields[4]" |
        curl -q --silent --show-error --fail --proto '=https' \
            --connect-timeout 10 --max-time 30 --header @- --get \
            --data-urlencode "query=$o_query" --data-urlencode "count=$count" \
            --data-urlencode "page=$page" --data-urlencode 'sort=timestamp' \
            --data-urlencode 'sort_dir=desc' --data-urlencode 'highlight=false' \
            https://slack.com/api/search.messages) || {
        warn 'Slack search request failed'; return 1
    }

    # Capture the whole validated page before publishing it. A malformed later
    # match must not leave earlier matches on stdout. Only public context is
    # passed as jq arguments; the response itself travels through a pipe.
    output=$(print -rn -- "$response" | jq -ces \
        --arg account "$account" --arg team "$fields[2]" --arg user "$fields[3]" \
        --arg query "$o_query" --argjson count $count --argjson page $page \
        -f ${functions_source[:execute:search]:A:h}/response.jq 2>/dev/null)
    case $? in
        (0) print -r -- "$output" ;;
        (10) warn 'Slack rejected the grant; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"; return 1 ;;
        (11) warn 'Slack search is rate limited; try again later'; return 1 ;;
        (12) warn 'Slack requires search:read; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"; return 1 ;;
        (*) warn 'Slack search failed or returned invalid data'; return 1 ;;
    esac
}
