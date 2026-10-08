# A page is accepted as a whole. Do not coerce malformed addresses or text,
# discard an invalid match, or reconstruct totals from the matches we received.
def require($condition): if $condition then . else error("invalid search response") end;
def integer: type == "number" and floor == .;
def nonnegative: integer and . >= 0;
def address: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

# Map only the four shared facts. Missing fields stay missing, so disagreement
# checks can distinguish an absent secondary value from a supplied null.
def pagination:
    to_entries | map(
        .key as $key |
        {per_page:"count", page:"page", page_count:"pages", total_count:"total"}[$key] as $mapped |
        select($mapped != null) | .key = $mapped
    ) | from_entries;

require(length == 1) | .[0] | require(type == "object") |
if .ok == false then
    if .error == "token_expired" or .error == "invalid_auth" then "" | halt_error(10)
    elif .error == "ratelimited" then "" | halt_error(11)
    elif .error == "missing_scope" then "" | halt_error(12)
    else error("search failed") end
else require(.ok == true) end |
.messages | require(type == "object") |
require(.matches | type == "array") |
(if has("pagination") then .pagination | require(type == "object") | pagination else null end) as $mapped |
(if has("paging") then .paging else $mapped end) as $paging |
require($paging | type == "object") |
require(($paging.count | integer and . >= 1 and . <= 100)
    and ($paging.page | nonnegative) and ($paging.pages | nonnegative)
    and ($paging.total | nonnegative)) |
require(if has("paging") and $mapped != null then
    all($mapped | keys[]; . as $key | $mapped[$key] == $paging[$key])
else true end) |
require(if has("total") then .total == $paging.total else true end) |
require((.matches | length) <= $count and (.matches | length) <= $paging.count
    and (.matches | length) <= $paging.total) |
# Empty searches have more than one zero-page convention. Preserve what was
# reported. Nonempty totals must identify the requested page; never silently
# return a different page or infer page counts with ceiling arithmetic.
require(if $paging.total == 0 then
    ($paging.page == 0 or $paging.page == $page)
    and ($paging.pages == 0 or $paging.pages == $page)
else $paging.page == $page and $paging.pages >= $page end) |
{
    account: $account, team_id: $team, user_id: $user, query: $query,
    paging: ($paging | {count, page, pages, total}),
    matches: [.matches[] | require(type == "object") |
        require((.channel | type == "object") and (.channel.id | address)
            and (.ts | address) and (.text | type == "string")) |
        require(.thread_ts == null or (.thread_ts | address)) |
        {channel: .channel.id, ts, thread_ts: (.thread_ts // null), text}]
}
