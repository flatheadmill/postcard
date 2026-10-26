function :help:renewer {
    help=$(<${functions_source[:help:renewer]:A:h}/help.md)
}

function :args:renewer {
    eval "$(args -bx h,help -- "$@")"
}

function :execute:renewer {
    (( $# == 0 )) || abend 'renewer takes no positional arguments'
    typeset root=${XDG_CONFIG_HOME:-$HOME/.config}/postcard/accounts
    typeset directory selected account
    typeset -a accounts=() fields=()
    integer failed=0
    if [[ -v o_account ]]; then
        accounts=( "$o_account" )
    else
        for directory in $root/*(N/); do
            [[ -e $directory/credentials.json || -L $directory/credentials.json ]] && accounts+=( ${directory:t} )
        done
    fi
    for selected in $accounts; do
        typeset o_account=$selected
        if ! postcard_account; then
            failed=1
        elif [[ $renewal_health != ready ]]; then
            warn 'account %s: %s' "$account" "$renewal_message"
            if [[ $renewal_health == login ]]; then
                warn 'run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"
            fi
            failed=1
        fi
    done
    return $failed
}
