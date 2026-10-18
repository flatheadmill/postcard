#!/bin/zsh -f

# Fictional transport and fault boundaries, selected by the tool's symlink.
setopt pipefail no_bgnice
zmodload zsh/zselect zsh/system
typeset tool=${ZSH_ARGZERO:t} phase=''
integer index
case $tool in
    (curl)
        typeset -a calls=( $POSTCARD_TEST_READER/request.*.json(N) )
        index=$(( $#calls + 1 ))
        printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' \
            > $POSTCARD_TEST_READER/request.$index.json
        /bin/cat > $POSTCARD_TEST_READER/header.$index
        if [[ -n $POSTCARD_TEST_REPLACEMENT && $index == 1 ]]; then
            /bin/cp $POSTCARD_TEST_REPLACEMENT $POSTCARD_TEST_CREDENTIALS.next || exit
            /bin/mv $POSTCARD_TEST_CREDENTIALS.next $POSTCARD_TEST_CREDENTIALS || exit
        fi
        phase=curl-$index ;;
    (jq)
        for (( index=1; index <= $#; index++ )); do
            if [[ $argv[index] == -f ]]; then
                phase=${argv[index+1]:t:r}
                break
            fi
        done ;;
    (cat) [[ $argv[-1] == */output ]] && phase=output ;;
    (mv) [[ $argv[-1] == */readers/*.json ]] && phase=publish ;;
esac

[[ $phase != output ]] || print -r -- $$ > $POSTCARD_TEST_READER/output-started
if [[ -n $phase && $phase == $POSTCARD_TEST_FAULT ]]; then
    exit 71
fi
if [[ -n $phase && $phase == $POSTCARD_TEST_GATE ]]; then
    # For the post-rename boundary the new checkpoint is already visible.
    if [[ $phase == publish && $POSTCARD_TEST_AFTER_RENAME == 1 ]]; then
        /bin/mv "$@" || exit
    fi
    print -r -- $$ > $POSTCARD_TEST_READER/ready
    while [[ ! -e $POSTCARD_TEST_READER/release ]]; do
        zselect -t 2
    done
    [[ $phase != publish || $POSTCARD_TEST_AFTER_RENAME != 1 ]] || exit 0
fi

case $tool in
    (curl)
        [[ ! -f $POSTCARD_TEST_READER/status.$index ]] || exit $(<$POSTCARD_TEST_READER/status.$index)
        exec /bin/cat $POSTCARD_TEST_READER/page.$index.json ;;
    (jq) exec $POSTCARD_TEST_JQ "$@" ;;
    (cat) exec /bin/cat "$@" ;;
    (mv) exec /bin/mv "$@" ;;
esac
