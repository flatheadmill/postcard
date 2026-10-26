#!/usr/bin/env zsh

emulate -L zsh -o pipefail

typeset root=${ZSH_ARGZERO:A:h:h}

$root/test/login.zsh || exit
$root/test/oauth.zsh || exit
$root/test/renewal.zsh || exit
$root/test/search.zsh || exit
$root/test/alias.zsh || exit
$root/test/thread.zsh || exit
$root/test/reader.zsh || exit
$root/test/watch.zsh || exit
$root/test/post.zsh
