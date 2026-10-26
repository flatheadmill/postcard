#!/bin/zsh -f

# Fictional API, byte streams and process boundaries. No endpoint is contacted.
setopt pipefail no_bgnice
zmodload zsh/zselect
typeset tool=${ZSH_ARGZERO:t} phase='' output_file='' format='' config='' data='' url='' response
typeset argument option base=$POSTCARD_TEST_FILES
integer index
case $tool in
    (curl)
        printf '%s\0' "$@" | $POSTCARD_TEST_JQ -Rs 'split("\u0000")[:-1]' > $base/argv.next
        for (( index=1; index <= $#; index++ )); do
            case $argv[index] in
                (--output) output_file=$argv[index+1] ;;
                (--write-out) format=$argv[index+1] ;;
                (--config) config=$argv[index+1] ;;
                (--data-binary) data=$argv[index+1] ;;
            esac
        done
        if [[ -n $config ]]; then
            url=$(<$config)
            if [[ $url == *'/upload/v1/'* ]]; then
                phase=bytes-${${url##*/}%\"}
                /bin/cat > $base/$phase.body
            else
                phase=download
                /bin/cat > $base/$phase.header
            fi
        else
            phase=${argv[-1]:t}
            [[ $argv[-1] == https://slack.com/api/$phase ]] || exit 99
            /bin/cat > $base/$phase.header
            if [[ $data == @* && $data != @- ]]; then
                /bin/cat -- ${data#@} > $base/$phase.body
            fi
            if [[ $phase == files.getUploadURLExternal ]]; then
                integer count=1
                [[ ! -f $base/allocations ]] || count=$(( $(<$base/allocations) + 1 ))
                print -r -- $count > $base/allocations
                phase=allocate-$count
            fi
        fi
        /bin/mv $base/argv.next $base/$phase.argv.json
        print -r -- "$phase" >> $base/calls
        if [[ $phase == allocate-1 && -f $base/replace-input ]]; then
            /bin/mv -- $base/replacement $base/source
        fi
        ;;
    (ln)
        [[ $argv[-1] != $base/destination* ]] || phase=publish
        [[ $argv[-1] != */postcard/sent/* ]] || phase=sent
        ;;
    (cat) [[ $argv[-1] == */.postcard.fetch.*/receipt ]] && phase=output ;;
esac

if [[ $phase == publish && -n $POSTCARD_TEST_RACE ]]; then
    case $POSTCARD_TEST_RACE in
        (file) print -r -- 'existing' > $argv[-1] ;;
        (directory) /bin/mkdir $argv[-1] ;;
        (symlink) /bin/ln -s $base/protected $argv[-1] ;;
    esac
fi
if [[ $phase == publish && $POSTCARD_TEST_AFTER_LINK == 1 ]]; then
    /bin/ln "$@" || exit
fi
if [[ -n $phase && $phase == $POSTCARD_TEST_GATE ]]; then
    print -r -- $$ > $base/ready
    while [[ ! -e $base/release ]]; do
        zselect -t 2
    done
fi
[[ -z $phase || $phase != $POSTCARD_TEST_FAULT ]] || exit 71
case $tool in
    (curl)
        if [[ $phase == bytes-* ]]; then
            response=/dev/null
        elif [[ $phase == download ]]; then
            response=$base/download.body
        else
            response=$base/$phase.json
        fi
        if [[ -n $output_file ]]; then
            /bin/cat -- $response > $output_file || exit
        else
            /bin/cat -- $response || exit
        fi
        [[ ! -f $base/$phase.status ]] || exit $(<$base/$phase.status)
        if [[ -n $format ]]; then
            typeset http=200
            [[ ! -f $base/$phase.http ]] || http=$(<$base/$phase.http)
            print -rn -- "$http"
            if [[ $format == *size_upload* ]]; then
                zmodload zsh/stat
                typeset -A attributes
                zstat -H attributes -- $base/$phase.body || exit
                [[ ! -f $base/$phase.size ]] || attributes[size]=$(<$base/$phase.size)
                print -rn -- " $attributes[size]"
            fi
        fi
        ;;
    (ln) [[ $POSTCARD_TEST_AFTER_LINK != 1 || $phase != publish ]] || exit 0
         exec /bin/ln "$@" ;;
    (cat) exec /bin/cat "$@" ;;
esac
