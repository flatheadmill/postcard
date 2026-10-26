def text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
def seconds: type == "number" and . > 0 and . <= (9007199254740991 - $started) and floor == .;
select(length == 2) | .[0] as $old | .[1] |
select(type == "object" and .ok == true and .token_type == "user") |
select((.access_token | text) and (.refresh_token | text) and (.expires_in | seconds)) |
select(if has("client_id") then .client_id == $old.client_id else true end) |
select(if has("team") then .team.id == $old.team_id else true end) |
select(if has("team_id") then .team_id == $old.team_id else true end) |
select(if has("id") then .id == $old.user_id else true end) |
select(if has("user_id") then .user_id == $old.user_id else true end) |
select(if has("authed_user") then .authed_user.id == $old.user_id else true end) |
select(if has("is_enterprise_install") then .is_enterprise_install == false else true end) |
select(if has("scope") then .scope | text else true end) |
. as $new | $old + {
    access_token: $new.access_token, refresh_token: $new.refresh_token,
    expires_at: ($started + $new.expires_in), scope: ($new.scope // $old.scope)
} | del(.renewal_pending, .renewal_after)
