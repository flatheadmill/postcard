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

function postcard_thread_fetch {
    typeset request=$1 mode=${2:-read} payload cursor='' inspected classification team
    typeset pages=() cursors=()
    payload=$(print -r -- "$request" | jq -c '
        .projection as $projection | .address + {limit:200} +
        (if $projection.kind == "after" then {oldest:$projection.after,inclusive:false} else {} end)') || return
    while true; do
        postcard_form_api conversations.replies "$payload" || return
        inspected=$(print -r -- "$request" "$pc_response" | jq -s '{request:.[0],page:.[1]}' |
            python3 "$postcard[root]/share/postcard/thread.py" page) || return
        cursor=$(print -r -- "$inspected" | jq -r '.cursor') || return
        if [[ $mode == probe && $(print -r -- "$inspected" | jq '.found') == true ]]; then
            team=$(print -r -- "$pc_credentials" | jq -r '.team.id') || return
            if ! postcard_receipt_lock "$team"; then
                print -u2 -- 'postcard: local send receipt evidence is unavailable; notifying normally'
                pc_thread_result=true
                return 0
            fi
            classification=$(print -r -- "$request" "$inspected" | jq -sc --arg team "$team" '
                {team:$team,channel:.[0].address.channel,thread_ts:.[0].address.ts,
                 candidates:.[1].candidates}' |
                python3 "$postcard[root]/share/postcard/receipt.py" classify \
                    "$HOME/.local/state/postcard/sent")
            integer classification_result=$?
            postcard_receipt_unlock || classification_result=1
            if (( classification_result )); then
                print -u2 -- 'postcard: local send receipt evidence could not be checked; notifying normally'
                pc_thread_result=true
                return 0
            fi
            if [[ $(print -r -- "$classification" | jq '.found') == true ]]; then
                pc_thread_result=true
                return 0
            fi
        fi
        [[ $mode == probe ]] || pages+=( "$pc_response" )
        [[ -n $cursor ]] || break
        (( ! cursors[(Ie)$cursor] )) || {
            postcard_error 'Slack returned a repeated pagination cursor'; return 1
        }
        cursors+=( "$cursor" )
        payload=$(print -r -- "$payload" | jq -c --arg cursor "$cursor" '. + {cursor:$cursor}') || return
    done
    if [[ $mode == probe ]]; then
        pc_thread_result=false
        return 0
    fi
    # Publish once, after terminal pagination and projection. Later failures
    # cannot leave an accumulated prefix masquerading as the thread's end.
    pc_thread_result=$(print -rl -- "$request" "${pages[@]}" | jq -s '{request:.[0],pages:.[1:]}' |
        python3 "$postcard[root]/share/postcard/thread.py" project) || return
}

function postcard_thread {
    typeset request=$1 address context result sender profile people='[]' pc_thread_result
    typeset senders=()
    address=$(postcard_resolve_address "$(print -r -- "$request" | jq -c '.address')") || return
    request=$(print -r -- "$request" "$address" | jq -sc '.[0] + {address:.[1]}') || return
    postcard_ready || return
    context=$(postcard_context) || return
    postcard_thread_fetch "$request" || return
    result=$pc_thread_result
    senders=( ${(f)"$(print -r -- "$result" | jq -r \
        '.messages[].sender | strings | select(test("^[UW][A-Z0-9]+$"))' | sort -u)"} )
    for sender in "${senders[@]}"; do
        profile=$(postcard_profile "$sender") || return
        people=$(print -r -- "$people" "$profile" | jq -sc '.[0] + [.[1]]') || return
    done
    result=$(print -r -- "$result" "$people" | jq -sc '.[0] + {people:.[1]}') || return
    print -r -- "$result" "$context" | jq -s '.[0] + .[1]'
}
