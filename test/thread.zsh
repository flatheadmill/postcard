#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/datetime zsh/system
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.thread.XXXXXX) || exit 1
typeset case_dir credentials original
typeset -a address=( --channel C_FIXTURE --ts 1700000000.000000 )
integer failures=0 result
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
ln -s $root/test/thread-curl.zsh $fixture/bin/curl
cat > $fixture/bin/jq <<'EOF'
#!/bin/zsh -f
print -rl -- "$@" >> $POSTCARD_TEST_THREAD/jq.argv
exec $POSTCARD_TEST_JQ "$@"
EOF
chmod +x $fixture/bin/jq
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
    mkdir -p $case_dir
    export XDG_CONFIG_HOME=$case_dir/config XDG_STATE_HOME=$case_dir/state
    export POSTCARD_TEST_THREAD=$case_dir
    unset POSTCARD_TEST_REPLACEMENT POSTCARD_TEST_CREDENTIALS POSTCARD_TEST_CURL_STATUS POSTCARD_TEST_HTTP_STATUS
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    original=$case_dir/original
    $POSTCARD_TEST_JQ -n '{ok:true,has_more:false,response_metadata:{next_cursor:""},
        messages:[{type:"message",user:"U_FIXTURE",ts:"1700000000.000000",
            thread_ts:"1700000000.000000",text:"Shipment planning.",reply_count:3}]
    }' > $case_dir/response.json
}

function save_grant {
    typeset name=${1:-widgets}
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/$name
    $POSTCARD_TEST_JQ -n '{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE",
        access_token:"fixture-thread-secret",scope:"channels:history"}' \
        > $XDG_CONFIG_HOME/postcard/accounts/$name/credentials.json
    [[ -e $credentials ]] && cp $credentials $original
}

function run_thread {
    $root/bin/postcard "$@" > $case_dir/out 2> $case_dir/err
    result=$?
}

function failed {
    (( result != 0 )) && [[ ! -s $case_dir/out ]]
}

function no_request {
    [[ ! -e $case_dir/calls ]]
}

function rejected_option {
    # The parser's unknown-long-option exit status is tracked separately.
    # Rejection must still diagnose the option without executing a Slack read.
    [[ ! -s $case_dir/out ]] &&
        rg -Fq "unknown argument \"$1\"." $case_dir/err && no_request
}

function one_request {
    [[ -e $case_dir/calls ]] && (( $(wc -l < $case_dir/calls) == 1 ))
}

function unchanged {
    cmp -s $credentials $original
}

function private_output {
    ! rg -Fq fixture-thread-secret $case_dir/{out,err,argv.json,jq.argv}(N)
}

function relogin {
    rg -Fq 'postcard --account widgets login --client-id 123.456' $case_dir/err
}

function change_response {
    $POSTCARD_TEST_JQ "$1" $case_dir/response.json > $case_dir/next.json || return
    mv $case_dir/next.json $case_dir/response.json
}

function change_grant {
    $POSTCARD_TEST_JQ "$1" $credentials > $case_dir/next.json || return
    mv $case_dir/next.json $credentials
    cp $credentials $original
}

function rejects_response {
    setup_case $1
    save_grant
    change_response "$2" || return
    run_thread thread "${address[@]}"
    check "$1 fails with empty stdout" failed
    check "$1 makes one request" one_request
    check "$1 preserves credentials" unchanged
    check "$1 does not disclose the token" private_output
}

