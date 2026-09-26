# These operations run inside one selected-account session. Only public facts
# cross to runtime.py, which writes stdout and waits without a grant lock.
function postcard_reader_path {
    typeset reader=$1 directory
    python3 - "$reader" "$postcard[root]/share/postcard" <<'PY' || return
import sys
sys.path.insert(0, sys.argv[2])
from thread import reader_name
reader_name(sys.argv[1])
PY
    for directory in "$HOME/.local/state/postcard" "$HOME/.local/state/postcard/accounts" \
        "$HOME/.local/state/postcard/accounts/$pc_account" \
        "$HOME/.local/state/postcard/accounts/$pc_account/cursors"; do
        postcard_private_directory "$directory" || return
    done
    REPLY=$directory/$reader.json
}

function postcard_reader_binding {
    print -r -- "$pc_credentials" | jq -c '{client_id,team_id:.team.id,user_id:.user.id}'
}

function postcard_reader_prepare {
    typeset request=$1 binding address file
    address=$(postcard_resolve_address "$(print -r -- "$request" | jq -c '.address')") || return
    request=$(print -r -- "$request" "$address" | jq -sc '.[0] + {address:.[1]}') || return
    binding=$(postcard_reader_binding) || return
    postcard_reader_path "$(print -r -- "$request" | jq -r '.reader')" || return
    file=$REPLY
    print -r -- "$request" "$binding" | jq -s '{request:.[0],binding:.[1]}' |
        python3 "$postcard[root]/share/postcard/reader.py" prepare "$file"
}

function postcard_reader_read {
    typeset ticket result request
    ticket=$(postcard_reader_prepare "$1") || return
    request=$(print -r -- "$ticket" | jq -c '{address,projection:{kind:"after",after:.after}}') || return
    result=$(postcard_thread "$request") || return
    print -r -- "$ticket" "$result" | jq -s '
        {ticket:.[0],result:(.[1] + {cursor:(.[0] | {name:.reader,start_after,after,looks})})}'
}

function postcard_reader_commit {
    typeset value=$1 file binding
    postcard_reader_path "$(print -r -- "$value" | jq -r '.ticket.reader')" || return
    file=$REPLY
    binding=$(postcard_reader_binding) || return
    print -r -- "$value" "$binding" | jq -s '.[0] + {binding:.[1]}' |
        python3 "$postcard[root]/share/postcard/reader.py" commit "$file"
}

function postcard_watch_probe {
    typeset value=$1 request ticket key pending pc_thread_result
    integer result=0
    request=$(print -r -- "$value" | jq -c '.request') || return
    pending=$(print -r -- "$value" | jq -c '.pending') || return
    ticket=$(postcard_reader_prepare "$request") || return
    key=$(print -r -- "$ticket" | jq -c '{binding,address,start_after,looks}') || return
    if print -r -- "$key" "$pending" | jq -se '.[0] == .[1]' >/dev/null; then
        jq -cn --arg account "$pc_account" --argjson key "$key" '{account:$account,key:$key,found:false}'
        return
    fi
    # Renewal is never covered by the observation retry policy.
    postcard_ready || return
    request=$(print -r -- "$ticket" | jq -c '{address,projection:{kind:"after",after:.after}}') || return
    pc_probe=1
    postcard_thread_fetch "$request" probe || result=$?
    pc_probe=0
    if (( result == 75 )); then
        jq -cn --arg account "$pc_account" --argjson delay "$pc_retry_after" '{account:$account,retry_after:$delay}'
    elif (( result )); then
        return $result
    else
        jq -cn --arg account "$pc_account" --argjson key "$key" --argjson found "$pc_thread_result" \
            '{account:$account,key:$key,found:$found}'
    fi
}
