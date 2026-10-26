#!/bin/zsh -f

setopt pipefail no_bgnice
umask 077
zmodload zsh/datetime zsh/system
typeset root=${ZSH_ARGZERO:A:h:h}
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/postcard.post.XXXXXX) || exit 1
typeset case_dir credentials original
integer failures=0 result
export POSTCARD_TEST_JQ=$commands[jq]
mkdir -p $fixture/bin
ln -s $root/test/post-curl.zsh $fixture/bin/curl
cat > $fixture/bin/jq <<'EOF'
#!/bin/zsh -f
print -rl -- "$@" >> $POSTCARD_TEST_POST/jq.argv
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
    export POSTCARD_TEST_POST=$case_dir
    unset POSTCARD_TEST_REPLACEMENT POSTCARD_TEST_CREDENTIALS
    credentials=$XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json
    original=$case_dir/original
    print -r -- 'The review is ready.' > $case_dir/input
    $POSTCARD_TEST_JQ -n '{ok:true,team_id:"T012TEAM",user_id:"U012SENDER"}' > $case_dir/auth.test.json
    $POSTCARD_TEST_JQ -n '{ok:true,user:{id:"U012SENDER",team_id:"T012TEAM",deleted:false,
        is_bot:false,profile:{display_name:"Jane Doe",real_name:"Jane Doe"},name:"jane.doe"}}' > $case_dir/users.info.json
    $POSTCARD_TEST_JQ -n '{ok:true,channel:{id:"D012TARGET",is_im:true,user:"U012TARGET"}}' > $case_dir/conversations.open.json
    $POSTCARD_TEST_JQ -n '{ok:true,messages:[{type:"message",ts:"1700000000.000000"}]}' > $case_dir/conversations.replies.json
    $POSTCARD_TEST_JQ -n '{ok:true,channel:"C012TARGET",ts:"1700000000.000001",
        message:{type:"message",user:"U012SENDER",team:"T012TEAM",ts:"1700000000.000001"}}' > $case_dir/chat.postMessage.json
    $POSTCARD_TEST_JQ -n '{ok:true,channel:"C012TARGET",permalink:"https://widgets.slack.com/archives/C012TARGET/p1700000000000001"}' > $case_dir/chat.getPermalink.json
}

function save_grant {
    typeset name=${1:-widgets}
    mkdir -p $XDG_CONFIG_HOME/postcard/accounts/$name
    $POSTCARD_TEST_JQ -n '{client_id:"123.456",team_id:"T012TEAM",user_id:"U012SENDER",
        access_token:"fixture-post-secret",scope:"chat:write,users:read,im:write,channels:history"}' \
        > $XDG_CONFIG_HOME/postcard/accounts/$name/credentials.json
    [[ ! -e $credentials ]] || cp $credentials $original
}

function save_alias {
    typeset name=$1 channel=$2 ts=$3
    $POSTCARD_TEST_JQ -n --arg name "$name" --arg channel "$channel" --arg ts "$ts" '
        {version:1,binding:{client_id:"123.456",team_id:"T012TEAM",user_id:"U012SENDER"},
         aliases:{($name):{channel:$channel,ts:$ts}}}
    ' > $XDG_CONFIG_HOME/postcard/accounts/widgets/aliases.json
}

function run_post {
    $root/bin/postcard "$@" < $case_dir/input > $case_dir/out 2> $case_dir/err
    result=$?
}

