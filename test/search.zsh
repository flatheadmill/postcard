#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/datetime zsh/system
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.search.XXXXXX) || exit 1
typeset case_dir credentials original
integer failures=0 result
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
ln -s $root/test/search-curl.zsh $fixture/bin/curl
cat > $fixture/bin/jq <<'EOF'
#!/bin/zsh -f
print -rl -- "$@" >> $POSTCARD_TEST_SEARCH/jq.argv
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
    export POSTCARD_TEST_SEARCH=$case_dir
    unset POSTCARD_TEST_REPLACEMENT POSTCARD_TEST_CREDENTIALS POSTCARD_TEST_CURL_STATUS
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    original=$case_dir/original
    $POSTCARD_TEST_JQ -n '{ok:true,messages:{
        total:40,paging:{count:20,page:1,pages:2,total:40},
        matches:[{channel:{id:"C_FIXTURE"},ts:"1700000000.000002",text:"A fixture message."}]
    }}' > $case_dir/response.json
}

function save_grant {
    typeset name=${1:-widgets}
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/$name
    $POSTCARD_TEST_JQ -n '{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE",
        access_token:"fixture-search-secret",scope:"chat:write,search:read,users:read"}' \
        > $XDG_CONFIG_HOME/postcard/accounts/$name/credentials.json
    [[ -e $credentials ]] && cp $credentials $original
}

function run_search {
    $root/bin/postcard "$@" > $case_dir/out 2> $case_dir/err
    result=$?
}

function failed {
    (( result != 0 )) && [[ ! -s $case_dir/out ]]
}

function no_request {
    [[ ! -e $case_dir/calls ]]
}

function unchanged {
    cmp -s $credentials $original
}

function relogin {
    grep -Fq 'postcard --account widgets login --client-id 123.456' $case_dir/err
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
    run_search search --query fixture
    check "$1 fails with empty stdout" failed
    check "$1 preserves credentials" unchanged
}

