function :help:post {
    help=$(<${functions_source[:help:post]:A:h}/help.md)
}

function :args:post {
    eval "$(args ,alias ,channel ,user ,ts ,slug ,where -a ,attach -rs ,model -bx h,help -- "$@")"
}

function :execute:post {
    setopt localoptions pipefail

    function postcard_post_files {
        setopt localoptions localtraps no_bgnice
        zmodload zsh/system zsh/stat zsh/parameter || return
        typeset upload_work='' upload_umask=$(umask) file filename decoded url file_id method http
        typeset completion=unattempted
        typeset postcard_post_save_interrupt=postcard_post_files_stop
        typeset -a descriptors=() sizes=() ids=() transfer=()
        typeset -A attributes=()
        typeset -i10 fd child result index
        function postcard_post_files_cleanup {
            typeset job descriptor
            for job in ${(k)jobstates}; do
                kill -TERM %$job 2>/dev/null
            done
            wait 2>/dev/null
            for descriptor in $descriptors; do
                exec {descriptor}<&-
            done
            descriptors=()
            [[ -z $upload_work ]] || rm -rf -- "$upload_work"
            upload_work=''
            umask $upload_umask
        }
        function postcard_post_files_stop {
            integer result=$1
            if [[ $completion == attempted ]]; then
                warn 'File sharing is uncertain. Inspect Slack before repeating. Known file IDs: %s' "${(j:, :)ids}"
                result=4
            elif [[ $completion == confirmed ]]; then
                warn 'Files were shared; output was interrupted. Do not repeat.'
            fi
            postcard_post_files_cleanup
            exit $result
        }
        function postcard_post_file_request {
            method=$1
            shift
            curl -q --silent --proto '=https' --connect-timeout 10 --max-time 60 \
                --header @- --output $upload_work/response --write-out '%{http_code}' \
                "$@" https://slack.com/api/$method \
                < <(printf 'Authorization: Bearer %s\n' "$fields[4]") > $upload_work/http 2>/dev/null &
            child=$!
            wait $child
            result=$?
            http=$(<$upload_work/http)
            (( result == 0 )) && [[ $http == 200 ]] || return 1
            jq -ces --arg method "$method" --arg account "$account" \
                --arg team "$fields[2]" --arg user "$fields[3]" --arg channel "$channel" --arg parent "$parent" --arg posted "$posted" \
                --slurpfile expected $upload_work/files -f $directory/files.jq \
                $upload_work/response > $upload_work/checked 2>/dev/null &
            child=$!
            wait $child
        }
        trap 'postcard_post_files_stop 130' INT
        trap 'postcard_post_files_stop 143' TERM HUP
        trap 'postcard_post_files_stop 141' PIPE
        {
            umask 077
            upload_work=$(mktemp -d "${TMPDIR:-/tmp}/postcard.upload.XXXXXX") || return
            : > $upload_work/files || return
            # Open every input before allocating an upload. Nonblocking open
            # lets fstat reject a FIFO without waiting for a writer; held
            # descriptors keep pathname replacement from changing our inputs.
            for file in "${o_attach[@]}"; do
                sysopen -r -o cloexec,nonblock -u fd -- "$file" 2>/dev/null || {
                    warn 'cannot open attachment %s' "${(q)file}"; return 1
                }
                descriptors+=( $fd )
                zstat -H attributes -f $fd || return
                (( (attributes[mode] & 8#170000) == 8#100000 )) || {
                    warn 'attachment must be a regular file: %s' "${(q)file}"; return 1
                }
                sizes+=( $attributes[size] )
                filename=${file:t}
                decoded=$(print -rn -- "$filename" | jq -Rjs '. + "\u0001"' 2>/dev/null) || return
                [[ $filename == "${decoded%$'\1'}" ]] || { warn 'attachment name must be valid UTF-8'; return 1; }
            done
            for (( index=1; index <= $#descriptors; index++ )); do
                filename=${o_attach[index]:t}
                postcard_post_file_request files.getUploadURLExternal \
                    --data-urlencode "filename=$filename" --data-urlencode "length=$sizes[index]" || {
                    warn 'could not allocate attachment upload; sharing was not attempted'; return 1
                }
                file_id=$(jq -r .id $upload_work/checked) || return
                url=$(jq -r .url $upload_work/checked) || return
                (( ! ${ids[(Ie)$file_id]} )) || { warn 'Slack repeated an upload ID; sharing was not attempted'; return 1; }
                ids+=( "$file_id" )
                jq -cn --arg id "$file_id" --arg name "$filename" --argjson size $sizes[index] \
                    '{id:$id,name:$name,size:$size}' >> $upload_work/files || return
                fd=$descriptors[index]
                # Curl reads original bytes directly. The capability URL uses
                # its own pipe and receives no bearer header. Never redirect.
                curl -q --silent --proto '=https' --connect-timeout 10 --max-time 300 \
                    --config /dev/fd/3 --header 'Content-Type: application/octet-stream' \
                    --data-binary @- --output /dev/null --write-out '%{http_code} %{size_upload}' \
                    3< <(printf 'url = "%s"\n' "$url") <&$fd > $upload_work/http 2>/dev/null &
                child=$!
                wait $child
                result=$?
                transfer=( ${(z)"$(<$upload_work/http)"} )
                (( result == 0 )) && [[ $transfer[1] == 200 && $transfer[2] == $sizes[index] ]] || {
                    warn 'attachment bytes were not confirmed; sharing was not attempted'; return 1
                }
            done
            print -rn -- "$card" | jq -ce --slurpfile files $upload_work/files '
                {files:($files | map({id,title:.name})),channel_id:.channel,blocks} +
                (if .thread_ts then {thread_ts} else {} end)
            ' > $upload_work/completion || return
            # Once this call starts, only the complete returned ID set can
            # confirm success. Neither a subset nor an unknown result is retried.
            completion=attempted
            if ! postcard_post_file_request files.completeUploadExternal \
                --header 'Content-Type: application/json; charset=utf-8' --data-binary @$upload_work/completion; then
                warn 'File sharing is uncertain. Inspect Slack before repeating. Known file IDs: %s' "${(j:, :)ids}"
                return 4
            fi
            completion=confirmed
            receipt=$(<$upload_work/checked)
            posted=$(print -rn -- "$receipt" | jq -r '.ts // empty')
            if [[ -n $posted ]]; then
                postcard_post_save || warn 'Files were shared; local receipt unavailable, so an own-post notification may occur. Do not repeat.'
                if postcard_post_file_request chat.getPermalink --get --data-urlencode "channel=$channel" \
                    --data-urlencode "message_ts=$posted"; then
                    if linked=$(printf '%s\n%s' "$receipt" "$(<$upload_work/checked)" | jq -cs '.[0] + {permalink:.[1]}'); then
                        receipt=$linked
                    else
                        warn 'Files were shared; permalink unavailable. Do not repeat.'
                    fi
                else
                    warn 'Files were shared; permalink unavailable. Do not repeat.'
                fi
            fi
            # Keep the confirmed state and owner alive through output. A
            # stopped or broken writer must not make another share look safe.
            print -r -- "$receipt" &
            child=$!
            wait $child || { warn 'Files were shared; JSON output failed. Do not repeat.'; return 1; }
        } always {
            postcard_post_files_cleanup
        }
    }

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
        trap 'postcard_post_save_cleanup; [[ -z ${postcard_post_save_interrupt-} ]] || $postcard_post_save_interrupt 130; exit 130' INT
        trap 'postcard_post_save_cleanup; [[ -z ${postcard_post_save_interrupt-} ]] || $postcard_post_save_interrupt 143; exit 143' TERM HUP
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
                ln -- $staged $final &
                child=$!
                wait $child && [[ $final -ef $staged ]] && return 0
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
    body=$(print -rn -- "$content" | jq -Rces --argjson attachments ${#o_attach} \
        'select((length > 0 or $attachments > 0) and length <= 12000)' 2>/dev/null) ||
        abend 'message body must contain 1–12000 characters, or be empty with attachments'
    # jq replaces malformed UTF-8. Compare its decoded value with the input so
    # sending a card cannot silently change bytes. The sentinel preserves final
    # newlines across command substitution; this is not Unicode normalization.
    decoded=$(print -rn -- "$body" | jq -jr '. + "\u0001"' 2>/dev/null) || return 1
    [[ $content == "${decoded%$'\1'}" ]] || abend 'message body must be valid UTF-8'

    postcard_access || return
    if [[ -v o_alias ]]; then
        aliases=$(postcard_alias_read) || return
        resolved=$(print -rn -- "$aliases" | jq -cer --arg name "$o_alias" '.aliases[$name] // empty') ||
            abend 'unknown alias %s' "$o_alias"
        channel=$(print -rn -- "$resolved" | jq -r .channel) || return
        parent=$(print -rn -- "$resolved" | jq -r .ts) || return
    fi
    [[ ! -v o_user ]] || scopes+=( im:write )
    (( ! $#o_attach )) || scopes+=( files:write )
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
    if (( $#o_attach )); then
        postcard_post_files
        return
    fi
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
