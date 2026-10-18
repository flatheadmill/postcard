# Compare decimal strings by value without a floating-point conversion. Strip
# insignificant zeroes for comparison only; delivered objects keep their text.
def decimal:
    split(".") | (.[0] | sub("^0+"; "") | if . == "" then "0" else . end) as $integer |
    [$integer | length] + [$integer, (.[1] | sub("0+$"; ""))];

($after | decimal) as $boundary |
[.[].messages[] | select((.ts | decimal) > $boundary)] as $messages |
# Strict comparison retains the first observed spelling when maxima tie.
(reduce $messages[] as $message ({key:$boundary, through:$after};
    ($message.ts | decimal) as $key |
    if $key > .key then {key:$key, through:$message.ts} else . end)) as $maximum |
{account:$account, team_id:$team, user_id:$user, reader:$reader,
 channel:$channel, ts:$ts, generation:$generation, after:$after,
 through:$maximum.through, messages:$messages}
