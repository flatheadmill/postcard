function :help:watch {
    help=$(<${functions_source[:help:watch]:A:h}/help.md)
}

function :args:watch {
    typeset o_interval=15
    eval "$(args -r ,reader -d ,interval -bx h,help -- "$@")"
}

function :execute:watch {
    setopt localoptions localtraps pipefail no_bgnice extendedglob
    (( $# == 0 )) || abend 'watch takes no positional arguments'
    [[ $o_reader =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]] || abend 'invalid reader name'
    [[ $o_interval == <-> ]] || abend 'interval must be a positive whole number of seconds'
    typeset interval=${o_interval##0#}
    [[ -n $interval ]] || abend 'interval must be a positive whole number of seconds'
    # zselect parses centiseconds into a signed native long. Check before
    # appending the two zeroes so a large argument cannot wrap into a busy loop.
    (( $#interval < 17 )) || {
        [[ $#interval == 17 && ! $interval > 92233720368547758 ]] || abend 'interval exceeds the native timer range'
    }

    typeset account channel ts after cursor work='' saved_umask=$(umask)
    typeset directory=${functions_source[:execute:watch]:A:h}
    typeset -a fields=() metadata=() principal=()
    typeset -A seen=()
    integer count=100 child generation pending=0 found
    postcard_account_read || return
    # Resolve an omitted account once. Adding another account must not change
    # the selection; subsequent grants may change the token, never the owner.
    typeset o_account=$account
    principal=( "$fields[1]" "$fields[2]" "$fields[3]" )
    typeset record=${XDG_STATE_HOME:-$HOME/.local/state}/postcard/accounts/$account/readers/$o_reader.json
    zmodload zsh/parameter zsh/zselect || return

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
                # Stop only after a whole validated page proves new messages.
                while true; do
                    postcard_thread_page || return
                    jq -e -L $directory/../../jq --arg after "$after" \
                        -f $directory/newer.jq $work/page > /dev/null 2>/dev/null &
                    child=$!
                    wait $child
                    case $? in
                        (0) found=1; break ;;
                        (1) ;;
                        (*) warn 'cannot compare watch timestamps'; return 1 ;;
                    esac
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