{
    setup_case literal
    save_grant
    change_response '.has_more=true | .response_metadata.next_cursor="next+/=%& token" |
        .messages[0] += {text:"<@U_FIXTURE> &amp; café 🦆\n\\ literal",blocks:[{type:"rich_text",elements:[]}],
            files:[{id:"F_FIXTURE",name:"packing.txt",size:17}],edited:{user:"U_EDITOR",ts:"1700000000.000001"},
            arbitrary:{nested:[null,true,17,"unchanged"]}} |
        .messages += [{type:"message",subtype:"bot_message",bot_id:"B_FIXTURE",app_id:"A_FIXTURE",
            ts:"99999999999999999999.000001",thread_ts:"1700000000.000000",attachments:[]},
            {ts:"1700000000.000002",thread_ts:"1700000000.000000",text:"later in array"},
            {ts:"1700000000.000002",thread_ts:"1700000000.000000",text:"same address, different payload"}]'
    run_thread --account widgets thread "${address[@]}"
    check 'explicit thread account succeeds with one history scope' test $result -eq 0
    check 'thread makes one request despite continuation' one_request
    check 'thread request wire and bounds are explicit' $POSTCARD_TEST_JQ -e '
        def option($name; $value): index($name) as $i | $i != null and .[$i+1] == $value;
        .[0] == "-q" and .[-1] == "https://slack.com/api/conversations.replies"
        and option("--proto"; "=https") and option("--connect-timeout"; "10") and option("--max-time"; "30")
        and option("--header"; "@-") and index("--get") != null and index("--fail") != null
        and index("--retry") == null and index("--location") == null
        and (index("channel=C_FIXTURE") as $i | .[$i-1] == "--data-urlencode")
        and (index("ts=1700000000.000000") as $i | .[$i-1] == "--data-urlencode")
        and (index("limit=20") as $i | .[$i-1] == "--data-urlencode")
        and (any(.[]; startswith("oldest=") or startswith("cursor=")) | not)
    ' $case_dir/argv.json
    check 'thread bearer token uses stdin' rg -Fxq 'Authorization: Bearer fixture-thread-secret' $case_dir/header
    check 'thread output identifies its saved principal and request' $POSTCARD_TEST_JQ -e '
        .account=="widgets" and .team_id=="T_FIXTURE" and .user_id=="U_FIXTURE"
        and .channel=="C_FIXTURE" and .ts=="1700000000.000000" and .after==null
        and .paging=={count:20,cursor:null,next_cursor:"next+/=%& token"}
        and keys==["account","after","channel","messages","paging","team_id","ts","user_id"]
    ' $case_dir/out
    check 'all message fields, duplicates, order, and timestamp strings survive' $POSTCARD_TEST_JQ -es \
        '.[0].messages == .[1].messages' $case_dir/response.json $case_dir/out
    check 'thread preserves credential bytes' unchanged
    check 'thread token stays out of argv, output, and diagnostics' private_output
    check 'thread creates no state directory' test ! -e $XDG_STATE_HOME

    setup_case continuation
    save_grant
    typeset cursor=$'opaque+/= &%? \\ $(not-a-command)\ncontinuation'
    $POSTCARD_TEST_JQ --arg cursor "$cursor" '.messages[0].ts="1700000000.000011" |
        .has_more=true | .response_metadata.next_cursor=$cursor' $case_dir/response.json > $case_dir/next.json
    mv $case_dir/next.json $case_dir/response.json
    run_thread thread "${address[@]}" --count 001 --after 1700000000.000010
    check 'first bounded after page succeeds' test $result -eq 0
    cp $case_dir/out $case_dir/first.json
    cp $case_dir/argv.json $case_dir/first-argv.json
    cursor=$($POSTCARD_TEST_JQ -r '.paging.next_cursor' $case_dir/first.json)
    change_response '.messages[0].ts="1700000000.000012" | .has_more=false | .response_metadata.next_cursor=null'
    run_thread --account widgets thread "${address[@]}" --count 001 --after 1700000000.000010 --cursor "$cursor"
    check 'explicit continuation page succeeds without the parent' test $result -eq 0
    check 'two invocations make exactly two requests' test "$(wc -l < $case_dir/calls)" -eq 2
    check 'opaque cursor is one value for URL encoding' $POSTCARD_TEST_JQ -e --arg cursor "$cursor" \
        'index("cursor="+$cursor) as $i | $i != null and .[$i-1]=="--data-urlencode"' $case_dir/argv.json
    check 'continuation repeats the exact address and exclusive lower bound' $POSTCARD_TEST_JQ -es '
        all(.[]; index("channel=C_FIXTURE") != null and index("ts=1700000000.000000") != null
            and index("limit=1") != null and index("oldest=1700000000.000010") != null
            and index("inclusive=false") != null)
    ' $case_dir/first-argv.json $case_dir/argv.json
    check 'continuation envelope records the cursor and unchanged boundary' $POSTCARD_TEST_JQ -e --arg cursor "$cursor" \
        '.after=="1700000000.000010" and .paging=={count:1,cursor:$cursor,next_cursor:null}' $case_dir/out
    check 'after never saves progress' test ! -e $XDG_STATE_HOME
    check 'continuation preserves credentials' unchanged

    typeset value option
    for value in 0 101 -1 1.5 '1+1' nope 999999999999999999999999 ''; do
        setup_case invalid-count-${value:-empty}
        save_grant
        run_thread thread "${address[@]}" --count "$value"
        check "thread count=$value is rejected" failed
        check "thread count=$value sends no request" no_request
    done
    setup_case hundred
    save_grant
    run_thread thread "${address[@]}" --count 100
    check 'thread count upper bound is accepted' test $result -eq 0
    check 'thread count upper bound reaches Slack' $POSTCARD_TEST_JQ -e 'index("limit=100") != null' $case_dir/argv.json

    setup_case required-address
    save_grant
    run_thread thread --ts 1700000000.000000
    check 'thread parser requires channel' failed
    run_thread thread --channel C_FIXTURE
    check 'thread parser requires parent' failed
    check 'incomplete addresses send no request' no_request
    run_thread thread --channel '' --ts 1700000000.000000
    check 'empty channel is rejected' failed
    for option in ts after; do
        for value in '' nope 1700000000 '1+1.000000' 1.2.3 -1.000000 $'1.000000\n'; do
            run_thread thread "${address[@]}" --$option "$value"
            check "invalid thread $option=${value:-empty} is rejected" failed
        done
    done
    check 'invalid timestamps send no request' no_request
    run_thread thread "${address[@]}" --cursor ''
    check 'explicit empty cursor cannot restart a query' failed
    check 'empty cursor sends no request' no_request
    run_thread thread "${address[@]}" unexpected
    check 'thread rejects positional arguments' failed
    for option in reader alias permalink all window around from through; do
        run_thread thread "${address[@]}" --$option fixture
        check "thread does not accept --$option" rejected_option "$option"
    done

    setup_case no-accounts
    run_thread thread "${address[@]}"
    check 'thread with no account requires login' failed
    check 'thread with no account sends no request' no_request
    setup_case unfinished
    save_grant
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/unfinished
    run_thread thread "${address[@]}"
    check 'sole saved thread account ignores unfinished directories' test $result -eq 0
    typeset second
    for second in valid broken expired; do
        setup_case multiple-$second
        save_grant
        save_grant other
        case $second in
            (broken) print -r -- broken > $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json ;;
            (expired) $POSTCARD_TEST_JQ '.+{refresh_token:"fixture-refresh",expires_at:1}' $credentials \
                > $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json ;;
        esac
        run_thread thread "${address[@]}"
        check "thread requires selection beside $second account" failed
        check "ambiguous $second thread selection sends no request" no_request
        run_thread --account widgets thread "${address[@]}"
        check "explicit thread account works beside $second account" test $result -eq 0
    done
    setup_case no-fallback
    save_grant
    for value in missing Widgets '../widgets' ''; do
        run_thread --account "$value" thread "${address[@]}"
        check "thread never falls back from account=$value" failed
    done
    check 'invalid explicit accounts send no request' no_request
    print -r -- broken > $credentials
    run_thread thread "${address[@]}"
    check 'sole broken thread account is rejected' failed
    check 'broken thread grant sends no request' no_request

    setup_case rotating
    save_grant
    change_grant ".+{refresh_token:\"fixture-refresh\",expires_at:$(( EPOCHSECONDS + 3600 ))}"
    run_thread thread "${address[@]}"
    check 'unexpired rotating thread grant works' test $result -eq 0
    check 'thread does not rotate the grant' unchanged
    setup_case expired
    save_grant
    change_grant '.+{refresh_token:"fixture-refresh",expires_at:1}'
    run_thread thread "${address[@]}"
    check 'local thread expiry leaves stdout empty' failed
    check 'local thread expiry gives concrete login instruction' relogin
    check 'local thread expiry makes no request' no_request
    check 'local thread expiry leaves credentials alone' unchanged

    setup_case snapshot
    save_grant
    $POSTCARD_TEST_JQ '.team_id="T_NEW" | .user_id="U_NEW" | .access_token="replacement-secret"' \
        $credentials > $case_dir/replacement
    export POSTCARD_TEST_REPLACEMENT=$case_dir/replacement POSTCARD_TEST_CREDENTIALS=$credentials
    run_thread thread "${address[@]}"
    check 'thread tolerates a concurrent credential replacement' test $result -eq 0
    check 'thread uses the original snapshot token' rg -Fxq 'Authorization: Bearer fixture-thread-secret' $case_dir/header
    check 'thread uses the original snapshot identity' $POSTCARD_TEST_JQ -e \
        '.team_id=="T_FIXTURE" and .user_id=="U_FIXTURE"' $case_dir/out
    check 'thread leaves the replacement intact' cmp -s $credentials $case_dir/replacement
    setup_case unlocked-read
    save_grant
    typeset lock_file=$XDG_STATE_HOME/postcard/accounts/widgets/login.lock
    mkdir -p ${lock_file:h}
    : > $lock_file
    integer held
    zsystem flock -t 0.001 -f held $lock_file || exit 1
    run_thread thread "${address[@]}"
    zsystem flock -u $held
    check 'thread reads while login holds its lock' test $result -eq 0

    typeset shape
    for shape in short empty; do
        setup_case $shape-page
        save_grant
        change_response '.has_more=true | .response_metadata.next_cursor="next-page"'
        [[ $shape != empty ]] || change_response '.messages=[]'
        run_thread thread "${address[@]}"
        check "$shape thread page can continue" test $result -eq 0
        check "$shape thread page keeps its cursor" $POSTCARD_TEST_JQ -e '.paging.next_cursor=="next-page"' $case_dir/out
        check "$shape thread page is one request" one_request
    done
    for shape in empty null absent metadata-absent metadata-null; do
        setup_case terminal-$shape
        save_grant
        case $shape in
            (empty) change_response '.response_metadata.next_cursor=""' ;;
            (null) change_response '.response_metadata.next_cursor=null' ;;
            (absent) change_response 'del(.response_metadata.next_cursor)' ;;
            (metadata-absent) change_response 'del(.response_metadata)' ;;
            (metadata-null) change_response '.response_metadata=null' ;;
        esac
        change_response '.messages=[]'
        run_thread thread "${address[@]}" --after 1700000000.000010
        check "terminal $shape cursor succeeds" test $result -eq 0
        check "terminal $shape cursor becomes null" $POSTCARD_TEST_JQ -e \
            '.paging.next_cursor==null and .messages==[]' $case_dir/out
    done
    setup_case cursor-without-more
    save_grant
    change_response 'del(.has_more) | .response_metadata.next_cursor="next-page"'
    run_thread thread "${address[@]}"
    check 'thread does not require has_more to expose a cursor' test $result -eq 0
    check 'thread retains a cursor without has_more' $POSTCARD_TEST_JQ -e '.paging.next_cursor=="next-page"' $case_dir/out

    for shape in absent null empty; do
        setup_case parent-$shape
        save_grant
        case $shape in
            (absent) change_response 'del(.messages[0].thread_ts)' ;;
            (null) change_response '.messages[0].thread_ts=null' ;;
            (empty) change_response '.messages[0].thread_ts=""' ;;
        esac
        run_thread thread "${address[@]}"
        check "parent evidence $shape accepts a single message" test $result -eq 0
        check "parent evidence $shape is preserved literally" $POSTCARD_TEST_JQ -es \
            '.[0].messages==.[1].messages' $case_dir/response.json $case_dir/out
    done
    setup_case different-parent
    save_grant
    change_response '.messages += [{ts:"1700000000.000002",thread_ts:"1699999999.999999",text:"Reply to another parent."}]'
    run_thread thread "${address[@]}"
    check 'a later conflicting parent fails the whole page' failed
    check 'thread reports the actual parent' rg -Fq 'use --ts 1699999999.999999' $case_dir/err
    check 'parent conflict performs no discovery request' one_request
    check 'parent conflict preserves credentials' unchanged

    rejects_response wrong-ok '.ok="true"'
    rejects_response multiple-documents '., .'
    rejects_response root-array '[.]'
    rejects_response missing-messages 'del(.messages)'
    rejects_response null-messages '.messages=null'
    rejects_response wrong-messages '.messages={}'
    rejects_response later-scalar '.messages += [17]'
    rejects_response missing-ts 'del(.messages[0].ts)'
    rejects_response numeric-ts '.messages[0].ts=1700000000.1'
    rejects_response malformed-ts '.messages[0].ts="not a timestamp"'
    rejects_response numeric-parent '.messages[0].thread_ts=17'
    rejects_response diagnostic-parent '.messages[0].thread_ts="fixture-thread-secret"'
    rejects_response newline-parent '.messages[0].thread_ts="1700000000.000001\n"'
    rejects_response oversized-page '.messages=[range(21) | {ts:"1700000000.000000"}]'
    rejects_response wrong-metadata '.response_metadata=[]'
    rejects_response numeric-cursor '.response_metadata.next_cursor=17'
    rejects_response object-cursor '.response_metadata.next_cursor={}'
    rejects_response wrong-has-more '.has_more="true"'
    rejects_response null-has-more '.has_more=null'
    rejects_response more-without-cursor '.has_more=true | del(.response_metadata)'
    rejects_response more-null-cursor '.has_more=true | .response_metadata.next_cursor=null'
    rejects_response more-empty-cursor '.has_more=true | .response_metadata.next_cursor=""'

    typeset error
    for error in token_expired invalid_auth token_revoked missing_scope ratelimited invalid_cursor thread_not_found unknown_error; do
        setup_case slack-$error
        save_grant
        change_response "{ok:false,error:\"$error\",detail:\"fixture-thread-secret\"}"
        run_thread thread "${address[@]}"
        check "thread Slack $error fails with empty stdout" failed
        check "thread Slack $error is not retried" one_request
        check "thread Slack $error leaves credentials unchanged" unchanged
        check "thread Slack $error does not disclose the token" private_output
        case $error in
            (token_expired|invalid_auth|token_revoked|missing_scope) check "thread Slack $error gives concrete login instruction" relogin ;;
            (ratelimited) check 'thread reports rate limiting' rg -Fq 'rate limited' $case_dir/err ;;
            (invalid_cursor) check 'thread reports rejected cursor' rg -Fq 'pagination cursor' $case_dir/err ;;
        esac
    done
    typeset failure
    for failure in transport http-429 http-500 invalid-json; do
        setup_case $failure
        save_grant
        case $failure in
            (transport) export POSTCARD_TEST_CURL_STATUS=28 ;;
            (http-*) export POSTCARD_TEST_CURL_STATUS=22 POSTCARD_TEST_HTTP_STATUS=${failure#http-} ;;
            (invalid-json) print -r -- 'invalid response fixture-thread-secret' > $case_dir/response.json ;;
        esac
        run_thread thread "${address[@]}"
        check "thread $failure fails with empty stdout" failed
        check "thread $failure makes one request" one_request
        check "thread $failure preserves credentials" unchanged
        check "thread $failure does not disclose the token" private_output
    done
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}
(( failures == 0 )) || { print -r -- "thread: $failures failure(s)"; exit 1; }
print -r -- 'thread: PASS'
