#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/system zsh/zselect zsh/stat
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.reader.XXXXXX) || exit 1
typeset case_dir credentials record reader_dir original
typeset -a address=( --channel C012FIXTURE --ts 1.000000 )
integer failures=0 result process consumer pipefd=-1
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
typeset tool
for tool in curl jq cat mv; do
    ln -s $root/test/reader-tool.zsh $fixture/bin/$tool
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
    mkdir -p $case_dir
    export XDG_CONFIG_HOME=$case_dir/config XDG_STATE_HOME=$case_dir/state POSTCARD_TEST_READER=$case_dir
    unset POSTCARD_TEST_FAULT POSTCARD_TEST_GATE POSTCARD_TEST_AFTER_RENAME POSTCARD_TEST_REPLACEMENT POSTCARD_TEST_CREDENTIALS
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    reader_dir=$XDG_STATE_HOME/postcard/accounts/widgets/readers
    record=$reader_dir/workshop.json
    original=$case_dir/original
    mkdir -p ${credentials:h}
    $POSTCARD_TEST_JQ -n '{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE",
        access_token:"fixture-reader-secret",scope:"channels:history"}' > $credentials
    page 1 '[{ts:"2.0",text:"one"}]'
}

function page {
    $POSTCARD_TEST_JQ -n --arg cursor "${3-}" \
        "$2 | {ok:true,messages:.,response_metadata:{next_cursor:\$cursor}}" > $case_dir/page.$1.json
}

function save_reader {
    mkdir -p $reader_dir
    $POSTCARD_TEST_JQ -n '{version:1,binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},
        channel:"C012FIXTURE",ts:"1.000000",through:"1.0",generation:7}' > $record
    cp $record $original
}

function save_alias {
    $POSTCARD_TEST_JQ -n --arg channel "$1" '{version:1,
        binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},
        aliases:{planning:{channel:$channel,ts:"1.000000"}}}' > ${credentials:h}/aliases.json
}

function run_reader {
    $root/bin/postcard --account widgets thread --reader workshop "$@" > $case_dir/out 2> $case_dir/err
    result=$?
}

