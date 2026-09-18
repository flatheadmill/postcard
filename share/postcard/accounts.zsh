# The root lock protects name creation and legacy adoption only. Grant use
# releases it before waiting for the selected account's independent lock.
function postcard_account_name {
    [[ $1 =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]] ||
        postcard_error 'account names must be 1–64 ASCII letters, digits, dots, underscores or hyphens, starting with a letter or digit'
}

function postcard_root_options {
    typeset name='' option
    integer selected=0
    while (( $# )); do
        option=$1
        case $option in
            (--account)
                (( $# >= 2 )) || { postcard_error '--account requires a name'; return 1; }
                name=$2
                (( ++selected ))
                shift 2
                ;;
            (--account=*)
                name=${option#--account=}
                (( ++selected ))
                shift
                ;;
            (-h|--help) shift ;;
            (*) break ;;
        esac
    done
    (( selected <= 1 )) || { postcard_error '--account may be supplied only once'; return 1; }
    (( ! selected )) || postcard_account_name "$name"
}

function postcard_private_directory {
    typeset directory=$1
    [[ ! -h $directory ]] || { postcard_error 'storage directory must not be a symlink'; return 1; }
    mkdir -p -- "$directory" || return
    [[ -d $directory && -O $directory ]] || {
        postcard_error 'storage directory must be owned by this user'; return 1
    }
    chmod 700 "$directory"
}

function postcard_lock {
    typeset file=$1 variable=$2
    [[ ! -h $file && ( ! -e $file || ( -f $file && -O $file ) ) ]] || {
        postcard_error 'invalid storage lock file'; return 1
    }
    : >> "$file" && chmod 600 "$file" || return
    zsystem flock -t 5 -f "$variable" "$file" || {
        postcard_error 'another Postcard command holds the storage lock'; return 1
    }
}

function postcard_no_legacy {
    [[ ! -e $pc_root/credentials.json && ! -h $pc_root/credentials.json ]] || {
        postcard_error 'legacy credentials found; run postcard account adopt NAME first'
        return 1
    }
}

function postcard_account_names {
    typeset directory
    pc_accounts=()
    for directory in "$pc_root/accounts"/*(DN); do
        # Empty ordinary directories are unfinished enrollments. Broken paths
        # and credential entries remain visible and count for selection.
        if [[ -h $directory || ! -d $directory || ! -r $directory || ! -x $directory ||
              -e $directory/credentials.json || -h $directory/credentials.json ]]; then
            pc_accounts+=( "${directory:t}" )
        fi
    done
}

function postcard_account_collision {
    typeset directory name
    for directory in "$pc_root/accounts"/*(DN); do
        name=${directory:t}
        if [[ ${(L)name} == ${(L)pc_account} && $name != $pc_account ]]; then
            postcard_error 'account name conflicts with an existing spelling; use the exact name from account list'
            return 1
        fi
    done
}

function postcard_select_account {
    typeset operation=$1
    postcard_no_legacy || return
    if [[ $operation == postcard_login ]]; then
        [[ -n $pc_account ]] || {
            postcard_error 'login requires postcard --account NAME login'; return 1
        }
    elif [[ -z $pc_account ]]; then
        postcard_account_names
        (( ${#pc_accounts} == 1 )) || {
            postcard_error 'select an account with postcard --account NAME COMMAND; use postcard account list to see accounts'
            return 1
        }
        pc_account=$pc_accounts[1]
    fi
    postcard_account_name "$pc_account" && postcard_account_collision || return
    pc_directory=$pc_root/accounts/$pc_account
    pc_file=$pc_directory/credentials.json
    if [[ $operation != postcard_login && ! -e $pc_file && ! -h $pc_file ]]; then
        postcard_error 'selected account has no credentials; use account list or explicitly log in to that name'
        return 1
    fi
    postcard_private_directory "$pc_directory" || return
    # Name reservation is now visible, including to case-collision checks.
    zsystem flock -u "$pc_root_lock" || return
    pc_root_lock=''
    postcard_lock "$pc_directory/.lock" pc_lock || return
    postcard_no_legacy || return
    if [[ -e $pc_file || -h $pc_file ]]; then
        postcard_load_credentials || return
        pc_existing=1
    elif [[ $operation != postcard_login ]]; then
        postcard_error 'selected account credentials disappeared'; return 1
    fi
}

function postcard_load_credentials {
    [[ -f $pc_file && ! -h $pc_file && -O $pc_file && -r $pc_file ]] || {
        postcard_error 'credentials must be a readable regular file owned by this user'; return 1
    }
    chmod 600 "$pc_file" || return
    pc_credentials=$(< "$pc_file")
    postcard_validate
}

function postcard_context {
    print -r -- "$pc_credentials" "$pc_identity" | jq -sc --arg account "$pc_account" '
        (.[1] // .[0]) as $identity |
        {account:$account,
         team:($identity.team | {id,name,url}),
         user:($identity.user | {id,name,username})}'
}

function postcard_account_list {
    [[ -z $pc_account ]] || { postcard_error 'account list does not take --account'; return 1; }
    postcard_no_legacy || return
    postcard_account_names
    typeset name directory entry
    typeset -a entries=()
    for name in "${pc_accounts[@]}"; do
        directory=$pc_root/accounts/$name
        entry=$(postcard_account_entry "$name" "$directory") || return
        entries+=( "$entry" )
    done
    print -rl -- "${entries[@]}" | jq -s '{accounts:.}'
}

function postcard_account_entry {
    typeset pc_account=$1 directory=$2 pc_credentials='{}' pc_token='' reason=''
    typeset file=$directory/credentials.json
    if ! postcard_account_name "$pc_account" 2>/dev/null; then
        reason='invalid account name'
    elif ! postcard_account_collision 2>/dev/null; then
        reason='account name has a case collision'
    elif [[ -h $directory || ! -d $directory || ! -O $directory || ! -r $directory || ! -x $directory ||
            -h $file || ! -f $file || ! -O $file || ! -r $file ]]; then
        reason='unusable credential entry'
    else
        # Refresh saves are atomic, so listing may read either complete record
        # without taking a grant lock, refreshing, or changing its permissions.
        pc_credentials=$(< "$file")
        postcard_validate 2>/dev/null || reason='invalid credential record'
    fi
    if [[ -n $reason ]]; then
        jq -cn --arg account "$pc_account" --arg reason "$reason" '
            {account:$account,team:null,user:null,client_id:null,
             expires_at:null,refreshable:null,state:"error",error:$reason}'
    else
        print -r -- "$pc_credentials" | jq -c --arg account "$pc_account" --argjson now "$EPOCHSECONDS" '
            {account:$account,team:(.team|{id,name}),user:(.user|{id,name,username}),
             client_id,expires_at:.grant.expires_at,refreshable:(.grant.refresh_token != null),
             state:(if .grant.refresh_uncertain == true then "refresh-uncertain"
                    elif .grant.expires_at != null and .grant.expires_at <= $now then "expired"
                    else "ready" end),error:null}'
    fi
}

function postcard_account_adopt {
    [[ -z $pc_account ]] || { postcard_error 'account adopt takes NAME, not --account'; return 1; }
    pc_account=$1
    postcard_account_name "$pc_account" && postcard_account_collision || return
    pc_file=$pc_root/credentials.json
    [[ -e $pc_file || -h $pc_file ]] || {
        postcard_error 'no legacy credentials found; use postcard account list'; return 1
    }
    postcard_load_credentials || return
    pc_directory=$pc_root/accounts/$pc_account
    postcard_private_directory "$pc_directory" || return
    postcard_lock "$pc_directory/.lock" pc_lock || return
    typeset destination=$pc_directory/credentials.json receipt
    receipt=$(postcard_context) || return
    # Both source and destination writer locks are held. os.rename performs
    # only a rename: unlike mv, it never falls back to copying across devices.
    python3 - "$pc_file" "$destination" <<'PY' || return
import os
import sys

source, destination = sys.argv[1:]
if os.path.lexists(destination):
    print("postcard: adoption destination is occupied", file=sys.stderr)
    sys.exit(1)
try:
    os.rename(source, destination)
except OSError:
    print("postcard: could not atomically adopt credentials; no copy was attempted", file=sys.stderr)
    sys.exit(1)
PY
    print -r -- "$receipt" | jq '. + {adopted:true}'
}
