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
    # pipefail propagates a failed hash command through the encoding pipeline.
    setopt localoptions localtraps nomultibyte pipefail

    [[ -n $o_account ]] || abend '--account is required'
    (( $# == 0 )) || abend 'login takes no positional arguments'

    # Keep the verifier in memory for the code exchange. Only its SHA-256
    # challenge goes to the browser; state identifies this authorization attempt.
    typeset state verifier challenge authorization_url
    state=$(openssl rand -hex 32) || return
    verifier=$(openssl rand -hex 32) || return
    challenge=$(print -rn -- "$verifier" | openssl dgst -sha256 -binary |
        openssl base64 -A) || return
    challenge=${${${challenge//+/-}//\//_}//=/}
    authorization_url=$(jq -er --arg client "$o_client_id" \
        --arg state "$state" --arg challenge "$challenge" '
        .oauth_config |
        "https://slack.com/oauth/v2/authorize?" + ({
            client_id: $client,
            redirect_uri: .redirect_urls[0],
            user_scope: (.scopes.user | join(",")),
            state: $state,
            code_challenge: $challenge,
            code_challenge_method: "S256"
        } | to_entries | map((.key | @uri) + "=" + (.value | @uri)) | join("&"))
    ' "${zshctl[argzero]:A:h:h}/slack-manifest.json") || return

    zmodload zsh/net/tcp zsh/zselect zsh/system zsh/datetime || return

    # These quoted commands run when their signals arrive and end the process;
    # the OS then closes its sockets. The exit statuses follow 128 + signal:
    # 130 for SIGINT (2), 143 for SIGTERM (15). HUP is treated as termination
    # and also exits 143. The always block below handles socket cleanup when
    # the function returns normally, including an error return.
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    integer listener=-1 connection=-1 result=1
    typeset REPLY code oauth_error
    typeset -a reply=()
    typeset port=8765
    typeset response='400 Bad Request' body=$'Invalid request.\n'

    {
        ztcp -l $port || return
        listener=$REPLY
        print -r -u2 -- "Listening on http://localhost:$port/auth (up to five minutes)."
        # Listen before opening the browser so an immediate redirect can connect.
        open "$authorization_url" || return
        zselect -r -t 30000 $listener || return 1
        ztcp -a -t $listener || return
        connection=$REPLY
        ztcp -c $listener
        listener=-1

        if postcard_callback_read $connection $state; then
            # Keep the code in memory for the later token exchange.
            code=$reply[1]
            oauth_error=$reply[2]
            response='200 OK'
            if [[ -n $oauth_error ]]; then
                body=$'Slack authorization was declined or failed.\n'
            else
                body=$'Authorization callback verified. Token exchange is not yet implemented.\n'
                result=0
            fi
        fi

        printf 'HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
            "$response" "${#body}" "$body" >&$connection || return 1
        return $result
    } always {
        (( connection < 0 )) || ztcp -c $connection
        (( listener < 0 )) || ztcp -c $listener
    }
}
