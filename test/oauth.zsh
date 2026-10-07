#!/usr/bin/env zsh

# The fake browser sends a real TCP callback; fake curl records the exchange
# form and returns fictional Slack JSON. Storage and locks are real, isolated
# in temporary XDG directories, with command wrappers injecting write failures.
# The driver varies the listener port; login.zsh also exercises the actual CLI.
# No request reaches Slack.

emulate -L zsh -o pipefail
setopt no_bgnice
umask 077
zmodload zsh/stat zsh/datetime zsh/system

typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.oauth.XXXXXX) || exit 1
typeset case_dir credentials lock_file original
integer failures=0 run_status test_port=$(( 40000 + RANDOM % 10000 ))
export POSTCARD_TEST_REAL_JQ=$commands[jq]
export POSTCARD_TEST_REAL_MV=$commands[mv]
export POSTCARD_TEST_REAL_MKTEMP=$commands[mktemp]
mkdir -p $fixture/bin
ln -s $root/test/browser.zsh $fixture/bin/open
ln -s $root/test/curl.zsh $fixture/bin/curl

# Probe external arguments, and inject failures only at storage boundaries.
cat > $fixture/bin/jq <<'EOF'
#!/bin/zsh -f
print -rl -- "$@" >> $POSTCARD_TEST_JQ_ARGS
exec $POSTCARD_TEST_REAL_JQ "$@"
EOF
cat > $fixture/bin/mv <<'EOF'
#!/bin/zsh -f
if [[ -n $POSTCARD_TEST_INSTALL_GATE ]]; then
    : > $POSTCARD_TEST_INSTALL_GATE.ready
    for attempt in {1..500}; do
        [[ -e $POSTCARD_TEST_INSTALL_GATE ]] && break
        sleep 0.01
    done
fi
[[ $POSTCARD_TEST_RENAME_FAILURE == 1 ]] && exit 1
exec $POSTCARD_TEST_REAL_MV "$@"
EOF
cat > $fixture/bin/mktemp <<'EOF'
#!/bin/zsh -f
[[ $POSTCARD_TEST_STAGE_FAILURE == 1 ]] && exit 1
file=$($POSTCARD_TEST_REAL_MKTEMP "$@") || exit
[[ $POSTCARD_TEST_WRITE_FAILURE == 1 ]] && chmod 400 "$file"
print -r -- "$file"
EOF
chmod +x $fixture/bin/{jq,mv,mktemp}
export PATH=$fixture/bin:$PATH

function check {
    typeset description=$1
    shift
    # Only application jq calls belong in the argument-exposure probe.
    if [[ $1 == jq ]]; then
        shift
        set -- $POSTCARD_TEST_REAL_JQ "$@"
    fi
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
    export POSTCARD_TEST_RESPONSE=$case_dir/browser.response
    export POSTCARD_TEST_URL=$case_dir/browser.url
    export POSTCARD_TEST_REQUEST=$case_dir/request
    export POSTCARD_TEST_SLACK_RESPONSE=$case_dir/slack.json
    export POSTCARD_TEST_JQ_ARGS=$case_dir/jq.args
    unset POSTCARD_TEST_TRANSPORT_FAILURE POSTCARD_TEST_CALLBACK \
        POSTCARD_TEST_RENAME_FAILURE POSTCARD_TEST_STAGE_FAILURE \
        POSTCARD_TEST_WRITE_FAILURE POSTCARD_TEST_BROWSER_FAILURE \
        POSTCARD_TEST_BROWSER_GATE POSTCARD_TEST_EXCHANGE_GATE POSTCARD_TEST_INSTALL_GATE \
        POSTCARD_TEST_DISCONNECT
    credentials=$XDG_CONFIG_HOME/postcard/accounts/fixture/credentials.json
    lock_file=$XDG_STATE_HOME/postcard/accounts/fixture/login.lock
    print -r -- '{"ok":true,"team":{"id":"T_FIXTURE"},"authed_user":{"id":"U_FIXTURE","token_type":"user","access_token":"fixture-new-token","scope":"chat:write"}}' > $case_dir/slack.json
}

function save_original {
    mkdir -p ${credentials:h}
    print -r -- '{"client_id":"123.456","team_id":"T_FIXTURE","user_id":"U_FIXTURE","access_token":"fixture-old-token","scope":"chat:write"}' > $credentials
    original=$case_dir/original
    cp $credentials $original
}

function run_login {
    typeset prefix=$1
    export POSTCARD_TEST_PORT=$(( ++test_port ))
    $root/test/login-driver.zsh ${2:-fixture} ${3:-123.456} > $case_dir/$prefix.out 2> $case_dir/$prefix.err
    run_status=$?
}

function preserves_original {
    (( run_status != 0 )) && cmp -s $original $credentials && [[ ! -s $case_dir/result.out ]]
}

