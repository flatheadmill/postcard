include "decimal";
include "sent";
($after | decimal) as $boundary |
($records | split("\u0000")[:-1]) as $files |
[range(0; $files | length; 2) as $i |
    {coordinate:$files[$i], receipt:($files[$i+1] | fromjson)}] as $receipts |
# A path hit is only a candidate. Every newer message needs complete matching
# proof, including repeated coordinates with contradictory observed metadata.
all($receipts[]; (.receipt | sent) and .coordinate == .receipt.ts) and
all(.messages[] | select((.ts | decimal) > $boundary);
    . as $message |
    any($receipts[].receipt;
        .binding.team_id == $team and .channel == $channel and .ts == $message.ts
        and .slug == $slug
        and (if .thread_ts == null then .ts == $parent else .thread_ts == $parent end)
        and ($message.user == null or $message.user == .binding.user_id)
        and ($message.team == null or $message.team == .binding.team_id)
        and ($message.channel == null or $message.channel == .channel)))