function failed { (( result != 0 )) && [[ ! -s $case_dir/out ]] }
function no_request { [[ ! -e $case_dir/request.1.json ]] }
function unchanged { cmp -s $record $original }
function absent { [[ ! -e $record ]] }
function clean {
    typeset -a stages=( $reader_dir/.*.work.*(N) $reader_dir/.*.state.*(N) )
    (( $#stages == 0 ))
}
function request_count {
    typeset -a requests=( $case_dir/request.*.json(N) )
    (( $#requests == $1 ))
}
function wait_file {
    integer attempts
    for (( attempts=0; attempts < 500; attempts++ )); do
        [[ ! -e $1 ]] || return 0
        zselect -t 1
    done
    return 1
}
function wait_dead {
    integer attempts
    for (( attempts=0; attempts < 500; attempts++ )); do
        kill -0 $1 2>/dev/null || return 0
        zselect -t 1
    done
    return 1
}
function cancel {
    kill -TERM $process 2>/dev/null
    if ! wait_dead $process; then
        check 'cancelled command exits promptly' false
        kill -KILL $process 2>/dev/null
    fi
    wait $process
    result=$?
}
function next_run {
    rm -f $case_dir/request.*.json(N) $case_dir/header.*(N) $case_dir/ready $case_dir/release $case_dir/output-started
}

{
    setup_case traversal
    typeset cursor=$'opaque+/= &%? \\ $(not-a-command)\n\n'
    page 1 '[{ts:"0001.000",text:"equal"},{ts:"99999999999999999999.000001",other:{nested:[true,null]}},
        {ts:"02.10",text:"first two"}]' "$cursor"
    page 2 '[]' third
    page 3 '[{ts:"2.100",text:"duplicate value"},{ts:"2.100",text:"duplicate value"},
        {ts:"99999999999999999999.0000010",text:"maximum tie"},{ts:"1.00001",text:"small later"}]'
    run_reader "${address[@]}" --after 1.0 --count 3
    # Four messages on the third page must still obey the per-page bound.
    check 'oversized later page fails before output' failed
    check 'failed initialization publishes no reader' absent
    next_run
    run_reader "${address[@]}" --after 1.0 --count 4
    check 'complete traversal initializes a reader' test $result -eq 0
    check 'empty continuing page is followed' request_count 3
    check 'complete result exceeds requested page size and preserves literal order' $POSTCARD_TEST_JQ -es '
        .[3].messages == ([.[0].messages[],.[1].messages[],.[2].messages[]] | .[1:])
        and .[3].through=="99999999999999999999.000001" and .[3].after=="1.0"
        and .[3].generation==0 and .[3].reader=="workshop"
        and (.[3]|keys)==["account","after","channel","generation","messages","reader","team_id","through","ts","user_id"]
    ' $case_dir/page.{1,2,3}.json $case_dir/out
    check 'first publication is generation one with the first maximum literal' $POSTCARD_TEST_JQ -e '
        .version==1 and .generation==1 and .through=="99999999999999999999.000001"
        and .binding=={client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"}
    ' $record
    check 'opaque cursor retains its trailing newlines' $POSTCARD_TEST_JQ -e --arg cursor "$cursor" \
        'index("cursor="+$cursor)!=null' $case_dir/request.2.json
    check 'all pages retain the original boundary, address and page size' $POSTCARD_TEST_JQ -es '
        all(.[]; index("oldest=1.0")!=null and index("channel=C012FIXTURE")!=null
            and index("ts=1.000000")!=null and index("limit=4")!=null and index("inclusive=false")!=null)
    ' $case_dir/request.{1,2,3}.json
    check 'success removes staging and retains the stable lock' clean
    check 'stable lock remains' test -f $reader_dir/workshop.lock
    integer mode
    typeset -A stat
    zstat -H stat $record
    check 'published state is private' test $(( stat[mode] & 8#777 )) -eq $(( 8#600 ))
    next_run
    page 1 '[]'
    run_reader
    check 'empty continuation succeeds' test $result -eq 0
    check 'empty continuation retains boundary and reports starting generation' $POSTCARD_TEST_JQ -e \
        '.messages==[] and .generation==1 and .after==.through and .through=="99999999999999999999.000001"' $case_dir/out
    check 'empty observation advances generation' $POSTCARD_TEST_JQ -e '.generation==2' $record

    setup_case empty-initial
    page 1 '[]'
    mkdir -p $reader_dir
    : > $reader_dir/workshop.lock
    run_reader "${address[@]}" --after 0001.000
    check 'leftover lock permits empty initialization' test $result -eq 0
    check 'empty initialization preserves literal boundary at generation one' $POSTCARD_TEST_JQ -e \
        '.through=="0001.000" and .generation==1' $record

    setup_case decimal
    page 1 '[{ts:"0009.2000"},{ts:"09.20"},{ts:"9.20000"},{ts:"9.20001"},{ts:"9.21"},
        {ts:"9.3"},{ts:"9.3000"},{ts:"10.000"},{ts:"0010.0"}]'
    run_reader "${address[@]}" --after 9.20
    check 'different widths and zero spellings compare by decimal value' $POSTCARD_TEST_JQ -e \
        '[.messages[].ts]==["9.20001","9.21","9.3","9.3000","10.000","0010.0"] and .through=="10.000"' $case_dir/out

    setup_case alias
    save_alias C012FIXTURE
    run_reader --alias planning --after 1.0
    check 'alias initialization succeeds' test $result -eq 0
    save_alias C999OTHER
    next_run
    run_reader
    check 'alias rebinding does not redirect a reader' $POSTCARD_TEST_JQ -e 'index("channel=C012FIXTURE")!=null' $case_dir/request.1.json
    next_run
    typeset option
    for option in alias after; do
        if [[ $option == alias ]]; then run_reader --alias planning; else run_reader --after 2.0; fi
        check "existing reader refuses --$option" failed
    done
    run_reader "${address[@]}"
    check 'existing reader refuses direct address' failed
    check 'retarget attempts make no request' no_request

    setup_case account-isolation
    run_reader "${address[@]}" --after 1.0
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/other
    cp $credentials $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json
    next_run
    $root/bin/postcard --account other thread --reader workshop "${address[@]}" --after 1.0 > $case_dir/other.out 2> $case_dir/other.err
    check 'same reader name in another account initializes independently' test $? -eq 0
    check 'account readers each start at generation one' $POSTCARD_TEST_JQ -es \
        'length==2 and all(.[]; .generation==1)' $record $XDG_STATE_HOME/postcard/accounts/other/readers/workshop.json

    setup_case forms
    run_reader
    check 'new reader requires an address and boundary' failed
    run_reader "${address[@]}"
    check 'new reader requires explicit after' failed
    run_reader --after 1.0
    check 'new reader requires explicit address' failed
    run_reader "${address[@]}" --after 1.0 --cursor opaque
    check 'reader refuses Slack cursor option' failed
    run_reader "${address[@]}" --alias planning --after 1.0
    check 'reader refuses competing address forms' failed
    typeset name
    for name in '' Upper '../escape' '-name' '.name' $'name\n' ${(l:65::a:)}; do
        run_reader "${address[@]}" --after 1.0 --reader "$name"
        check "invalid reader name ${(qq)name} is rejected" failed
    done
    check 'invalid reader forms make no request' no_request
    check 'invalid reader forms publish no record' absent

    typeset shape
    for shape in broken multi extra binding address timestamp generation fractional exhausted symlink; do
        setup_case state-$shape
        save_reader
        case $shape in
            (broken) print -r -- broken > $record ;;
            (multi) /bin/cat $original >> $record ;;
            (extra) $POSTCARD_TEST_JQ '.extra=true' $original > $record ;;
            (binding) $POSTCARD_TEST_JQ '.binding.user_id="U_OTHER"' $original > $record ;;
            (address) $POSTCARD_TEST_JQ '.channel="not a channel"' $original > $record ;;
            (timestamp) $POSTCARD_TEST_JQ '.through="1.0\n"' $original > $record ;;
            (generation) $POSTCARD_TEST_JQ '.generation=0' $original > $record ;;
            (fractional) $POSTCARD_TEST_JQ '.generation=1.5' $original > $record ;;
            (exhausted) $POSTCARD_TEST_JQ '.generation=9007199254740992' $original > $record ;;
            (symlink) rm $record; ln -s $original $record ;;
        esac
        [[ $shape == symlink ]] || cp $record $original
        run_reader
        check "invalid $shape state refuses before output" failed
        check "invalid $shape state makes no request" no_request
        check "invalid $shape state preserves bytes" unchanged
        check "invalid $shape state cleans staging" clean
    done

    for shape in repeat malformed transport invalid-cursor nul-cursor; do
        setup_case later-$shape
        save_reader
        page 1 '[{ts:"2.0"}]' later
        case $shape in
            (repeat) page 2 '[{ts:"3.0"}]' later ;;
            (malformed) print -r -- broken > $case_dir/page.2.json ;;
            (transport) print 28 > $case_dir/status.2 ;;
            (invalid-cursor) print -r -- '{"ok":false,"error":"invalid_cursor"}' > $case_dir/page.2.json ;;
            (nul-cursor) $POSTCARD_TEST_JQ -n '{ok:true,messages:[],response_metadata:{next_cursor:"x\u0000y"}}' > $case_dir/page.2.json ;;
        esac
        run_reader
        check "$shape on later page fails without output" failed
        check "$shape on later page leaves checkpoint bytes" unchanged
        check "$shape on later page stops after two calls" request_count 2
        check "$shape on later page cleans staging" clean
    done

    setup_case snapshot
    save_reader
    page 1 '[{ts:"2.0"}]' later
    page 2 '[{ts:"3.0"}]'
    $POSTCARD_TEST_JQ '.team_id="T_NEW" | .user_id="U_NEW" | .access_token="replacement-secret"' $credentials > $case_dir/replacement
    export POSTCARD_TEST_REPLACEMENT=$case_dir/replacement POSTCARD_TEST_CREDENTIALS=$credentials
    run_reader
    check 'grant replacement does not interrupt a traversal' test $result -eq 0
    check 'every page uses the original token' cmp -s $case_dir/header.1 $case_dir/header.2
    check 'original token remains on stdin' rg -Fxq 'Authorization: Bearer fixture-reader-secret' $case_dir/header.2
    check 'output keeps original binding' $POSTCARD_TEST_JQ -e '.team_id=="T_FIXTURE" and .user_id=="U_FIXTURE"' $case_dir/out
    check 'checkpoint keeps original binding' $POSTCARD_TEST_JQ -e '.binding.team_id=="T_FIXTURE"' $record
    check 'new grant remains installed' cmp -s $credentials $case_dir/replacement
    next_run
    run_reader
    check 'next invocation rejects mismatched replacement grant' failed
    check 'mismatched replacement makes no request' no_request

    typeset phase
    for phase in reader-result reader-next output publish; do
        setup_case failure-$phase
        save_reader
        export POSTCARD_TEST_FAULT=$phase
        run_reader
        check "$phase failure returns nonzero" test $result -ne 0
        check "$phase failure preserves checkpoint bytes" unchanged
        check "$phase failure cleans staging" clean
        if [[ $phase == publish ]]; then
            check 'failed publication follows complete useful output' $POSTCARD_TEST_JQ -e '.messages==[{ts:"2.0",text:"one"}] and .generation==7' $case_dir/out
            check 'failed publication explains unsaved progress' rg -Fq 'output delivered but progress was not saved' $case_dir/err
            cp $case_dir/out $case_dir/delivered
            unset POSTCARD_TEST_FAULT
            next_run
            run_reader
            check 'retry repeats delivered observations after failed publication' cmp -s $case_dir/out $case_dir/delivered
        else
            check "$phase failure writes no output" test ! -s $case_dir/out
        fi
    done

    setup_case simultaneous-initialization
    export POSTCARD_TEST_GATE=curl-1
    $root/bin/postcard --account widgets thread --reader workshop "${address[@]}" --after 1.0 > $case_dir/first.out 2> $case_dir/first.err &
    process=$!
    check 'first initializer reaches its locked request' wait_file $case_dir/ready
    run_reader "${address[@]}" --after 1.0
    check 'concurrent initializer fails without output' failed
    check 'concurrent initializer reports the named reader busy' rg -Fq 'reader workshop is busy' $case_dir/err
    check 'concurrent initializer makes no second request' request_count 1
    check 'in-flight initialization has no published reader' absent
    check 'staging contains no bearer token' zsh -fc '! rg -q fixture-reader-secret "$1"' _ $reader_dir
    typeset file
    integer private=1
    for file in $reader_dir/**/*(DN); do
        zstat -H stat $file
        (( (stat[mode] & 8#077) == 0 )) || private=0
    done
    check 'working files and directories are private' test $private -eq 1
    : > $case_dir/release
    wait $process
    check 'first initializer finishes after release' test $? -eq 0
    unset POSTCARD_TEST_GATE
    next_run
    run_reader "${address[@]}" --after 1.0
    check 'initializer after publication sees the existing reader' failed
    check 'refused initializer sends no request' no_request

    # A real pipe with a reader that does not drain forces cat to block. Only
    # this reader's lock is held. Closing the read end then exercises SIGPIPE.
    for shape in cancel broken; do
        setup_case pipe-$shape
        save_reader
        page 1 '[{ts:"2.0",text:("x" * 2097152)}]'
        cp $case_dir/page.1.json $case_dir/page.2.json
        mkfifo $case_dir/pipe
        sysopen -rw -o cloexec -u pipefd $case_dir/pipe || exit 1
        $root/bin/postcard --account widgets thread --reader workshop > $case_dir/pipe 2> $case_dir/err &
        process=$!
        check "$shape pipe reaches actual stdout writer" wait_file $case_dir/output-started
        integer writer=$(<$case_dir/output-started)
        check "$shape blocked writer remains alive" kill -0 $writer
        check "$shape blocked output has not published" unchanged
        $root/bin/postcard --account widgets thread --reader workshop > $case_dir/busy.out 2> $case_dir/busy.err
        check "$shape blocked output holds its reader lock" test $? -ne 0
        check "$shape blocked lock reports busy" rg -Fq 'reader workshop is busy' $case_dir/busy.err
        $root/bin/postcard --account widgets thread --reader other "${address[@]}" --after 1.0 > $case_dir/other.out 2> $case_dir/other.err
        check "$shape blocked reader leaves another reader independent" test $? -eq 0
        if [[ $shape == cancel ]]; then
            cancel
            exec {pipefd}>&-
        else
            exec {pipefd}>&-
            if ! wait_dead $process; then
                check 'broken pipe stops command promptly' false
                cancel
            else
                wait $process
                result=$?
            fi
        fi
        pipefd=-1
        check "$shape pipe exits nonzero" test $result -ne 0
        check "$shape pipe reaps the stdout writer" wait_dead $writer
        check "$shape pipe preserves checkpoint bytes" unchanged
        check "$shape pipe cleans stages" clean
    done

    # Pause actual subprocess boundaries, signal only Postcard, then require
    # its child to be reaped and its lock usable by a later invocation.
    for phase in curl-1 response reader-result reader-next output publish; do
        setup_case cancel-$phase
        save_reader
        export POSTCARD_TEST_GATE=$phase
        $root/bin/postcard --account widgets thread --reader workshop > $case_dir/out 2> $case_dir/err &
        process=$!
        if ! wait_file $case_dir/ready; then
            check "$phase cancellation boundary reached" false
            cancel
            continue
        fi
        integer worker=$(<$case_dir/ready)
        cancel
        check "$phase cancellation exits nonzero" test $result -ne 0
        check "$phase cancellation reaps active child" wait_dead $worker
        check "$phase cancellation preserves checkpoint" unchanged
        check "$phase cancellation removes stages" clean
        unset POSTCARD_TEST_GATE
        next_run
        run_reader
        check "$phase cancellation releases lock" test $result -eq 0
    done

    setup_case post-rename
    export POSTCARD_TEST_GATE=publish POSTCARD_TEST_AFTER_RENAME=1
    $root/bin/postcard --account widgets thread --reader workshop "${address[@]}" --after 1.0 > $case_dir/out 2> $case_dir/err &
    process=$!
    check 'post-rename boundary reached' wait_file $case_dir/ready
    cancel
    check 'cancellation after first rename can leave generation one' $POSTCARD_TEST_JQ -e '.generation==1 and .through=="2.0"' $record
    check 'post-rename cancellation follows complete output' $POSTCARD_TEST_JQ -e '.generation==0 and .through=="2.0"' $case_dir/out
    unset POSTCARD_TEST_GATE POSTCARD_TEST_AFTER_RENAME
    next_run
    run_reader "${address[@]}" --after 1.0
    check 'initialization refuses a record installed before cancellation' failed
    check 'refused reinitialization makes no request' no_request
    page 1 '[]'
    run_reader
    check 'continuation uses the published record after cancellation' $POSTCARD_TEST_JQ -e '.generation==1 and .after=="2.0"' $case_dir/out
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}
(( failures == 0 )) || { print -r -- "reader: $failures failure(s)"; exit 1; }
print -r -- 'reader: PASS'
