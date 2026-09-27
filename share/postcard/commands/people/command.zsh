function :help:people {
    heredoc -v help <<'    EOF'
        # desc
        Find checked Slack user IDs by profile name.
        # opt query -- text
        Case-insensitive text matched against username, display name and real name. Required.
        # opt count -- n
        Maximum candidates to return, from 1 to 100. Defaults to 20. No leading zeros.
        # opt help
        Display help for `people`.
        # man
        ## SYNOPSIS
        ```synopsis
        --query QUERY [--count N]
        ```
        ## DESCRIPTION
        Traverses the selected account's complete cursor-paginated users.list
        result, then matches locally. Results are structured JSON and include
        exact Slack user IDs, profile names and account context. No email field
        is requested or returned.

        Exact field matches sort before partial matches, but the command never
        chooses a person, opens a conversation or posts. matched\_count describes
        the complete directory result; returned and truncated describe the
        bounded candidates array. Refine a truncated or ambiguous query, then
        pass an explicitly selected U... ID to `post`.

        Later-page failure, malformed users and repeated cursors emit no partial
        result. The command may omit --account only when exactly one account
        exists, like other account-scoped commands.
        ## OPTIONS
        > options
    EOF
}

function postcard_people_options {
    if (( $# == 1 )) && [[ $1 == (-h|--help) ]]; then
        return 0
    fi
    typeset option
    integer queries=0 counts=0
    while (( $# )); do
        option=$1
        case $option in
            (--query|--count)
                (( $# >= 2 )) || {
                    postcard_error "$option requires a value"; return 1
                }
                [[ $option != --query ]] || (( ++queries ))
                [[ $option != --count ]] || (( ++counts ))
                shift 2
                ;;
            (--query=*|--count=*)
                [[ $option != --query=* ]] || (( ++queries ))
                [[ $option != --count=* ]] || (( ++counts ))
                shift
                ;;
            (-h|--help) shift ;;
            (--)
                shift
                (( $# == 0 )) || {
                    postcard_error 'people takes no positional arguments'; return 1
                }
                ;;
            (*)
                postcard_error 'people expects --query or --count; no positional arguments'
                return 1
                ;;
        esac
    done
    (( queries == 1 )) || {
        postcard_error 'people requires --query exactly once'; return 1
    }
    (( counts <= 1 )) || {
        postcard_error 'people accepts --count at most once'; return 1
    }
}

function :args:people {
    if [[ $zshctl[args:mode] != (help|completion) ]]; then
        postcard_people_options "$@" || return
    fi
    typeset parsed
    parsed=$(args -bx h,help -s ,query -s ,count -- "$@") || return
    eval "$parsed"
}

function :execute:people {
    (( $# == 0 )) || abend 'fatal: people takes no positional arguments'
    typeset request
    request=$(python3 "$postcard[root]/share/postcard/people.py" options \
        "${o_query-}" "${o_count-20}") || return
    postcard_session postcard_people "$request"
}
