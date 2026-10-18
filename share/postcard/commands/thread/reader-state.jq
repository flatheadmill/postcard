def timestamp: type == "string" and test("\\A[0-9]+[.][0-9]+\\z");
select(length == 1) | .[0] |
select(type == "object" and keys == ["binding","channel","generation","through","ts","version"]
    and .version == 1
    and .binding == {client_id:$client,team_id:$team,user_id:$user}
    and (.channel | type == "string" and test("\\A[CDG][A-Z0-9]+\\z"))
    and (.ts | timestamp) and (.through | timestamp)
    and (.generation | type == "number" and . >= 1 and . <= 9007199254740991 and floor == .)) |
.channel, .ts, .through, (.generation | tostring)
