#!/bin/zsh -f

# The real command runs against fictional transport. Gates pause actual child
# boundaries so publication and cancellation do not depend on lucky timing.
setopt pipefail no_bgnice
zmodload zsh/zselect zsh/datetime
typeset tool=${ZSH_ARGZERO:t} phase=''
if [[ $tool == curl && -n $POSTCARD_TEST_POST ]]; then
    exec ${0:A:h}/post-curl.zsh "$@"
fi
typeset -a calls
integer index
case $tool in
    (curl)
        calls=( $POSTCARD_TEST_WATCH/request.*.json(N) )
        index=$(( $#calls + 1 ))
        printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' \
            > $POSTCARD_TEST_WATCH/request.$index.json
        /bin/cat > $POSTCARD_TEST_WATCH/header.$index
        print -r -- $EPOCHREALTIME > $POSTCARD_TEST_WATCH/start.$index
        phase=curl-$index ;;
    (jq)
        for (( index=1; index <= $#; index++ )); do
            if [[ $argv[index] == -f ]]; then
                phase=${argv[index+1]:t:r}
                calls=( $POSTCARD_TEST_WATCH/$phase.*.started(N) )
                phase+=-$(( $#calls + 1 ))
                break
            fi
        done ;;
esac
[[ -z $phase ]] || print -r -- $$ > $POSTCARD_TEST_WATCH/${phase%-*}.${phase##*-}.started
if [[ -n $phase && $phase == $POSTCARD_TEST_WATCH_GATE ]]; then
    if [[ $POSTCARD_TEST_WATCH_AFTER == 1 ]]; then
        $POSTCARD_TEST_JQ "$@" || exit
    fi
    print -r -- $$ > $POSTCARD_TEST_WATCH/ready
    while [[ ! -e $POSTCARD_TEST_WATCH/release ]]; do
        zselect -t 1
    done
    [[ $POSTCARD_TEST_WATCH_AFTER != 1 ]] || exit 0
fi
case $tool in
    (curl)
        print -r -- $EPOCHREALTIME > $POSTCARD_TEST_WATCH/end.$index
        exec /bin/cat $POSTCARD_TEST_WATCH/page.$index.json ;;
    (jq) exec $POSTCARD_TEST_JQ "$@" ;;
esac
