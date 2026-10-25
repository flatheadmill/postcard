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

    typeset account channel ts after cursor work='' sent_dir='' saved_umask=$(umask)
    typeset directory=${functions_source[:execute:watch]:A:h}
    typeset -a fields=() metadata=() principal=() sent_parents=() candidates=()
    typeset -A seen=()
    integer count=100 child generation pending=0 found
    postcard_account_read || return
    # Resolve an omitted account once. Adding another account must not change
    # the selection; subsequent grants may change the token, never the owner.
    typeset o_account=$account
    principal=( "$fields[1]" "$fields[2]" "$fields[3]" )
    typeset record=${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/$account/readers/$o_reader.json
    zmodload zsh/parameter zsh/zselect zsh/stat || return

    function postcard_watch_cleanup {
        typeset job
        for job in ${(k)jobstates}; do
            kill -TERM %$job 2>/dev/null
        done
        wait 2>/dev/null
        [[ -z $work ]] || rm -rf -- "$work"
        umask $saved_umask
    }
    function postcard_watch_read {
        postcard_reader_read || return
        [[ $metadata[1] == $channel && $metadata[2] == $ts ]] || {
            warn 'reader %s changed its thread address' "$o_reader"; return 1
        }
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
    # Explicit trap exits bypass always. Reap owned jobs before removing their
    # scratch, including a child launched just before its PID was recorded.
    trap 'postcard_watch_cleanup; exit 130' INT
    trap 'postcard_watch_cleanup; exit 143' TERM HUP
    trap 'warn "watch notification output failed"; postcard_watch_cleanup; exit 141' PIPE
    {
        umask 077
        work=$(mktemp -d "${TMPDIR:-/tmp}/postcard.watch.XXXXXX") || return
        postcard_reader_read || return
        channel=$metadata[1] ts=$metadata[2]
        if [[ -v o_slug ]]; then
            postcard_sent_directory || { sent_dir=''; warn 'local receipts unavailable; own-post notifications may occur'; }
        fi
        while true; do
            postcard_watch_read || return
            if (( metadata[4] != pending )); then
                after=$metadata[3] generation=$metadata[4]
                postcard_account_read || return
                [[ $fields[1] == $principal[1] && $fields[2] == $principal[2] && $fields[3] == $principal[3] ]] || {
                    warn 'account %s changed its client, workspace or user binding' "$account"; return 1
                }
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
            fi
            # Delay after each probe or pending inspection. A publication seen
            # at the next inspection permits a probe without a second sleep.
            # Waiting on the job keeps cancellation out of zselect's EINTR loop.
            zselect -t "${interval}00" &
            child=$!
            wait $child
        done
    } always {
        postcard_watch_cleanup
    }
}
