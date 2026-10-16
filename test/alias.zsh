#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/datetime zsh/stat zsh/system
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.alias.XXXXXX) || exit 1
typeset case_dir credentials
integer failures=0 result

function check {
    typeset description=$1
    shift
    if "$@" >/dev/null; then
        print -r -- "ok: $description"
    else
        print -r -- "FAIL: $description"
        (( failures++ ))
    fi
}

function setup_case {
    case_dir=$fixture/$1
    mkdir -p $case_dir
    export XDG_CONFIG_HOME=$case_dir/config XDG_STATE_HOME=$case_dir/state
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
}

function save_grant {
    typeset name=${1:-widgets} team=${2:-T_FIXTURE} user=${3:-U_FIXTURE}
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/$name
    jq -n --arg team "$team" --arg user "$user" '
        {client_id:"123.456",team_id:$team,user_id:$user,
         access_token:"fixture-alias-secret",scope:"channels:history,chat:write,users:read"}
    ' > $XDG_CONFIG_HOME/postcard/accounts/$name/credentials.json
}

function run_alias {
    $root/bin/postcard "$@" > $case_dir/out 2> $case_dir/err
    result=$?
}

function failed { (( result != 0 )) && [[ ! -s $case_dir/out ]] }
function private_output { ! rg -Fq fixture-alias-secret $case_dir/{out,err}(N) }
function mode_is {
    typeset -a info
    zstat -A info +mode $1 && (( (info[1] & 8#777) == $2 ))
}

{
    setup_case lifecycle
    save_grant
    run_alias alias
    check 'empty alias list succeeds' test $result -eq 0
    check 'empty list carries account context' jq -e '
        .=={account:"widgets",team_id:"T_FIXTURE",user_id:"U_FIXTURE",aliases:[]}
    ' $case_dir/out
    check 'listing creates no alias state' test ! -e $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json

    run_alias alias planning --channel C012TARGET --ts 1700000000.000000
    check 'direct alias binding succeeds' test $result -eq 0
    check 'binding returns the exact address' jq -e '
        .name=="planning" and .channel=="C012TARGET" and .ts=="1700000000.000000"
        and .account=="widgets" and .team_id=="T_FIXTURE" and .user_id=="U_FIXTURE"
    ' $case_dir/out
    check 'alias file records its identity binding' jq -e '
        .version==1 and .binding=={client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"}
        and .aliases=={planning:{channel:"C012TARGET",ts:"1700000000.000000"}}
    ' $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    check 'alias file is private' mode_is $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json 8#600
    check 'stable alias lock is private' mode_is $XDG_STATE_HOME/postcard/accounts/widgets/aliases.lock 8#600

    run_alias alias planning
    check 'named alias inspection succeeds' test $result -eq 0
    check 'inspection returns the stored address' jq -e '.name=="planning" and .channel=="C012TARGET"' $case_dir/out
    run_alias alias zulu --channel G012TARGET --ts 1700000000.000009
    run_alias alias
    check 'listing is sorted by alias name' jq -e '
        [.aliases[].name]==["planning","zulu"] and .aliases[1].channel=="G012TARGET"
    ' $case_dir/out

    run_alias alias planning --permalink \
        'https://widgets.slack.com/archives/D012TARGET/p1700000000000002?thread_ts=1700000000.000001&cid=D012TARGET'
    check 'thread permalink replaces an alias' test $result -eq 0
    check 'explicit permalink parent is retained' jq -e '
        .channel=="D012TARGET" and .ts=="1700000000.000001"
    ' $case_dir/out
    run_alias alias root --permalink 'https://widgets.slack.com/archives/C012TARGET/p1700000000123456'
    check 'root permalink binds successfully' test $result -eq 0
    check 'packed permalink timestamp is decoded' jq -e '.ts=="1700000000.123456"' $case_dir/out

    run_alias alias planning --delete
    check 'alias deletion succeeds' test $result -eq 0
    check 'deletion reports the removed address' jq -e '
        .name=="planning" and .channel=="D012TARGET" and .ts=="1700000000.000001" and .deleted==true
    ' $case_dir/out
    run_alias alias planning
    check 'deleted alias is unknown' failed
    check 'alias operations keep credentials private' private_output

    setup_case grammar
    save_grant
    typeset -a invalid=(
        'alias Upper --channel C012TARGET --ts 1.000000'
        'alias planning --channel C012TARGET'
        'alias planning --ts 1.000000'
        'alias planning --channel C012TARGET --ts 1.000000 --permalink https://example.test/archives/C012TARGET/p1000000'
        'alias --delete'
        'alias planning --delete --channel C012TARGET --ts 1.000000'
        'alias one two'
    )
    typeset command
    for command in $invalid; do
        run_alias ${(z)command}
        check "invalid alias grammar is rejected: $command" failed
    done
    run_alias alias ''
    check 'an explicitly empty alias name is rejected' failed
    run_alias alias planning --permalink 'http://widgets.slack.com/archives/C012TARGET/p1700000000000000'
    check 'non-HTTPS permalink is rejected' failed
    run_alias alias planning --permalink \
        'https://widgets.slack.com/archives/C012TARGET/p1700000000000000?thread_ts=1.000000&thread_ts=2.000000'
    check 'duplicate permalink parent is rejected' failed
    check 'invalid alias grammar writes no alias file' test ! -e $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json

    setup_case isolation
    save_grant widgets T_WIDGETS U_WIDGETS
    save_grant other T_OTHER U_OTHER
    run_alias --account widgets alias shared --channel C012WIDGETS --ts 1.000000
    run_alias --account other alias shared --channel C012OTHER --ts 2.000000
    check 'same alias name can exist in separate accounts' test $result -eq 0
    run_alias --account widgets alias shared
    check 'widget alias stays in its account' jq -e '.channel=="C012WIDGETS" and .team_id=="T_WIDGETS"' $case_dir/out
    run_alias --account other alias shared
    check 'other alias stays in its account' jq -e '.channel=="C012OTHER" and .team_id=="T_OTHER"' $case_dir/out

    setup_case expired
    save_grant
    jq '.+{refresh_token:"fixture-refresh",expires_at:1}' $credentials > $case_dir/expired.json
    mv $case_dir/expired.json $credentials
    run_alias alias planning --channel C012TARGET --ts 1.000000
    check 'expired grant can bind local aliases' test $result -eq 0
    run_alias alias planning
    check 'expired grant can inspect local aliases' jq -e '.channel=="C012TARGET"' $case_dir/out

    setup_case malformed
    save_grant
    print -r -- broken > $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    run_alias alias
    check 'malformed alias file is rejected' failed
    rm -f $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    jq -n '{version:1,binding:{client_id:"123.456",team_id:"T_OTHER",user_id:"U_FIXTURE"},aliases:{}}' \
        > $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    run_alias alias
    check 'mismatched alias binding is rejected' failed
    rm -f $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    jq -n '
        {version:1,binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},aliases:{}},
        {version:1,binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},aliases:{}}
    ' > $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    cp $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json $case_dir/multiple.before
    run_alias alias
    check 'multiple alias documents are rejected' failed
    run_alias alias planning --channel C012TARGET --ts 1.000000
    check 'multiple documents refuse mutation with empty stdout' failed
    check 'refused multi-document mutation preserves the original bytes' cmp -s \
        $case_dir/multiple.before $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    rm -f $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    ln -s /dev/null $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
    run_alias alias
    check 'symlinked alias file is rejected' failed
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}
(( failures == 0 )) || { print -r -- "alias: $failures failure(s)"; exit 1; }
print -r -- 'alias: PASS'
