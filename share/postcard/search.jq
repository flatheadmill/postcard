# Input is the stored credential record and one Slack response, over stdin.
# Only the explicit public identity fields below leave this filter.
def optional_text:
    if type == "string" then . else null end;
def optional_name:
    if type == "string" and length > 0 then . else null end;
def matches_pattern($pattern):
    if type == "string" then test($pattern) else false end;
def optional_id($pattern):
    if matches_pattern($pattern) then . else null end;
def timestamp: "^[0-9]+\\.[0-9]{6}\\z";
def integer_at_least($minimum):
    if type == "number" then . >= $minimum and . == floor else false end;
def equivalent($values; $minimum):
    [$values[] | select(. != null)] as $present |
    if all($present[]; integer_at_least($minimum)) and
       ($present | unique | length) <= 1
    then $present[0]
    else error("invalid or conflicting pagination metadata") end;
def optional_object:
    if . == null or type == "object" then .
    else error("invalid pagination object") end;
def match:
    if type != "object" then error("invalid search match") else . end |
    if (.channel | type) != "object" then error("invalid channel") else . end |
    if (.channel.id | matches_pattern("^[CDG][A-Z0-9]+\\z")) and
       (.ts | matches_pattern(timestamp))
    then {
        channel:.channel.id,
        channel_name:(.channel.name | optional_name),
        ts,
        thread_ts:(.thread_ts | optional_id(timestamp)),
        sender:(.user | optional_id("^[UW][A-Z0-9]+\\z")),
        permalink:(.permalink | optional_name),
        text:(.text | optional_text),
        type:(.type | optional_name),
        subtype:(.subtype | optional_name),
        bot_id:(.bot_id | optional_id("^B[A-Z0-9]+\\z")),
        app_id:(.app_id | optional_id("^A[A-Z0-9]+\\z"))
    } else error("invalid exact search address") end;

if length != 2 then error("expected one Slack response") else . end |
.[0] as $record | .[1] |
if type != "object" then error("invalid Slack response") else . end |
.query as $echo | .messages |
if type != "object" then error("missing search messages") else . end |
if (.matches | type) != "array" then error("missing search matches") else . end |
if (.matches | length) > $count then error("search exceeded requested count") else . end |
(.paging | optional_object) as $paging |
(.pagination | optional_object) as $pagination |
(equivalent([$paging.page, $pagination.page]; 1) // $page) as $actual_page |
# Live empty results have paging.count=0 and pagination.per_page=5. The
# legacy count is not a reliable capacity field; returned is measured below.
(equivalent([$pagination.per_page]; 1) // $count) as $per_page |
equivalent([.total, $paging.total, $pagination.total_count]; 0) as $total |
equivalent([$paging.pages, $pagination.page_count]; 0) as $pages |
(if $pages != null then $actual_page < $pages
 elif $total != null then $actual_page * $per_page < $total
 else null end) as $has_more |
{
    team:{id:$record.team.id, name:($record.team.name | optional_name)},
    user:{id:$record.user.id, name:($record.user.name | optional_name),
          username:($record.user.username | optional_name)},
    query:($echo | optional_text),
    requested_query:$requested_query,
    text_format:"slack",
    sort:"timestamp",
    sort_dir:"desc",
    pagination:{
        page:$actual_page, per_page:$per_page, returned:(.matches | length),
        total:$total, pages:$pages, has_more:$has_more,
        next_page:(if $has_more == true and $actual_page < 100
                   then $actual_page + 1 else null end)
    },
    matches:(.matches | map(match))
}