function failed { (( result == ${1:-1} )) && [[ ! -s $case_dir/out ]] }
function no_request { [[ ! -e $case_dir/calls ]] }
function no_post { [[ ! -e $case_dir/calls ]] || ! rg -q '^chat.postMessage$' $case_dir/calls }
function one_post { [[ -e $case_dir/calls && $(rg -c '^chat.postMessage$' $case_dir/calls) == 1 ]] }
function unchanged { cmp -s $credentials $original }
function private_output { ! rg -Fq fixture-post-secret $case_dir/{out,err,*.argv.json,jq.argv}(N) }
function private_body { ! rg -Fq fixture-private-body $case_dir/{out,err,*.argv.json,jq.argv}(N) }
function uncertain { failed 4 && rg -Fq 'Do not repost without inspecting Slack.' $case_dir/err }
function calls {
    typeset -a expected=( "$@" )
    [[ -e $case_dir/calls && $(< $case_dir/calls) == "${(F)expected}" ]]
}
function change_response {
    $POSTCARD_TEST_JQ "$2" $case_dir/$1.json > $case_dir/next.json || return
    mv $case_dir/next.json $case_dir/$1.json
}
function change_grant {
    $POSTCARD_TEST_JQ "$1" $credentials > $case_dir/next.json || return
    mv $case_dir/next.json $credentials
    cp $credentials $original
}
function rejects_before_send {
    setup_case $1
    save_grant
    change_response "$2" "$3" || return
    run_post post --model Codex "${@:4}"
    check "$1 refuses before posting" failed
    check "$1 sends no message" no_post
    check "$1 preserves credentials" unchanged
    check "$1 keeps secrets private" private_output
}
function disputes_receipt {
    setup_case $1
    save_grant
    change_response chat.postMessage "$2" || return
    run_post post --model Codex --channel C012TARGET "${@:3}"
    check "$1 has uncertain status and no stdout" uncertain
    check "$1 sends once and stops before permalink" calls auth.test users.info chat.postMessage
    check "$1 never repeats the write" one_post
    check "$1 keeps secrets private" private_output
    check "$1 never creates local send proof" test ! -e $XDG_STATE_HOME/postcard/sent
}

