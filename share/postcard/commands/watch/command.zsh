function :help:watch {
    help=$(<${functions_source[:help:watch]:A:h}/help.md)
}

function :args:watch {
    typeset o_interval=15
    eval "$(args ,slug -r ,reader -d ,interval -bx h,help -- "$@")"
}

function :execute:watch {
    setopt localoptions localtraps pipefail no_bgnice extendedglob
    (( $# == 0 )) || abend 'watch takes no positional arguments'
    [[ ! -v o_slug ]] || postcard_label_check slug "$o_slug" || return
    [[ $o_reader =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]] || abend 'invalid reader name'
    [[ $o_interval == <-> ]] || abend 'interval must be a positive whole number of seconds'
    typeset interval=${o_interval##0#}
    [[ -n $interval ]] || abend 'interval must be a positive whole number of seconds'
    # zselect parses centiseconds into a signed native long. Check before
    # appending the two zeroes so a large argument cannot wrap into a busy loop.
    (( $#interval < 17 )) || {
        [[ $#interval == 17 && ! $interval > 92233720368547758 ]] || abend 'interval exceeds the native timer range'
    }

    typeset account channel ts after cursor record work='' sent_dir='' saved_umask=$(umask)
    typeset health='' current_health notice
    typeset directory=${functions_source[:execute:watch]:A:h}
    typeset -a fields=() metadata=() principal=() sent_parents=() candidates=()
    typeset -A seen=()
    integer count=100 child generation pending=0 found postcard_account_allow_expired=1 watch_stopping=0 login_notified=0
    float next_probe=0 next_maintenance=0 now deadline
    zmodload zsh/parameter zsh/zselect zsh/stat || return

    function postcard_watch_cleanup {
        watch_stopping=1
        typeset job
        for job in ${(k)jobstates}; do
            kill -TERM %$job 2>/dev/null
        done
        wait 2>/dev/null
        [[ -z $work ]] || rm -rf -- "$work"
        work=''
        umask $saved_umask
    }
    function postcard_watch_read {
        postcard_reader_read || return
        [[ $metadata[1] == $channel && $metadata[2] == $ts ]] || {
            warn 'reader %s changed its thread address' "$o_reader"; return 1
        }
    }
    function postcard_watch_notice {
        # Like the bell, a health line must remain interruptible on a full pipe.
        print -r -- "$notice" &
        child=$!
        wait $child || { warn 'watch notification output failed'; return 1; }
    }
    function postcard_watch_own {
        [[ -n $sent_dir ]] || return 1
        typeset parent candidate file contents
        typeset -a receipts=()
        typeset -A attributes=()
        for parent in $sent_parents; do
            [[ -d $parent && ! -L $parent && -O $parent ]] || return 1
            zstat -H attributes -- $parent 2>/dev/null || return 1
            (( (attributes[mode] & 8#77) == 0 )) || return 1
        done
        for candidate in $candidates; do
            # Whole-page validation already proved a digits-dot-digits ts.
            file=$sent_dir/$candidate.json
            [[ -f $file && ! -L $file && -O $file && -r $file ]] || return 1
            zstat -H attributes -- $file 2>/dev/null || return 1
            (( (attributes[mode] & 8#77) == 0 )) || return 1
            contents=$(<$file) || return 1
            [[ $contents != *$'\0'* ]] || return 1
            receipts+=( "$candidate" "$contents" )
        done
        # Frame each file separately so malformed or multiple JSON documents
        # cannot borrow another candidate's path when the batch is parsed.
        printf '%s\0' "${receipts[@]}" > $work/receipts || return 1
        jq -e -L $directory/../../jq --arg after "$after" \
            --arg team "$fields[2]" --arg channel "$channel" \
            --arg parent "$ts" --arg slug "$o_slug" \
            --rawfile records $work/receipts -f $directory/own.jq \
            $work/page > /dev/null 2>/dev/null &
        child=$!
        wait $child
    }
    # Signal paths clean up explicitly; cleanup is safe if always also unwinds.
    # Reap jobs before removing scratch, even just before a PID was recorded.
    trap 'postcard_watch_cleanup; exit 130' INT
    trap 'postcard_watch_cleanup; exit 143' TERM HUP
    trap 'warn "watch notification output failed"; postcard_watch_cleanup; exit 141' PIPE
    typeset postcard_account_cleanup=postcard_watch_cleanup
    {
        umask 077
        work=$(mktemp -d "${TMPDIR:-/tmp}/postcard.watch.XXXXXX") || return
        postcard_account_read || return
        # Pin the selection even while access is expired. Another saved account
        # cannot redirect this watch, and login may change tokens, not identity.
        typeset o_account=$account
        principal=( "$fields[1]" "$fields[2]" "$fields[3]" )
        record=${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/$account/readers/$o_reader.json
        postcard_reader_read || return
        channel=$metadata[1] ts=$metadata[2]
        if [[ -v o_slug ]]; then
            postcard_sent_directory || { sent_dir=''; warn 'local receipts unavailable; own-post notifications may occur'; }
        fi
        while true; do
            postcard_watch_read || return
            now=$EPOCHREALTIME
            # Maintenance has its own deadline. Neither an unread bell nor a
            # long message interval can postpone credential health indefinitely.
            if (( now >= next_maintenance || (now >= next_probe && metadata[4] != pending) )) || [[ $health != ready:1 ]]; then
                postcard_account || return
                [[ $fields[1] == $principal[1] && $fields[2] == $principal[2] && $fields[3] == $principal[3] ]] || {
                    warn 'account %s changed its client, workspace or user binding' "$account"; return 1
                }
                next_maintenance=$(( EPOCHREALTIME + 900 ))
                # Notice access expiry promptly, and honor a shorter Retry-After.
                (( fields[5] <= EPOCHSECONDS || fields[5] >= next_maintenance )) || next_maintenance=$fields[5]
                (( fields[8] <= EPOCHSECONDS || fields[8] >= next_maintenance )) || next_maintenance=$fields[8]
                current_health=$renewal_health:$grant_usable
                if [[ $current_health != $health ]]; then
                    notice=''
                    # Contention, deferred renewal and recovery are routine.
                    # Only a human-action boundary earns a window notification;
                    # expiry or intervening contention must not repeat it.
                    if [[ $renewal_health == login ]] && (( ! login_notified )); then
                        notice="Postcard account $account cannot renew automatically. Inform the human user that reauthentication is required. Do not troubleshoot, repair credentials, or start competing login attempts. Ask the user to coordinate one login: postcard --account ${(q)account} login --client-id ${(q)fields[1]}. Watch will resume automatically after reauthentication."
                        postcard_watch_notice || return
                        login_notified=1
                    elif [[ $renewal_health == ready ]] && (( grant_usable )); then
                        login_notified=0
                    fi
                    health=$current_health
                fi
            fi
            if (( metadata[4] != pending && grant_usable && EPOCHREALTIME >= next_probe )); then
                after=$metadata[3] generation=$metadata[4]
                cursor='' seen=() found=0
                # Each probe holds its boundary and grant through every page.
                # Own messages remain unread. Follow their pages until an
                # unproven message rings or terminal traversal proves quiet.
                while true; do
                    postcard_thread_page || return
                    jq -r -L $directory/../../jq --arg after "$after" \
                        -f $directory/newer.jq $work/page > $work/newer 2>/dev/null &
                    child=$!
                    wait $child || { warn 'cannot compare watch timestamps'; return 1; }
                    candidates=( ${(f)"$(<$work/newer)"} )
                    if (( $#candidates )); then
                        if [[ ! -v o_slug ]] || ! postcard_watch_own; then
                            found=1
                            break
                        fi
                    fi
                    jq -jr '.paging.next_cursor // "" |
                        if contains("\u0000") then error("invalid cursor") else . + "\u0001" end' \
                        $work/page > $work/cursor 2>/dev/null &
                    child=$!
                    wait $child || { warn 'invalid watch pagination cursor'; return 1; }
                    cursor=$(<$work/cursor)
                    cursor=${cursor%$'\1'}
                    [[ -n $cursor ]] || break
                    (( ! ${+seen[$cursor]} )) || { warn 'Slack repeated a pagination cursor'; return 1; }
                    seen[$cursor]=1
                done
                if (( found )); then
                    # A publication during the probe discards its observation.
                    # A publication racing stdout may still yield a stale hint;
                    # pending always names the generation actually probed.
                    postcard_watch_read || return
                    if (( metadata[4] == generation )); then
                        # A builtin can defer traps while stdout is blocked.
                        # Own it as a job so the parent can stop and reap it.
                        # Account and reader grammars make these bare command
                        # arguments safe to reproduce in the instruction.
                        print -r -- 'You have messages: `postcard --account '"$account"' thread --reader '"$o_reader"'`.' &
                        child=$!
                        wait $child || {
                            warn 'watch notification output failed'; return 1
                        }
                        pending=$generation
                    fi
                fi
                next_probe=$(( EPOCHREALTIME + interval ))
            fi
            # Local inspection retains the requested interval. Health wakes may
            # occur earlier, but they never move the next Slack probe forward.
            now=$EPOCHREALTIME
            deadline=$(( now + interval ))
            (( next_probe <= now || next_probe >= deadline )) || deadline=$next_probe
            (( next_maintenance >= deadline )) || deadline=$next_maintenance
            # Waiting on a job keeps cancellation out of zselect's EINTR loop.
            integer delay=$(( (deadline - now) * 100 ))
            (( delay > 0 )) || delay=1
            zselect -t $delay &
            child=$!
            wait $child
        done
    } always {
        integer watch_result=$?
        if (( watch_result != 0 && ! watch_stopping )); then
            notice="Postcard watch stopped for account ${account:-${o_account:-unknown}}: inspect stderr, repair the account or reader, and restart postcard watch --reader $o_reader with the same --account."
            postcard_watch_notice
        fi
        postcard_watch_cleanup
    }
}
