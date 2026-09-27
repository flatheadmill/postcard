# Shared command implementation. Credential-bearing values remain shell locals;
# curl and jq receive them through pipes, never their argument lists.

function postcard_error {
    print -r -u2 -- "postcard${pc_account:+ [$pc_account]}: $*"
    return 1
}

function postcard_address {
    [[ $1 == self || $1 =~ '^[CDGUW][A-Z0-9]+$' ]] ||
        postcard_error 'expected an exact conversation ID, user ID, or self'
}

function postcard_timestamp {
    [[ $1 =~ '^[0-9]+\.[0-9]{6}$' ]] || postcard_error 'invalid Slack timestamp'
}

function postcard_session {
    # The subshell releases its locks before public stdout can block.
    typeset result
    result=$(postcard_session_locked "$@") || return
    if [[ -n $result ]]; then
        print -r -- "$result" || return
    fi
    return 0
}

function postcard_session_locked {
    (
        emulate -L zsh
        setopt pipefail
        unsetopt xtrace verbose bgnice
        umask 077
        zmodload zsh/system && zmodload zsh/datetime || exit 1
        typeset dependency
        for dependency in curl jq python3 openssl; do
            (( $+commands[$dependency] )) || {
                postcard_error "missing dependency: $dependency"
                exit 1
            }
        done
        typeset pc_root=${postcard[directory]:a} pc_account=${postcard[account]:-}
        typeset pc_directory='' pc_file='' pc_tmp='' pc_listener=''
        typeset pc_credentials='{}' pc_response='' pc_token='' pc_identity=''
        typeset pc_body='' pc_http='' pc_lock='' pc_root_lock='' pc_headers=''
        typeset pc_receipt_lock=''
        typeset pc_retry_after=0
        integer pc_probe=0
        typeset -a pc_accounts=()
        integer pc_existing=0
        trap 'postcard_cleanup' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM HUP
        postcard_private_directory "$pc_root" &&
            postcard_lock "$pc_root/.lock" pc_root_lock &&
            postcard_private_directory "$pc_root/accounts" || exit 1
        case $1 in
            (postcard_account_list|postcard_account_adopt) ;;
            (*) postcard_select_account "$1" || exit 1 ;;
        esac
        "$@"
    )
}

function postcard_cleanup {
    if [[ -n $pc_listener ]]; then
        kill "$pc_listener" 2>/dev/null
        wait "$pc_listener" 2>/dev/null
    fi
    [[ -z $pc_tmp ]] || rm -f -- "$pc_tmp"
    [[ -z $pc_headers ]] || rm -f -- "$pc_headers"
    return 0
}

function postcard_receipt_lock {
    typeset team=$1 channel=${2:-} directory
    [[ $team =~ '^T[A-Z0-9]+$' ]] || {
        postcard_error 'invalid workspace for local send receipts'; return 1
    }
    [[ -z $channel || $channel =~ '^[CDG][A-Z0-9]+$' ]] || {
        postcard_error 'invalid conversation for local send receipts'; return 1
    }
    for directory in "$HOME/.local/state/postcard" "$HOME/.local/state/postcard/sent" \
        "$HOME/.local/state/postcard/sent/$team"; do
        postcard_private_directory "$directory" || return
    done
    postcard_lock "$HOME/.local/state/postcard/sent/$team/.lock" pc_receipt_lock wait || return
    if [[ -n $channel ]] &&
        ! postcard_private_directory "$HOME/.local/state/postcard/sent/$team/$channel"; then
        postcard_receipt_unlock >/dev/null 2>&1
        return 1
    fi
}

function postcard_receipt_unlock {
    if [[ -n $pc_receipt_lock ]]; then
        zsystem flock -u "$pc_receipt_lock" || {
            pc_receipt_lock=''
            postcard_error 'could not release local send receipt lock'
            return 1
        }
        pc_receipt_lock=''
    fi
}

