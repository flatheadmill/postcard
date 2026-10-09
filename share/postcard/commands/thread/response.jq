# Keep the message objects whole. Validation establishes usable addresses and
# pagination, not a transcript schema that would discard unfamiliar subtypes.
def require($condition): if $condition then . else error("invalid thread response") end;
def timestamp: type == "string" and test("\\A[0-9]+[.][0-9]+\\z");
def nullable: if . == "" then null else . end;

require(length == 1) | .[0] | require(type == "object") |
if .ok == false then
    if .error == "token_expired" or .error == "invalid_auth" or .error == "token_revoked" then "" | halt_error(10)
    elif .error == "ratelimited" then "" | halt_error(11)
    elif .error == "missing_scope" then "" | halt_error(12)
    elif .error == "invalid_cursor" then "" | halt_error(14)
    else error("thread request failed") end
else require(.ok == true) end |
require(.messages | type == "array") |
require((.messages | length) <= $count) |
require(all(.messages[]; type == "object" and (.ts | timestamp)
    and (.thread_ts == null or .thread_ts == "" or (.thread_ts | timestamp)))) |
require(if has("has_more") then .has_more | type == "boolean" else true end) |
require(.response_metadata == null or (.response_metadata | type == "object")) |
.response_metadata.next_cursor as $next |
require($next == null or ($next | type == "string")) |
($next | nullable) as $next |
# Short and empty pages may continue. The cursor determines the next request;
# a claim of more data without a cursor cannot be presented as a terminal page.
require(.has_more != true or $next != null) |
(first(.messages[].thread_ts | select(. != null and . != "" and . != $ts)) // null) as $parent |
if $parent != null then
    # The entire page was validated before this address becomes a diagnostic.
    # Missing parent evidence is allowed; contradictory evidence is not.
    $parent | halt_error(13)
else {
    account: $account, team_id: $team, user_id: $user,
    channel: $channel, ts: $ts, after: ($after | nullable),
    paging: {count: $count, cursor: ($cursor | nullable), next_cursor: $next},
    messages
} end
