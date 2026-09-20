# Aliases use the selected account's binding and lock. They are exact local
# addresses; reading or changing one never needs a Slack request or renewal.
function postcard_aliases_load {
    typeset file=$pc_directory/aliases.json
    pc_aliases='{"version":1,"aliases":{}}'
    if [[ -e $file || -h $file ]]; then
        [[ -f $file && ! -h $file && -O $file && -r $file ]] || {
            postcard_error 'aliases must be a readable regular file owned by this user'; return 1
        }
        pc_aliases=$(< "$file")
    fi
    print -r -- "$pc_aliases" | jq -e '
        def matches($pattern): if type == "string" then test($pattern) else false end;
        .version == 1 and (.aliases | type == "object") and
        (.aliases | to_entries | all(.[];
            (.key | matches("^[a-z0-9][a-z0-9._-]*\\z")) and
            (.value | type == "object") and
            (.value.channel | matches("^[CDG][A-Z0-9]+\\z")) and
            (.value.ts | matches("^[0-9]+\\.[0-9]{6}\\z"))))
        ' >/dev/null 2>&1 || { postcard_error 'invalid alias file'; return 1; }
}

function postcard_alias_address {
    typeset name=$1
    print -r -- "$pc_aliases" | jq -ec --arg name "$name" '.aliases[$name] // empty | {channel,ts}' || {
        postcard_error "unknown alias: $name"; return 1
    }
}

function postcard_resolve_address {
    typeset address=$1 pc_aliases
    if [[ $(print -r -- "$address" | jq 'has("alias")') == true ]]; then
        postcard_aliases_load || return
        postcard_alias_address "$(print -r -- "$address" | jq -r '.alias')"
    else
        print -r -- "$address"
    fi
}

function postcard_alias {
    typeset request=$1 pc_aliases context action name address result
    postcard_aliases_load || return
    context=$(postcard_context) || return
    action=$(print -r -- "$request" | jq -r '.action')
    name=$(print -r -- "$request" | jq -r '.name // empty')
    case $action in
        (list)
            result=$(print -r -- "$pc_aliases" | jq '{aliases:(.aliases | to_entries | sort_by(.key) |
                map({name:.key,channel:.value.channel,ts:.value.ts}))}') || return
            ;;
        (get|delete)
            address=$(postcard_alias_address "$name") || return
            result=$(print -r -- "$address" | jq --arg name "$name" --arg action "$action" \
                '. + {name:$name} + (if $action == "delete" then {deleted:true} else {} end)') || return
            ;;
        (bind)
            address=$(print -r -- "$request" | jq -c '.address') || return
            result=$(print -r -- "$address" | jq --arg name "$name" '. + {name:$name}') || return
            ;;
    esac
    if [[ $action == (bind|delete) ]]; then
        pc_aliases=$(print -r -- "$pc_aliases" "$address" | jq -sc --arg name "$name" --arg action "$action" '
            .[1] as $address | .[0] |
            if $action == "delete" then del(.aliases[$name]) else .aliases[$name] = $address end') || return
        pc_tmp=$(mktemp "$pc_directory/.aliases.XXXXXX") || return
        print -r -- "$pc_aliases" > "$pc_tmp" && chmod 600 "$pc_tmp" &&
            mv -f -- "$pc_tmp" "$pc_directory/aliases.json" || return
        pc_tmp=''
    fi
    print -r -- "$result" "$context" | jq -s '.[0] + .[1]'
}

function postcard_post_request {
    typeset request=$1 message=$2 address
    address=$(postcard_resolve_address "$(print -r -- "$request" | jq -c '.address')") || return
    postcard_post "$(print -r -- "$address" | jq -r '.channel')" \
        "$(print -r -- "$request" | jq -r '.model')" \
        "$(print -r -- "$address" | jq -r '.ts // empty')" "$message"
}

function postcard_thread {
    typeset request=$1 address context payload cursor='' result
    typeset pages=() cursors=()
    address=$(postcard_resolve_address "$(print -r -- "$request" | jq -c '.address')") || return
    request=$(print -r -- "$request" "$address" | jq -sc '.[0] + {address:.[1]}') || return
    postcard_ready || return
    context=$(postcard_context) || return
    payload=$(print -r -- "$request" | jq -c '
        .projection as $projection | .address + {limit:200} +
        (if $projection.kind == "after" then {oldest:$projection.after,inclusive:false} else {} end)') || return
    while true; do
        postcard_api conversations.replies "$payload" || return
        cursor=$(print -r -- "$pc_response" | jq -er '
            if (.messages | type) != "array" then error("missing messages") else . end |
            .has_more as $more |
            (.response_metadata | if . == null then {} else . end) |
            if type != "object" then error("invalid pagination") else . end |
            (.next_cursor | if . == null then "" else . end) |
            if type != "string" or ($more == true and . == "")
            then error("invalid cursor") else . end' 2>/dev/null) || {
            postcard_error 'invalid thread response'; return 1
        }
        pages+=( "$pc_response" )
        [[ -n $cursor ]] || break
        (( ! cursors[(Ie)$cursor] )) || {
            postcard_error 'Slack returned a repeated pagination cursor'; return 1
        }
        cursors+=( "$cursor" )
        payload=$(print -r -- "$payload" | jq -c --arg cursor "$cursor" '. + {cursor:$cursor}') || return
    done
    # Publish once, after terminal pagination and projection. Later failures
    # cannot leave an accumulated prefix masquerading as the thread's end.
    result=$(print -rl -- "$request" "${pages[@]}" | jq -s '{request:.[0],pages:.[1:]}' |
        python3 "$postcard[root]/share/postcard/thread.py" project) || return
    print -r -- "$result" "$context" | jq -s '.[0] + .[1]'
}
