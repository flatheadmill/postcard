#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/system zsh/zselect zsh/datetime zsh/stat
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.watch-test.XXXXXX) || exit 1
typeset case_dir credentials record original reader_dir sent_dir sent_file
typeset bell='You have messages: `postcard --account widgets thread --reader workshop`.'
integer failures=0 result process=0 posting=0 pipefd=-1 lifetime=-1
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
ln -s $root/test/watch-tool.zsh $fixture/bin/curl
ln -s $root/test/watch-tool.zsh $fixture/bin/jq
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
function page {
    $POSTCARD_TEST_JQ -n --arg cursor "${3-}" \
        "$2 | {ok:true,messages:.,response_metadata:{next_cursor:\$cursor}}" > $case_dir/page.$1.json
}
function setup_case {
    case_dir=$fixture/$1
    export XDG_CONFIG_HOME=$case_dir/config XDG_STATE_HOME=$case_dir/state POSTCARD_TEST_WATCH=$case_dir
    export TMPDIR=$case_dir/tmp
    unset POSTCARD_TEST_WATCH_GATE POSTCARD_TEST_WATCH_AFTER POSTCARD_TEST_POST
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    reader_dir=$XDG_STATE_HOME/postcard/accounts/widgets/readers
    record=$reader_dir/workshop.json
    original=$case_dir/original
    mkdir -p ${credentials:h} $reader_dir $TMPDIR
    $POSTCARD_TEST_JQ -n '{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE",
        access_token:"fixture-watch-secret",scope:"channels:history"}' > $credentials
    $POSTCARD_TEST_JQ -n '{version:1,binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},
        channel:"C012FIXTURE",ts:"1.000000",through:"1.0",generation:7}' > $record
    cp $record $original
    print -r -- "$bell" > $case_dir/expected
    page 1 '[{ts:"2.0"}]'
}
function setup_sent {
    setup_case "$1"
    sent_dir=$XDG_STATE_HOME/postcard/sent/team-T_FIXTURE/C012FIXTURE
    sent_file=$sent_dir/2.0.json
    replace $credentials '.scope="chat:write,users:read,channels:history"'
    mkdir -p $case_dir/post
    $POSTCARD_TEST_JQ -n '{ok:true,team_id:"T_FIXTURE",user_id:"U_FIXTURE"}' > $case_dir/post/auth.test.json
    $POSTCARD_TEST_JQ -n '{ok:true,user:{id:"U_FIXTURE",profile:{display_name:"Jane Doe"}}}' > $case_dir/post/users.info.json
    $POSTCARD_TEST_JQ -n '{ok:true,messages:[{ts:"1.000000"}]}' > $case_dir/post/conversations.replies.json
    print -r -- 28 > $case_dir/post/chat.getPermalink.status
}
function post_response {
    $POSTCARD_TEST_JQ -n --arg posted "$1" --arg parent "${2-1.000000}" '
        {ok:true,channel:"C012FIXTURE",ts:$posted,
         message:{user:"U_FIXTURE",ts:$posted} +
            (if $parent == "" then {} else {thread_ts:$parent} end)}
    ' > $case_dir/post/chat.postMessage.json
}
function send {
    typeset posted=$1
    shift
    post_response "$posted"
    POSTCARD_TEST_POST=$case_dir/post POSTCARD_TEST_SENT_FILE=$sent_dir/$posted.json \
        $root/bin/postcard --account widgets post \
        --channel C012FIXTURE --ts 1.000000 --model Codex "$@" \
        <<< 'The review is ready.' > $case_dir/post/out 2> $case_dir/post/err
}
function no_stages {
    typeset -a stages=( $XDG_STATE_HOME/postcard/sent/**/.sent.*(DN) )
    (( $#stages == 0 ))
}
function receipt_warning { rg -Fq 'local receipt unavailable' $case_dir/post/err }
function replace {
    $POSTCARD_TEST_JQ "$2" "$1" > "$1.next" && /bin/mv "$1.next" "$1"
}
function await {
    integer attempts
    for (( attempts=0; attempts < 500; attempts++ )); do
        "$@" && return 0
        zselect -t 1
    done
    return 1
}
function dead { ! kill -0 $1 2>/dev/null }
function finished {
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
    check 'watch stops promptly' finished
}
function start_watch {
    $root/bin/postcard --account widgets watch --reader workshop --interval 1 "$@" > $case_dir/out 2> $case_dir/err &
    process=$!
}
function count_requests {
    typeset -a requests=( $case_dir/request.*.json(N) )
    (( $#requests == $1 ))
}
function bells {
    typeset data=$(<$case_dir/out)
    typeset -a lines=( "${(@f)data}" )
    [[ -n $data ]] && (( $#lines == $1 ))
}
function clean {
    typeset -a scratch=( $TMPDIR/*(DN) )
    (( $#scratch == 0 ))
}
function unchanged { cmp -s $record $original }
function quiet_failure {
    (( result != 0 )) && [[ -s $case_dir/err ]] && ! rg -q '^You have messages:' $case_dir/out
}
function fill_pipe {
    mkfifo $case_dir/pipe
    sysopen -rw -o nonblock,cloexec -u pipefd $case_dir/pipe || return
    typeset fill=${(l:4096::x:)}
    integer written
    filled=0
    while syswrite -c written -o $pipefd "$fill" 2>/dev/null; do
        (( filled += written ))
    done
}
function open_lifetime {
    # Descriptor 3 is inherited by the command and its native builtin jobs.
    # EOF after cancellation proves no surviving job retains it, without
    # depending on a platform process-list service.
    mkfifo $case_dir/lifetime
    sysopen -r -o nonblock,cloexec -u lifetime $case_dir/lifetime
}
function lifetime_closed {
    sysread -i $lifetime -s 1 2>/dev/null
    (( $? == 5 ))
}
function lifetime_open {
    sysread -t 0 -i $lifetime -s 1 2>/dev/null
    (( $? == 4 ))
}

{
    setup_case immediate
    # Default 15-second cadence cannot hide a delayed first probe.
    $root/bin/postcard --account widgets watch --reader workshop > $case_dir/out 2> $case_dir/err &
    process=$!
    check 'first probe is immediate' await bells 1
    check 'bell is the exact command with one LF' cmp -s $case_dir/out $case_dir/expected
    check 'watch requests a fixed page of 100 at the reader boundary' $POSTCARD_TEST_JQ -e '
        index("limit=100")!=null and index("oldest=1.0")!=null and index("inclusive=false")!=null
        and index("channel=C012FIXTURE")!=null and index("ts=1.000000")!=null
    ' $case_dir/request.1.json
    check 'watch leaves reader bytes unchanged' unchanged
    check 'watch does not create a reader lock' test ! -e $reader_dir/workshop.lock
    check 'working files contain no bearer token' zsh -fc '! rg -q fixture-watch-secret "$1"' _ $TMPDIR
    cancel
    check 'cancelling the native wait cleans scratch' clean

    setup_case continuation
    typeset cursor=$'opaque+/= &%? \\ $(not-a-command)\n\n'
    page 1 '[{ts:"0001.00000"},{ts:"0.99999999"}]' "$cursor"
    page 2 '[]' third
    page 3 '[{ts:"1.000000000000000000000000000000000001"}]' unused
    start_watch
    check 'exact comparison follows equal and empty pages to the first newer timestamp' await bells 1
    check 'first qualifying page stops without its continuation' count_requests 3
    check 'opaque cursor keeps trailing newlines' $POSTCARD_TEST_JQ -e --arg cursor "$cursor" \
        'index("cursor="+$cursor)!=null' $case_dir/request.2.json
    check 'all pages retain original boundary and address' $POSTCARD_TEST_JQ -es '
        all(.[]; index("oldest=1.0")!=null and index("ts=1.000000")!=null)
    ' $case_dir/request.{1,2,3}.json
    cancel
    check 'existence probe never advances reader' unchanged

    setup_sent own-pagination
    check 'first window saves a confirmed reply' send 2.0 --slug workshop
    check 'second window saves a confirmed reply in the same local store' send 3.0 --slug shipping
    check 'saved receipt has exact binding, parent and window, without body or grant' $POSTCARD_TEST_JQ -e '
        .=={version:1,binding:{client_id:"123.456",team_id:"T_FIXTURE",user_id:"U_FIXTURE"},
            channel:"C012FIXTURE",ts:"2.0",thread_ts:"1.000000",slug:"workshop"}
    ' $sent_file
    typeset -A attributes
    zstat -H attributes $sent_file
    check 'published receipt is private' test $(( attributes[mode] & 8#777 )) -eq 384
    check 'receipt already exists when permalink begins' cmp -s $sent_dir/3.0.json $case_dir/post/receipt-at-permalink
    check 'post removes its staging names' no_stages
    page 1 '[{ts:"2.0"}]' second
    page 2 '[]' third
    page 3 '[{ts:"2.0",user:"U_FIXTURE"}]'
    page 4 '[{ts:"2.0"}]' second
    page 5 '[{ts:"3.0",user:"U_FIXTURE"}]' unused
    export POSTCARD_TEST_WATCH_GATE=curl-4
    start_watch --slug workshop
    check 'all-local terminal traversal continues ordinary polling' await test -e $case_dir/ready
    check 'own messages and empty continuations do not ring' test ! -s $case_dir/out
    check 'quiet observation preserves progress and generation bytes' unchanged
    check 'quiet watch follows every continuation to the terminal page' count_requests 4
    : > $case_dir/release
    check 'another local window using the same Slack user rings' await bells 1
    check 'first outside message stops before its unused continuation' count_requests 5
    check 'every quiet and mixed page uses the unchanged boundary' $POSTCARD_TEST_JQ -es \
        'all(.[]; index("oldest=1.0")!=null)' $case_dir/request.*.json
    cancel
    mkdir $case_dir/read
    print -r -- '{"ok":true,"messages":[{"ts":"2.0","text":"own"},{"ts":"3.0","text":"outside"}]}' > $case_dir/read/page.1.json
    POSTCARD_TEST_WATCH=$case_dir/read $root/bin/postcard --account widgets thread --reader workshop \
        > $case_dir/read/out 2> $case_dir/read/err
    check 'ordinary reader still succeeds after suppressed observation' test $? -eq 0
    check 'ordinary reader returns own and outside content together' $POSTCARD_TEST_JQ -e \
        '[.messages[].text]==["own","outside"] and .through=="3.0" and .generation==7' $case_dir/read/out
    check 'only the real read publishes progress' $POSTCARD_TEST_JQ -e '.generation==8 and .through=="3.0"' $record
    check 'reading retains reusable receipt evidence' test -f $sent_file

    # Each failure of proof must remain an ordinary bell, not a read failure.
    typeset evidence
    for evidence in no-watch-slug no-post-slug other-window remote-same-user copied-labels missing corrupt empty \
        multiple-documents wrong-coordinate wrong-team wrong-channel wrong-parent wrong-user malformed-user \
        wrong-observed-team wrong-observed-channel bad-binding extra-field public-file unreadable-file symlink-file \
        symlink-directory swapped-files duplicate-conflict partial-file nul-record; do
        setup_sent evidence-$evidence
        if [[ $evidence == no-post-slug ]]; then
            send 2.0 || exit 1
        else
            send 2.0 --slug workshop || exit 1
        fi
        page 1 '[{ts:"2.0",user:"U_FIXTURE"}]'
        case $evidence in
            (other-window) replace $sent_file '.slug="shipping"' ;;
            (remote-same-user) page 1 '[{ts:"3.0",user:"U_FIXTURE"}]' ;;
            (copied-labels) page 1 '[{ts:"3.0",user:"U_FIXTURE",text:"— in workshop on harbor"}]' ;;
            (missing) rm $sent_file ;;
            (corrupt) print -r -- broken > $sent_file ;;
            (empty) : > $sent_file ;;
            (multiple-documents) cat $sent_file $sent_file > $sent_file.next; mv $sent_file.next $sent_file ;;
            (wrong-coordinate) replace $sent_file '.ts="02.0"' ;;
            (wrong-team) replace $sent_file '.binding.team_id="T_OTHER"' ;;
            (wrong-channel) replace $sent_file '.channel="C999OTHER"' ;;
            (wrong-parent) replace $sent_file '.thread_ts="9.0"' ;;
            (wrong-user) page 1 '[{ts:"2.0",user:"U_OTHER"}]' ;;
            (malformed-user) page 1 '[{ts:"2.0",user:17}]' ;;
            (wrong-observed-team) page 1 '[{ts:"2.0",team:"T_OTHER"}]' ;;
            (wrong-observed-channel) page 1 '[{ts:"2.0",channel:"C999OTHER"}]' ;;
            (bad-binding) replace $sent_file '.binding.client_id=null' ;;
            (extra-field) replace $sent_file '.extra=true' ;;
            (public-file) chmod 644 $sent_file ;;
            (unreadable-file) chmod 000 $sent_file ;;
            (symlink-file) mv $sent_file $sent_file.real; ln -s $sent_file.real $sent_file ;;
            (symlink-directory) mv $sent_dir $sent_dir.real; ln -s $sent_dir.real $sent_dir ;;
            (swapped-files)
                send 3.0 --slug workshop || exit 1
                mv $sent_file $sent_dir/swap
                mv $sent_dir/3.0.json $sent_file
                mv $sent_dir/swap $sent_dir/3.0.json
                page 1 '[{ts:"2.0"},{ts:"3.0"}]' ;;
            (duplicate-conflict) page 1 '[{ts:"2.0"},{ts:"2.0",user:"U_OTHER"}]' ;;
            (partial-file) mv $sent_file $sent_dir/.sent.partial ;;
            (nul-record) printf '\0' >> $sent_file ;;
        esac
        if [[ $evidence == no-watch-slug ]]; then start_watch
        else start_watch --slug workshop; fi
        check "$evidence stays eligible for an ordinary bell" await bells 1
        check "$evidence leaves reader progress unchanged" unchanged
        cancel
        check "$evidence cleans watch scratch" clean
    done

    setup_sent late-receipt
    page 1 '[{ts:"2.0",user:"U_FIXTURE"}]'
    mkdir $case_dir/late-post
    post_response 2.0
    POSTCARD_TEST_POST=$case_dir/post POSTCARD_TEST_WATCH=$case_dir/late-post \
        POSTCARD_TEST_WATCH_GATE=sent-1 $root/bin/postcard --account widgets post \
        --channel C012FIXTURE --ts 1.000000 --model Codex --slug workshop \
        <<< 'The review.' > $case_dir/post/out 2> $case_dir/post/err &
    posting=$!
    check 'confirmed local send pauses before receipt publication' await test -e $case_dir/late-post/ready
    export POSTCARD_TEST_WATCH_GATE=reader-state-5
    start_watch --slug workshop
    check 'visible message before local proof rings' await bells 1
    : > $case_dir/late-post/release
    check 'late receipt writer finishes' await dead $posting
    wait $posting
    check 'late receipt preserves the successful send' test $? -eq 0
    posting=0
    check 'later publication saves exact proof' test -f $sent_file
    check 'late receipt reaches a subsequent pending inspection' await test -e $case_dir/ready
    check 'late receipt never releases pending or probes Slack' count_requests 1
    check 'late receipt neither retracts nor repeats the bell' bells 1
    check 'late receipt leaves reader boundary intact' unchanged
    cancel
    unset POSTCARD_TEST_WATCH_GATE
    rm $case_dir/ready $case_dir/release(N)
    page 2 '[{ts:"2.0"}]'
    export POSTCARD_TEST_WATCH_GATE=curl-3
    start_watch --slug workshop
    check 'restart reuses the receipt and reaches another quiet probe' await test -e $case_dir/ready
    check 'restart with proven own content is quiet' test ! -s $case_dir/out
    cancel

    setup_sent alternate-account
    send 2.0 --slug 'Workshop_é' || exit 1
    replace $credentials '.client_id="789.123" | .user_id="U_OTHER"'
    replace $record '.binding.client_id="789.123" | .binding.user_id="U_OTHER"'
    cp $record $original
    page 1 '[{ts:"2.0",user:"U_FIXTURE"}]'
    export POSTCARD_TEST_WATCH_GATE=curl-2
    start_watch --slug 'Workshop_é'
    check 'same window recognizes evidence through another sending binding' await test -e $case_dir/ready
    check 'watch principal does not replace recorded sender identity' test ! -s $case_dir/out
    cancel
    unset POSTCARD_TEST_WATCH_GATE
    page 3 '[{ts:"2.0"}]'
    start_watch --slug 'workshop_é'
    check 'window names compare without case folding' await bells 1
    cancel

    setup_sent root-receipt
    post_response 1.000000 ''
    POSTCARD_TEST_POST=$case_dir/post $root/bin/postcard --account widgets post --channel C012FIXTURE \
        --model Codex --slug workshop <<< 'The parent.' > $case_dir/post/out 2> $case_dir/post/err
    check 'top-level confirmed post saves a null parent' $POSTCARD_TEST_JQ -e '.thread_ts==null' $sent_dir/1.000000.json
    replace $record '.through="0.0"'
    page 1 '[{ts:"1.000000",thread_ts:"1.000000"}]'
    export POSTCARD_TEST_WATCH_GATE=curl-2
    start_watch --slug workshop
    check 'a receipted root beyond the boundary can be quiet' await test -e $case_dir/ready
    check 'root receipt belongs to its own thread' test ! -s $case_dir/out
    cancel

    for evidence in blocked-directory occupied-directory conflict publication-failure; do
        setup_sent save-$evidence
        case $evidence in
            (blocked-directory) print -r -- occupied > $XDG_STATE_HOME/postcard/sent ;;
            (occupied-directory) mkdir -p $sent_file ;;
            (conflict) send 2.0 --slug shipping || exit 1; cp $sent_file $case_dir/existing ;;
            (publication-failure)
                mkdir $case_dir/bin
                print -rl -- '#!/bin/zsh -f' 'exit 1' > $case_dir/bin/ln
                chmod +x $case_dir/bin/ln ;;
        esac
        PATH=$case_dir/bin:$PATH check "$evidence does not invalidate a confirmed send" send 2.0 --slug workshop
        check "$evidence reports unsaved evidence on stderr" receipt_warning
        check "$evidence keeps ordinary parseable success output" $POSTCARD_TEST_JQ -e '.ts=="2.0" and .permalink==null' $case_dir/post/out
        check "$evidence removes staging files" no_stages
        [[ $evidence != conflict ]] || check 'conflict preserves existing evidence' cmp -s $sent_file $case_dir/existing
    done

    for phase in sent-1 own-1; do
        for signal in INT TERM HUP; do
            setup_sent cancel-$phase-$signal
            if [[ $phase == own-1 ]]; then
                send 2.0 --slug workshop || exit 1
                export POSTCARD_TEST_WATCH_GATE=$phase
                start_watch --slug workshop
            else
                post_response 2.0
                export POSTCARD_TEST_WATCH_GATE=$phase
                POSTCARD_TEST_POST=$case_dir/post $root/bin/postcard --account widgets post \
                    --channel C012FIXTURE --ts 1.000000 --model Codex --slug workshop \
                    <<< 'The review.' > $case_dir/post/out 2> $case_dir/post/err &
                process=$!
            fi
            check "$phase $signal reaches receipt work" await test -e $case_dir/ready
            integer worker=$(<$case_dir/ready)
            cancel $signal
            check "$phase $signal reaps its validator" await dead $worker
            check "$phase $signal removes stages" no_stages
            check "$phase $signal cleans scratch" clean
            if [[ $phase == sent-1 ]]; then
                check "$signal before publication leaves no proof" test ! -e $sent_file
            else
                check "$signal classification retains published proof" test -f $sent_file
            fi
        done
    done

    setup_sent post-broken-output
    fill_pipe || exit 1
    post_response 2.0
    POSTCARD_TEST_POST=$case_dir/post POSTCARD_TEST_SENT_FILE=$sent_file $root/bin/postcard --account widgets post \
        --channel C012FIXTURE --ts 1.000000 --model Codex --slug workshop \
        <<< 'The review.' > $case_dir/pipe 2> $case_dir/post/err &
    process=$!
    check 'post records proof before its output can block' await test -f $sent_file
    check 'permalink witnesses the already-published receipt' await test -f $case_dir/post/receipt-at-permalink
    exec {pipefd}>&-
    pipefd=-1
    check 'broken post stdout terminates' finished
    check 'broken stdout cannot erase confirmed local evidence' test -f $sent_file
    check 'broken post stdout leaves no staging file' no_stages

    setup_case cadence
    page 1 '[]'
    page 2 '[{ts:"2.0"}]'
    export POSTCARD_TEST_WATCH_GATE=curl-1
    start_watch
    check 'first probe reaches the held request' await test -e $case_dir/ready
    zselect -t 120
    : > $case_dir/release
    check 'empty observation is probed again' await bells 1
    float first_end=$(<$case_dir/end.1) second_start=$(<$case_dir/start.2)
    check 'interval is measured after the completed probe' test $(( second_start - first_end >= 0.95 )) -eq 1
    cancel

    setup_case pending
    page 2 '[{ts:"2.0"}]'
    export POSTCARD_TEST_WATCH_GATE=reader-state-5
    start_watch
    check 'pending watch rings once' await bells 1
    mkdir -p $case_dir/read
    print -r -- '{"ok":true,"messages":[{"ts":12}]}' > $case_dir/read/page.1.json
    POSTCARD_TEST_WATCH=$case_dir/read $root/bin/postcard --account widgets thread --reader workshop \
        > $case_dir/read/out 2> $case_dir/read/err
    check 'failed reader leaves the pending generation published' test $? -ne 0
    check 'failed reader preserves progress bytes' unchanged
    check 'unchanged generation reaches another local inspection' await test -e $case_dir/ready
    check 'pending generation suppresses Slack probes and repeated bells' count_requests 1
    check 'unchanged state has one bell' bells 1
    # Exercise the real reader publication, including an empty observation.
    print -r -- '{"ok":true,"messages":[]}' > $case_dir/read/page.2.json
    POSTCARD_TEST_WATCH=$case_dir/read $root/bin/postcard --account widgets thread --reader workshop \
        > $case_dir/read/out 2> $case_dir/read/err
    check 'empty reader succeeds while watch holds no writer lock' test $? -eq 0
    check 'empty reader reports the original generation and unchanged boundary' $POSTCARD_TEST_JQ -e \
        '.generation==7 and .messages==[] and .through=="1.0"' $case_dir/read/out
    float released=$EPOCHREALTIME
    : > $case_dir/release
    check 'published generation rearms without another interval' await bells 2
    float restarted=$(<$case_dir/start.2)
    check 'inspection proceeds directly into its probe' test $(( restarted - released < 0.95 )) -eq 1
    cancel
    check 'watch leaves the newly published reader intact' $POSTCARD_TEST_JQ -e '.generation==8 and .through=="1.0"' $record

    setup_case during-probe
    export POSTCARD_TEST_WATCH_GATE=curl-1
    page 2 '[{ts:"3.0"}]'
    start_watch
    check 'publication race reaches request gate' await test -e $case_dir/ready
    replace $record '.generation=8 | .through="2.0"'
    : > $case_dir/release
    check 'next generation eventually rings' await bells 1
    first_end=$(<$case_dir/end.1) second_start=$(<$case_dir/start.2)
    check 'changed generation discards old observation and takes ordinary delay' test $(( second_start - first_end >= 0.95 )) -eq 1
    check 'discarded observation produces no stale bell' cmp -s $case_dir/out $case_dir/expected
    check 'next attempt uses published boundary' $POSTCARD_TEST_JQ -e 'index("oldest=2.0")!=null' $case_dir/request.2.json
    cancel

    setup_case grant
    export POSTCARD_TEST_WATCH_GATE=curl-1
    page 1 '[]' second
    page 2 '[{ts:"2.0"}]'
    page 3 '[{ts:"2.0"}]'
    # Initial selection is implicit; a later second account cannot redirect it.
    $root/bin/postcard watch --reader workshop --interval 1 > $case_dir/out 2> $case_dir/err &
    process=$!
    check 'grant snapshot reaches first request' await test -e $case_dir/ready
    replace $credentials '.access_token="replacement-watch-secret"'
    mkdir -p ${credentials:h:h}/other
    cp $credentials ${credentials:h:h}/other/credentials.json
    : > $case_dir/release
    check 'paginated original grant rings' await bells 1
    check 'one probe keeps its original token across pages' cmp -s $case_dir/header.1 $case_dir/header.2
    check 'original probe uses original token' rg -Fq fixture-watch-secret $case_dir/header.2
    replace $record '.generation += 1'
    check 'same binding replacement permits next probe' await bells 2
    check 'next probe takes the replacement token' rg -Fq replacement-watch-secret $case_dir/header.3
    check 'implicit account remains explicit in every bell' zsh -fc '[[ "$(<$1)" == "$2"$'"'\n'"'"$2" ]]' _ $case_dir/out "$bell"
    cancel

    typeset shape
    for shape in malformed-page oversized-page wrong-parent more-without-cursor repeated-cursor nul-cursor; do
        setup_case $shape
        case $shape in
            (malformed-page) page 1 '[{ts:"2.0"},{ts:12}]' ;;
            (oversized-page) page 1 '[range(101) | {ts:"2.0"}]' ;;
            (wrong-parent) page 1 '[{ts:"2.0",thread_ts:"9.0"}]' ;;
            (more-without-cursor) replace $case_dir/page.1.json '.has_more=true' ;;
            (repeated-cursor) page 1 '[]' again; page 2 '[]' again ;;
            (nul-cursor) page 1 '[]' $'x\0y' ;;
        esac
        start_watch
        check "$shape terminates promptly" finished
        check "$shape fails visibly without a bell" quiet_failure
        check "$shape preserves reader" unchanged
        check "$shape cleans scratch" clean
    done

    for shape in missing malformed extra-field wrong-binding retarget-channel retarget-parent; do
        setup_case state-$shape
        start_watch
        check "$shape state change follows a pending bell" await bells 1
        case $shape in
            (missing) rm $record ;;
            (malformed) print -r -- broken > $record ;;
            (extra-field) replace $record '.extra=true' ;;
            (wrong-binding) replace $record '.binding.user_id="U_OTHER"' ;;
            (retarget-channel) replace $record '.channel="C999OTHER"' ;;
            (retarget-parent) replace $record '.ts="01.000000"' ;;
        esac
        check "$shape state stops pending watch" finished
        check "$shape state reports failure" test $result -ne 0
        check "$shape state reports on stderr" test -s $case_dir/err
        check "$shape state sends no further request" count_requests 1
        check "$shape state cleans scratch" clean
    done

    for shape in client_id team_id user_id; do
        setup_case grant-$shape
        start_watch
        check "$shape grant change follows a pending bell" await bells 1
        replace $credentials ".$shape=\"different-owner\""
        replace $record '.generation += 1'
        check "$shape grant stops before another request" finished
        check "$shape grant fails visibly" test $result -ne 0
        check "$shape grant reports on stderr" test -s $case_dir/err
        check "$shape grant is not sent" count_requests 1
        check "$shape grant failure runs cleanup" clean
    done

    typeset signal phase
    for signal in INT TERM HUP; do
        setup_case wait-$signal
        open_lifetime || exit 1
        $root/bin/postcard --account widgets watch --reader workshop \
            3> $case_dir/lifetime > $case_dir/out 2> $case_dir/err &
        process=$!
        check "$signal native wait follows the first bell" await bells 1
        zselect -t 5
        check "$signal sleeper retains the lifetime pipe before cancellation" lifetime_open
        cancel $signal
        check "$signal native wait leaves no sleeper holding the lifetime pipe" lifetime_closed
        exec {lifetime}>&-
        lifetime=-1
        check "$signal native wait cleans scratch" clean
    done
    for phase in curl-1 thread-response-1 reader-state-1 newer-1; do
        for signal in INT TERM HUP; do
            setup_case cancel-$phase-$signal
            export POSTCARD_TEST_WATCH_GATE=$phase
            start_watch
            check "$phase $signal reaches an owned child" await test -e $case_dir/ready
            integer worker=$(<$case_dir/ready)
            cancel $signal
            check "$phase $signal returns nonzero" test $result -ne 0
            check "$phase $signal reaps its child" await dead $worker
            check "$phase $signal preserves reader" unchanged
            check "$phase $signal cleans scratch" clean
        done
    done

    # Fill a real pipe before the short notification. Its builtin print must
    # block; cancellation and SIGPIPE exercise the shell, not a fake writer.
    integer filled
    for shape in cancel broken publication; do
        setup_case stdout-$shape
        fill_pipe || exit 1
        open_lifetime || exit 1
        export POSTCARD_TEST_WATCH_GATE=reader-state-3 POSTCARD_TEST_WATCH_AFTER=1
        page 2 '[{ts:"2.0"}]'
        $root/bin/postcard --account widgets watch --reader workshop --interval 1 \
            3> $case_dir/lifetime > $case_dir/pipe 2> $case_dir/err &
        process=$!
        check "$shape stdout reaches the final checked snapshot" await test -e $case_dir/ready
        : > $case_dir/release
        check "$shape stdout finishes validation" await dead $(<$case_dir/ready)
        zselect -t 110
        check "$shape full pipe keeps watch alive" kill -0 $process
        check "$shape full pipe sends no next request" count_requests 1
        check "$shape full pipe leaves reader unchanged" unchanged
        check "$shape writer retains the lifetime pipe before cancellation" lifetime_open
        if [[ $shape == publication ]]; then
            # Publication while stdout is blocked must not become pending for
            # the older probe. Draining releases its write, then generation 8
            # must permit the next observation and another complete bell.
            replace $record '.generation += 1'
            typeset chunk
            integer received
            while (( filled > 0 )); do
                sysread -i $pipefd -s $filled -c received chunk || break
                (( filled -= received ))
            done
            : > $case_dir/out
            integer attempts
            for (( attempts=0; attempts < 500; attempts++ )); do
                if sysread -i $pipefd -s 4096 chunk 2>/dev/null; then
                    print -rn -- "$chunk" >> $case_dir/out
                fi
                bells 2 && break
                zselect -t 1
            done
            check 'publication while stdout blocked releases the probed generation' bells 2
            check 'publication race permits exactly the next probe' count_requests 2
            print -rl -- "$bell" "$bell" > $case_dir/expected
            check 'stdout race retains complete LF-terminated bells' cmp -s $case_dir/out $case_dir/expected
            cancel
            exec {pipefd}>&-
        elif [[ $shape == cancel ]]; then
            cancel
            exec {pipefd}>&-
        else
            exec {pipefd}>&-
            check 'broken stdout stops watch promptly' finished
            check 'broken stdout reports failure' test $result -ne 0
            check 'broken stdout writes a diagnostic' rg -Fq 'watch notification output failed' $case_dir/err
        fi
        pipefd=-1
        check "$shape stdout leaves no writer holding the lifetime pipe" lifetime_closed
        exec {lifetime}>&-
        lifetime=-1
        check "$shape stdout cleans scratch" clean
    done

    typeset value
    integer invalid_slug=0
    for value in '' $'two\nlines' ${(l:65::x:)} $'bad\xff'; do
        setup_case bad-slug-$(( ++invalid_slug ))
        start_watch --slug "$value"
        check 'invalid window slug finishes' finished
        check 'invalid window slug fails without stdout' quiet_failure
        check 'invalid window slug makes no request' count_requests 0
    done
    for value in 0 -1 1.2 abc 92233720368547759 99999999999999999999999999999999; do
        setup_case bad-interval-${value//./_}
        start_watch --interval "$value"
        check "invalid interval $value finishes" finished
        check "invalid interval $value fails without stdout" quiet_failure
        check "invalid interval $value makes no request" count_requests 0
    done
} always {
    (( process == 0 )) || { kill -TERM $process 2>/dev/null; wait $process 2>/dev/null; }
    (( posting == 0 )) || { kill -TERM $posting 2>/dev/null; wait $posting 2>/dev/null; }
    (( pipefd < 0 )) || exec {pipefd}>&-
    (( lifetime < 0 )) || exec {lifetime}>&-
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}
(( failures == 0 )) || { print -r -- "watch: $failures failure(s)"; exit 1; }
print -r -- 'watch: PASS'
