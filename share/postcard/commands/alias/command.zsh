function :help:alias {
    help=$(<${functions_source[:help:alias]:A:h}/help.md)
}

function :args:alias {
    # Interspersed option parsing drops empty positional fields. Preserve them
    # as an invalid field so an explicit empty name cannot become the list form.
    # Every positional and option-value grammar here must reject the newline.
    typeset -a arguments=( "$@" )
    integer index
    for (( index = 1; index <= ${#arguments}; index++ )); do
        [[ -n $arguments[index] ]] || arguments[index]=$'\n'
    done
    eval "$(args -@ -d ,permalink -d ,channel -d ,ts -b ,delete -bx h,help -- "${(@)arguments}")"
}

function :execute:alias {
    setopt localoptions localtraps pipefail
    (( $# <= 1 )) || abend 'alias accepts at most one name'
    integer named=$#
    typeset name=${1-} action address aliases output staged=''
    (( ! named )) || [[ $name =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]] ||
        abend 'alias name must use 1–64 lowercase letters, numbers, dots, underscores or hyphens'

    integer forms=$(( ${+o_permalink} + (${+o_channel} || ${+o_ts}) ))
    (( forms <= 1 )) || abend 'select either --permalink or --channel with --ts'
    (( ${+o_channel} == ${+o_ts} )) || abend '--channel and --ts must be supplied together'
    [[ ! -v o_channel || $o_channel =~ '^[CDG][A-Z0-9]+$' ]] || abend 'invalid conversation ID'
    [[ ! -v o_ts || $o_ts == <->.<-> ]] || abend 'parent timestamp must be a decimal string'
    if (( o_delete )); then
        (( named )) || abend 'deleting an alias requires a name'
        (( forms == 0 )) || abend '--delete does not take a thread address'
        action=delete
    elif (( forms )); then
        (( named )) || abend 'binding an alias requires a name'
        action=bind
    elif (( named )); then
        action=get
    else
        action=list
    fi

    typeset account
    typeset -a fields=()
    integer postcard_account_allow_expired=1
    postcard_account_read || return
    if [[ -v o_permalink ]]; then
        address=$(jq -cen --arg permalink "$o_permalink" \
            -f ${functions_source[:execute:alias]:A:h}/address.jq 2>/dev/null) ||
            abend 'invalid Slack message permalink'
    elif [[ -v o_channel ]]; then
        address=$(jq -cn --arg channel "$o_channel" --arg ts "$o_ts" '{channel:$channel,ts:$ts}') || return
    fi

    if [[ $action == (bind|delete) ]]; then
        zmodload zsh/system || return
        typeset state_root=${XDG_STATE_HOME:-$HOME/.local/state}/postcard
        typeset state_dir=$state_root/accounts/$account
        typeset lock_file=$state_dir/aliases.lock
        typeset saved_umask=$(umask)
        integer lock=-1 result=1
        trap '[[ -z $staged ]] || rm -f -- "$staged"; exit 130' INT
        trap '[[ -z $staged ]] || rm -f -- "$staged"; exit 143' TERM HUP
        {
            umask 077
            [[ ! -L $state_dir ]] || { warn 'invalid alias state directory'; return 1; }
            mkdir -p -- $state_dir || return
            chmod 700 $state_root $state_root/accounts $state_dir || return
            [[ ! -L $lock_file && ( ! -e $lock_file || -f $lock_file ) ]] || {
                warn 'invalid alias lock file'; return 1
            }
            : >> $lock_file && chmod 600 $lock_file || return
            zsystem flock -t 5 -f lock $lock_file || {
                warn 'could not lock aliases for account %s' "$account"; return 1
            }
            aliases=$(postcard_alias_read) || return
            if [[ $action == delete ]]; then
                print -rn -- "$aliases" | jq -e --arg name "$name" '.aliases | has($name)' >/dev/null ||
                    abend 'unknown alias %s' "$name"
                address=$(print -rn -- "$aliases" | jq -ce --arg name "$name" '.aliases[$name]') || return
                aliases=$(print -rn -- "$aliases" | jq -ce --arg name "$name" 'del(.aliases[$name])') || return
            else
                aliases=$(printf '%s\n%s' "$aliases" "$address" | jq -ces --arg name "$name" \
                    '.[1] as $address | .[0] | .aliases[$name]=$address') || return
            fi
            typeset account_dir=${XDG_CONFIG_HOME:-$HOME/.config}/postcard/accounts/$account
            staged=$(mktemp "$account_dir/.aliases.XXXXXX") || return
            print -r -- "$aliases" > "$staged" && chmod 600 "$staged" &&
                mv -f -- "$staged" "$account_dir/aliases.json" || return
            staged=''
            result=0
        } always {
            [[ -z $staged ]] || rm -f -- "$staged"
            (( lock < 0 )) || zsystem flock -u $lock
            umask $saved_umask
        }
        (( result == 0 )) || return
    else
        aliases=$(postcard_alias_read) || return
        if [[ $action == get ]]; then
            address=$(print -rn -- "$aliases" | jq -ce --arg name "$name" '.aliases[$name] // empty') ||
                abend 'unknown alias %s' "$name"
        fi
    fi

    case $action in
        (list)
            output=$(print -rn -- "$aliases" | jq -ce --arg account "$account" \
                --arg team "$fields[2]" --arg user "$fields[3]" '
                {account:$account,team_id:$team,user_id:$user,
                 aliases:(.aliases | to_entries | sort_by(.key) |
                    map({name:.key,channel:.value.channel,ts:.value.ts}))}
            ') || return ;;
        (*)
            output=$(print -rn -- "$address" | jq -ce --arg account "$account" \
                --arg team "$fields[2]" --arg user "$fields[3]" --arg name "$name" \
                --arg action "$action" '
                {account:$account,team_id:$team,user_id:$user,name:$name} + . +
                (if $action == "delete" then {deleted:true} else {} end)
            ') || return ;;
    esac
    print -r -- "$output"
}
