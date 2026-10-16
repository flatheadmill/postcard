# A copied Slack permalink carries either an explicit thread_ts query value or
# a packed message timestamp. The latter is only an asserted parent; thread and
# post retain responsibility for checking it before depending on that address.
def timestamp: type == "string" and test("\\A[0-9]+[.][0-9]+\\z");
def query_timestamp:
    ascii_downcase |
    gsub("%2e"; ".") |
    gsub("%30"; "0") | gsub("%31"; "1") | gsub("%32"; "2") |
    gsub("%33"; "3") | gsub("%34"; "4") | gsub("%35"; "5") |
    gsub("%36"; "6") | gsub("%37"; "7") | gsub("%38"; "8") |
    gsub("%39"; "9");

$permalink | capture(
    "\\Ahttps://[^/?#@[:space:][:cntrl:]]+/archives/" +
    "(?<channel>[CDG][A-Z0-9]+)/p(?<packed>[0-9]{7,})" +
    "(?:[?](?<query>[^#[:cntrl:]]*))?\\z"
) as $match |
($match.query // "" | split("&") |
    map(select(startswith("thread_ts=")) | ltrimstr("thread_ts=") | query_timestamp)) as $parents |
if ($parents | length) > 1 then error("duplicate thread_ts")
elif ($parents | length) == 1 then
    $parents[0] | if timestamp then {channel:$match.channel,ts:.} else error("invalid thread_ts") end
else
    {channel:$match.channel,ts:($match.packed[0:-6] + "." + $match.packed[-6:])}
end
