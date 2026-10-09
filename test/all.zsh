#!/usr/bin/env zsh

emulate -L zsh -o pipefail

typeset root=${ZSH_ARGZERO:A:h:h}

$root/test/login.zsh || exit
$root/test/oauth.zsh || exit
$root/test/search.zsh || exit
$root/test/thread.zsh
