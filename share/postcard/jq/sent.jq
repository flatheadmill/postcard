def sent:
    def text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    def timestamp: type == "string" and test("\\A[0-9]+[.][0-9]+\\z");
    type == "object" and keys == ["binding","channel","slug","thread_ts","ts","version"]
    and .version == 1
    and (.binding | type == "object" and keys == ["client_id","team_id","user_id"]
        and all(.[]; text))
    and (.channel | type == "string" and test("\\A[CDG][A-Z0-9]+\\z"))
    and (.ts | timestamp)
    and (.thread_ts == null or ((.thread_ts | timestamp) and .thread_ts != .ts))
    and (.slug == null or (.slug | text and length <= 64 and (test("[\u2028\u2029]") | not)));