{
    setup_case literal
    save_grant
    print -rn -- $'- fixture-private-body\n$(not-a-command) \\ "quote" <@U012TARGET> & café 🦆\n\n' > $case_dir/input
    change_response users.info '.user.profile.display_name="Jane <Doe> & Co"'
    run_post --account widgets post --channel C012TARGET --model Codex
    check 'exact conversation post succeeds' test $result -eq 0
    check 'conversation post follows identity, profile, write, permalink order' calls auth.test users.info chat.postMessage chat.getPermalink
    check 'post receipt contains checked identity and actual address' $POSTCARD_TEST_JQ -e '
        . == {account:"widgets",team_id:"T012TEAM",user_id:"U012SENDER",channel:"C012TARGET",ts:"1700000000.000001",
            thread_ts:null,sender:"U012SENDER",permalink:"https://widgets.slack.com/archives/C012TARGET/p1700000000000001"}
    ' $case_dir/out
    check 'card has exact literal body, escaped context and accessible fallback' $POSTCARD_TEST_JQ -e --rawfile body $case_dir/input '
        def escape: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
        .channel=="C012TARGET" and .blocks==[
            {type:"context",elements:[{type:"mrkdwn",text:"*Jane &lt;Doe&gt; &amp; Co\u0027s Codex, from Postcard* :mailbox_with_mail:"}]},
            {type:"divider"},{type:"markdown",text:$body},{type:"divider"}]
        and .text==(("Jane <Doe> & Co\u0027s Codex, from Postcard\n\n"+$body)|escape)
        and .mrkdwn==false and .parse=="none" and .link_names==false
        and .unfurl_links==false and .unfurl_media==false
        and keys==["blocks","channel","link_names","mrkdwn","parse","text","unfurl_links","unfurl_media"]
    ' $case_dir/body.json
    check 'post JSON uses an anonymous pipe and bearer header uses stdin' $POSTCARD_TEST_JQ -e '
        def option($name;$value): index($name) as $i | $i!=null and .[$i+1]==$value;
        .[0]=="-q" and option("--data-binary";"@/dev/fd/3") and option("--header";"@-")
        and option("--connect-timeout";"10") and option("--max-time";"30") and option("--proto";"=https")
        and index("--retry")==null and index("--location")==null and index("--fail")!=null
    ' $case_dir/chat.postMessage.argv.json
    check 'profile request uses a form-encoded query for the sender' $POSTCARD_TEST_JQ -e '
        index("user=U012SENDER") as $i | .[$i-1]=="--data-urlencode" and index("--get")!=null
    ' $case_dir/users.info.argv.json
    check 'body never reaches argv or diagnostics' private_body
    check 'bearer never reaches argv or diagnostics' private_output
    check 'post leaves credentials alone' unchanged
    check 'confirmed post retains its exact checked identity without an association' $POSTCARD_TEST_JQ -e '
        . == {version:1,binding:{client_id:"123.456",team_id:"T012TEAM",user_id:"U012SENDER"},
            channel:"C012TARGET",ts:"1700000000.000001",thread_ts:null,slug:null}
    ' $XDG_STATE_HOME/postcard/sent/team-T012TEAM/C012TARGET/1700000000.000001.json

    typeset combination origin option value
    typeset -a labels
    for combination in neither slug where both; do
        setup_case origin-$combination
        save_grant
        labels=() origin=''
        case $combination in
            (slug) labels=( --slug workshop_alpha ); origin='— in workshop_alpha' ;;
            (where) labels=( --where harbor ); origin='— on harbor' ;;
            (both) labels=( --slug workshop_alpha --where harbor ); origin='— in workshop_alpha on harbor' ;;
        esac
        run_post post --model Codex --channel C012TARGET "${labels[@]}"
        check "$combination origin combination succeeds" test $result -eq 0
        check "$combination origin preserves the header, body, dividers and literal aside" $POSTCARD_TEST_JQ -e \
            --arg origin "$origin" --rawfile body $case_dir/input '
            .blocks==[
                {type:"context",elements:([
                    {type:"mrkdwn",text:"*Jane Doe\u0027s Codex, from Postcard* :mailbox_with_mail:"}
                ] + if $origin=="" then [] else [{type:"plain_text",text:$origin,emoji:false}] end)},
                {type:"divider"},{type:"markdown",text:$body},{type:"divider"}]
            and .text==("Jane Doe\u0027s Codex, from Postcard" +
                (if $origin=="" then "" else " " + $origin end) + "\n\n" + $body)
        ' $case_dir/body.json
        check "$combination origin adds no requests or repeated writes" calls auth.test users.info chat.postMessage chat.getPermalink
    done

    setup_case origin-literal
    save_grant
    typeset slug='workshop_alpha *bold* _italic_ ~strike~ `code`'
    typeset where='São Tomé & <@U012TARGET> :mailbox_with_mail:'
    run_post post --model Codex --channel C012TARGET --slug "$slug" --where "$where"
    check 'Unicode and markup-shaped origin labels succeed' test $result -eq 0
    check 'origin is literal plain text while the fallback escapes Slack controls' $POSTCARD_TEST_JQ -e \
        --arg slug "$slug" --arg where "$where" --rawfile body $case_dir/input '
        def escape: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
        .blocks[0].elements[1]=={type:"plain_text",text:("— in " + $slug + " on " + $where),emoji:false}
        and .text==(("Jane Doe\u0027s Codex, from Postcard — in " + $slug + " on " + $where + "\n\n" + $body)|escape)
    ' $case_dir/body.json

    for option in slug where; do
        setup_case $option-limit
        save_grant
        value=${(l:64::é:)}
        run_post post --model Codex --channel C012TARGET --$option "$value"
        check "$option permits 64 Unicode characters" test $result -eq 0
        check "$option retains every character" $POSTCARD_TEST_JQ -e --arg value "$value" \
            '.blocks[0].elements[1].text | endswith($value)' $case_dir/body.json
        setup_case invalid-$option
        save_grant
        for value in '' ${(l:65::é:)} $'line\nbreak' $'carriage\rreturn' $'tab\there' \
            $'control\x1f' $'delete\x7f' $'next\u0085line' $'line\u2028break' $'paragraph\u2029break' $'bad\xffbytes'; do
            run_post post --model Codex --channel C012TARGET --$option "$value"
            check "invalid $option label is rejected" failed
        done
        check "invalid $option labels fail before network activity" no_request
    done

    # Each context text object has its own bound; the complete accessible
    # fallback also includes the labels and must stay within Slack's limit.
    setup_case origin-context-limit
    save_grant
    change_response users.info '.user.profile.display_name=("x" * (3000 - ("*\u0027s Codex, from Postcard* :mailbox_with_mail:" | length)))'
    run_post post --model Codex --channel C012TARGET --slug workshop --where harbor
    check 'labels can accompany a maximum-size existing context element' test $result -eq 0
    check 'context limit counts each text object' $POSTCARD_TEST_JQ -e \
        '(.blocks[0].elements[0].text|length)==3000 and (.blocks[0].elements|length)==2' $case_dir/body.json
    change_response users.info '.user.profile.display_name += "x"'
    rm $case_dir/calls
    run_post post --model Codex --channel C012TARGET --slug workshop --where harbor
    check 'oversized existing context still refuses a decorated card' failed
    check 'oversized context is not posted' no_post

    setup_case origin-fallback-limit
    save_grant
    $POSTCARD_TEST_JQ -nrj '40000 - ("Jane Doe\u0027s Codex, from Postcard\n\n"|length) as $room |
        ("&" * (($room / 5)|floor)) + ("x" * ($room % 5))' > $case_dir/input
    run_post post --model Codex --channel C012TARGET
    check 'maximum escaped fallback is accepted without labels' test $result -eq 0
    check 'maximum fallback is complete' $POSTCARD_TEST_JQ -e '.text|length==40000' $case_dir/body.json
    rm $case_dir/calls
    run_post post --model Codex --channel C012TARGET --slug workshop --where harbor
    check 'origin is included in the escaped fallback limit' failed
    check 'oversized decorated fallback is not posted' no_post

    typeset user channel method error
    for user in U012TARGET W012TARGET U012SENDER; do
        setup_case dm-$user
        save_grant
        change_response conversations.open ".channel.user=\"$user\""
        change_response chat.postMessage '.channel="D012TARGET"'
        change_response chat.getPermalink '.channel="D012TARGET" | .permalink="https://widgets.slack.com/archives/D012TARGET/p1700000000000001"'
        run_post post --model Codex --user "$user"
        check "$user DM succeeds" test $result -eq 0
        check "$user DM is opened before the single post" calls auth.test users.info conversations.open chat.postMessage chat.getPermalink
        check "$user DM requests the exact user and full IM" $POSTCARD_TEST_JQ -e --arg user "$user" '
            index("users="+$user)!=null and index("return_im=true")!=null
        ' $case_dir/conversations.open.argv.json
        check "$user DM writes only the returned conversation" $POSTCARD_TEST_JQ -e '.channel=="D012TARGET"' $case_dir/body.json
    done
    for channel in D012TARGET G012TARGET; do
        setup_case direct-$channel
        save_grant
        change_response chat.postMessage ".channel=\"$channel\""
        run_post post --model Codex --channel "$channel"
        check "direct $channel does not open a DM" calls auth.test users.info chat.postMessage chat.getPermalink
        check "direct $channel succeeds despite unavailable permalink" test $result -eq 0
    done

    setup_case reply
    save_grant
    change_response chat.postMessage '.message.thread_ts="1700000000.000000"'
    change_response chat.getPermalink '.permalink += "?thread_ts=1700000000.000000&cid=C012TARGET"'
    run_post post --model Codex --channel C012TARGET --ts 1700000000.000000
    check 'thread post checks the parent before sending' calls auth.test users.info conversations.replies chat.postMessage chat.getPermalink
    check 'thread preflight is bounded at one message' $POSTCARD_TEST_JQ -e '
        index("limit=1")!=null and index("inclusive=true")!=null
        and index("ts=1700000000.000000")!=null
        and index("oldest=1700000000.000000")!=null
        and index("latest=1700000000.000000")!=null
        and index("channel=C012TARGET")!=null
    ' $case_dir/conversations.replies.argv.json
    check 'thread payload names the parent without broadcasting' $POSTCARD_TEST_JQ -e '.thread_ts=="1700000000.000000" and .reply_broadcast==false' $case_dir/body.json
    check 'reply receipt has Slack-confirmed parent' $POSTCARD_TEST_JQ -e '.thread_ts=="1700000000.000000"' $case_dir/out

    setup_case alias
    save_grant
    save_alias planning C012TARGET 1700000000.000000
    change_response chat.postMessage '.message.thread_ts="1700000000.000000"'
    run_post post --model Codex --alias planning
    check 'post resolves an account-local alias' test $result -eq 0
    check 'alias post preflights and writes the resolved thread' calls auth.test users.info conversations.replies chat.postMessage chat.getPermalink
    check 'alias post payload contains the exact saved address' $POSTCARD_TEST_JQ -e '
        .channel=="C012TARGET" and .thread_ts=="1700000000.000000"
    ' $case_dir/body.json
    check 'alias post receipt contains the confirmed parent' $POSTCARD_TEST_JQ -e '.thread_ts=="1700000000.000000"' $case_dir/out
    check 'local proof records the resolved alias parent' $POSTCARD_TEST_JQ -e '.thread_ts=="1700000000.000000"' \
        $XDG_STATE_HOME/postcard/sent/team-T012TEAM/C012TARGET/1700000000.000001.json

    setup_case grammar
    save_grant
    run_post post --channel C012TARGET
    check 'parser requires a model' test $result -ne 0
    run_post post --model Codex
    check 'post requires a destination' failed
    run_post post --model Codex --channel C012TARGET --user U012TARGET
    check 'post refuses two destinations' failed
    run_post post --model Codex --alias planning --channel C012TARGET
    check 'post refuses an alias beside another destination' failed
    run_post post --model Codex --user U012TARGET --ts 1700000000.000000
    check 'post refuses a parent with a user destination' failed
    run_post post --model Codex C012TARGET
    check 'post refuses positional destinations' failed
    for value in '' 'Casey Lee' U012TARGET c012TARGET '#shipping' $'C012TARGET\n'; do
        run_post post --model Codex --channel "$value"
        check "invalid channel $value is rejected" failed
    done
    for value in '' C012TARGET u012TARGET '<@U012TARGET>' $'U012TARGET\n'; do
        run_post post --model Codex --user "$value"
        check "invalid user $value is rejected" failed
    done
    for value in '' Planning 'two words' '../planning' $'planning\n'; do
        run_post post --model Codex --alias "$value"
        check "invalid alias $value is rejected" failed
    done
    for value in '' 1700000000 1.2.3 -1.000000 $'1.000000\n'; do
        run_post post --model Codex --channel C012TARGET --ts "$value"
        check "invalid parent $value is rejected" failed
    done
    for value in '' $'Codex\n' '<@U012TARGET>' '-model' ${(l:65::x:)}; do
        run_post post --model "$value" --channel C012TARGET
        check 'invalid model is rejected' failed
    done
    check 'invalid grammar makes no request' no_request

    for value in empty nul invalid-utf8 oversized; do
        setup_case body-$value
        save_grant
        case $value in
            (empty) : > $case_dir/input ;;
            (nul) printf 'before\0after' > $case_dir/input ;;
            (invalid-utf8) printf 'before\377after' > $case_dir/input ;;
            (oversized) print -rn -- ${(l:12001::x:)} > $case_dir/input ;;
        esac
        run_post post --model Codex --channel C012TARGET
        check "$value body is rejected before network" failed
        check "$value body sends no request" no_request
    done
    setup_case body-limit
    save_grant
    print -rn -- ${(l:12000::x:)} > $case_dir/input
    run_post post --model Codex --channel C012TARGET
    check '12000-character Markdown body is accepted' test $result -eq 0
    check 'maximum body stays complete' $POSTCARD_TEST_JQ -e '.blocks[2].text|length==12000' $case_dir/body.json

    rejects_before_send wrong-live-team auth.test '.team_id="T999OTHER"' --channel C012TARGET
    rejects_before_send wrong-live-user auth.test '.user_id="U999OTHER"' --channel C012TARGET
    rejects_before_send bot-grant auth.test '.bot_id="B012BOT"' --channel C012TARGET
    rejects_before_send wrong-profile users.info '.user.id="U999OTHER"' --channel C012TARGET
    rejects_before_send deleted-profile users.info '.user.deleted=true' --channel C012TARGET
    rejects_before_send numeric-name users.info '.user.profile.display_name=17' --channel C012TARGET
    rejects_before_send wrong-dm-user conversations.open '.channel.user="U999OTHER"' --user U012TARGET
    rejects_before_send wrong-dm-type conversations.open '.channel.is_im=false' --user U012TARGET
    rejects_before_send wrong-dm-id conversations.open '.channel.id="C012TARGET"' --user U012TARGET
    rejects_before_send empty-parent conversations.replies '.messages=[]' --channel C012TARGET --ts 1700000000.000000
    rejects_before_send different-parent conversations.replies '.messages[0].thread_ts="1699999999.000000"' --channel C012TARGET --ts 1700000000.000000
    rejects_before_send wrong-parent-message conversations.replies '.messages[0].ts="1699999999.000000"' --channel C012TARGET --ts 1700000000.000000
    rejects_before_send oversized-parent-page conversations.replies '.messages += .messages' --channel C012TARGET --ts 1700000000.000000

    for method in auth.test users.info conversations.open conversations.replies; do
        typeset -a address=( --channel C012TARGET )
        [[ $method != conversations.open ]] || address=( --user U012TARGET )
        [[ $method != conversations.replies ]] || address+=( --ts 1700000000.000000 )
        rejects_before_send multiple-$method "$method" '., .' "${address[@]}"
    done

    for value in real-name username id; do
        setup_case name-$value
        save_grant
        change_response users.info '.user.profile.display_name=""'
        [[ $value == real-name ]] || change_response users.info '.user.profile.real_name=null'
        [[ $value != id ]] || change_response users.info 'del(.user.name)'
        run_post post --model Codex --channel C012TARGET
        check "$value supplies missing display name" test $result -eq 0
    done

    disputes_receipt wrong-returned-channel '.channel="C999OTHER"'
    disputes_receipt wrong-returned-user '.message.user="U999OTHER"'
    disputes_receipt wrong-returned-ts '.message.ts="1700000000.000009"'
    disputes_receipt wrong-returned-parent '.message.thread_ts="1700000000.000000"'
    disputes_receipt missing-message 'del(.message)'
    disputes_receipt malformed-write-ts '.ts=17'
    disputes_receipt multiple-write-documents '., .'
    disputes_receipt secret-response '{ok:"fixture-post-secret"}'

    setup_case missing-reply-evidence
    save_grant
    run_post post --model Codex --channel C012TARGET --ts 1700000000.000000
    check 'missing reply evidence is uncertain' uncertain
    check 'missing reply evidence never reposts' one_post
    check 'disputed receipt gives safe coordinates' rg -Fq 'C012TARGET 1700000000.000001' $case_dir/err

    for error in invalid_auth token_expired token_revoked missing_scope ratelimited rate_limited channel_not_found not_in_channel is_archived invalid_blocks restricted_action_thread_locked; do
        setup_case rejected-$error
        save_grant
        change_response chat.postMessage "{ok:false,error:\"$error\",detail:\"fixture-post-secret\"}"
        run_post post --model Codex --channel C012TARGET
        check "$error is a known rejection" failed
        check "$error is never retried" one_post
        check "$error keeps secrets private" private_output
    done
    for error in internal_error fatal_error request_timeout new_error; do
        setup_case uncertain-$error
        save_grant
        change_response chat.postMessage "{ok:false,error:\"$error\",detail:\"fixture-post-secret\"}"
        run_post post --model Codex --channel C012TARGET
        check "$error is uncertain delivery" uncertain
        check "$error is never retried" one_post
        check "$error keeps secrets private" private_output
    done
    for value in 7 22 28 52 55 56; do
        setup_case write-transport-$value
        save_grant
        print -r -- "$value" > $case_dir/chat.postMessage.status
        run_post post --model Codex --channel C012TARGET
        check "write transport $value is uncertain" uncertain
        check "write transport $value is one attempt" one_post
        check "write transport $value suppresses private diagnostics" private_output
        check "write transport $value leaves credentials alone" unchanged
    done
    for method in auth.test users.info conversations.open conversations.replies; do
        setup_case preflight-transport-$method
        save_grant
        print -r -- 28 > $case_dir/$method.status
        typeset -a address=( --channel C012TARGET )
        [[ $method != conversations.open ]] || address=( --user U012TARGET )
        [[ $method != conversations.replies ]] || address+=( --ts 1700000000.000000 )
        run_post post --model Codex "${address[@]}"
        check "$method transport failure is before sending" failed
        check "$method failure never posts" no_post
        check "$method suppresses private diagnostics" private_output
    done

    for value in transport malformed rejected mismatch wrong-url; do
        setup_case permalink-$value
        save_grant
        case $value in
            (transport) print -r -- 28 > $case_dir/chat.getPermalink.status ;;
            (malformed) print -r -- 'fixture-post-secret broken JSON' > $case_dir/chat.getPermalink.json ;;
            (rejected) change_response chat.getPermalink '{ok:false,error:"invalid_auth",detail:"fixture-post-secret"}' ;;
            (mismatch) change_response chat.getPermalink '.channel="C999OTHER"' ;;
            (wrong-url) change_response chat.getPermalink '.permalink="https://widgets.slack.com/archives/C012TARGET/p999"' ;;
        esac
        run_post post --model Codex --channel C012TARGET
        check "permalink $value cannot undo success" test $result -eq 0
        check "permalink $value returns a receipt without link" $POSTCARD_TEST_JQ -e '.permalink==null and .ts=="1700000000.000001"' $case_dir/out
        check "permalink $value warns against reposting" rg -Fq 'Message was posted; permalink unavailable. Do not repost.' $case_dir/err
        check "permalink $value never repeats the post" one_post
        check "permalink $value keeps secrets private" private_output
    done

    setup_case snapshot
    save_grant
    $POSTCARD_TEST_JQ '.team_id="T999OTHER" | .user_id="U999OTHER" | .access_token="replacement-secret"' $credentials > $case_dir/replacement
    export POSTCARD_TEST_REPLACEMENT=$case_dir/replacement POSTCARD_TEST_CREDENTIALS=$credentials
    run_post post --model Codex --channel C012TARGET
    check 'concurrent login replacement does not change the posting snapshot' test $result -eq 0
    for method in auth.test users.info chat.postMessage chat.getPermalink; do
        check "$method uses original snapshot bearer" rg -Fxq 'Authorization: Bearer fixture-post-secret' $case_dir/$method.header
    done
    check 'concurrent replacement remains installed' cmp -s $credentials $case_dir/replacement

    setup_case no-accounts
    run_post post --model Codex --channel C012TARGET
    check 'post without a saved account fails' failed
    check 'post without an account makes no request' no_request
    setup_case ambiguous
    save_grant
    save_grant other
    print -r -- broken > $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json
    run_post post --model Codex --channel C012TARGET
    check 'broken second account still makes selection ambiguous' failed
    check 'ambiguous account sends no request' no_request
    run_post --account widgets post --model Codex --channel C012TARGET
    check 'explicit account works beside a broken account' test $result -eq 0
    setup_case expired
    save_grant
    change_grant '.+{expires_at:1,refresh_token:"fixture-refresh",renewal_pending:true}'
    run_post post --model Codex --channel C012TARGET
    check 'expired grant stops before network' failed
    check 'expired uncertain renewal is not replayed' unchanged
    check 'expired grant sends no request' no_request
    setup_case missing-scope
    save_grant
    change_grant '.scope="users:read"'
    run_post post --model Codex --channel C012TARGET
    check 'missing write scope stops before network' failed
    check 'missing write scope opens no DM and sends no request' no_request
} always {
    if (( failures )); then
        print -r -- "fixture retained: $fixture"
    else
        rm -rf $fixture
    fi
}
(( failures == 0 )) || { print -r -- "post: $failures failure(s)"; exit 1; }
print -r -- 'post: PASS'