function no_stage {
    typeset -a files=( ${credentials:h}/.credentials.*(N) )
    (( ${#files} == 0 ))
}

function mode_is {
    typeset -a info
    zstat -A info +mode $1 && (( (info[1] & 8#777) == $2 ))
}

function wait_file {
    integer attempt
    for attempt in {1..500}; do
        [[ -e $1 ]] && return 0
        sleep 0.01
    done
    return 1
}

function edit_response {
    $POSTCARD_TEST_REAL_JQ "$1" $case_dir/slack.json > $case_dir/changed.json || return
    $POSTCARD_TEST_REAL_MV $case_dir/changed.json $case_dir/slack.json
}

function failed_response {
    setup_case $1
    save_original
    edit_response "$2" || return
    run_login result
    check "$1 preserves credentials and reports failure" preserves_original
    check "$1 removes staging files" no_stage
}

function lock_released {
    zsh -fc 'zmodload zsh/system; zsystem flock -t 0.001 -f held "$1" || exit; zsystem flock -u $held' -- $lock_file
}

function contention_case {
    typeset phase=$1
    setup_case lock-$phase
    save_original
    case $phase in
        (browser) export POSTCARD_TEST_BROWSER_GATE=$case_dir/gate ;;
        (exchange) export POSTCARD_TEST_EXCHANGE_GATE=$case_dir/gate ;;
        (install) export POSTCARD_TEST_INSTALL_GATE=$case_dir/gate ;;
    esac
    export POSTCARD_TEST_PORT=$(( ++test_port ))
    $root/test/login-driver.zsh > $case_dir/first.out 2> $case_dir/first.err &
    integer first=$! first_status
    if ! wait_file $case_dir/gate.ready; then
        check "$phase gate reached" false
        kill $first 2>/dev/null
        wait $first
        return
    fi
    typeset -a before after
    zstat -A before +inode $lock_file
    check "$phase has not replaced the original" cmp -s $original $credentials
    run_login second
    check "$phase contention fails" test $run_status -ne 0
    check "$phase contention reports busy" grep -Fq 'is busy' $case_dir/second.err
    check "$phase second login reports no success" test ! -s $case_dir/second.out
    : > $case_dir/gate
    wait $first
    first_status=$?
    check "$phase first login completes" test $first_status -eq 0
    zstat -A after +inode $lock_file
    check "$phase retains the lock inode" test $before[1] -eq $after[1]
    check "$phase releases the lock" lock_released
}

{
    setup_case fresh
    integer started=$EPOCHSECONDS
    run_login result
    check 'fresh login succeeds' test $run_status -eq 0
    check 'fresh grant contains the workspace user token' jq -e '
        . == {client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE",
            access_token:"fixture-new-token",scope:"chat:write"}
    ' $credentials
    check 'success is explicit' grep -Fxq 'Logged in to account fixture.' $case_dir/result.out
    check 'credentials are private' mode_is $credentials 8#600
    check 'account directory is private' mode_is ${credentials:h} 8#700
    check 'lock is private' mode_is $lock_file 8#600
    check 'lock directory is private' mode_is ${lock_file:h} 8#700
    check 'successful install leaves no staging file' no_stage
    check 'lock is released after success' lock_released
    check 'one exchange request' test $(wc -l < $case_dir/request.calls) -eq 1
    check 'exchange uses stdin' grep -Fxq '@-' $case_dir/request.argv
    check 'exchange targets Slack' grep -Fxq 'https://slack.com/api/oauth.v2.access' $case_dir/request.argv
    typeset form=$(<$case_dir/request) url=$(<$case_dir/browser.url)
    typeset verifier=${${form#*code_verifier=}%%&*}
    typeset challenge=$(print -rn -- "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A)
    challenge=${${${challenge//+/-}//\//_}//=/}
    check 'exchange carries the matching PKCE verifier' test "${${url#*code_challenge=}%%&*}" = "$challenge"
    check 'exchange carries the verified code' test "${${form#*&code=}%%&*}" = fixture-code
    check 'exchange keeps the original redirect' test "${${form#*redirect_uri=}%%&*}" = 'http%3A%2F%2Flocalhost%3A8765%2Fauth'
    check 'exchange carries the client ID' test "${${form#client_id=}%%&*}" = 123.456
    check 'exchange uses the authorization code grant' test "${${form#*grant_type=}%%&*}" = authorization_code
    check 'no client secret is sent' test "${form#*client_secret}" = "$form"
    if grep -F -e fixture-code -e fixture-new-token -e "$verifier" \
        $case_dir/request.argv $case_dir/jq.args $case_dir/result.out $case_dir/result.err; then
        check 'secrets stay out of external argv and diagnostics' false
    else
        check 'secrets stay out of external argv and diagnostics' true
    fi

    setup_case rotating
    edit_response '.authed_user += {refresh_token:"fixture-refresh", expires_in:43200}'
    started=$EPOCHSECONDS
    run_login result
    check 'rotating login succeeds' test $run_status -eq 0
    check 'rotation facts are saved' jq -e --argjson start $started --argjson end $EPOCHSECONDS '
        .refresh_token == "fixture-refresh" and .expires_at >= ($start + 43200)
        and .expires_at <= ($end + 43200)
    ' $credentials

    setup_case reauthorize
    save_original
    run_login result
    check 'same binding can reauthorize' test $run_status -eq 0
    check 'reauthorization replaces the token' jq -e '.access_token == "fixture-new-token"' $credentials

    typeset callback
    for callback in valid denied invalid; do
        setup_case disconnect-$callback
        save_original
        export POSTCARD_TEST_DISCONNECT=1 POSTCARD_TEST_CALLBACK=$callback
        run_login result
        check "$callback browser disconnect makes the acknowledgement fail" \
            test "$(<$case_dir/browser.url.ack-status)" -ne 0
        if [[ $callback == valid ]]; then
            check 'valid callback survives browser disconnect' test $run_status -eq 0
            check 'browser disconnect still installs the grant' jq -e '.access_token == "fixture-new-token"' $credentials
            check 'browser disconnect still reports success' grep -Fxq 'Logged in to account fixture.' $case_dir/result.out
        else
            check "$callback disconnect preserves credentials" preserves_original
            check "$callback disconnect never exchanges" test ! -e $case_dir/request
        fi
    done

    setup_case wrong-client
    save_original
    run_login result fixture 999.999
    check 'different client preserves credentials' preserves_original
    check 'different client never opens the browser' test ! -e $case_dir/browser.url
    check 'different client never exchanges' test ! -e $case_dir/request

    failed_response wrong-team '.team.id = "T_OTHER"'
    failed_response wrong-user '.authed_user.id = "U_OTHER"'
    failed_response slack-error '{ok:false,error:"invalid_code"}'
    failed_response missing-token 'del(.authed_user.access_token)'
    failed_response bot-only 'del(.authed_user) | .access_token = "fixture-bot"'
    failed_response wrong-token-type '.authed_user.token_type = "bot"'
    failed_response missing-team 'del(.team)'
    failed_response enterprise '.is_enterprise_install = true'
    failed_response malformed-enterprise '.is_enterprise_install = "false"'
    failed_response missing-scope 'del(.authed_user.scope)'
    failed_response refresh-only '.authed_user.refresh_token = "fixture-refresh"'
    failed_response expiry-only '.authed_user.expires_in = 43200'
    failed_response invalid-expiry '.authed_user += {refresh_token:"fixture-refresh",expires_in:-1}'
    failed_response fractional-expiry '.authed_user += {refresh_token:"fixture-refresh",expires_in:1.5}'
    failed_response non-object '[]'
    failed_response multiple-documents '., .'

    typeset failure
    for failure in malformed-json transport denied invalid browser stage write rename; do
        setup_case $failure
        save_original
        case $failure in
            (malformed-json) print -r -- 'not JSON' > $case_dir/slack.json ;;
            (transport) export POSTCARD_TEST_TRANSPORT_FAILURE=1 ;;
            (denied|invalid) export POSTCARD_TEST_CALLBACK=$failure ;;
            (browser) export POSTCARD_TEST_BROWSER_FAILURE=1 ;;
            (stage) export POSTCARD_TEST_STAGE_FAILURE=1 ;;
            (write) export POSTCARD_TEST_WRITE_FAILURE=1 ;;
            (rename) export POSTCARD_TEST_RENAME_FAILURE=1 ;;
        esac
        run_login result
        check "$failure preserves credentials and reports failure" preserves_original
        check "$failure removes staging files" no_stage
        check "$failure releases the lock" lock_released
        case $failure in
            (denied|invalid|browser) check "$failure never exchanges" test ! -e $case_dir/request ;;
            (*) check "$failure never retries the exchange" test $(wc -l < $case_dir/request.calls) -eq 1 ;;
        esac
    done

    setup_case corrupt-existing
    save_original
    print -r -- 'broken credentials' > $credentials
    cp $credentials $original
    run_login result
    check 'corrupt existing record is preserved' preserves_original
    check 'corrupt existing record stops before browser' test ! -e $case_dir/browser.url

    setup_case unsafe-name
    run_login result ../elsewhere
    check 'unsafe account name fails' test $run_status -ne 0
    check 'unsafe name stops before browser' test ! -e $case_dir/browser.url

    contention_case browser
    contention_case exchange
    contention_case install
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}

(( failures == 0 )) || { print -r -- "oauth: $failures failure(s)"; exit 1; }
print -r -- 'oauth: PASS'
