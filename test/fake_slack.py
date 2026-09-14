#!/usr/bin/env python3
"""A curl/browser stand-in. Uses fictional tokens and never contacts Slack."""

import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

fixture = Path(os.environ["POSTCARD_TEST_DIR"])
scenario = os.environ.get("POSTCARD_TEST_SCENARIO", "success")
mode = Path(sys.argv[0]).name

if mode in ("open", "xdg-open"):
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(sys.argv[1]).query)
    assert query["client_id"] == ["123.456"]
    assert query["code_challenge_method"] == ["S256"]
    assert "client_secret" not in query
    (fixture / "authorization.json").write_text(json.dumps(query))
    values = {"state": query["state"][0]}
    if scenario == "denied":
        values["error"] = "access_denied"
    else:
        values["code"] = "fixture-authorization-code"
    request = query["redirect_uri"][0] + "?" + urllib.parse.urlencode(values)
    try:
        urllib.request.urlopen(request, timeout=5).read()
    except urllib.error.HTTPError as error:
        assert error.code == 400 and scenario == "denied"
        error.close()
    sys.exit(0)

assert mode == "curl"
assert sys.argv[1] == "-q"
assert not any("fixture-access" in arg or "fixture-refresh" in arg
               or "fixture-authorization-code" in arg for arg in sys.argv)
assert "--retry" not in sys.argv
method = sys.argv[-1].removeprefix("https://slack.com/api/")
assert "/" not in method
body = sys.stdin.read()
if method in ("oauth.v2.access", "users.info", "search.messages"):
    assert "Content-Type: application/x-www-form-urlencoded" in sys.argv
    fields = urllib.parse.parse_qs(body, keep_blank_values=True, strict_parsing=True)
    assert all(len(values) == 1 for values in fields.values())
    body = {k: v[0] for k, v in fields.items()}
else:
    body = json.loads(body)
if method != "oauth.v2.access":
    header_paths = [sys.argv[i + 1][1:] for i, arg in enumerate(sys.argv[:-1])
                    if arg == "--header" and sys.argv[i + 1].startswith("@")]
    assert len(header_paths) == 1
    header = Path(header_paths[0]).read_text()
    assert header.startswith("Authorization: Bearer fixture-access")

with (fixture / "requests.jsonl").open("a") as stream:
    # Public parameters only. Even the fixture never logs OAuth credentials.
    stream.write(json.dumps({"method": method, "body": body if method != "oauth.v2.access"
                             else {"grant_type": body["grant_type"]}}) + "\n")

if method == "oauth.v2.access":
    assert body["client_id"] == "123.456"
    assert "client_secret" not in body
    if body["grant_type"] == "refresh_token":
        assert body["refresh_token"] == "fixture-refresh-old"
        if scenario == "refresh_failure":
            result = {"ok": False, "error": "invalid_refresh_token"}
        else:
            time.sleep(0.15)  # Let a second CLI contend for the lock.
            result = {"ok": True, "token_type": "user", "access_token": "fixture-access-new",
                      "expires_in": 43200, "refresh_token": "fixture-refresh-new"}
    else:
        assert body["code"] == "fixture-authorization-code"
        assert body["redirect_uri"] == "http://localhost:8765/auth"
        verifier = body["code_verifier"]
        assert 43 <= len(verifier) <= 128
        actual = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
        expected = json.loads((fixture / "authorization.json").read_text())["code_challenge"][0]
        assert actual == expected
        scopes = json.loads((fixture / "authorization.json").read_text())["user_scope"][0]
        grant = {"id": "U123ABC", "scope": scopes, "token_type": "user",
                 "access_token": "fixture-access-old"}
        if scenario == "rotating_login":
            grant.update(expires_in=43200, refresh_token="fixture-refresh-old", refresh_expires_in=2592000)
        if scenario == "missing_scope":
            grant["scope"] = "chat:write"
        if scenario == "bot_grant":
            grant["token_type"] = "bot"
        result = {"ok": True, "app_id": "A123ABC", "team": {"id": "T123ABC", "name": "Workshop"},
                  "authed_user": grant}
elif method == "auth.test":
    result = {"ok": True, "team_id": "T123ABC", "team": "Workshop", "url": "https://workshop.slack.com/",
              "user_id": "U999ZZZ" if scenario == "identity_mismatch" else "U123ABC"}
elif method == "users.info":
    assert body["user"] == "U123ABC"
    result = {"ok": True, "user": {"id": "U123ABC", "name": "robin", "is_bot": False,
                                   "profile": {"display_name": "Robin", "real_name": "Robin Example"}}}
elif method == "search.messages":
    assert set(body) == {"query", "count", "page", "sort", "sort_dir", "highlight"}
    assert body["query"].strip()
    assert body["sort"] == "timestamp" and body["sort_dir"] == "desc"
    assert body["highlight"] == "false"
    assert 1 <= int(body["count"]) <= 100 and 1 <= int(body["page"]) <= 100
    assert str(int(body["count"])) == body["count"]
    assert str(int(body["page"])) == body["page"]
    if scenario == "search_timeout":
        sys.exit(28)
    response_file = fixture / "search-response.json"
    if response_file.exists():
        result = json.loads(response_file.read_text())
    else:
        result = {
            "ok": True, "query": body["query"],
            "messages": {
                "matches": [{"channel": {"id": "C123ABC", "name": "general"},
                             "ts": "1700000000.000002", "user": "U456DEF",
                             "permalink": "https://workshop.slack.com/archives/C123ABC/p1700000000000002",
                             "text": "Literal &amp; <@U456DEF> *Slack* text", "type": "message"}],
                "paging": {"page": int(body["page"]), "count": int(body["count"]),
                           "pages": (41 + int(body["count"]) - 1) // int(body["count"]),
                           "total": 41},
                "total": 41,
            },
        }
elif method == "conversations.open":
    assert body["users"] == "U456DEF"
    result = {"ok": True, "channel": {"id": "D456DEF"}}
elif method == "conversations.list":
    assert body["types"] == "im"
    if body["cursor"] == "":
        result = {"ok": True, "channels": [], "response_metadata": {"next_cursor": "next-page"}}
    else:
        assert body["cursor"] == "next-page"
        result = {"ok": True, "channels": [{"id": "D123ABC", "is_im": True, "user": "U123ABC"}],
                  "response_metadata": {"next_cursor": ""}}
elif method == "chat.postMessage":
    (fixture / "message.json").write_text(json.dumps(body))
    if scenario == "post_timeout":
        sys.exit(28)
    result = {"ok": True, "channel": body["channel"], "ts": "1700000000.000002",
              "message": {"user": "U123ABC", "text": body["text"]}}
elif method == "chat.getPermalink":
    result = ({"ok": False, "error": "ratelimited"} if scenario == "permalink_failure" else
              {"ok": True, "permalink": "https://workshop.slack.com/archives/D123ABC/p1700000000000002"})
elif method in ("conversations.history", "conversations.replies"):
    assert body["oldest"] == body["latest"] == "1700000000.000002"
    assert body["inclusive"] is True
    if method == "conversations.replies":
        assert body["ts"] == "1700000000.000001"
    result = {"ok": True, "messages": [{"ts": "1700000000.000002" if scenario != "nearby_message"
                                       else "1700000000.000003", "user": "U123ABC", "text": "A carded message"}]}
else:
    raise AssertionError(method)

sys.stdout.write(json.dumps(result) + "\n200")
