# Completion proves the full file set independently of optional share evidence.
# Only one matching share per file, all at the same coordinate and by the
# checked sender, can establish a local own-post receipt.
def require($condition): if $condition then . else error("invalid file response") end;
def timestamp: type == "string" and test("\\A[0-9]+[.][0-9]+\\z");
def shares:
    try [.shares.public[$channel][]?, .shares.private[$channel][]?] catch [];
def coordinate:
    try (shares | select(length == 1) | .[0] |
    select((.ts | timestamp) and .share_user_id == $user and
        (if $parent == "" then (.thread_ts == null or .thread_ts == "" or .thread_ts == .ts)
         else .thread_ts == $parent and .ts != $parent end)) | .ts) catch empty;

require(length == 1) | .[0] | require(type == "object" and .ok == true) |
if $method == "files.getUploadURLExternal" then
    require(.file_id | type == "string" and test("\\AF[A-Z0-9]+\\z")) |
    require(.upload_url | type == "string" and
        test("\\Ahttps://files[.]slack[.]com/upload/v1/[A-Za-z0-9_/?=&%+.-]+\\z")) |
    {id:.file_id,url:.upload_url}
elif $method == "files.completeUploadExternal" then
    require(.files | type == "array") |
    require((.files | map(.id) | sort) == ($expected | map(.id) | sort)) |
    ([.files[] | coordinate]) as $coordinates |
    (if ($coordinates | length) == ($expected | length) and ($coordinates | unique | length) == 1
     then $coordinates[0] else null end) as $posted |
    {account:$account,team_id:$team,user_id:$user,
     requested:{channel:$channel,thread_ts:(if $parent == "" then null else $parent end)},
     files:$expected,channel:(if $posted then $channel else null end),ts:$posted,
     thread_ts:(if $posted and $parent != "" then $parent else null end),
     sender:(if $posted then $user else null end),permalink:null}
elif $method == "chat.getPermalink" then
    require(.channel == $channel and (.permalink | type == "string")) |
    .permalink |
    require(test("\\Ahttps://[^/?#[:space:][:cntrl:]]+/archives/" + $channel + "/p" + ($posted | gsub("\\."; "")) + "([?][^[:space:][:cntrl:]]*)?\\z"))
else error("unknown file method") end
