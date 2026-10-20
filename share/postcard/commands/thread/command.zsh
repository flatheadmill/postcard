function :help:thread {
    help=$(<${functions_source[:help:thread]:A:h}/help.md)
}

function :args:thread {
    typeset o_count=20
    eval "$(args ,alias ,channel ,ts -d ,count ,cursor ,after ,reader -bx h,help -- "$@")"
}

function :execute:thread {
    setopt localoptions localtraps pipefail no_bgnice
    (( $# == 0 )) || abend 'thread takes no positional arguments'
    integer forms=$(( ${+o_alias} + (${+o_channel} || ${+o_ts}) ))
    if [[ -v o_reader ]]; then
        [[ $o_reader =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]] || abend 'invalid reader name'
        [[ ! -v o_cursor ]] || abend '--reader cannot be used with --cursor'
        (( forms <= 1 )) || abend 'select either --alias or --channel with --ts'
    else
        (( forms == 1 )) || abend 'select either --alias or --channel with --ts'
    fi
    (( ${+o_channel} == ${+o_ts} )) || abend '--channel and --ts must be supplied together'
    [[ ! -v o_alias || $o_alias =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]] || abend 'invalid alias name'
    [[ ! -v o_channel || $o_channel =~ '^[CDG][A-Z0-9]+$' ]] || abend 'invalid conversation ID'
    [[ ! -v o_ts || $o_ts == <->.<-> ]] || abend 'parent timestamp must be a decimal string'
    [[ ! -v o_after || $o_after == <->.<-> ]] || abend 'after timestamp must be a decimal string'
    [[ ! -v o_cursor || -n $o_cursor ]] || abend 'cursor must not be empty'
    [[ $o_count == <1-100> ]] || abend 'count must be an integer from 1 through 100'
    integer count=$(( 10#$o_count ))

    typeset account aliases resolved channel=${o_channel-} ts=${o_ts-}
    typeset after=${o_after-} cursor=${o_cursor-}
    typeset directory=${functions_source[:execute:thread]:A:h}
    typeset work='' staged='' record lock_file saved_umask=$(umask)
    typeset -a fields=() metadata=()
    typeset -A seen=()
    integer lock=-1 child generation=0
    postcard_account_read || return
    zmodload zsh/system zsh/parameter || return

    function postcard_thread_cleanup {
        # All asynchronous jobs in this command are ours. Jobspecs also cover
        # a signal between launching a child and recording $!: stop and reap
        # writers before removing their files. Never remove the lock inode.
        typeset job
        for job in ${(k)jobstates}; do
            kill -TERM %$job 2>/dev/null
        done
        wait 2>/dev/null
        [[ -z $work ]] || rm -rf -- "$work"
        [[ -z $staged ]] || rm -f -- "$staged"
        (( lock < 0 )) || zsystem flock -u $lock
        umask $saved_umask
    }
    # Exiting a signal trap bypasses always, so these paths clean up explicitly.
    trap 'postcard_thread_cleanup; exit 130' INT
    trap 'postcard_thread_cleanup; exit 143' TERM HUP
    trap 'postcard_thread_cleanup; exit 141' PIPE
    {
        umask 077
        if [[ -v o_reader ]]; then
            typeset state_root=${XDG_STATE_HOME:-$HOME/.local/state}/postcard
            typeset reader_dir=$state_root/accounts/$account/readers parent
            for parent in $state_root $state_root/accounts $state_root/accounts/$account $reader_dir; do
                [[ ! -L $parent && ( ! -e $parent || ( -d $parent && -O $parent ) ) ]] || {
                    warn 'invalid reader state directory'; return 1
                }
            done
            mkdir -p -- $reader_dir || return
            chmod 700 $state_root $state_root/accounts $state_root/accounts/$account $reader_dir || return
            record=$reader_dir/$o_reader.json
            lock_file=$reader_dir/$o_reader.lock
            [[ ! -L $lock_file && ( ! -e $lock_file || ( -f $lock_file && -O $lock_file ) ) ]] || {
                warn 'invalid reader lock file'; return 1
            }
            : >> $lock_file && chmod 600 $lock_file || return
            zsystem flock -t 0.001 -f lock $lock_file 2>/dev/null || {
                warn 'reader %s is busy for account %s' "$o_reader" "$account"; return 1
            }
            work=$(mktemp -d "$reader_dir/.$o_reader.work.XXXXXX") || return
            staged=$(mktemp "$reader_dir/.$o_reader.state.XXXXXX") || return
            : > $work/pages && : > $work/output || return

            # Only the published record establishes existence. Inspect it while
            # locked: a concurrent initializer cannot authorize an overwrite by
            # seeing an absent file before the first reader has published.
            if [[ -e $record || -L $record ]]; then
                postcard_reader_read || return
                (( forms == 0 && ! ${+o_after} )) || {
                    warn 'reader %s already exists; omit its address and --after' "$o_reader"; return 1
                }
                channel=$metadata[1] ts=$metadata[2] after=$metadata[3] generation=$metadata[4]
            else
                (( forms == 1 && ${+o_after} )) || {
                    warn 'new reader %s requires an address and --after' "$o_reader"; return 1
                }
            fi
        else
            work=$(mktemp -d "${TMPDIR:-/tmp}/postcard.thread.XXXXXX") || return
        fi

        if [[ -v o_alias ]]; then
            aliases=$(postcard_alias_read) || return
            resolved=$(print -rn -- "$aliases" | jq -cer --arg name "$o_alias" '.aliases[$name] // empty') || {
                warn 'unknown alias %s' "$o_alias"; return 1
            }
            channel=$(print -rn -- "$resolved" | jq -r .channel) || return
            ts=$(print -rn -- "$resolved" | jq -r .ts) || return
        fi
        if [[ ! -v o_reader ]]; then
            postcard_thread_page || return
            cat -- $work/page &
            child=$!
            wait $child
            return
        fi

        # Every page uses the original boundary. A high timestamp on an early
        # page cannot suppress smaller qualifying observations on later pages.
        while true; do
            postcard_thread_page || return
            cat -- $work/page >> $work/pages &
            child=$!
            wait $child || { warn 'cannot collect reader page'; return 1; }
            # The sentinel preserves trailing newlines in an opaque cursor.
            # NUL cannot travel in curl's argv and must fail before another call.
            jq -jr '.paging.next_cursor // "" |
                if contains("\u0000") then error("invalid cursor") else . + "\u0001" end' \
                $work/page > $work/cursor 2>/dev/null &
            child=$!
            wait $child || { warn 'invalid reader pagination cursor'; return 1; }
            cursor=$(<$work/cursor)
            cursor=${cursor%$'\1'}
            [[ -n $cursor ]] || break
            (( ! ${+seen[$cursor]} )) || { warn 'Slack repeated a pagination cursor'; return 1; }
            seen[$cursor]=1
        done

        jq -ces -L $directory/../../jq --arg account "$account" --arg team "$fields[2]" --arg user "$fields[3]" \
            --arg reader "$o_reader" --arg channel "$channel" --arg ts "$ts" \
            --arg after "$after" --argjson generation $generation \
            -f $directory/reader-result.jq $work/pages > $work/output 2>/dev/null &
        child=$!
        wait $child || { warn 'cannot assemble reader output'; return 1; }
        jq -ce --arg client "$fields[1]" -f $directory/reader-next.jq \
            $work/output > $staged 2>/dev/null &
        child=$!
        wait $child || { warn 'cannot prepare reader progress'; return 1; }

        # Both documents are complete before delivery. A failed write forbids
        # publication. A failed rename can follow useful output; the diagnostic
        # and nonzero exit tell the caller that a retry may repeat that output.
        cat -- $work/output &
        child=$!
        wait $child || { warn 'reader output failed; progress was not saved'; return 1; }
        mv -f -- $staged $record &
        child=$!
        wait $child || { warn 'reader output delivered but progress was not saved'; return 1; }
        staged=''
    } always {
        postcard_thread_cleanup
    }
}
