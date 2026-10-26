#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/stat zsh/zselect zsh/system zsh/datetime
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.files.XXXXXX) || exit 1
fixture=${fixture:A}
typeset case_dir credentials tool
integer failures=0 result process=0 pipefd=-1
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
for tool in curl ln cat; do
    ln -s $root/test/files-tool.zsh $fixture/bin/$tool
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
function change {
    jq "$2" "$1" > $case_dir/next && mv $case_dir/next "$1"
}
function setup_case {
    case_dir=$fixture/$1
    mkdir -p $case_dir/tmp
    export POSTCARD_TEST_FILES=$case_dir TMPDIR=$case_dir/tmp/
    export XDG_CONFIG_HOME=$case_dir/config XDG_STATE_HOME=$case_dir/state
    unset POSTCARD_TEST_GATE POSTCARD_TEST_FAULT POSTCARD_TEST_RACE POSTCARD_TEST_AFTER_LINK
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    mkdir -p ${credentials:h}
    jq -n '{client_id:"123.456",team_id:"T012TEAM",user_id:"U012SENDER",access_token:"fixture-file-secret",
        scope:"chat:write,users:read,im:write,channels:history,files:write,files:read"}' > $credentials
    jq -n '{ok:true,team_id:"T012TEAM",user_id:"U012SENDER"}' > $case_dir/auth.test.json
    jq -n '{ok:true,user:{id:"U012SENDER",team_id:"T012TEAM",profile:{display_name:"Jane Doe"}}}' > $case_dir/users.info.json
    jq -n '{ok:true,messages:[{ts:"1.000000"}]}' > $case_dir/conversations.replies.json
    jq -n '{ok:true,channel:{id:"D012TARGET",is_im:true,user:"U012TARGET"}}' > $case_dir/conversations.open.json
    jq -n '{ok:true,channel:"C012TARGET",permalink:"https://widgets.slack.com/archives/C012TARGET/p2000000"}' > $case_dir/chat.getPermalink.json
    integer index
    for index in 1 2; do
        jq -n --arg id "F012FILE$index" --arg url "https://files.slack.com/upload/v1/$index" \
            '{ok:true,file_id:$id,upload_url:$url}' > $case_dir/allocate-$index.json
    done
    jq -n '{ok:true,files:["F012FILE1","F012FILE2"] | map({id:.,shares:{private:{C012TARGET:[
        {ts:"2.000000",thread_ts:"1.000000",share_user_id:"U012SENDER"}]}}})}' > $case_dir/files.completeUploadExternal.json
    printf 'binary\0\377\r\n\001end\n' > $case_dir/source
    printf 'second\n' > $case_dir/second
    cp $case_dir/source $case_dir/download.body
    jq -n '{ok:true,file:{id:"F012FILE1",size:15,mode:"snippet",is_external:false,
        url_private:"https://files.slack.com/files-pri/T012TEAM-F012FILE1/original"}}' > $case_dir/files.info.json
    print -r -- 'Attached fixture.' > $case_dir/input
    print -r -- 'protected' > $case_dir/protected
}
function post {
    $root/bin/postcard --account widgets post --model Codex --channel C012TARGET --ts 1.000000 \
        --attach $case_dir/source --attach $case_dir/second "$@" < $case_dir/input > $case_dir/out 2> $case_dir/err
    result=$?
}
function fetch {
    $root/bin/postcard --account widgets fetch --file F012FILE1 --output $case_dir/destination "$@" \
        > $case_dir/out 2> $case_dir/err
    result=$?
}
function failed { (( result == ${1:-1} )) && [[ ! -s $case_dir/out ]] }
function calls { [[ -f $case_dir/calls && $(<$case_dir/calls) == "${(F)@}" ]] }
function no_request { [[ ! -e $case_dir/calls ]] }
function no_share { [[ ! -e $case_dir/calls ]] || ! rg -q 'files.completeUploadExternal|chat.postMessage' $case_dir/calls }
function clean {
    typeset -a paths=( $case_dir/tmp/*(ND) $case_dir/.postcard.fetch.*(N) )
    (( $#paths == 0 ))
}
function private {
    ! rg -Fq fixture-file-secret $case_dir/{out,err,*.argv.json}(N)
}
function no_receipt { [[ ! -d $XDG_STATE_HOME/postcard/sent ]] }
function wait_file {
    integer count
    for (( count=0; count < 500; count++ )); do
        [[ ! -e $1 ]] || return 0
        zselect -t 1
    done
    return 1
}
function dead {
    integer count
    for (( count=0; count < 500; count++ )); do
        kill -0 $1 2>/dev/null || return 0
        zselect -t 1
    done
    return 1
}
function cancel {
    kill -TERM $process 2>/dev/null
    dead $process || { kill -KILL $process 2>/dev/null; return 1; }
    wait $process
    result=$?
    process=0
}

{
    setup_case grouped
    post --slug workshop --where harbor
    check 'grouped attachment post succeeds' test $result -eq 0
    check 'every byte upload precedes the single completion' calls auth.test users.info conversations.replies allocate-1 bytes-1 allocate-2 bytes-2 files.completeUploadExternal chat.getPermalink
    check 'binary attachment bytes are unchanged' cmp -s $case_dir/source $case_dir/bytes-1.body
    check 'second attachment bytes are unchanged' cmp -s $case_dir/second $case_dir/bytes-2.body
    check 'one completion carries both IDs, body and origin without initial_comment' jq -e '
        keys==["blocks","channel_id","files","thread_ts"] and .channel_id=="C012TARGET" and .thread_ts=="1.000000"
        and (.files|map(.id))==["F012FILE1","F012FILE2"]
        and .blocks[0].elements[1].text=="— in workshop on harbor" and .blocks[2].text=="Attached fixture.\n"
    ' $case_dir/files.completeUploadExternal.body
    check 'receipt separates requested destination and observed coordinates' jq -e '
        .requested=={channel:"C012TARGET",thread_ts:"1.000000"} and .channel=="C012TARGET" and .ts=="2.000000"
        and .thread_ts=="1.000000" and (.files|map(.id))==["F012FILE1","F012FILE2"] and .permalink!=null
    ' $case_dir/out
    check 'exact grouped coordinates earn own-post evidence' jq -e '.slug=="workshop" and .ts=="2.000000"' \
        $XDG_STATE_HOME/postcard/sent/team-T012TEAM/C012TARGET/2.000000.json
    check 'upload capability gets no bearer and no redirect/retry' jq -e '
        index("@-")!=null and index("--location")==null and index("--retry")==null and
        all(.[]; contains("Authorization:")|not) and all(.[]; contains("https://files.slack.com")|not)
    ' $case_dir/bytes-1.argv.json
    check 'upload cleans private scratch' clean
    check 'upload keeps bearer private' private

    setup_case replaced-path
    cp $case_dir/source $case_dir/before
    print replacement > $case_dir/replacement
    : > $case_dir/replace-input
    post
    check 'held descriptor survives input pathname replacement' cmp -s $case_dir/before $case_dir/bytes-1.body
    check 'pathname replacement does not prevent completion' test $result -eq 0

    setup_case permalink-failure
    print 28 > $case_dir/chat.getPermalink.status
    post
    check 'metadata failure cannot undo confirmed completion' test $result -eq 0
    check 'failed permalink remains nullable' jq -e '.ts=="2.000000" and .permalink==null' $case_dir/out
    check 'metadata failure retains send evidence' test -f $XDG_STATE_HOME/postcard/sent/team-T012TEAM/C012TARGET/2.000000.json

    setup_case empty-file
    : > $case_dir/source
    post
    check 'zero-length original is streamed and counted' test $result -eq 0
    check 'zero-length original has a zero byte receipt' jq -e '.files[0].size==0' $case_dir/out

    setup_case top-level
    change $case_dir/files.completeUploadExternal.json 'del(.files[].shares.private.C012TARGET[].thread_ts)'
    $root/bin/postcard post --channel C012TARGET --model Codex --attach $case_dir/source --attach $case_dir/second \
        < $case_dir/input > $case_dir/out 2> $case_dir/err
    result=$?
    check 'top-level completion records no asserted parent' jq -e '.requested.thread_ts==null and .thread_ts==null and .ts=="2.000000"' $case_dir/out
    check 'top-level completion omits thread_ts on the wire' jq -e 'has("thread_ts")|not' $case_dir/files.completeUploadExternal.body

    setup_case alias
    jq -n '{version:1,binding:{client_id:"123.456",team_id:"T012TEAM",user_id:"U012SENDER"},
        aliases:{planning:{channel:"C012TARGET",ts:"1.000000"}}}' > ${credentials:h}/aliases.json
    $root/bin/postcard post --alias planning --model Codex --attach $case_dir/source --attach $case_dir/second \
        < $case_dir/input > $case_dir/out 2> $case_dir/err
    check 'attachment post resolves the account-local alias' jq -e '.requested=={channel:"C012TARGET",thread_ts:"1.000000"}' $case_dir/out

    setup_case dm
    change $case_dir/files.completeUploadExternal.json 'del(.files[].shares)'
    $root/bin/postcard post --user U012TARGET --model Codex --attach $case_dir/source --attach $case_dir/second \
        < $case_dir/input > $case_dir/out 2> $case_dir/err
    check 'attachment post uses the checked opened DM' jq -e '.requested=={channel:"D012TARGET",thread_ts:null}' $case_dir/out
    check 'DM is checked before uploads and completion' calls auth.test users.info conversations.open allocate-1 bytes-1 allocate-2 bytes-2 files.completeUploadExternal

    typeset shape filter
    for shape filter in absent 'del(.files[].shares)' wrong-user '.files[0].shares.private.C012TARGET[0].share_user_id="UOTHER"' \
        wrong-parent '.files[0].shares.private.C012TARGET[0].thread_ts="3.0"' \
        different-ts '.files[0].shares.private.C012TARGET[0].ts="3.0"' \
        ambiguous '.files[0].shares.private.C012TARGET += [.files[0].shares.private.C012TARGET[0]]' \
        malformed '.files[0].shares.private.C012TARGET=["bad"]'; do
        setup_case coordinates-$shape
        change $case_dir/files.completeUploadExternal.json "$filter"
        post
        check "$shape coordinates preserve confirmed completion" test $result -eq 0
        check "$shape coordinates remain absent instead of inferred" jq -e '.ts==null and .channel==null and (.files|length)==2' $case_dir/out
        check "$shape coordinates cannot suppress another window" no_receipt
        check "$shape coordinates cause no metadata recovery loop" calls auth.test users.info conversations.replies allocate-1 bytes-1 allocate-2 bytes-2 files.completeUploadExternal
    done

    setup_case empty-body
    : > $case_dir/input
    post
    check 'file-only stdin through EOF succeeds' test $result -eq 0
    check 'file-only card has attribution without empty Markdown' jq -e '.blocks|map(.type)==["context","divider","divider"]' $case_dir/files.completeUploadExternal.body

    for shape filter in subset '.files|=.[0:1]' foreign '.files[1].id="FOTHER"' duplicate '.files[1].id=.files[0].id' \
        refused '{ok:false,error:"internal_error"}'; do
        setup_case uncertain-$shape
        change $case_dir/files.completeUploadExternal.json "$filter"
        post
        check "$shape completion has status 4 and empty stdout" failed 4
        check "$shape completion names known IDs" rg -q 'F012FILE1.*F012FILE2' $case_dir/err
        check "$shape completion is never retried" calls auth.test users.info conversations.replies allocate-1 bytes-1 allocate-2 bytes-2 files.completeUploadExternal
        check "$shape completion leaves no local receipt" no_receipt
        check "$shape completion cleans scratch" clean
    done

    for shape in transport malformed; do
        setup_case uncertain-$shape
        if [[ $shape == transport ]]; then print 28 > $case_dir/files.completeUploadExternal.status
        else print -r -- '{broken' > $case_dir/files.completeUploadExternal.json; fi
        post
        check "$shape completion is uncertain" failed 4
        check "$shape completion names known IDs" rg -q 'F012FILE1.*F012FILE2' $case_dir/err
        check "$shape completion keeps secrets private" private
    done

    for phase in allocate-1 bytes-1 allocate-2 bytes-2; do
        setup_case fail-$phase
        print 28 > $case_dir/$phase.status
        post
        check "$phase failure refuses the share" failed
        check "$phase failure never finalizes a subset" no_share
        check "$phase failure cleans scratch" clean
    done
    setup_case changed-length
    print 1 > $case_dir/bytes-2.size
    post
    check 'declared and sent lengths must agree' failed
    check 'length failure never shares subset' no_share

    setup_case unsafe-upload-url
    change $case_dir/allocate-1.json '.upload_url="https://files.slack.com.evil.example/upload/v1/1"'
    post
    check 'unexpected upload URL stops before sending original bytes' calls auth.test users.info conversations.replies allocate-1
    check 'unexpected upload URL never shares' failed

    setup_case repeated-upload-id
    change $case_dir/allocate-2.json '.file_id="F012FILE1"'
    post
    check 'repeated allocation ID cannot be completed twice' failed
    check 'repeated allocation ID never shares' no_share

    for kind in missing directory fifo; do
        setup_case invalid-$kind
        rm $case_dir/second
        case $kind in (directory) mkdir $case_dir/second ;; (fifo) mkfifo $case_dir/second ;; esac
        post
        check "$kind input fails before allocation" calls auth.test users.info conversations.replies
        check "$kind input has empty stdout" failed
        check "$kind input cleans descriptors and scratch" clean
    done

    setup_case literal
    typeset literal=$case_dir/$'-quote " $(untouched) \\ café\n.txt'
    mv $case_dir/source "$literal"
    change $case_dir/files.completeUploadExternal.json '.files|=.[0:1]'
    $root/bin/postcard post --model Codex --channel C012TARGET --ts 1.000000 --attach "$literal" \
        < $case_dir/input > $case_dir/out 2> $case_dir/err
    result=$?
    check 'literal filename survives shell and JSON boundaries' jq -e --arg name "${literal:t}" '.files[0].name==$name' $case_dir/out
    check 'literal filename does not alter file bytes' cmp -s "$literal" $case_dir/bytes-1.body
    check 'literal filename reaches Slack exactly' jq -e --arg name "filename=${literal:t}" 'index($name)!=null' $case_dir/allocate-1.argv.json

    setup_case missing-file-scope
    change $credentials '.scope="chat:write,users:read"'
    post
    check 'upload requires file scope before requests' no_request
    check 'missing upload scope fails' failed

    setup_case wrong-binding
    change $case_dir/auth.test.json '.team_id="TOTHER"'
    post
    check 'upload checks saved identity before allocation' calls auth.test
    check 'wrong upload identity fails' failed

    typeset operation
    for operation in post fetch; do
        setup_case renewal-$operation
        change $credentials ". + {refresh_token:\"fixture-refresh-secret\",expires_at:$(( EPOCHSECONDS + 60 ))}"
        jq -n '{ok:true,token_type:"user",access_token:"fixture-renewed-secret",refresh_token:"fixture-next-secret",expires_in:43200}' > $case_dir/oauth.v2.access.json
        $operation
        check "$operation shares the ordinary renewal path" test $result -eq 0
        check "$operation uses renewed access for checked identity" rg -Fxq 'Authorization: Bearer fixture-renewed-secret' $case_dir/auth.test.header
        check "$operation atomically retains the renewed grant" jq -e '.access_token=="fixture-renewed-secret" and .renewal_pending==null' $credentials
        check "$operation renewal and transfer remove scratch" clean

        setup_case expired-$operation
        change $credentials ". + {refresh_token:\"fixture-refresh-secret\",expires_at:$(( EPOCHSECONDS - 60 )),renewal_pending:true}"
        $operation
        check "$operation never replays an uncertain expired renewal" no_request
        check "$operation refuses unusable access" failed
    done

    setup_case binary-fetch
    fetch
    check 'fetch succeeds for a hosted snippet' test $result -eq 0
    check 'fetch checks identity then exact file before bytes' calls auth.test files.info download
    check 'fetch publishes exact binary bytes' cmp -s $case_dir/download.body $case_dir/destination
    check 'fetch returns a checked JSON receipt' jq -e --arg output "$case_dir/destination" '
        .=={account:"widgets",team_id:"T012TEAM",user_id:"U012SENDER",file_id:"F012FILE1",output:$output,bytes:15}
    ' $case_dir/out
    check 'fetch never redirects or retries bearer download' jq -e 'index("--location")==null and index("--retry")==null and index("@-")!=null' $case_dir/download.argv.json
    check 'fetch keeps secrets private' private
    check 'fetch removes staging' clean
    typeset -A attributes
    zstat -H attributes -- $case_dir/destination
    check 'published file remains private' test $(( attributes[mode] & 8#77 )) -eq 0
    fetch
    check 'existing output is never overwritten' failed
    check 'existing output remains exact' cmp -s $case_dir/download.body $case_dir/destination

    setup_case fetch-literal
    typeset output=$case_dir/$'-quote " $(untouched) \\ café\n.bin'
    change $case_dir/files.info.json '.file.mode="hosted" | .file.name="../../not-the-output" |
        .file.url_private_download="https://files.slack.com/files-pri/T012TEAM-F012FILE1/download"'
    $root/bin/postcard fetch --file F012FILE1 --output "$output" > $case_dir/out 2> $case_dir/err
    check 'explicit literal output path is returned exactly' jq -e --arg output "$output" '.output==$output' $case_dir/out
    check 'Slack filename never selects local path' cmp -s "$output" $case_dir/download.body
    check 'literal destination removes staging' clean

    for shape in missing-parent symlink directory; do
        setup_case output-$shape
        case $shape in
            (missing-parent) output=$case_dir/missing/destination ;;
            (symlink) ln -s $case_dir/missing $case_dir/destination; output=$case_dir/destination ;;
            (directory) mkdir $case_dir/destination; output=$case_dir/destination ;;
        esac
        $root/bin/postcard fetch --file F012FILE1 --output "$output" > $case_dir/out 2> $case_dir/err
        result=$?
        check "$shape destination fails before network" no_request
        check "$shape destination is refused" failed
    done

    for shape filter in external '.file.is_external=true' wrong-id '.file.id="FOTHER"' \
        http '.file.url_private="http://files.slack.com/file"' \
        prefix '.file.url_private="https://files.slack.com.evil.example/file"' \
        userinfo '.file.url_private="https://files.slack.com@evil.example/file"' \
        config '.file.url_private="https://files.slack.com/file\"\nheader=secret"' \
        port '.file.url_private="https://files.slack.com:443/file"' \
        size '.file.size=-1' missing-url 'del(.file.url_private)' mode '.file.mode="external"'; do
        setup_case fetch-$shape
        change $case_dir/files.info.json "$filter"
        fetch
        check "$shape file metadata refuses download" failed
        check "$shape metadata sends no bearer to file URL" calls auth.test files.info
        check "$shape metadata leaves no destination" test ! -e $case_dir/destination
        check "$shape metadata removes staging" clean
    done

    for shape in redirect transport short; do
        setup_case fetch-$shape
        case $shape in
            (redirect) print 302 > $case_dir/download.http ;;
            (transport) print 28 > $case_dir/download.status ;;
            (short) print short > $case_dir/download.body ;;
        esac
        fetch
        check "$shape download fails" failed
        check "$shape download publishes no bytes" test ! -e $case_dir/destination
        check "$shape download removes staging" clean
    done
    setup_case fetch-scope
    change $credentials '.scope="chat:write"'
    fetch
    check 'fetch requires files:read before network' no_request
    check 'fetch missing scope fails' failed
    setup_case fetch-binding
    change $case_dir/auth.test.json '.user_id="UOTHER"'
    fetch
    check 'fetch checks saved identity before metadata' calls auth.test
    check 'fetch wrong identity fails' failed

    for shape in file directory symlink; do
        setup_case race-$shape
        export POSTCARD_TEST_RACE=$shape
        fetch
        check "$shape publication race never succeeds" failed
        check "$shape publication race cleans staging" clean
        check "$shape publication preserves unrelated bytes" rg -Fxq protected $case_dir/protected
        if [[ $shape == file ]]; then
            check 'file race preserves existing destination' rg -Fxq existing $case_dir/destination
        elif [[ $shape == directory ]]; then
            check 'directory race leaves no accidental nested hard link' test ! -e $case_dir/destination/bytes
        fi
    done
    setup_case output-failure
    export POSTCARD_TEST_FAULT=output
    fetch
    check 'stdout failure reports failure without JSON' failed
    check 'stdout failure retains published complete file' cmp -s $case_dir/download.body $case_dir/destination
    check 'stdout failure says the file already exists' rg -Fq 'file already exists' $case_dir/err
    check 'stdout failure cleans staging' clean

    setup_case cancel-after-link
    export POSTCARD_TEST_GATE=publish POSTCARD_TEST_AFTER_LINK=1
    $root/bin/postcard fetch --file F012FILE1 --output $case_dir/destination > $case_dir/out 2> $case_dir/err &
    process=$!
    check 'publication boundary reaches already-created hard link' wait_file $case_dir/ready
    cancel
    check 'cancellation after link retains complete bytes' cmp -s $case_dir/download.body $case_dir/destination
    check 'cancellation after link reports existing output' rg -Fq 'file already exists' $case_dir/err
    check 'cancellation after link cleans private staging' clean

    for phase in bytes-1 files.completeUploadExternal chat.getPermalink sent download publish output; do
        setup_case cancel-$phase
        export POSTCARD_TEST_GATE=$phase
        if [[ $phase == (bytes-1|files.completeUploadExternal|chat.getPermalink|sent) ]]; then
            $root/bin/postcard post --model Codex --channel C012TARGET --ts 1.000000 \
                --attach $case_dir/source --attach $case_dir/second < $case_dir/input > $case_dir/out 2> $case_dir/err &
        else
            $root/bin/postcard fetch --file F012FILE1 --output $case_dir/destination > $case_dir/out 2> $case_dir/err &
        fi
        process=$!
        check "$phase cancellation reaches owned child" wait_file $case_dir/ready
        integer writer=$(<$case_dir/ready)
        cancel
        check "$phase cancellation reaps child promptly" dead $writer
        check "$phase cancellation cleans scratch" clean
        if [[ $phase == files.completeUploadExternal ]]; then
            check 'interrupted completion is uncertain with empty stdout' failed 4
            check 'interrupted completion names known IDs' rg -q 'F012FILE1.*F012FILE2' $case_dir/err
        elif [[ $phase == output ]]; then
            check 'cancelled output preserves published bytes' cmp -s $case_dir/download.body $case_dir/destination
            check 'cancelled output says the file exists' rg -Fq 'file already exists' $case_dir/err
        elif [[ $phase == (chat.getPermalink|sent) ]]; then
            check "$phase interruption reports confirmed sharing" rg -Fq 'Files were shared' $case_dir/err
        else
            check "$phase cancellation exits nonzero" test $result -ne 0
        fi
    done

    # A full pipe holds the actual Zsh receipt writer after confirmed sharing.
    # Closing it or signalling only the owner must reap that writer promptly.
    for shape in cancel broken; do
        setup_case post-pipe-$shape
        mkfifo $case_dir/pipe
        sysopen -rw -o nonblock,cloexec -u pipefd $case_dir/pipe || exit 1
        typeset padding=${(l:65536::x:)}
        while syswrite -o $pipefd "$padding" 2>/dev/null; do :; done
        $root/test/files-driver.zsh < $case_dir/input > $case_dir/pipe 2> $case_dir/err &
        process=$!
        check "$shape output reaches actual builtin writer" wait_file $case_dir/writer
        [[ -s $case_dir/writer ]] || { cancel; exec {pipefd}>&-; pipefd=-1; continue; }
        integer writer=$(<$case_dir/writer)
        check "$shape output has a live owned writer" kill -0 $writer
        if [[ $shape == cancel ]]; then
            cancel
            exec {pipefd}>&-
        else
            exec {pipefd}>&-
            check 'broken output owner exits promptly' dead $process
            wait $process
            result=$?
            process=0
        fi
        pipefd=-1
        check "$shape output failure remains nonzero" test $result -ne 0
        check "$shape output reports that files were shared" rg -Fq 'Files were shared' $case_dir/err
        check "$shape output reaps the owned writer" dead $writer
        check "$shape output cleans upload scratch" clean
    done
    print -r -- "files: $failures failure(s)"
} always {
    (( process == 0 )) || { kill -TERM $process 2>/dev/null; wait $process 2>/dev/null; }
    (( pipefd < 0 )) || exec {pipefd}>&-
    if (( failures == 0 )); then
        rm -rf -- $fixture
    else
        print -r -- "fixtures retained: $fixture"
    fi
}
(( failures == 0 ))
