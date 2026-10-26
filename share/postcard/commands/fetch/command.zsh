function :help:fetch {
    help=$(<${functions_source[:help:fetch]:A:h}/help.md)
}

function :args:fetch {
    eval "$(args -r ,file ,output -bx h,help -- "$@")"
}

function :execute:fetch {
    setopt localoptions localtraps pipefail no_bgnice
    (( $# == 0 )) || abend 'fetch takes no positional arguments'
    [[ $o_file =~ '^F[A-Z0-9]+$' ]] || abend 'invalid file ID'
    [[ -n $o_output && $o_output[-1] != / && -d ${o_output:h} ]] ||
        abend 'output requires a filename and an existing parent directory'
    typeset destination=${o_output:a}
    [[ ! -e $destination && ! -L $destination ]] || abend 'output already exists'
    zmodload zsh/stat zsh/parameter || return
    typeset account directory=${functions_source[:execute:fetch]:A:h}
    typeset fetch_work='' fetch_umask=$(umask) method http url receipt decoded
    typeset -a fields=()
    typeset -A attributes=()
    integer child outcome bytes published=0

    function postcard_fetch_cleanup {
        typeset job
        for job in ${(k)jobstates}; do
            kill -TERM %$job 2>/dev/null
        done
        wait 2>/dev/null
        if [[ -n $fetch_work && -d $destination && ! -L $destination && $destination/bytes -ef $fetch_work/bytes ]]; then
            rm -f -- $destination/bytes
        fi
        [[ -z $fetch_work ]] || rm -rf -- "$fetch_work"
        fetch_work=''
        umask $fetch_umask
    }
    function postcard_fetch_stop {
        if (( published )) || [[ -n $fetch_work && $destination -ef $fetch_work/bytes ]]; then
            warn 'File was downloaded to %s; output was interrupted. The file already exists.' "${(q)destination}"
        fi
        postcard_fetch_cleanup
        exit $1
    }
    function postcard_fetch_request {
        method=$1
        shift
        curl -q --silent --proto '=https' --connect-timeout 10 --max-time 30 \
            --header @- --output $fetch_work/response --write-out '%{http_code}' \
            "$@" https://slack.com/api/$method \
            < <(printf 'Authorization: Bearer %s\n' "$fields[4]") > $fetch_work/http 2>/dev/null &
        child=$!
        wait $child
        outcome=$?
        http=$(<$fetch_work/http)
        (( outcome == 0 )) && [[ $http == 200 ]] || { warn 'Slack %s transport failed' "$method"; return 1; }
        jq -ces --arg method "$method" --arg file "$o_file" --arg team "$fields[2]" --arg user "$fields[3]" \
            -f $directory/response.jq $fetch_work/response > $fetch_work/checked 2>/dev/null &
        child=$!
        wait $child || { warn 'Slack %s did not confirm the identity or a downloadable original; check access and scopes' "$method"; return 1; }
    }
    typeset postcard_account_cleanup=postcard_fetch_cleanup
    trap 'postcard_fetch_stop 130' INT
    trap 'postcard_fetch_stop 143' TERM HUP
    trap 'postcard_fetch_stop 141' PIPE
    {
        umask 077
        decoded=$(print -rn -- "$destination" | jq -Rjs '. + "\u0001"' 2>/dev/null) || return
        [[ $destination == "${decoded%$'\1'}" ]] || { warn 'output path must be valid UTF-8'; return 1; }
        postcard_access || return
        [[ ,$fields[6], == *,files:read,* ]] || {
            warn 'grant lacks files:read; run postcard --account %s login --client-id %s' "${(q)account}" "${(q)fields[1]}"; return 1
        }
        # Private staging shares the destination filesystem. Slack filenames
        # never choose a path, and failed downloads never publish partial bytes.
        fetch_work=$(mktemp -d "${destination:h}/.postcard.fetch.XXXXXX") || return
        postcard_fetch_request auth.test --data '' || return
        postcard_fetch_request files.info --get --data-urlencode "file=$o_file" || return
        url=$(jq -r .url $fetch_work/checked) || return
        bytes=$(jq -r .size $fetch_work/checked) || return
        # The adjacent filter admits only the exact HTTPS Slack file host.
        # No redirect carries this bearer elsewhere; the URL stays off argv.
        curl -q --silent --proto '=https' --connect-timeout 10 --max-time 300 \
            --header @- --config /dev/fd/3 --output $fetch_work/bytes --write-out '%{http_code}' \
            3< <(printf 'url = "%s"\n' "$url") \
            < <(printf 'Authorization: Bearer %s\n' "$fields[4]") > $fetch_work/http 2>/dev/null &
        child=$!
        wait $child
        outcome=$?
        http=$(<$fetch_work/http)
        (( outcome == 0 )) && [[ $http == 200 ]] || { warn 'file download failed; output was not created'; return 1; }
        zstat -H attributes -- $fetch_work/bytes || return
        (( attributes[size] == bytes )) || { warn 'download size differs from files.info; output was not created'; return 1; }
        jq -cn --arg account "$account" --arg team "$fields[2]" --arg user "$fields[3]" \
            --arg file "$o_file" --arg output "$destination" --argjson bytes $bytes \
            '{account:$account,team_id:$team,user_id:$user,file_id:$file,output:$output,bytes:$bytes}' \
            > $fetch_work/receipt || return
        # Create a new hard link, never replace an existing name. Checking the
        # inode also catches a directory appearing at the destination mid-call.
        if [[ ! -e $destination && ! -L $destination ]]; then
            ln -n -- $fetch_work/bytes $destination 2>/dev/null &
            child=$!
            wait $child
            outcome=$?
            if (( outcome == 0 )) && [[ $destination -ef $fetch_work/bytes ]]; then
                published=1
            elif [[ -d $destination && $destination/bytes -ef $fetch_work/bytes ]]; then
                rm -f -- $destination/bytes
            fi
        fi
        (( published )) || { warn 'output was not published; destination may already exist'; return 1; }
        cat -- $fetch_work/receipt &
        child=$!
        wait $child || {
            warn 'File was downloaded to %s; JSON output failed. The file already exists.' "${(q)destination}"; return 1
        }
    } always {
        postcard_fetch_cleanup
    }
}
