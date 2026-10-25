include "sent";
{version:1, binding:{client_id:$client,team_id:$team,user_id:$user},
 channel:$channel, ts:$posted,
 thread_ts:(if $parent == "" then null else $parent end),
 slug:(if $slug == "" then null else $slug end)} | select(sent)
