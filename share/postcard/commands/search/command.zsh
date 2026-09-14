function :help:search {
    heredoc -v help <<'    EOF'
        # desc
        Search one bounded page of Slack messages as JSON.
        # opt query -- text
        Slack search query, quoted as one argument. Required exactly once.
        # opt count -- n
        Matches per page, a decimal integer from 1 to 100. Defaults to 20.
        # opt page -- n
        Page number, a decimal integer from 1 to 100. Defaults to 1.
        # opt help
        Display help for `search`.
        # man
        ## SYNOPSIS
        postcard search --query QUERY [--count N] [--page N]
        ## DESCRIPTION
        Makes one search request, plus a credential refresh if needed.
        Results are sorted by timestamp descending, with highlights off.
        There is no automatic retry, pagination, or identity lookup.

        Quote a multiword query as one argument. An option-looking query
        can use `--query='-excluded term'`. Query text is sent unchanged.

        JSON includes the stored team/user, Slack's nullable query echo,
        requested_query, text_format, sort, sort_dir, pagination, and matches.
        Pagination reports page, per_page, returned, total, pages, has_more,
        and next_page. Unknown totals and continuation are null. Page 100
        has no next_page even when Slack reports more results.

        Matches contain channel, channel_name, ts, thread_ts, sender,
        permalink, text, type, subtype, bot_id, and app_id. Text remains
        Slack text, without Markdown conversion or card classification.
        Optional unusable fields are null. A null thread_ts means unknown
        parentage: an exact read of a reply may need --thread PARENT_TIMESTAMP.
        Search results are discovery, not a complete conversation transcript.
        ## OPTIONS
        > options
    EOF
}

function postcard_search_options {
    # zshctl currently leaves a trailing scalar option unset and overwrites
    # repeated scalar values. Check these before parsing loses that evidence.
    typeset option
    integer queries=0
    while (( $# )); do
        option=$1
        case $option in
            (--query|--count|--page)
                (( $# >= 2 )) || {
                    postcard_error "$option requires a value"; return 1
                }
                [[ $option != --query ]] || (( ++queries ))
                shift 2
                ;;
            (--query=*|--count=*|--page=*)
                [[ $option != --query=* ]] || (( ++queries ))
                shift
                ;;
            (-h|--help) shift ;;
            (--)
                shift
                (( $# == 0 )) || {
                    postcard_error 'search takes no positional arguments'; return 1
                }
                ;;
            (*)
                postcard_error 'search expects --query, --count or --page; no positional arguments'
                return 1
                ;;
        esac
    done
    (( queries <= 1 )) || {
        postcard_error 'search requires --query exactly once'; return 1
    }
    return 0
}

function :args:search {
    if [[ $zshctl[args:mode] != (help|completion) ]]; then
        postcard_search_options "$@" || return
    fi
    eval "$(args -bx h,help -s ,query -s ,count -s ,page -- "$@")"
}

function :execute:search {
    (( $# == 0 )) || abend 'fatal: search takes no positional arguments'
    [[ -v o_query && -n ${o_query//[[:space:]]/} ]] ||
        abend 'fatal: search requires a non-whitespace --query value'
    typeset count=${o_count-20} page=${o_page-1}
    [[ $count =~ '^([1-9][0-9]?|100)$' ]] ||
        abend 'fatal: --count must be a canonical decimal integer from 1 to 100'
    [[ $page =~ '^([1-9][0-9]?|100)$' ]] ||
        abend 'fatal: --page must be a canonical decimal integer from 1 to 100'
    postcard_session postcard_search "$o_query" "$count" "$page"
}