{
    setup_case literal
    save_grant
    typeset query=$'"widget shipment" in:general + & = % \\ $(not-a-command)\nsecond line'
    change_response '.messages.matches[0].text = "<@U_FIXTURE> &amp; café 🦆\n\\ literal" |
        .messages.matches += [(.messages.matches[0] | .ts = "99999999999999999999.000001" | .thread_ts = "1700000000.000000")]'
    run_search --account widgets search --query "$query"
    check 'explicit account search succeeds' test $result -eq 0
    check 'one request despite further pages' test "$(wc -l < $case_dir/calls)" -eq 1
    check 'query and page options reach curl unchanged' $POSTCARD_TEST_JQ -e --arg query "$query" '
        index("query=" + $query) != null and index("count=20") != null and index("page=1") != null
        and index("sort=timestamp") != null and index("sort_dir=desc") != null and index("highlight=false") != null
        and index("--get") != null and index("--header") != null and index("@-") != null
        and .[-1] == "https://slack.com/api/search.messages"
        and index("--max-time") != null and index("--retry") == null and .[0] == "-q"
    ' $case_dir/argv.json
    check 'bearer token travels on stdin' grep -Fxq 'Authorization: Bearer fixture-search-secret' $case_dir/header
    check 'result uses saved account context and original query' $POSTCARD_TEST_JQ -e --arg query "$query" '
        .account == "widgets" and .team_id == "T_FIXTURE" and .user_id == "U_FIXTURE" and .query == $query
    ' $case_dir/out
    check 'literal text and string timestamps survive without local sorting' $POSTCARD_TEST_JQ -es '
        .[0].messages.matches as $matches | .[1].matches as $out |
        ($out | length) == 2 and $out[0].text == $matches[0].text and $out[1].ts == $matches[1].ts
        and $out[0].ts == $matches[0].ts and $out[0].thread_ts == null and $out[1].thread_ts == $matches[1].thread_ts
        and ($out[0] | keys) == ["channel","text","thread_ts","ts"]
    ' $case_dir/response.json $case_dir/out
    check 'search never changes credentials' unchanged
    if grep -Fq fixture-search-secret $case_dir/argv.json $case_dir/jq.argv $case_dir/out $case_dir/err; then
        check 'token stays out of argv, output, and diagnostics' false
    else
        check 'token stays out of argv, output, and diagnostics' true
    fi

    setup_case page
    save_grant
    change_response '.messages.paging = {count:1,page:2,pages:40,total:40}'
    run_search search --query fixture --count 001 --page 2
    check 'sole account and explicit page succeed' test $result -eq 0
    check 'count and page reach the request' $POSTCARD_TEST_JQ -e 'index("count=1") != null and index("page=2") != null' $case_dir/argv.json
    check 'reported paging is retained' $POSTCARD_TEST_JQ -e '.paging == {count:1,page:2,pages:40,total:40}' $case_dir/out

    typeset option value
    for option in count page; do
        for value in 0 101 -1 1.5 '1+1' nope 999999999999999999999999 ''; do
            setup_case invalid-$option-${value:-empty}
            save_grant
            run_search search --query fixture --$option "$value"
            check "$option=$value is rejected before HTTP" failed
            check "$option=$value sends no request" no_request
        done
    done
    setup_case hundred
    save_grant
    change_response '.messages.paging = {count:100,page:100,pages:100,total:10000} | .messages.total = 10000'
    run_search search --query fixture --count 100 --page 100
    check 'upper option bounds are accepted' test $result -eq 0

    setup_case no-query
    save_grant
    run_search search
    check 'query is required by the parser' failed
    check 'missing query sends no request' no_request
    run_search search --query ''
    check 'empty query is rejected' failed

    setup_case no-accounts
    run_search search --query fixture
    check 'no accounts requires login' failed
    check 'no accounts sends no request' no_request
    setup_case unfinished
    save_grant
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/unfinished
    run_search search --query fixture
    check 'unfinished directory does not make selection ambiguous' test $result -eq 0

    typeset second
    for second in valid broken expired; do
        setup_case multiple-$second
        save_grant
        save_grant other
        case $second in
            (broken) print -r -- broken > $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json ;;
            (expired) $POSTCARD_TEST_JQ '. + {refresh_token:"fixture-refresh",expires_at:1}' $credentials > $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json ;;
        esac
        run_search search --query fixture
        check "multiple accounts including $second require selection" failed
        check "ambiguous $second selection sends no request" no_request
        run_search --account widgets search --query fixture
        check "explicit selection works beside $second account" test $result -eq 0
    done
    setup_case no-fallback
    save_grant
    run_search --account missing search --query fixture
    check 'missing explicit account never falls back' failed
    run_search --account Widgets search --query fixture
    check 'explicit account spelling is exact' failed
    check 'unknown account sends no request' no_request
    print -r -- broken > $credentials
    run_search search --query fixture
    check 'sole broken account reports invalid credentials' failed
    check 'broken credentials send no request' no_request

    setup_case rotating
    save_grant
    change_grant ". + {refresh_token:\"fixture-refresh\",expires_at:$(( EPOCHSECONDS + 3600 ))}"
    run_search search --query fixture
    check 'unexpired rotating grant can search' test $result -eq 0
    check 'rotating grant stays unchanged' unchanged
    setup_case expired
    save_grant
    change_grant '. + {refresh_token:"fixture-refresh",expires_at:1}'
    run_search search --query fixture
    check 'local expiry fails with empty stdout' failed
    check 'local expiry gives concrete re-login instruction' relogin
    check 'local expiry never contacts Slack' no_request
    check 'local expiry preserves refresh credentials' unchanged
    setup_case scope
    save_grant
    change_grant '.scope = "search:reader,chat:write"'
    run_search search --query fixture
    check 'missing exact search scope fails' failed
    check 'missing scope sends no request' no_request
    check 'missing scope gives re-login instruction' relogin

    typeset error
    for error in token_expired invalid_auth missing_scope ratelimited; do
        setup_case slack-$error
        save_grant
        change_response "{ok:false,error:\"$error\"}"
        run_search search --query fixture
        check "Slack $error fails with empty stdout" failed
        check "Slack $error leaves credentials unchanged" unchanged
        check "Slack $error is not retried or renewed" test "$(wc -l < $case_dir/calls)" -eq 1
        [[ $error == ratelimited ]] || check "Slack $error gives re-login instruction" relogin
    done

    setup_case snapshot
    save_grant
    $POSTCARD_TEST_JQ '.team_id="T_NEW" | .user_id="U_NEW" | .access_token="replacement-secret"' $credentials > $case_dir/replacement
    export POSTCARD_TEST_REPLACEMENT=$case_dir/replacement POSTCARD_TEST_CREDENTIALS=$credentials
    run_search search --query fixture
    check 'replacement during search succeeds with one snapshot' test $result -eq 0
    check 'request uses original token' grep -Fxq 'Authorization: Bearer fixture-search-secret' $case_dir/header
    check 'output uses original identity' $POSTCARD_TEST_JQ -e '.team_id=="T_FIXTURE" and .user_id=="U_FIXTURE"' $case_dir/out
    check 'search does not overwrite replacement' cmp -s $credentials $case_dir/replacement

    setup_case unlocked-read
    save_grant
    typeset lock_file=$XDG_STATE_HOME/postcard/accounts/widgets/login.lock
    mkdir -p ${lock_file:h}
    : > $lock_file
    integer held
    zsystem flock -t 0.001 -f held $lock_file || exit 1
    run_search search --query fixture
    zsystem flock -u $held
    check 'search can read while login holds its lock' test $result -eq 0

    typeset convention
    for convention in 0 1; do
        setup_case empty-$convention
        save_grant
        change_response ".messages = {matches:[],paging:{count:20,page:$convention,pages:$convention,total:0}}"
        run_search search --query fixture
        check "empty result convention $convention succeeds" test $result -eq 0
        check "empty result $convention retains empty array" $POSTCARD_TEST_JQ -e '.matches == [] and .paging.total == 0' $case_dir/out
    done
    setup_case modern-paging
    save_grant
    change_response '.messages |= (del(.paging) | .pagination={per_page:20,page:1,page_count:2,total_count:40})'
    run_search search --query fixture
    check 'pagination-only response maps explicitly' test $result -eq 0
    check 'mapped paging fields are correct' $POSTCARD_TEST_JQ -e '.paging == {count:20,page:1,pages:2,total:40}' $case_dir/out
    setup_case both-paging
    save_grant
    change_response '.messages.pagination={per_page:20,page:1,page_count:2,total_count:40}'
    run_search search --query fixture
    check 'consistent paging envelopes succeed' test $result -eq 0

    rejects_response wrong-ok '.ok="true"'
    rejects_response multiple-documents '., .'
    rejects_response missing-messages 'del(.messages)'
    rejects_response missing-matches 'del(.messages.matches)'
    rejects_response malformed-match '.messages.matches += [{channel:{id:"C_OTHER"},ts:17,text:"bad later match"}]'
    rejects_response missing-channel 'del(.messages.matches[0].channel)'
    rejects_response missing-text 'del(.messages.matches[0].text)'
    rejects_response wrong-parent '.messages.matches[0].thread_ts=17'
    rejects_response missing-paging 'del(.messages.paging)'
    rejects_response wrong-page '.messages.paging.page=2'
    rejects_response fractional-paging '.messages.paging.total=1.5'
    rejects_response negative-paging '.messages.paging.pages=-1'
    rejects_response null-paging '.messages.paging=null'
    rejects_response short-pagination '.messages |= (del(.paging) | .pagination={page:1})'
    rejects_response conflict '.messages.pagination={per_page:20,page:2,page_count:2,total_count:40}'
    rejects_response null-secondary '.messages.pagination={page:null}'
    rejects_response total-conflict '.messages.total=41'
    rejects_response oversized-page '.messages.paging.count=1 | .messages.matches += .messages.matches'
    rejects_response impossible-empty '.messages.total=0 | .messages.paging.total=0'
    rejects_response unexpected-empty-page '.messages={matches:[],paging:{count:20,page:2,pages:0,total:0}}'

    typeset failure
    for failure in transport http invalid-json; do
        setup_case $failure
        save_grant
        case $failure in
            (transport) export POSTCARD_TEST_CURL_STATUS=28 ;;
            (http) export POSTCARD_TEST_CURL_STATUS=22 ;;
            (invalid-json) print -r -- 'invalid response fixture-search-secret' > $case_dir/response.json ;;
        esac
        run_search search --query fixture
        check "$failure fails with empty stdout" failed
        check "$failure preserves credentials" unchanged
        if grep -Fq fixture-search-secret $case_dir/out $case_dir/err; then
            check "$failure does not disclose the token" false
        fi
    done
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}
(( failures == 0 )) || { print -r -- "search: $failures failure(s)"; exit 1; }
print -r -- 'search: PASS'
