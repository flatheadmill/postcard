function :help:post {
    help=$(<${functions_source[:help:post]:A:h}/help.md)
}

function :args:post {
    eval "$(args ,alias ,channel ,user ,ts ,slug ,where -r ,model -bx h,help -- "$@")"
}

function :execute:post {
    setopt localoptions pipefail

    function postcard_post_request {
        typeset method=$1 response
        shift
        integer result=1
        # The bearer header uses stdin; the card has its own anonymous pipe.
        # Neither secret nor body becomes an argument or a temporary file.
        # Suppress transport/parser diagnostics: they can contain remote data.
        if response=$(printf 'Authorization: Bearer %s\n' "$fields[4]" |
            curl -q --silent --fail --proto '=https' \
                --connect-timeout 10 --max-time 30 --header @- \
                "$@" https://slack.com/api/$method 2>/dev/null); then
            output=$(print -rn -- "$response" | jq -ces \
                --arg method "$method" --arg account "$account" \
                --arg team "$fields[2]" --arg user "$fields[3]" \
                --arg channel "$channel" --arg recipient "${o_user-}" \
                --arg ts "$parent" --arg posted "$posted" \
                -f $directory/response.jq 2>&1)
            result=$?
        fi
        (( result == 0 )) && return 0
        # A permalink is decoration after a confirmed send. Its failure cannot
        # change that send's status or recommend another authorization/send.
        [[ $method != chat.getPermalink ]] || return 1
        case $result in
            (10) warn 'Slack rejected the grant; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}" ;;
            (11) warn 'Slack %s request is rate limited; no message was posted' "$method" ;;
            (12) warn 'Slack requires additional scope for %s; run postcard --account %s login --client-id %s' "$method" "${(q)account}" "${(q)fields[1]}" ;;
            (13) warn 'Slack %s did not confirm the saved identity or requested destination; no message was posted' "$method" ;;
            (14) warn 'Slack reported a posted message at %s, but its receipt could not be confirmed. Do not repost without inspecting Slack.' "$output"; return 4 ;;
            (15) warn 'Slack rejected the post: %s; no message was posted' "$output" ;;
            (*)
                if [[ $method == chat.postMessage ]]; then
                    warn 'Delivery is uncertain; the message may have been posted. Do not repost without inspecting Slack.'
                    return 4
                fi
                warn 'Slack %s failed or returned invalid data; no message was posted' "$method"
                ;;
        esac
        return 1
    }

    function postcard_post_save {
        setopt localoptions localtraps no_bgnice
        typeset sent_dir staged='' ancestor saved_umask=$(umask)
        typeset -a sent_parents=()
        typeset -A attributes=()
        integer child
        zmodload zsh/parameter zsh/stat || return
        function postcard_post_save_cleanup {
            typeset job
            for job in ${(k)jobstates}; do
                kill -TERM %$job 2>/dev/null
            done
            wait 2>/dev/null
            [[ -z $staged ]] || rm -f -- "$staged"
            umask $saved_umask
        }
        trap 'postcard_post_save_cleanup; exit 130' INT
        trap 'postcard_post_save_cleanup; exit 143' TERM HUP
        {
            umask 077
            postcard_sent_directory || return
            for ancestor in $sent_parents; do
                [[ ! -L $ancestor && ( ! -e $ancestor || ( -d $ancestor && -O $ancestor ) ) ]] || return 1
            done
            mkdir -p -- $sent_dir && chmod 700 $sent_parents || return
            typeset final=$sent_dir/$posted.json
            staged=$(mktemp "$sent_dir/.sent.XXXXXX") || return
            # The checked sending identity supplies provenance even if Slack
            # omits its optional sender field. No grant or body enters state.
            jq -cne -L $directory/../../jq --arg client "$fields[1]" \
                --arg team "$fields[2]" --arg user "$fields[3]" \
                --arg channel "$channel" --arg posted "$posted" \
                --arg parent "$parent" --arg slug "${o_slug-}" \
                -f $directory/sent.jq > $staged &
            child=$!
            wait $child || return
            chmod 600 $staged || return
            # A hard link publishes the whole immutable record without
            # replacing another writer's evidence or taking a network lock.
            if [[ ! -e $final && ! -L $final ]]; then
                ln -- $staged $final && [[ $final -ef $staged ]] && return 0
            fi
            [[ -f $final && ! -L $final && -O $final && -r $final ]] || return 1
            zstat -H attributes -- $final || return
            (( (attributes[mode] & 8#77) == 0 )) || return 1
            cmp -s -- $staged $final
        } always {
            postcard_post_save_cleanup
        }
    }

    (( $# == 0 )) || abend 'post takes no positional arguments'
    (( ${+o_alias} + ${+o_channel} + ${+o_user} == 1 )) ||
        abend 'select exactly one of --alias, --channel or --user'
    [[ ! -v o_alias || $o_alias =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]] || abend 'invalid alias name'
    [[ ! -v o_channel || $o_channel =~ '^[CDG][A-Z0-9]+$' ]] || abend 'invalid conversation ID'
    [[ ! -v o_user || $o_user =~ '^[UW][A-Z0-9]+$' ]] || abend 'invalid user ID'
    [[ ! -v o_ts || ( -v o_channel && $o_ts == <->.<-> ) ]] ||
        abend '--ts requires --channel and a decimal parent timestamp'
    [[ $o_model =~ '^[A-Za-z0-9][A-Za-z0-9 ._/-]{0,63}$' ]] ||
        abend 'model must be 1–64 letters, numbers, spaces, dots, slashes, underscores or hyphens, starting with a letter or number'

    typeset account content body decoded output name card receipt linked scope aliases resolved option
    typeset directory=${functions_source[:execute:post]:A:h}
    typeset channel=${o_channel-} parent=${o_ts-} posted=''
    typeset -a fields=() scopes=( chat:write users:read )
    for option in o_slug o_where; do
        [[ -v $option ]] || continue
        postcard_label_check "${option#o_}" "${(P)option}" || return
    done
    # Read through EOF without stripping trailing newlines. A successful read
    # found the NUL delimiter, which cannot belong to a Slack message.
    IFS= read -r -d '' content && abend 'message body must not contain NUL'
    body=$(print -rn -- "$content" | jq -Rces 'select(length > 0 and length <= 12000)' 2>/dev/null) ||
        abend 'message body must contain 1–12000 characters'
    # jq replaces malformed UTF-8. Compare its decoded value with the input so
    # sending a card cannot silently change bytes. The sentinel preserves final
    # newlines across command substitution; this is not Unicode normalization.
    decoded=$(print -rn -- "$body" | jq -jr '. + "\u0001"' 2>/dev/null) || return 1
    [[ $content == "${decoded%$'\1'}" ]] || abend 'message body must be valid UTF-8'

    postcard_account_read || return
    if [[ -v o_alias ]]; then
        aliases=$(postcard_alias_read) || return
        resolved=$(print -rn -- "$aliases" | jq -cer --arg name "$o_alias" '.aliases[$name] // empty') ||
            abend 'unknown alias %s' "$o_alias"
        channel=$(print -rn -- "$resolved" | jq -r .channel) || return
        parent=$(print -rn -- "$resolved" | jq -r .ts) || return
    fi
    [[ ! -v o_user ]] || scopes+=( im:write )
    for scope in $scopes; do
        [[ ,$fields[6], == *,$scope,* ]] ||
            abend 'grant lacks %s; run postcard --account %s login --client-id %s' "$scope" "${(q)account}" "${(q)fields[1]}"
    done
    postcard_post_request auth.test --data '' || return
    postcard_post_request users.info --get --data-urlencode "user=$fields[3]" || return
    name=$output
    card=$(printf '%s\n%s' "$body" "$name" | jq -ces --arg model "$o_model" \
        --arg slug "${o_slug-}" --arg where "${o_where-}" \
        -f $directory/card.jq 2>/dev/null) || {
        warn 'card context or fallback text exceeds Slack limits'; return 1
    }

    if [[ -v o_user ]]; then
        postcard_post_request conversations.open --data-urlencode "users=$o_user" \
            --data-urlencode 'return_im=true' || return
        channel=$(print -rn -- "$output" | jq -r .)
    elif [[ -n $parent ]]; then
        # A write needs positive parent evidence. An empty page or a reply's
        # timestamp is not a destination we can silently correct for the caller.
        postcard_post_request conversations.replies --get --data-urlencode "channel=$channel" \
            --data-urlencode "ts=$parent" --data-urlencode "oldest=$parent" \
            --data-urlencode "latest=$parent" --data-urlencode 'inclusive=true' \
            --data-urlencode 'limit=1' || return
    fi
    card=$(print -rn -- "$card" | jq -ce --arg channel "$channel" --arg ts "$parent" '
        . + {channel:$channel} + (if $ts == "" then {} else {thread_ts:$ts,reply_broadcast:false} end)
    ' 2>/dev/null) || return 1

    # This is the only message write. Any unconfirmed outcome is terminal for
    # this invocation; neither a retry nor another destination can repair it.
    postcard_post_request chat.postMessage --header 'Content-Type: application/json; charset=utf-8' \
        --data-binary @/dev/fd/3 3< <(print -rn -- "$card") || return
    receipt=$output
    posted=$(print -rn -- "$receipt" | jq -r .ts)
    # Save proof before decoration or public output can fail. Failure here
    # permits an extra bell, never another send or a changed success receipt.
    postcard_post_save 2>/dev/null || warn 'Message was posted; local receipt unavailable, so an own-post notification may occur. Do not repost.'
    if postcard_post_request chat.getPermalink --get --data-urlencode "channel=$channel" \
        --data-urlencode "message_ts=$posted"; then
        if linked=$(printf '%s\n%s' "$receipt" "$output" | jq -cs '.[0] + {permalink:.[1]}' 2>/dev/null); then
            receipt=$linked
        else
            warn 'Message was posted; permalink unavailable. Do not repost.'
        fi
    else
        warn 'Message was posted; permalink unavailable. Do not repost.'
    fi
    print -r -- "$receipt"
}
