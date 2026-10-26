def require($condition): if $condition then . else error("invalid fetch response") end;
require(length == 1) | .[0] | require(type == "object" and .ok == true) |
if $method == "auth.test" then
    require(.team_id == $team and .user_id == $user and .bot_id == null) | true
elif $method == "files.info" then
    .file | require(type == "object" and .id == $file and .is_external == false
        and (.mode == "hosted" or .mode == "snippet")
        and (.external_type == null or .external_type == "")) |
    require(.size | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .) |
    (.url_private_download // .url_private) as $url |
    # This deliberately accepts one origin and a config-safe URL alphabet.
    # No userinfo, port, prefix match, control byte or curl-config quoting.
    require($url | type == "string" and
        test("\\Ahttps://files[.]slack[.]com/[A-Za-z0-9_/?=&%+.,~!$():;@*-]+\\z")) |
    {id,size,url:$url}
else error("unknown fetch method") end
