function :help:login {
    help=$(<${functions_source[:help:login]:A:h}/help.md)
}

function :args:login {
    eval "$(args -r ,client-id -bx h,help -- "$@")"
}

function postcard_query_decode {
    typeset input=$1 byte
    REPLY=''
    while [[ -n $input ]]; do
        case $input[1] in
            (%)
                [[ $input[2,3] == [[:xdigit:]][[:xdigit:]] ]] || return 1
                printf -v byte '%b' "\\x${input[2,3]}"
                input=$input[4,-1]
                ;;
            (+) byte=' '; input=$input[2,-1] ;;
            (*) byte=$input[1]; input=$input[2,-1] ;;
        esac
        [[ $byte != [[:cntrl:]] ]] || return 1
        REPLY+=$byte
    done
}

function postcard_http_line {
    # Read a CRLF-terminated line into REPLY. The server owns http_buffer,
    # http_bytes and http_deadline so limits apply across every read and header.
    # Limits include line endings: 1 KiB per line, 8 KiB for the whole request head.
    typeset chunk
    float remaining
    integer size
    while [[ $http_buffer != *$'\n'* ]]; do
        remaining=$(( http_deadline - EPOCHREALTIME ))
        (( remaining > 0 && ${#http_buffer} < 1024 && http_bytes < 8192 )) || return 1
        size=$(( 1024 - ${#http_buffer} ))
        (( size <= 8192 - http_bytes )) || size=$(( 8192 - http_bytes ))
        sysread -i $1 -s $size -t $remaining chunk || return 1
        http_buffer+=$chunk
        (( http_bytes += ${#chunk} ))
    done
    REPLY=${http_buffer%%$'\n'*}
    http_buffer=${http_buffer#*$'\n'}
    [[ $REPLY == *$'\r' && ${#REPLY} -lt 1024 ]] || return 1
    REPLY=${REPLY%$'\r'}
}

function postcard_callback_read {
    setopt localoptions nomultibyte

    integer connection=$1 http_bytes=0 host_seen=0
    float http_deadline=$(( EPOCHREALTIME + 2 ))
    typeset state=$2 http_buffer='' REPLY name value
    typeset header_name=$'^[!#$%&\'*+.^_`|~0-9A-Za-z-]+$'

    postcard_http_line $connection || return 1
    # The callback is a GET to /auth, optionally followed by a query,
    # using HTTP/1.0 or HTTP/1.1. Require exactly three fields:
    # extra spaces produce empty fields and are rejected along with
    # missing or extra fields. The target must contain no literal
    # whitespace or control bytes, including tabs that survive the
    # space split.
    typeset -a request=( "${(@s: :)REPLY}" )
    (( ${#request} == 3 )) || return 1
    [[ $request[1] == GET && $request[3] == HTTP/1.[01] ]] || return 1
    [[ $request[2] == /auth || $request[2] == /auth\?* ]] || return 1
    [[ $request[2] != *[[:cntrl:][:space:]]* ]] || return 1

    # Read headers through the blank line that ends them.
    # Host must be nonempty and appear at most once. Content-Length
    # must be 0 if present; Transfer-Encoding and Expect are rejected.
    # This callback accepts no request body.
    while true; do
        postcard_http_line $connection || return 1
        [[ -n $REPLY ]] || break
        [[ $REPLY == *:* ]] || return 1
        name=${REPLY%%:*}
        value=${REPLY#*:}
        [[ $name =~ $header_name ]] || return 1
        # Allow horizontal tabs in values, but no other control bytes.
        [[ ${value//$'\t'/} != *[[:cntrl:]]* ]] || return 1
        case ${(L)name} in
            (host)
                (( ! host_seen )) || return 1
                [[ -n ${value//[[:space:]]/} ]] || return 1
                host_seen=1
                ;;
            (content-length)
                [[ ${value//[[:space:]]/} == 0 ]] || return 1
                ;;
            (transfer-encoding|expect) return 1 ;;
        esac
    done
    [[ $request[3] == HTTP/1.0 ]] || (( host_seen )) || return 1

    # Split before decoding so escaped ampersands and equals signs
    # stay inside their fields. Decode names too, so an escaped name
    # cannot hide a duplicate state, code, or error.
    [[ $request[2] == /auth\?* && $request[2] != *\#* ]] || return 1
    typeset query=${request[2]#*\?} field
    typeset -A callback=()
    for field in "${(@s:&:)query}"; do
        [[ $field == *=* ]] || return 1
        postcard_query_decode "${field%%=*}" || return 1
        name=$REPLY
        postcard_query_decode "${field#*=}" || return 1
        case $name in
            (state|code|error)
                [[ ! -v callback[$name] && -n $REPLY ]] || return 1
                callback[$name]=$REPLY
                ;;
        esac
    done

    # Accept only our authorization attempt, with exactly one outcome.
    [[ ${callback[state]} == "$state" ]] || return 1
    (( ${+callback[code]} + ${+callback[error]} == 1 )) || return 1
    reply=( "${callback[code]}" "${callback[error]}" )
}

function postcard_grant_check {
    # Both a saved grant and a new exchange must supply this complete record.
    # Slurping also rejects empty input and more than one JSON document.
    jq -ces '
        def text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
        def seconds: type == "number" and . > 0 and floor == .;
        select(length == 1) | .[0] | select(type == "object") |
        select((.client_id | text) and (.team_id | text) and (.user_id | text)
            and (.access_token | text) and (.scope | text)) |
        select(if has("refresh_token") or has("expires_at") then
            (.refresh_token | text) and (.expires_at | seconds)
        else true end)
    ' 2>/dev/null
}

# ztcp binds the chosen port to 0.0.0.0, all IPv4 interfaces; it offers
# no loopback-only bind. We accept that for this short-lived login
# listener: keeping it in Zsh is worth allowing a failed login when
# another client reaches the port first.
#
# If the host exposes this port to the public Internet, an attacker
# could win the race with the browser, send junk, or stall the request.
# In that situation, failing to log in is an acceptable outcome. We
# close the listener immediately after the first accept and bound the
# accepted connection by byte limits and a request deadline. Valid or
# invalid, that is the only request: no second accept and no retry.
# These limits bound our work; they do not protect the host or network
# from a traffic flood.
function :execute:login {
    # localtraps restores the caller's signal handlers when login returns.
    # nomultibyte makes string lengths and indexing count bytes: the request
    # limits and HTTP Content-Length are byte counts, regardless of locale.
    # pipefail propagates failures in the hash and exchange pipelines.
    setopt localoptions localtraps nomultibyte pipefail

    [[ -n $o_account ]] || abend '--account is required'
    (( $# == 0 )) || abend 'login takes no positional arguments'
    [[ $o_account =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]] ||
        abend 'account names must be 1–64 ASCII letters, digits, dots, underscores or hyphens, starting with a letter or digit'

    # Keep the verifier in memory for the code exchange. Only its SHA-256
    # challenge goes to the browser; state identifies this authorization attempt.
    typeset state verifier challenge authorization_url redirect_uri
    redirect_uri=$(jq -er '.oauth_config.redirect_urls[0]' \
        "${zshctl[argzero]:A:h:h}/slack-manifest.json") || return
    state=$(openssl rand -hex 32) || return
    verifier=$(openssl rand -hex 32) || return
    challenge=$(print -rn -- "$verifier" | openssl dgst -sha256 -binary |
        openssl base64 -A) || return
    challenge=${${${challenge//+/-}//\//_}//=/}
    authorization_url=$(jq -er --arg client "$o_client_id" --arg redirect "$redirect_uri" \
        --arg state "$state" --arg challenge "$challenge" '
        .oauth_config |
        "https://slack.com/oauth/v2/authorize?" + ({
            client_id: $client,
            redirect_uri: $redirect,
            user_scope: (.scopes.user | join(",")),
            state: $state,
            code_challenge: $challenge,
            code_challenge_method: "S256"
        } | to_entries | map((.key | @uri) + "=" + (.value | @uri)) | join("&"))
    ' "${zshctl[argzero]:A:h:h}/slack-manifest.json") || return

    zmodload zsh/net/tcp zsh/zselect zsh/system zsh/datetime || return

    integer listener=-1 connection=-1 lock=-1 result=1 started
    typeset REPLY code oauth_error grant exchanged binding=null staged=''
    typeset -a reply=()
    typeset port=8765
    typeset response='400 Bad Request' body=$'Invalid request.\n'
    typeset config_root=${XDG_CONFIG_HOME:-$HOME/.config}/postcard
    typeset account_dir=$config_root/accounts/$o_account
    typeset state_root=${XDG_STATE_HOME:-$HOME/.local/state}/postcard
    typeset state_dir=$state_root/accounts/$o_account
    typeset credentials=$account_dir/credentials.json lock_file=$state_dir/login.lock
    typeset saved_umask=$(umask)

    # Signals remove the private staging file before exiting. The OS releases
    # the lock and sockets; always handles cleanup on ordinary returns.
    # INT exits 130; TERM and HUP exit 143, as in the callback-only listener.
    trap '[[ -z $staged ]] || rm -f -- "$staged"; exit 130' INT
    trap '[[ -z $staged ]] || rm -f -- "$staged"; exit 143' TERM HUP

    {
        umask 077
        [[ ! -L $account_dir && ! -L $state_dir ]] || {
            warn 'account directories must not be symbolic links'; return 1
        }
        mkdir -p -- $account_dir $state_dir || return
        chmod 700 $config_root $config_root/accounts \
            $account_dir $state_root $state_root/accounts $state_dir || return
        [[ ! -L $lock_file && ( ! -e $lock_file || -f $lock_file ) ]] || {
            warn 'invalid login lock file'; return 1
        }
        # Append creates a missing lock without replacing an existing inode.
        # Keep that inode after unlocking so every login locks the same file.
        : >> $lock_file || return
        chmod 600 $lock_file || return
        # A minimal timed attempt distinguishes contention (status 2) from
        # other lock errors; do not queue another authorization behind this one.
        zsystem flock -t 0.001 -f lock $lock_file
        case $? in
            (0) ;;
            (2) warn 'account %s is busy' "$o_account"; return 1 ;;
            (*) warn 'could not lock account %s' "$o_account"; return 1 ;;
        esac

        # Reauthorization may replace tokens, but must preserve the account's
        # identity. An unreadable binding is an error, not a new account.
        if [[ -e $credentials || -L $credentials ]]; then
            [[ -f $credentials && ! -L $credentials ]] || {
                warn 'invalid existing credential file'; return 1
            }
            binding=$(postcard_grant_check < $credentials |
                jq -ce '{client_id, team_id, user_id}') || {
                warn 'existing credentials are incomplete or unrecognized'; return 1
            }
            print -rn -- "$binding" | jq -e --arg client "$o_client_id" \
                '.client_id == $client' >/dev/null || {
                warn 'client ID does not match the saved account'; return 1
            }
        fi

        ztcp -l $port || return
        listener=$REPLY
        print -r -u2 -- "Listening on http://localhost:$port/auth (up to five minutes)."
        # Listen before opening the browser so an immediate redirect can connect.
        open "$authorization_url" || return
        zselect -r -t 30000 $listener || {
            warn 'timed out waiting for Slack authorization'; return 1
        }
        ztcp -a -t $listener || return
        connection=$REPLY
        ztcp -c $listener
        listener=-1

        if postcard_callback_read $connection $state; then
            code=$reply[1]
            oauth_error=$reply[2]
            response='200 OK'
            if [[ -n $oauth_error ]]; then
                body=$'Slack authorization was declined or failed.\n'
            else
                body=$'Authorization callback received. Check the terminal for the login result.\n'
                result=0
            fi
        fi

        # A browser may leave after submitting the callback. Its acknowledgement
        # is best effort; only the validated callback decides whether to exchange.
        function {
            setopt localtraps
            trap '' PIPE
            printf 'HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
                "$response" "${#body}" "$body" >&$connection 2>/dev/null
        } || :
        ztcp -c $connection
        connection=-1
        (( result == 0 )) || { warn '%s' "${body%$'\n'}"; return 1; }

        # Secret values travel through stdin, not curl or jq arguments. Do not
        # retry a code exchange: Slack may consume the code before a failure.
        started=$EPOCHSECONDS
        exchanged=$(printf '%s\0' "$o_client_id" "$code" "$verifier" "$redirect_uri" |
            jq -Rjs 'split("\u0000") | {
                client_id: .[0], code: .[1], code_verifier: .[2], redirect_uri: .[3],
                grant_type: "authorization_code"
            } | to_entries | map((.key | @uri) + "=" + (.value | @uri)) | join("&")' |
            curl -q --silent --show-error --fail --proto '=https' \
                --connect-timeout 10 --max-time 30 \
                --header 'Content-Type: application/x-www-form-urlencoded' \
                --data-binary @- https://slack.com/api/oauth.v2.access) || {
            warn 'Slack token exchange failed; authorize again'; return 1
        }

        # This command installs workspace user grants. Bot credentials and
        # organization-wide installs are not substitutes for that identity.
        # Anchor expiry before the request so network time cannot extend it.
        grant=$(print -rn -- "$exchanged" |
            jq -ces --arg client "$o_client_id" --argjson started $started '
                select(length == 1) | .[0] | select(type == "object") |
                select(.ok == true) |
                select(if has("is_enterprise_install") then .is_enterprise_install == false else true end) |
                select(.authed_user.token_type == "user") |
                .authed_user as $user |
                {client_id: $client, team_id: .team.id, user_id: $user.id,
                    access_token: $user.access_token, scope: $user.scope} +
                (if ($user | has("refresh_token") or has("expires_in")) then
                    if ($user.expires_in | type == "number" and . > 0 and floor == .) then
                        {refresh_token: $user.refresh_token, expires_at: ($started + $user.expires_in)}
                    else error("invalid expiry") end
                else {} end)
            ' 2>/dev/null | postcard_grant_check) || {
            warn 'Slack did not return a complete workspace user grant'; return 1
        }
        print -rn -- "$grant" | jq -e --argjson binding "$binding" '
            $binding == null or ({client_id, team_id, user_id} == $binding)
        ' >/dev/null || {
            warn 'Slack identity does not match the saved account'; return 1
        }

        # Rename within the private account directory is the installation
        # boundary. Earlier failures leave the old file untouched. This cannot
        # undo an exchange at Slack or promise durability across a power loss.
        staged=$(mktemp "$account_dir/.credentials.XXXXXX") || return
        print -r -- "$grant" > $staged || return
        chmod 600 $staged || return
        mv -f -- $staged $credentials || return
        staged=''
        print -r -- "Logged in to account $o_account."
    } always {
        [[ -z $staged ]] || rm -f -- $staged
        (( connection < 0 )) || ztcp -c $connection
        (( listener < 0 )) || ztcp -c $listener
        (( lock < 0 )) || zsystem flock -u $lock
        umask $saved_umask
    }
}
