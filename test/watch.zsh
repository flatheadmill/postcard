#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/system zsh/zselect zsh/datetime
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.watch-test.XXXXXX) || exit 1
typeset case_dir credentials record original reader_dir
typeset bell='You have messages: `postcard --account widgets thread --reader workshop`.'
integer failures=0 result process=0 pipefd=-1 lifetime=-1
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
    unset POSTCARD_TEST_WATCH_GATE POSTCARD_TEST_WATCH_AFTER
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
    (( result != 0 )) && [[ ! -s $case_dir/out && -s $case_dir/err ]]
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

    for shape in client_id team_id user_id expired; do
        setup_case grant-$shape
        start_watch
        check "$shape grant change follows a pending bell" await bells 1
        if [[ $shape == expired ]]; then
            replace $credentials '.refresh_token="fixture-refresh" | .expires_at=1'
        else
            replace $credentials ".$shape=\"different-owner\""
        fi
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
    for value in 0 -1 1.2 abc 92233720368547759 99999999999999999999999999999999; do
        setup_case bad-interval-${value//./_}
        start_watch --interval "$value"
        check "invalid interval $value finishes" finished
        check "invalid interval $value fails without stdout" quiet_failure
        check "invalid interval $value makes no request" count_requests 0
    done
} always {
    (( process == 0 )) || { kill -TERM $process 2>/dev/null; wait $process 2>/dev/null; }
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
