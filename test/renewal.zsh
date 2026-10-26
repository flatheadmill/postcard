#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/system zsh/zselect zsh/datetime
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.renewal-test.XXXXXX) || exit 1
typeset case_dir credentials original
integer failures=0 result process=0 other=0 lock=-1
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
mkdir -p $fixture/watch-bin
ln -s $root/test/watch-tool.zsh $fixture/watch-bin/curl
export POSTCARD_TEST_WATCH_CURL=$fixture/watch-bin/curl
for tool in curl jq mv; do
    ln -s $root/test/renewal-tool.zsh $fixture/bin/$tool
done
export PATH=$fixture/bin:$PATH

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
    export XDG_CONFIG_HOME=$case_dir/config XDG_STATE_HOME=$case_dir/state POSTCARD_TEST_RENEWAL=$case_dir
    export TMPDIR=$case_dir/tmp
    unset POSTCARD_TEST_SEARCH POSTCARD_TEST_WATCH POSTCARD_TEST_POST POSTCARD_TEST_THREAD
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    original=$case_dir/original
    mkdir -p ${credentials:h} $TMPDIR
    $POSTCARD_TEST_JQ -n --argjson expires $(( EPOCHSECONDS + 1800 )) '{
        client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE",access_token:"fixture-old-secret",
        refresh_token:"fixture-refresh-secret",expires_at:$expires,scope:"search:read,channels:history,chat:write,users:read",
        decoration:{future:"extension"}
    }' > $credentials
    cp $credentials $original
    $POSTCARD_TEST_JQ -n '{ok:true,token_type:"user",access_token:"fixture-new-secret",
        refresh_token:"fixture-next-secret",expires_in:43200}' > $case_dir/response.json
}
function replace {
    $POSTCARD_TEST_JQ "$2" "$1" > "$1.next" && /bin/mv "$1.next" "$1"
}
function run_renewer {
    $root/bin/postcard "$@" renewer > $case_dir/out 2> $case_dir/err
    result=$?
}
function calls {
    typeset -a requests=( $case_dir/refresh.*.form(N) )
    (( $#requests == $1 ))
}
function quiet { [[ ! -s $case_dir/out && ! -s $case_dir/err ]] }
function unchanged { cmp -s $credentials $original }
function marked { $POSTCARD_TEST_JQ -e '.renewal_pending == true and .access_token == "fixture-old-secret"' $credentials }
function renewed { $POSTCARD_TEST_JQ -e '.access_token == "fixture-new-secret" and .refresh_token == "fixture-next-secret" and (has("renewal_pending") | not)' $credentials }
function no_scratch {
    typeset -a scratch=( ${credentials:h}/.renewal.*(DN) $TMPDIR/*(DN) )
    (( $#scratch == 0 ))
}
function await {
    integer attempts
    for (( attempts=0; attempts<600; attempts++ )); do
        "$@" && return 0
        zselect -t 1
    done
    return 1
}
function dead { ! kill -0 $1 2>/dev/null }
function finish {
    if ! await dead $process; then
        kill -KILL $process 2>/dev/null
        wait $process 2>/dev/null
        process=0
        return 1
    fi
    wait $process 2>/dev/null
    result=$?
    process=0
}
function cancel {
    kill -${1:-TERM} $process 2>/dev/null
    finish
}
function search {
    typeset -a selector=( --account widgets )
    (( $# == 0 )) || selector=()
    export POSTCARD_TEST_SEARCH=$case_dir/search
    mkdir -p $POSTCARD_TEST_SEARCH
    $POSTCARD_TEST_JQ -n '{ok:true,messages:{total:0,paging:{count:20,page:1,pages:0,total:0},matches:[]}}' \
        > $POSTCARD_TEST_SEARCH/response.json
    $root/bin/postcard "${selector[@]}" search --query fixture > $case_dir/out 2> $case_dir/err
    result=$?
}
function setup_watch {
    export POSTCARD_TEST_WATCH=$case_dir/watch
    mkdir -p $POSTCARD_TEST_WATCH $XDG_STATE_HOME/postcard/accounts/widgets/readers
    reader=$XDG_STATE_HOME/postcard/accounts/widgets/readers/workshop.json
    $POSTCARD_TEST_JQ -n '{version:1,binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},
        channel:"C012FIXTURE",ts:"1.000000",through:"1.0",generation:7}' > $reader
    cp $reader $case_dir/reader.before
    print -r -- '{"ok":true,"messages":[{"ts":"2.0"}],"response_metadata":{"next_cursor":""}}' > $POSTCARD_TEST_WATCH/page.1.json
    cp $POSTCARD_TEST_WATCH/page.1.json $POSTCARD_TEST_WATCH/page.2.json
}
function watch_requests {
    typeset -a requests=( $POSTCARD_TEST_WATCH/request.*.json(N) )
    (( $#requests == $1 ))
}
function bells {
    integer lines=$(rg -c '^You have messages:' $case_dir/out || print 0)
    (( lines == $1 ))
}
function health_lines {
    integer lines=$(rg -c '^Postcard account' $case_dir/out || print 0)
    (( lines == $1 ))
}
function start_watch {
    $root/bin/postcard --account widgets watch --reader workshop --interval ${1:-1} > $case_dir/out 2> $case_dir/err &
    process=$!
}

{
    setup_case empty
    rm $credentials
    run_renewer
    check 'empty saved inventory succeeds quietly' test $result -eq 0
    check 'empty inventory has no output' quiet
    check 'empty inventory sends no exchange' calls 0

    for shape in nonrotating future; do
        setup_case $shape
        if [[ $shape == nonrotating ]]; then
            replace $credentials 'del(.refresh_token,.expires_at)'
        else
            replace $credentials ".expires_at=$(( EPOCHSECONDS + 7200 ))"
        fi
        cp $credentials $original
        run_renewer --account widgets
        check "$shape succeeds quietly" test $result -eq 0
        check "$shape is silent" quiet
        check "$shape needs no exchange" calls 0
        check "$shape preserves bytes" unchanged
    done

    for shape in due expired; do
        setup_case $shape
        [[ $shape != expired ]] || replace $credentials '.expires_at=1'
        run_renewer --account widgets
        check "$shape renews" test $result -eq 0
        check "$shape success is silent" quiet
        check "$shape exchanges once" calls 1
        check "$shape publishes new pair without marker" renewed
        check "$shape preserves optional grant extensions and principal" $POSTCARD_TEST_JQ -e '
            .decoration.future == "extension" and .client_id == "123.456" and .team_id == "T_FIXTURE" and .user_id == "U_FIXTURE"
        ' $credentials
        check "$shape anchors expiry before transport" $POSTCARD_TEST_JQ -e \
            --argjson sent "$(<$case_dir/refresh.1.time)" '.expires_at >= $sent + 43199 and .expires_at <= $sent + 43200' $credentials
        check "$shape removes private scratch" no_scratch
        check "$shape uses PKCE refresh form without secret or verifier" test "$(<$case_dir/refresh.1.form)" = \
            'client_id=123.456&refresh_token=fixture-refresh-secret&grant_type=refresh_token'
        check "$shape does not expose tokens in arguments or output" zsh -fc '! rg -q "fixture-(old|refresh|new|next)-secret" "$@"' _ \
            $case_dir/refresh.1.argv $case_dir/jq.argv $case_dir/out $case_dir/err
        run_renewer
        check "$shape subsequent call is a quiet no-op" quiet
        check "$shape subsequent call does not redeem again" calls 1
    done

    setup_case search-renews
    search
    check 'search renews before its request' test $result -eq 0
    check 'search uses the new snapshot' rg -Fxq 'Authorization: Bearer fixture-new-secret' $case_dir/search/header
    check 'search output stays JSON' $POSTCARD_TEST_JQ -e '.account == "widgets"' $case_dir/out

    for shape in bot missing-type missing-refresh fractional-expiry huge-expiry missing-access contradictory-team contradictory-user multiple; do
        setup_case invalid-$shape
        case $shape in
            (bot) replace $case_dir/response.json '.token_type="bot"' ;;
            (missing-type) replace $case_dir/response.json 'del(.token_type)' ;;
            (missing-refresh) replace $case_dir/response.json 'del(.refresh_token)' ;;
            (fractional-expiry) replace $case_dir/response.json '.expires_in=1.5' ;;
            (huge-expiry) replace $case_dir/response.json '.expires_in=1e30' ;;
            (missing-access) replace $case_dir/response.json 'del(.access_token)' ;;
            (contradictory-team) replace $case_dir/response.json '.team={id:"T_OTHER"}' ;;
            (contradictory-user) replace $case_dir/response.json '.authed_user={id:"U_OTHER"}' ;;
            (multiple) print -r -- '{}' >> $case_dir/response.json ;;
        esac
        run_renewer
        check "$shape rejects incomplete or wrong user grant" test $result -ne 0
        check "$shape retains marked old grant" marked
        run_renewer
        check "$shape never repeats the exchange" calls 1
    done

    for status_code in 5 6 7 28 35 60; do
        setup_case curl-$status_code
        print -r -- $status_code > $case_dir/status.1
        run_renewer
        check "curl $status_code reports failed maintenance" test $result -ne 0
        if (( status_code == 5 || status_code == 6 || status_code == 7 )); then
            check "curl $status_code clears marker and preserves grant" $POSTCARD_TEST_JQ -es '.[0] == .[1]' $original $credentials
            run_renewer
            check "curl $status_code permits a later successful attempt" test $result -eq 0
            check "curl $status_code retries only on a later invocation" calls 2
        else
            check "curl $status_code leaves refresh disabled" marked
            run_renewer
            check "curl $status_code does not replay" calls 1
            search
            check "curl $status_code still permits old unexpired access" test $result -eq 0
            check "curl $status_code uses the old token for search" rg -Fxq 'Authorization: Bearer fixture-old-secret' $case_dir/search/header
        fi
    done

    for error in internal_error fatal_error invalid_refresh_token; do
        setup_case $error
        $POSTCARD_TEST_JQ -n --arg error "$error" '{ok:false,error:$error}' > $case_dir/response.json
        run_renewer
        check "$error requires operator recovery" test $result -ne 0
        check "$error preserves marker" marked
        if [[ $error == invalid_refresh_token ]]; then
            check 'known rejection is diagnosed as rejection' rg -q 'rejected the refresh credential' $case_dir/err
        fi
        run_renewer
        check "$error is not replayed" calls 1
    done

    setup_case rate-limit
    print -r -- 429 > $case_dir/http
    print -r -- $'HTTP/1.1 200 Connection established\r\nRetry-After: 1\r\n\r\nHTTP/2 429\r\nRetry-After: 120\r\n\r\n' > $case_dir/headers
    print -r -- '{"ok":false,"error":"ratelimited"}' > $case_dir/response.json
    run_renewer
    check 'throttling reports deferred maintenance' test $result -ne 0
    check 'throttling clears pending and persists final response deadline' $POSTCARD_TEST_JQ -e \
        --argjson now $EPOCHSECONDS '(has("renewal_pending")|not) and .renewal_after >= $now + 118' $credentials
    run_renewer
    check 'another caller honors shared Retry-After' calls 1
    search
    check 'throttling still permits valid access' test $result -eq 0
    check 'search also honors shared Retry-After' calls 1

    for point in 1 2; do
        setup_case publish-$point
        print -r -- mv-$point > $case_dir/fail
        run_renewer
        check "publication $point failure is reported" test $result -ne 0
        if (( point == 1 )); then
            check 'failed marker install makes no exchange' calls 0
            check 'failed marker install preserves saved bytes' unchanged
        else
            check 'failed final install leaves marker' marked
            run_renewer
            check 'failed final install never reexchanges' calls 1
        fi
        check "publication $point failure removes scratch" no_scratch
    done
    setup_case failed-clear
    print -r -- 6 > $case_dir/status.1
    print -r -- mv-2 > $case_dir/fail
    run_renewer
    check 'failed clearing leaves persisted marker authoritative' marked
    run_renewer
    check 'failed clearing does not replay even known-unsent exchange' calls 1

    setup_case contention
    print -r -- curl-1 > $case_dir/gate
    $root/bin/postcard --account widgets renewer > $case_dir/first.out 2> $case_dir/first.err &
    process=$!
    check 'first renewal reaches gated exchange' await test -f $case_dir/ready
    check 'in-flight grant is marked' marked
    run_renewer --account widgets
    check 'concurrent renewal reports busy' test $result -ne 0
    check 'concurrent renewal does not redeem' calls 1
    search
    check 'busy renewal still permits ordinary access' test $result -eq 0
    $root/bin/postcard --account widgets login --client-id 123.456 > $case_dir/login.out 2> $case_dir/login.err
    check 'login contends on the same lock before opening browser' test $? -ne 0
    check 'login reports account busy' rg -q 'account widgets is busy' $case_dir/login.err
    touch $case_dir/release
    check 'first renewal completes' finish
    check 'first renewal succeeds' test $result -eq 0
    run_renewer
    check 'later caller uses already renewed grant' test $result -eq 0
    check 'later caller does not redeem again' calls 1

    setup_case reread-under-lock
    $POSTCARD_TEST_JQ --argjson expires $(( EPOCHSECONDS + 7200 )) \
        '.expires_at=$expires | .access_token="fixture-other-renewal"' $credentials > $case_dir/replacement
    touch $case_dir/replace-after-read
    run_renewer
    check 'renewal rechecks the whole saved grant under lock' test $result -eq 0
    check 'replacement after first snapshot avoids redundant redemption' calls 0

    setup_case selected-account-pinned
    $POSTCARD_TEST_JQ --argjson expires $(( EPOCHSECONDS + 7200 )) '.expires_at=$expires' $credentials > $case_dir/replacement
    touch $case_dir/replace-after-read $case_dir/add-account
    search implicit
    check 'selected account remains pinned through concurrent inventory change' test $result -eq 0
    check 'pinned replacement remains a no-op' calls 0

    setup_case expired-temporary
    replace $credentials '.expires_at=1'
    print -r -- 6 > $case_dir/status.1
    search
    check 'expired access cannot search through a temporary renewal failure' test $result -ne 0
    check 'temporary failure recommends retry' rg -q 'retry later' $case_dir/err
    check 'temporary failure does not falsely require new authorization' zsh -fc '! rg -q "login --client-id" "$1"' _ $case_dir/err

    for shape in false-marker marker-without-refresh invalid-deadline both-states; do
        setup_case metadata-$shape
        case $shape in
            (false-marker) replace $credentials '.renewal_pending=false' ;;
            (marker-without-refresh) replace $credentials 'del(.refresh_token,.expires_at) | .renewal_pending=true' ;;
            (invalid-deadline) replace $credentials '.renewal_after="tomorrow"' ;;
            (both-states) replace $credentials '.renewal_pending=true | .renewal_after=123' ;;
        esac
        run_renewer
        check "$shape metadata is rejected" test $result -ne 0
        check "$shape metadata makes no exchange" calls 0
    done

    setup_case independent-accounts
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/other $XDG_STATE_HOME/postcard/accounts/widgets
    $POSTCARD_TEST_JQ '.client_id="789.012" | .team_id="T_OTHER" | .user_id="U_OTHER"' $credentials \
        > $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json
    : > $XDG_STATE_HOME/postcard/accounts/widgets/login.lock
    zsystem flock -t 0.001 -f lock $XDG_STATE_HOME/postcard/accounts/widgets/login.lock || exit 1
    run_renewer
    check 'busy account contributes aggregate failure' test $result -ne 0
    check 'other account renews without waiting for held account lock' $POSTCARD_TEST_JQ -e \
        '.access_token=="fixture-new-secret" and .client_id=="789.012" and .team_id=="T_OTHER" and .user_id=="U_OTHER"' \
        $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json
    check 'held account is unchanged' unchanged
    check 'only independent account was exchanged' calls 1
    zsystem flock -u $lock
    lock=-1

    for point in curl-1 mv-2; do
        for signal in INT TERM HUP; do
            setup_case interrupted-$point-$signal
            print -r -- $point > $case_dir/gate
            $root/bin/postcard --account widgets renewer > $case_dir/out 2> $case_dir/err &
            process=$!
            check "$signal reaches $point" await test -f $case_dir/ready
            integer writer=$(<$case_dir/ready)
            check "$signal interrupts $point promptly" cancel $signal
            check "$signal reaps $point writer" dead $writer
            check "$signal preserves restart marker" marked
            check "$signal removes unpublished work" no_scratch
            run_renewer
            check "$signal restart never redeems again" calls 1
        done
    done

    setup_case account-isolation
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/broken $XDG_CONFIG_HOME/postcard/accounts/unfinished
    print -r -- broken > $XDG_CONFIG_HOME/postcard/accounts/broken/credentials.json
    run_renewer
    check 'one broken account makes aggregate failure' test $result -ne 0
    check 'broken account does not prevent another renewal' renewed
    check 'unfinished directory is not a failure' zsh -fc '! rg -q unfinished "$1"' _ $case_dir/err
    run_renewer --account widgets
    check 'explicit account narrows the pass' test $result -eq 0
    check 'explicit account no-op is quiet' quiet

    setup_case post-renewal-uncertain-write
    export POSTCARD_TEST_POST=$case_dir/post
    mkdir -p $POSTCARD_TEST_POST
    print -r -- '{"ok":true,"team_id":"T_FIXTURE","user_id":"U_FIXTURE"}' > $POSTCARD_TEST_POST/auth.test.json
    print -r -- '{"ok":true,"user":{"id":"U_FIXTURE","profile":{"display_name":"Jane Doe"}}}' > $POSTCARD_TEST_POST/users.info.json
    print -r -- 28 > $POSTCARD_TEST_POST/chat.postMessage.status
    $root/bin/postcard --account widgets post --channel C012FIXTURE --model Codex <<< 'A fixture post.' > $case_dir/out 2> $case_dir/err
    result=$?
    check 'renewal precedes post, whose uncertain write keeps status 4' test $result -eq 4
    check 'post used renewed snapshot' rg -Fxq 'Authorization: Bearer fixture-new-secret' $POSTCARD_TEST_POST/chat.postMessage.header
    check 'post refresh exchanges exactly once' calls 1
    check 'uncertain message is never resent after renewal' zsh -fc '[[ $(rg -c "^chat.postMessage$" "$1") == 1 ]]' _ $POSTCARD_TEST_POST/calls

    typeset reader
    setup_case watch-expiry-recovery
    setup_watch
    replace $credentials ".renewal_pending=true | .expires_at=$(( EPOCHSECONDS + 3 ))"
    start_watch
    check 'watch reports renewal trouble while still ringing with usable access' await bells 1
    check 'watch reports a single login-needed transition' health_lines 1
    check 'watch supplies an exact login command' rg -q 'postcard --account widgets login --client-id 123.456' $case_dir/out
    check 'watch reports waiting when old access expires' await rg -q 'Watch is waiting' $case_dir/out
    check 'watch has two health transitions after expiry' health_lines 2
    check 'waiting watch is alive' kill -0 $process
    check 'waiting watch does not redeem uncertain refresh' calls 0
    check 'waiting watch does not probe again' watch_requests 1
    replace $credentials ".access_token=\"fixture-relogin-secret\" | .expires_at=$(( EPOCHSECONDS + 7200 )) | del(.renewal_pending)"
    check 'same-binding login resumes watch health' await rg -q 'access and renewal are ready' $case_dir/out
    check 'recovery does not release the unread pending generation' watch_requests 1
    check 'health changes do not write reader progress' cmp -s $reader $case_dir/reader.before
    replace $reader '.generation += 1'
    check 'a real reader publication rearms after recovery' await bells 2
    check 'recovered probe uses the new login snapshot' rg -Fxq 'Authorization: Bearer fixture-relogin-secret' $POSTCARD_TEST_WATCH/header.2
    check 'recovered watch stops promptly' cancel
    check 'recovered watch cleans scratch' no_scratch

    setup_case watch-pending-maintenance
    setup_watch
    $POSTCARD_TEST_JQ '.expires_in=3' $case_dir/response.json > $case_dir/response.1.json
    start_watch 10
    check 'watch rings after initial quiet renewal' await bells 1
    check 'pending bell and long interval cannot block due maintenance' await calls 2
    check 'maintenance after a pending bell does not probe' watch_requests 1
    check 'routine maintenance stays silent' health_lines 0
    check 'pending maintenance leaves reader bytes unchanged' cmp -s $reader $case_dir/reader.before
    check 'next maintenance uses the replacement refresh token' rg -q 'refresh_token=fixture-next-secret' $case_dir/refresh.2.form
    check 'pending maintenance watch stops promptly' cancel
    check 'pending maintenance cleans scratch' no_scratch

    setup_case watch-maintenance-cadence
    setup_watch
    print -r -- '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}' > $POSTCARD_TEST_WATCH/page.1.json
    cp $POSTCARD_TEST_WATCH/page.1.json $POSTCARD_TEST_WATCH/page.2.json
    $POSTCARD_TEST_JQ '.expires_in=2' $case_dir/response.json > $case_dir/response.1.json
    start_watch 5
    check 'short-lived grant prompts maintenance during a long probe interval' await calls 2
    check 'maintenance wake does not accelerate Slack probe' watch_requests 1
    check 'next probe still follows the configured interval' await test -f $POSTCARD_TEST_WATCH/start.2
    check 'probe interval is measured independently of maintenance' zsh -fc \
        '(( $(<$1/start.2) - $(<$1/end.1) >= 4.9 ))' _ $POSTCARD_TEST_WATCH
    check 'cadence watch remains quiet' test ! -s $case_dir/out
    check 'cadence watch stops promptly' cancel

    setup_case watch-interrupted-renewal
    setup_watch
    print -r -- curl-1 > $case_dir/gate
    start_watch
    check 'watch reaches renewal exchange' await test -f $case_dir/ready
    integer writer=$(<$case_dir/ready)
    check 'watch cancellation interrupts nested renewal' cancel
    check 'nested renewal child is reaped' dead $writer
    check 'watch cancellation preserves marked grant' marked
    check 'watch cancellation removes both lifetimes scratch' no_scratch

    print -r -- "renewal: $failures failure(s)"
} always {
    (( process == 0 )) || { kill -TERM $process 2>/dev/null; wait $process 2>/dev/null; }
    (( other == 0 )) || { kill -TERM $other 2>/dev/null; wait $other 2>/dev/null; }
    (( lock < 0 )) || zsystem flock -u $lock
    if (( failures == 0 )); then
        rm -rf -- $fixture
    else
        print -r -- "fixtures retained: $fixture"
    fi
}
(( failures == 0 ))