function postcard_save {
    pc_tmp=$(mktemp "$pc_directory/.credentials.XXXXXX") || return
    print -r -- "$pc_credentials" > "$pc_tmp" &&
        chmod 600 "$pc_tmp" && mv -f -- "$pc_tmp" "$pc_file" || {
        postcard_error 'could not save credentials; log in again if renewal was in progress'
        return 1
    }
    pc_tmp=''
}

# No redirects or automatic retries: a post or refresh can succeed even when
# its response is lost. -q is first so ~/.curlrc cannot enable tracing/retries.
function postcard_http {
    typeset method=$1 content_type=$2 raw reason
    integer curl_result=0
    typeset -a header_options=()
    if (( pc_probe )); then
        pc_headers=$(mktemp "$pc_directory/.headers.XXXXXX") || return
        header_options=( --dump-header "$pc_headers" )
    fi
    raw=$(print -rn -- "$pc_body" | curl -q --silent --show-error --connect-timeout 10 --max-time 45 \
        --proto '=https' --header "Content-Type: $content_type" \
        --header @<(if [[ -n $pc_token ]]; then print -r -- "Authorization: Bearer $pc_token"; fi) \
        --data-binary @- "${header_options[@]}" \
        --write-out $'\n%{http_code}' "https://slack.com/api/$method") || curl_result=$?
    pc_retry_after=0
    if [[ -n $pc_headers ]]; then
        pc_retry_after=$(python3 "$postcard[root]/share/postcard/reader.py" retry-after < "$pc_headers") || return
        rm -f -- "$pc_headers"
        pc_headers=''
    fi
    if (( curl_result )); then
        # Only observation retries. OAuth and posts retain their one-attempt rule.
        if (( pc_probe )) && [[ $curl_result == (5|6|7|16|18|28|35|52|55|56|92) ]]; then
            print -r -u2 -- "postcard [$pc_account]: $method transport failed; waiting to probe again"
            return 75
        fi
        postcard_error "$method transport failed; a write may have succeeded. No retry was made."
        return 1
    fi
    pc_http=${raw##*$'\n'}
    pc_response=${raw%$'\n'*}
    if (( pc_probe )) && [[ $pc_http == 429 || $pc_http == 5[0-9][0-9] ]]; then
        [[ $pc_http != 429 || $pc_retry_after != 0 ]] || pc_retry_after=60
        print -r -u2 -- "postcard [$pc_account]: $method returned HTTP $pc_http; waiting to probe again"
        return 75
    fi
    [[ $pc_http == 200 ]] || {
        postcard_error "$method returned HTTP $pc_http; no retry was made"
        return 1
    }
    print -r -- "$pc_response" | jq -e '.ok == true' >/dev/null 2>&1 || {
        reason=$(print -r -- "$pc_response" | jq -er \
            '.error | strings | select(test("^[a-z0-9_]{1,80}$"))' 2>/dev/null)
        if (( pc_probe )) && [[ $reason == (ratelimited|internal_error|service_unavailable|fatal_error) ]]; then
            [[ $reason != ratelimited || $pc_retry_after != 0 ]] || pc_retry_after=60
            print -r -u2 -- "postcard [$pc_account]: $method: $reason; waiting to probe again"
            return 75
        fi
        postcard_error "$method: ${reason:-invalid Slack response}"
        return 1
    }
}

function postcard_api {
    pc_body=${2:-'{}'}
    postcard_http "$1" 'application/json; charset=utf-8'
}

function postcard_form_api {
    # Some Slack read methods report required JSON fields as missing instead
    # of parsing them. Convert Postcard's typed internal request at the wire
    # boundary; these payloads contain only public Slack coordinates.
    pc_body=$(print -r -- "$2" | jq -er '
        select(type == "object") | to_entries |
        map((.key | @uri) + "=" + (.value | tostring | @uri)) | join("&")') || return
    postcard_http "$1" application/x-www-form-urlencoded
}

function postcard_form {
    pc_body=$(jq -Rnr '[inputs] as $values | [range(0; ($values|length); 2) |
        ($values[.] | @uri) + "=" + ($values[. + 1] | @uri)] | join("&")')
}

function postcard_login {
    typeset client_id=$1 no_browser=$2 verifier challenge state callback url scopes
    typeset previous=$pc_credentials
    [[ -n $client_id ]] || client_id=$(print -r -- "$pc_credentials" |
        jq -r '.client_id // empty')
    [[ $client_id =~ '^[0-9]+\.[0-9]+$' ]] || {
        postcard_error 'login requires --client-id from Slack Basic Information'
        return 1
    }
    verifier=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n') || return
    state=$(openssl rand -hex 32) || return
    challenge=$(print -rn -- "$verifier" | openssl dgst -sha256 -binary |
        openssl base64 -A | tr '+/' '-_' | tr -d '=\n') || return
    scopes=$(jq -er '.oauth_config.scopes.user | join(",")' \
        "$postcard[root]/slack-manifest.json") || return
    url=$(jq -nr --arg client "$client_id" --arg scopes "$scopes" \
        --arg state "$state" --arg challenge "$challenge" \
        --arg redirect "$postcard[redirect]" '
        {client_id:$client, user_scope:$scopes, scope:"", state:$state,
         code_challenge:$challenge, code_challenge_method:"S256", redirect_uri:$redirect}
        | to_entries | map((.key|@uri) + "=" + (.value|@uri)) | join("&")
        | "https://slack.com/oauth/v2/authorize?" + .') || return
    coproc python3 "$postcard[root]/share/postcard/callback.py"
    pc_listener=$!
    print -rp -- "$state" || return
    IFS= read -rp callback || {
        postcard_error 'callback helper did not start'; return 1
    }
    [[ $callback == ready ]] || {
        postcard_error 'cannot listen on 127.0.0.1:8765; close the other listener and retry'
        return 1
    }
    print -rl -u2 -- 'Authorize Postcard in your browser (waiting up to five minutes):' "$url"
    if (( ! no_browser )); then
        if [[ $OSTYPE == darwin* ]]; then
            open "$url" >/dev/null 2>&1 || print -u2 'Open the URL above to continue.'
        else
            xdg-open "$url" >/dev/null 2>&1 || print -u2 'Open the URL above to continue.'
        fi
    fi
    IFS= read -rp callback || {
        postcard_error 'callback ended before authorization'; return 1
    }
    wait "$pc_listener" 2>/dev/null
    pc_listener=''
    typeset code
    code=$(print -r -- "$callback" | jq -er '.code | strings | select(length > 0)' 2>/dev/null) || {
        postcard_error "authorization declined or timed out; run postcard --account $pc_account login"
        return 1
    }
    # Use redirection, not a pipeline into the function: pc_body must remain
    # in this shell. None of these private values enter jq/curl argv.
    postcard_form < <(print -rl -- client_id "$client_id" grant_type authorization_code \
        code "$code" code_verifier "$verifier" redirect_uri "$postcard[redirect]") || return
    pc_token=''
    postcard_http oauth.v2.access application/x-www-form-urlencoded || return
    typeset candidate
    candidate=$(print -r -- "$pc_response" | jq -ec --arg client "$client_id" \
        --argjson now "$EPOCHSECONDS" '
        select(.team.id | type == "string" and length > 0) |
        select(.authed_user.id | type == "string" and length > 0) |
        {version:1, client_id:$client, app_id:.app_id, team:.team,
         user:{id:.authed_user.id}, grant:(.authed_user | del(.id))} |
        .grant.issued_at = $now |
        .grant.expires_at = (if .grant.expires_in == null then null
            else $now + .grant.expires_in end) |
        .grant.refresh_expires_at = (if .grant.refresh_expires_in == null then null
            else $now + .grant.refresh_expires_in end)
        ' 2>/dev/null) || {
        postcard_error 'Slack did not return a valid workspace user grant'; return 1
    }
    pc_credentials=$candidate
    postcard_validate || return
    typeset missing
    missing=$(print -r -- "$pc_credentials" | jq -r --arg requested "$scopes" \
        '($requested|split(",")) - (.grant.scope|split(",")) | join(",")') || return
    [[ -z $missing ]] || {
        postcard_error "grant is missing requested scopes: $missing"; return 1
    }
    postcard_identity || return
    pc_credentials=$(print -r -- "$pc_credentials" "$pc_identity" | jq -sc \
        '.[0] + {user:.[1].user, team:.[1].team}') || return
    if (( pc_existing )); then
        print -r -- "$previous" "$pc_credentials" | jq -se '
            def binding: [.client_id,.team.id,.user.id];
            (.[0]|binding) == (.[1]|binding)' >/dev/null 2>&1 || {
            postcard_error 'authorization would change this account’s client, workspace or user binding; existing credentials were preserved'
            return 1
        }
    fi
    postcard_save || return
    postcard_summary
}

function postcard_validate {
    print -r -- "$pc_credentials" | jq -e '
        .version == 1 and (.client_id | type == "string" and test("^[0-9]+\\.[0-9]+\\z")) and
        (.team.id | type == "string" and test("^T[A-Z0-9]+\\z")) and
        (.user.id | type == "string" and test("^[UW][A-Z0-9]+\\z")) and
        (.grant.token_type == "user") and
        (.grant.access_token | type == "string" and test("^[A-Za-z0-9._-]+\\z")) and
        (.grant.scope | type == "string") and
        (.grant.expires_at == null or (.grant.expires_at | type == "number")) and
        (.grant.refresh_expires_at == null or (.grant.refresh_expires_at | type == "number")) and
        (.grant.refresh_uncertain == null or (.grant.refresh_uncertain | type == "boolean")) and
        (.grant.refresh_token == null or
            (.grant.refresh_token | type == "string" and test("^[A-Za-z0-9._-]+\\z"))) and
        (.grant.expires_in == null or
            ((.grant.expires_in | type == "number" and . > 0) and
             (.grant.refresh_token | type == "string" and length > 0)))
        ' >/dev/null 2>&1 || {
        postcard_error 'invalid credential record; inspect the selected account before authorizing again'
        return 1
    }
    pc_token=$(print -r -- "$pc_credentials" | jq -r '.grant.access_token')
}

function postcard_ready {
    postcard_validate || return
    print -r -- "$pc_credentials" | jq -e '.grant.refresh_uncertain == true' >/dev/null && {
        postcard_error "previous renewal was interrupted or uncertain; run postcard --account $pc_account login"
        return 1
    }
    typeset expiry
    expiry=$(print -r -- "$pc_credentials" | jq -r '.grant.expires_at // 0') || return
    if (( expiry > 0 && EPOCHSECONDS + 120 >= expiry )); then
        postcard_refresh || return
    fi
}

function postcard_refresh {
    typeset refresh client_id replacement
    refresh=$(print -r -- "$pc_credentials" | jq -er '.grant.refresh_token | strings | select(length > 0)') || {
        postcard_error "grant has expired without a refresh token; run postcard --account $pc_account login"; return 1
    }
    client_id=$(print -r -- "$pc_credentials" | jq -r '.client_id')
    # Leave a durable uncertainty marker before spending a one-use token.
    # A killed process must not silently reuse it on the next invocation.
    pc_credentials=$(print -r -- "$pc_credentials" | jq -c '.grant.refresh_uncertain = true') || return
    postcard_save || return
    postcard_form < <(print -rl -- client_id "$client_id" grant_type refresh_token \
        refresh_token "$refresh") || return
    pc_token=''
    postcard_http oauth.v2.access application/x-www-form-urlencoded || {
        postcard_error "renewal is uncertain; run postcard --account $pc_account login to authorize again"; return 1
    }
    replacement=$(print -r -- "$pc_credentials" "$pc_response" | jq -esc \
        --argjson now "$EPOCHSECONDS" '
        .[0] as $old | .[1] as $response |
        ($response.authed_user // $response) as $new |
        select($response.team.id == null or $response.team.id == $old.team.id) |
        select($new.id == null or $new.id == $old.user.id) |
        select($new.token_type == "user") |
        select($new.refresh_token | type == "string" and length > 0) |
        select($new.expires_in | type == "number" and . > 0) |
        $old | .grant = ($new | del(.ok, .team, .enterprise, .authed_user, .id, .app_id)) |
        .grant.scope = ($new.scope // $old.grant.scope) |
        .grant.issued_at = $now | .grant.expires_at = ($now + $new.expires_in) |
        .grant.refresh_expires_at = (if $new.refresh_expires_in == null then null
            else $now + $new.refresh_expires_in end)
        ' 2>/dev/null) || {
        postcard_error "invalid renewal response; run postcard --account $pc_account login"; return 1
    }
    pc_credentials=$replacement
    postcard_validate && postcard_save
}

function postcard_identity {
    postcard_api auth.test || return
    typeset auth=$pc_response user_id team_id profile
    user_id=$(print -r -- "$pc_credentials" | jq -r '.user.id')
    team_id=$(print -r -- "$pc_credentials" | jq -r '.team.id')
    print -r -- "$auth" | jq -e --arg user "$user_id" --arg team "$team_id" \
        '.user_id == $user and .team_id == $team and (.bot_id == null)' >/dev/null || {
        postcard_error 'Slack identity does not match the stored grant'; return 1
    }
    profile=$(postcard_profile "$user_id") || return
    pc_identity=$(print -r -- "$auth" "$profile" | jq -sc '
        {team:{id:.[0].team_id,name:.[0].team,url:.[0].url},user:.[1]}')
}

function postcard_profile {
    typeset user_id=$1
    # Live Slack returned user_not_found for the JSON request; form encoding
    # resolves the same user successfully.
    postcard_form < <(print -rl -- user "$user_id") || return
    postcard_http users.info application/x-www-form-urlencoded || return
    print -r -- "$pc_response" | jq -ec --arg user "$user_id" '
        .user | select(.id == $user) |
        {id:.id, username:.name,
         name:([.profile.display_name, .profile.real_name, .real_name, .name]
             | map(select(type == "string") | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "") |
                 select(length > 0)) | first)} |
        select(.name != null)' || {
        postcard_error 'Slack returned no usable user profile'; return 1
    }
}

function postcard_summary {
    print -r -- "$pc_credentials" "$pc_identity" | jq -s --arg account "$pc_account" '
        .[0] as $record | .[1] + {account:$account,client_id:$record.client_id,
         scopes:($record.grant.scope|split(",")),
         expires_at:$record.grant.expires_at,
         refreshable:($record.grant.refresh_token != null),
         refresh_expires_at:$record.grant.refresh_expires_at}'
}

function postcard_whoami {
    postcard_ready && postcard_identity && postcard_summary
}

function postcard_self {
    typeset user_id=$1 cursor='' prior='' found payload
    # conversations.open explicitly excludes the calling user. Find the
    # existing self-DM by its actual participant, never by a display name.
    while true; do
        payload=$(jq -cn --arg cursor "$cursor" \
            '{types:"im",exclude_archived:true,limit:200,cursor:$cursor}') || return
        postcard_api conversations.list "$payload" || return
        found=$(print -r -- "$pc_response" | jq -r --arg user "$user_id" \
            '.channels[] | select(.is_im == true and .user == $user) | .id') || return
        if [[ $found =~ '^D[A-Z0-9]+$' ]]; then
            REPLY=$found
            return 0
        fi
        prior=$cursor
        cursor=$(print -r -- "$pc_response" | jq -r '.response_metadata.next_cursor // empty') || return
        [[ -n $cursor && $cursor != $prior ]] || break
    done
    postcard_error 'self-DM was not found; open it in Slack first, or use its exact conversation ID'
}

function postcard_post {
    typeset destination=$1 model=$2 thread=$3 message=$4 card payload receipt context permalink=''
    typeset team_id user_id origin proof
    [[ $model =~ '^[A-Za-z0-9][A-Za-z0-9 ._/-]{0,63}$' ]] || {
        postcard_error 'model name must be 1–64 letters, numbers, spaces, dots, slashes, underscores or hyphens'
        return 1
    }
    postcard_ready && postcard_identity || return
    context=$(postcard_context) || return
    card=$(print -r -- "$pc_identity" | jq -r --arg model "$model" \
        '.user.name + "\u0027s " + $model + ", from Postcard"') || return
    (( ${#message} <= 12000 )) || {
        postcard_error "message exceeds Slack's 12,000-character Markdown limit"; return 1
    }
    user_id=$(print -r -- "$pc_identity" | jq -r '.user.id')
    team_id=$(print -r -- "$pc_identity" | jq -r '.team.id')
    if [[ $destination == self || $destination == $user_id ]]; then
        postcard_self "$user_id" || return
        destination=$REPLY
    fi
    if [[ $destination == [UW]* ]]; then
        postcard_api conversations.open "$(jq -cn --arg user "$destination" '{users:$user}')" || return
        destination=$(print -r -- "$pc_response" | jq -er '.channel.id | strings') || return
    fi
    payload=$(print -rn -- "$card"$'\n\n'"$message" | jq -Rsc \
        --arg channel "$destination" --arg thread "$thread" --arg card "$card" --arg message "$message" '
        {channel:$channel, text:(gsub("&";"&amp;")|gsub("<";"&lt;")|gsub(">";"&gt;")),
         blocks:[
           {type:"context",elements:[{type:"mrkdwn",text:("*" +
             ($card|gsub("&";"&amp;")|gsub("<";"&lt;")|gsub(">";"&gt;")) +
             "* :mailbox_with_mail:")}]},
           {type:"divider"},
           {type:"markdown",text:$message},
           {type:"divider"}
         ],mrkdwn:false,parse:"none",link_names:false,
         unfurl_links:false, unfurl_media:false} +
        (if $thread == "" then {} else {thread_ts:$thread,reply_broadcast:false} end)') || return
    postcard_receipt_lock "$team_id" "$destination" || return
    if ! postcard_api chat.postMessage "$payload"; then
        postcard_receipt_unlock >/dev/null 2>&1
        return 1
    fi
    receipt=$(print -r -- "$pc_response" | jq -ec --arg card "$card" \
        --arg thread "$thread" '
        select(.channel | type == "string" and test("^[CDG][A-Z0-9]+$")) |
        select(.ts | type == "string" and test("^[0-9]+\\.[0-9]{6}$")) |
        {channel,ts,thread_ts:(if $thread == "" then .ts else $thread end),
         sender:.message.user,card:$card,permalink:null}') || {
        postcard_receipt_unlock >/dev/null 2>&1
        postcard_error 'Slack reported success without an address; inspect Slack before posting again'
        return 1
    }
    origin=$(print -r -- "$pc_credentials" | jq -c \
        '{client_id,team_id:.team.id,user_id:.user.id}') || origin=''
    proof=$(print -r -- "$pc_response" "$origin" | jq -sc \
        --arg team "$team_id" --arg channel "$destination" --arg thread "$thread" \
        '{response:.[0],origin:.[1],expected:{team:$team,channel:$channel,
          thread:(if $thread == "" then null else $thread end),user:.[1].user_id}}') || true
    if [[ -z $proof ]] || ! print -r -- "$proof" |
        python3 "$postcard[root]/share/postcard/receipt.py" publish \
            "$HOME/.local/state/postcard/sent"; then
        print -u2 -- 'postcard: message was posted; local send receipt was not saved. An own-post notification may occur. Do not repost.'
    fi
    postcard_receipt_unlock ||
        print -u2 -- 'postcard: message was posted; local send receipt lock release failed. Do not repost.'
    if postcard_form_api chat.getPermalink "$(print -r -- "$receipt" | jq -c '{channel,message_ts:.ts}')"; then
        permalink=$(print -r -- "$pc_response" | jq -r '.permalink // empty')
    else
        print -u2 'postcard: message was posted; permalink lookup failed. Do not repost.'
    fi
    print -r -- "$receipt" "$context" | jq -s --arg url "$permalink" \
        '.[0] + .[1] | .permalink = (if $url == "" then null else $url end)'
}

function postcard_read {
    typeset destination=$1 timestamp=$2 thread=$3 payload context
    postcard_ready || return
    context=$(postcard_context) || return
    payload=$(jq -cn --arg channel "$destination" --arg ts "$timestamp" \
        '{channel:$channel,oldest:$ts,latest:$ts,inclusive:true,limit:1}') || return
    if [[ -n $thread ]]; then
        payload=$(print -r -- "$payload" | jq -c --arg ts "$thread" '. + {ts:$ts,limit:15}') || return
        postcard_form_api conversations.replies "$payload" || return
    else
        postcard_api conversations.history "$payload" || return
    fi
    print -r -- "$pc_response" | jq -e --arg ts "$timestamp" --arg channel "$destination" --argjson context "$context" '
        [.messages[] | select(.ts == $ts)] | select(length == 1) | .[0] |
        {channel:$channel,ts,thread_ts:(.thread_ts // .ts),sender:.user,
         text,blocks,subtype,app_id,bot_id} + $context' || {
        postcard_error 'exact message was not returned; a reply needs --thread with its parent timestamp'
        return 1
    }
}

function postcard_search {
    typeset query=$1 count=$2 page=$3 result
    postcard_ready || return
    # The line-paired OAuth form helper cannot carry arbitrary query newlines.
    pc_body=$(jq -nr --arg query "$query" --arg count "$count" --arg page "$page" '
        {query:$query,count:$count,page:$page,
         sort:"timestamp",sort_dir:"desc",highlight:"false"} |
        to_entries | map((.key|@uri) + "=" + (.value|@uri)) | join("&")') || return
    postcard_http search.messages application/x-www-form-urlencoded || return
    # Buffer the whole result: a malformed later match must not leave partial
    # success on stdout. Credentials enter jq only over stdin, never argv.
    result=$(print -r -- "$pc_credentials" "$pc_response" | jq -se \
        --arg account "$pc_account" --arg requested_query "$query" --argjson count "$count" --argjson page "$page" \
        -f "$postcard[root]/share/postcard/search.jq" 2>/dev/null) || {
        postcard_error 'invalid search response: malformed matches or invalid/conflicting pagination'
        return 1
    }
    print -r -- "$result"
}

function postcard_people {
    typeset request=$1 context payload inspected cursor='' result
    typeset -a pages=() cursors=()
    postcard_ready || return
    context=$(postcard_context) || return
    payload=$(jq -cn '{limit:200,cursor:""}') || return
    while true; do
        postcard_form_api users.list "$payload" || return
        inspected=$(print -r -- "$pc_response" |
            python3 "$postcard[root]/share/postcard/people.py" page) || {
            postcard_error 'invalid people response or pagination'; return 1
        }
        pages+=( "$pc_response" )
        cursor=$(print -r -- "$inspected" | jq -r '.cursor') || return
        [[ -n $cursor ]] || break
        (( ! cursors[(Ie)$cursor] )) || {
            postcard_error 'Slack returned a repeated pagination cursor'; return 1
        }
        cursors+=( "$cursor" )
        payload=$(print -r -- "$payload" | jq -c --arg cursor "$cursor" '.cursor = $cursor') || return
    done
    result=$(print -rl -- "$request" "$context" "${pages[@]}" |
        jq -s '{request:.[0],context:.[1],pages:.[2:]}' |
        python3 "$postcard[root]/share/postcard/people.py" project) || {
        postcard_error 'invalid people response: malformed or duplicate users'
        return 1
    }
    print -r -- "$result"
}
