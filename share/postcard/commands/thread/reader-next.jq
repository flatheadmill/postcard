# Refuse exhaustion of jq's exact integer range before delivery.
select(.generation < 9007199254740991) |
{version:1, binding:{client_id:$client, team_id:.team_id, user_id:.user_id},
 channel, ts, through, generation:(.generation + 1)}
