# Each response is one complete document. Only deliberately selected fields
# leave this filter; raw Slack errors may contain credentials or message text.
def require($condition): if $condition then . else error("invalid post response") end;
def timestamp: type == "string" and test("\\A[0-9]+[.][0-9]+\\z");
def conversation: type == "string" and test("\\A[CDG][A-Z0-9]+\\z");
def text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
def optional_text: . == null or . == "" or text;
def binding($condition): if $condition then . else "" | halt_error(13) end;

require(length == 1) | .[0] | require(type == "object") |
if .ok == false then
    require(.error | type == "string") | .error as $error |
    if .error == "token_expired" or .error == "invalid_auth" or .error == "token_revoked" or .error == "not_authed" then "" | halt_error(10)
    elif .error == "ratelimited" or .error == "rate_limited" then "" | halt_error(11)
    elif .error == "missing_scope" then "" | halt_error(12)
    # These are refusals. Slack documents internal_error and fatal_error as
    # possibly following partial success; unfamiliar failures stay uncertain.
    elif $method == "chat.postMessage" and ([
        "channel_not_found", "not_in_channel", "is_archived", "no_text", "invalid_blocks",
        "invalid_blocks_format", "cannot_reply_to_message", "thread_not_found", "no_permission",
        "restricted_action", "restricted_action_read_only_channel", "restricted_action_thread_locked",
        "restricted_action_non_threadable_channel", "restricted_action_thread_only_channel"
    ] | index($error)) then .error | halt_error(15)
    else error("Slack request failed") end
else require(.ok == true) end |
if $method == "auth.test" then
    binding(.team_id == $team and .user_id == $user and .bot_id == null) | true
elif $method == "users.info" then
    require(.user | type == "object") |
    binding(.user.id == $user and (.user.team_id == null or .user.team_id == $team)
        and (.user.deleted == null or .user.deleted == false)
        and (.user.is_bot == null or .user.is_bot == false)
        and (.user.is_app_user == null or .user.is_app_user == false)) |
    .user | require(.profile | type == "object") |
    require(all(.profile.display_name, .profile.real_name, .name; optional_text)) |
    first(.profile.display_name, .profile.real_name, .name, .id | select(text))
elif $method == "conversations.open" then
    require(.channel | type == "object") |
    binding((.channel.id | type == "string" and test("\\AD[A-Z0-9]+\\z"))
        and .channel.is_im == true and .channel.user == $recipient) | .channel.id
elif $method == "conversations.replies" then
    require(.messages | type == "array" and length == 1) |
    require(.messages[0] | type == "object") |
    binding(.messages[0].ts == $ts and
        (.messages[0].thread_ts == null or .messages[0].thread_ts == "" or .messages[0].thread_ts == $ts)) | true
elif $method == "chat.postMessage" then
    require((.channel | conversation) and (.ts | timestamp)) |
    # The safe address survives a disputed receipt as a diagnostic, never as
    # success. Missing reply evidence is not replaced with the requested ts.
    (.channel + " " + .ts) as $address |
    if .channel == $channel and (.message | type == "object") and
        (.message.type == null or .message.type == "message") and
        (.message.ts == null or .message.ts == .ts) and
        (.message.channel == null or .message.channel == .channel) and
        (.message.user == null or .message.user == $user) and
        (.message.team == null or .message.team == $team) and
        (if $ts == "" then .message.thread_ts == null or .message.thread_ts == "" or .message.thread_ts == .ts
         else .ts != $ts and .message.thread_ts == $ts end)
    then {account:$account, team_id:$team, user_id:$user, channel, ts,
        thread_ts:(if $ts == "" then null else .message.thread_ts end),
        sender:(.message.user // null), permalink:null}
    else $address | halt_error(14) end
elif $method == "chat.getPermalink" then
    require(.channel == $channel and (.permalink | type == "string")) |
    .permalink |
    require(test("\\Ahttps://[^/?#[:space:][:cntrl:]]+/archives/" + $channel + "/p" + ($posted | gsub("\\."; "")) + "([?][^[:space:][:cntrl:]]*)?\\z"))
else error("unknown post method") end
