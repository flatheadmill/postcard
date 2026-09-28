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
    setopt localoptions localtraps nomultibyte

    zmodload zsh/net/tcp zsh/zselect zsh/system zsh/datetime || return

    # These quoted commands run when their signals arrive and end the process;
    # the OS then closes its sockets. The exit statuses follow 128 + signal:
    # 130 for SIGINT (2), 143 for SIGTERM (15). HUP is treated as termination
    # and also exits 143. The always block below handles socket cleanup when
    # the function returns normally, including an error return.
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    integer listener=-1 connection=-1 http_bytes=0 result=1
    float http_deadline # Preserve fractional seconds from EPOCHREALTIME.
    typeset http_buffer='' REPLY name value
    typeset port=${1:-8765}
    typeset response='400 Bad Request' body=$'Invalid request.\n'
    typeset header_name=$'^[!#$%&\'*+.^_`|~0-9A-Za-z-]+$'
    integer host_seen=0

    {
        ztcp -l $port || return
        listener=$REPLY
        print -r -u2 -- "Listening on http://localhost:$port/auth (up to five minutes)."
        zselect -r -t 30000 $listener || return 1
        ztcp -a -t $listener || return
        connection=$REPLY
        ztcp -c $listener
        listener=-1

        # A deadline for the whole request, including clients sending a byte at a time.
        http_deadline=$(( EPOCHREALTIME + 2 ))
        # The anonymous function lets any invalid line end parsing immediately.
        if function {
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
            [[ $request[3] == HTTP/1.0 ]] || (( host_seen ))
        }; then
            response='200 OK'
            body=$'hello, world!\n'
            result=0
        fi

        printf 'HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
            "$response" "${#body}" "$body" >&$connection || return 1
        return $result
    } always {
        (( connection < 0 )) || ztcp -c $connection
        (( listener < 0 )) || ztcp -c $listener
    }
}
