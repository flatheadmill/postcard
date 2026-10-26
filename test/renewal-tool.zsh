#!/bin/zsh -f

setopt pipefail no_bgnice
zmodload zsh/zselect zsh/datetime
typeset directory=$POSTCARD_TEST_RENEWAL tool=${ZSH_ARGZERO:t} phase='' destination='' headers=''
typeset -a calls
integer index=0
case $tool in
    (curl)
        if [[ $argv[-1] != https://slack.com/api/oauth.v2.access ]]; then
            if [[ -n $POSTCARD_TEST_WATCH ]]; then
                exec $POSTCARD_TEST_WATCH_CURL "$@"
            elif [[ -n $POSTCARD_TEST_POST ]]; then
                exec ${0:A:h}/post-curl.zsh "$@"
            elif [[ -n $POSTCARD_TEST_THREAD ]]; then
                exec ${0:A:h}/thread-curl.zsh "$@"
            else
                exec ${0:A:h}/search-curl.zsh "$@"
            fi
        fi
        calls=( $directory/refresh.*.form(N) )
        index=$(( $#calls + 1 ))
        for (( position=1; position <= $#; position++ )); do
            case $argv[position] in
                (--output) destination=$argv[position+1] ;;
                (--dump-header) headers=$argv[position+1] ;;
            esac
        done
        [[ -n $destination && -n $headers ]] || exit 99
        /bin/cat > $directory/refresh.$index.form
        printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' > $directory/refresh.$index.argv
        print -r -- $EPOCHSECONDS > $directory/refresh.$index.time
        phase=curl-$index ;;
    (mv)
        if [[ $argv[-2] == */.renewal.*/credentials ]]; then
            calls=( $directory/mv.*.started(N) )
            index=$(( $#calls + 1 ))
            phase=mv-$index
            print -r -- $$ > $directory/mv.$index.started
        fi ;;
    (jq)
        print -rl -- "$@" >> $directory/jq.argv
        if [[ -f $directory/replace-after-read && ! -e $directory/replaced && "$*" == *'.client_id, .team_id'* ]]; then
            cp $directory/replacement $directory/replacement.next &&
                /bin/mv $directory/replacement.next $XDG_CONFIG_HOME/postcard/accounts/widgets/credentials.json || exit
            if [[ -f $directory/add-account ]]; then
                mkdir -p $XDG_CONFIG_HOME/postcard/accounts/other
                cp $directory/replacement $XDG_CONFIG_HOME/postcard/accounts/other/credentials.json
            fi
            touch $directory/replaced
        fi ;;
esac
if [[ -n $phase && -f $directory/gate && $phase == "$(<$directory/gate)" ]]; then
    print -r -- $$ > $directory/ready
    while [[ ! -f $directory/release ]]; do
        zselect -t 1
    done
fi
case $tool in
    (curl)
        integer result=0
        [[ ! -f $directory/status.$index ]] || result=$(<$directory/status.$index)
        typeset response=$directory/response.$index.json
        [[ -f $response ]] || response=$directory/response.json
        /bin/cat $response > $destination
        if [[ -f $directory/headers ]]; then
            /bin/cat $directory/headers > $headers
        else
            print -r -- $'HTTP/1.1 200 OK\r\n\r\n' > $headers
        fi
        if [[ -f $directory/http ]]; then
            /bin/cat $directory/http
        else
            print -rn -- 200
        fi
        exit $result ;;
    (mv)
        [[ ! -f $directory/fail || $phase != "$(<$directory/fail)" ]] || exit 1
        exec /bin/mv "$@" ;;
    (jq) exec $POSTCARD_TEST_JQ "$@" ;;
esac
