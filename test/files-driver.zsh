#!/bin/zsh -f

# The CLI is covered by files.zsh. This driver identifies the actual builtin
# stdout writer in a full-pipe fixture without adding hooks to product code.
typeset root=${ZSH_ARGZERO:A:h:h}
zmodload zsh/parameter zsh/system
fpath=( $root/share/postcard/functions ${commands[zshctl]:A:h:h}/share/zshctl/functions $fpath )
autoload -Uz warn abend postcard_account_read postcard_grant_check postcard_sent_directory postcard_label_check
typeset -A zshctl=(argzero $root/bin/postcard)
source $root/bin/postcard
source $root/share/postcard/commands/post/command.zsh
typeset o_account=widgets o_model=Codex o_channel=C012TARGET o_ts=1.000000
typeset -a o_attach=( $POSTCARD_TEST_FILES/source $POSTCARD_TEST_FILES/second )
typeset account_grant renewal_health renewal_message postcard_account_cleanup=''
integer grant_usable=0
function print {
    if [[ $argv[1] == -r && $argv[-1] == '{"account":'* && $argv[-1] == *'"files":'* ]]; then
        builtin print -r -- $sysparams[pid] > $POSTCARD_TEST_FILES/writer
    fi
    builtin print "$@"
}
:execute:post
