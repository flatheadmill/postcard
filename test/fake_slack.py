#!/usr/bin/env python3
"""A curl/browser stand-in. All people, workspaces, IDs, and tokens are fictional."""

import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

fixture = Path(os.environ["POSTCARD_TEST_DIR"])
scenario = os.environ.get("POSTCARD_TEST_SCENARIO", "success")
mode = Path(sys.argv[0]).name
connections = {
    "123.456": {"name": "workshop", "team": "T123ABC", "team_name": "Amalgamated Widgets", "user": "U123ABC",
                "profile": "Jane Doe", "username": "jane.doe", "access": "fixture-access-", "refresh": "fixture-refresh-"},
    "789.012": {"name": "archive", "team": "T789DEF", "team_name": "Example Archives", "user": "U789DEF",
                "profile": "John Doe", "username": "john.doe", "access": "fixture-access-other-", "refresh": "fixture-refresh-other-"},
}

if mode in ("open", "xdg-open"):
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(sys.argv[1]).query)
    assert query["client_id"][0] in connections
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
form_methods = ("oauth.v2.access", "users.info", "search.messages", "conversations.replies",
                "chat.getPermalink")
if method in form_methods:
    assert "Content-Type: application/x-www-form-urlencoded" in sys.argv
    fields = urllib.parse.parse_qs(body, keep_blank_values=True, strict_parsing=True)
    assert all(len(values) == 1 for values in fields.values())
    body = {k: v[0] for k, v in fields.items()}
    if method == "conversations.replies":
        body["limit"] = int(body["limit"])
        if "inclusive" in body:
            assert body["inclusive"] in ("true", "false")
            body["inclusive"] = body["inclusive"] == "true"
else:
    body = json.loads(body)
if method != "oauth.v2.access":
    header_paths = [sys.argv[i + 1][1:] for i, arg in enumerate(sys.argv[:-1])
                    if arg == "--header" and sys.argv[i + 1].startswith("@")]
    assert len(header_paths) == 1
    header = Path(header_paths[0]).read_text()
    token = header.removeprefix("Authorization: Bearer ").strip()
    matching = [item for item in connections.values() if token in (item["access"] + "old", item["access"] + "new")]
    assert len(matching) == 1
    connection = matching[0]
else:
    assert body["client_id"] in connections
    connection = connections[body["client_id"]]
user = "U999ZZZ" if scenario == "different_user" else connection["user"]
team = "T999ZZZ" if scenario == "different_team" else connection["team"]

with (fixture / "requests.jsonl").open("a") as stream:
    # Public parameters only. Even the fixture never logs OAuth credentials.
    stream.write(json.dumps({"method": method, "connection": connection["name"], "encoding": "form" if method in form_methods else "json", "at": time.monotonic(), "pid": os.getpid(), "body": body if method != "oauth.v2.access"
                             else {"grant_type": body["grant_type"]}}) + "\n")

# Tests may script observation responses independently of the thread fixture.
# This is local fake transport, never an actual Slack request.
scripted = fixture / "responses.json"
if scripted.exists():
    plan = json.loads(scripted.read_text())
    if method in plan:
        calls = [json.loads(line) for line in (fixture / "requests.jsonl").read_text().splitlines()]
        index = sum(call["method"] == method for call in calls) - 1
        steps = plan[method]
        step = steps[min(index, len(steps) - 1)] if steps else None
        if step is not None:
            if step.get("wait"):
                if step.get("stop_wait"):
                    def stop(number, _frame):
                        (fixture / "http-stopping").touch()
                        while not (fixture / "http-release").exists():
                            time.sleep(0.01)
                        sys.exit(128 + number)
                    signal.signal(signal.SIGTERM, stop)
                (fixture / "http-waiting").write_text(str(os.getpid()))
                while not (fixture / "http-release").exists():
                    time.sleep(0.01)
            if "--dump-header" in sys.argv:
                header_file = Path(sys.argv[sys.argv.index("--dump-header") + 1])
                header_file.write_text(f"HTTP/1.1 {step.get('status', 200)} Fake\r\n" +
                                      (f"Retry-After: {step['retry_after']}\r\n" if "retry_after" in step else "") + "\r\n")
            if "exit" in step:
                sys.exit(step["exit"])
            response = step.get("raw", json.dumps(step.get("body", {"ok": True, "messages": []})))
            sys.stdout.write(response + "\n" + str(step.get("status", 200)))
            sys.exit(0)

if method == "oauth.v2.access":
    assert "client_secret" not in body
    if body["grant_type"] == "refresh_token":
        assert body["refresh_token"] == connection["refresh"] + "old"
        if scenario == "refresh_barrier":
            (fixture / ("refresh-ready-" + connection["name"])).touch()
            deadline = time.monotonic() + 5
            while len(list(fixture.glob("refresh-ready-*"))) < 2:
                assert time.monotonic() < deadline, "another account could not enter renewal independently"
                time.sleep(0.01)
        if scenario == "refresh_failure":
            result = {"ok": False, "error": "invalid_refresh_token"}
        else:
            time.sleep(0.15)  # Let a second CLI contend for the lock.
            result = {"ok": True, "token_type": "user", "access_token": connection["access"] + "new",
                      "expires_in": 43200, "refresh_token": connection["refresh"] + "new"}
    else:
        assert body["code"] == "fixture-authorization-code"
        assert body["redirect_uri"] == "http://localhost:8765/auth"
        verifier = body["code_verifier"]
        assert 43 <= len(verifier) <= 128
        actual = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
        expected = json.loads((fixture / "authorization.json").read_text())["code_challenge"][0]
        assert actual == expected
        scopes = json.loads((fixture / "authorization.json").read_text())["user_scope"][0]
        grant = {"id": user, "scope": scopes, "token_type": "user",
                 "access_token": connection["access"] + "old"}
        if scenario == "rotating_login":
            grant.update(expires_in=43200, refresh_token=connection["refresh"] + "old", refresh_expires_in=2592000)
        if scenario == "missing_scope":
            grant["scope"] = "chat:write"
        if scenario == "bot_grant":
            grant["token_type"] = "bot"
        result = {"ok": True, "app_id": "A123ABC", "team": {"id": team, "name": connection["team_name"]},
                  "authed_user": grant}
elif method == "auth.test":
    result = {"ok": True, "team_id": team, "team": connection["team_name"],
              "url": "https://" + connection["name"] + ".slack.example/",
              "user_id": "U999ZZZ" if scenario == "identity_mismatch" else user}
elif method == "users.info":
    requested = body["user"]
    if requested == user:
        name = "Updated profile" if scenario == "renamed_profile" else connection["profile"]
        if scenario == "literal_profile":
            name = "  Jane\n  <@U456DEF> & *Doe*  "
        username = connection["username"]
    else:
        assert requested == "U456DEF"
        name, username = "Casey Lee", "casey.lee"
    result = {"ok": True, "user": {"id": requested, "name": username, "is_bot": False,
                                   "profile": {"display_name": name, "real_name": name + " Example"}}}
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
                             "permalink": "https://workshop.slack.example/archives/C123ABC/p1700000000000002",
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
        result = {"ok": True, "channels": [{"id": "D123ABC", "is_im": True, "user": user}],
                  "response_metadata": {"next_cursor": ""}}
elif method == "chat.postMessage":
    (fixture / "message.json").write_text(json.dumps(body))
    if scenario == "post_timeout":
        sys.exit(28)
    result = {"ok": True, "channel": body["channel"], "ts": "1700000000.000002",
              "message": {"user": user, "text": body["text"]}}
elif method == "chat.getPermalink":
    assert set(body) == {"channel", "message_ts"}
    assert body["channel"] == "D123ABC"
    assert body["message_ts"] == "1700000000.000002"
    result = ({"ok": False, "error": "ratelimited"} if scenario == "permalink_failure" else
              {"ok": True, "permalink": "https://workshop.slack.example/archives/D123ABC/p1700000000000002"})
elif method == "conversations.replies" and (fixture / "thread.json").exists():
    thread = json.loads((fixture / "thread.json").read_text())
    assert body["limit"] == 200
    assert body["ts"] == thread.get("parent", "1700000000.000000")
    assert body["channel"] == thread.get("channel", "C123ABC")
    page = int(body.get("cursor", "page-0").removeprefix("page-"))
    if page == thread.get("fail_page"):
        result = {"ok": False, "error": "ratelimited"}
    elif page == thread.get("timeout_page"):
        sys.exit(28)
    elif "pages" in thread:
        result = thread["pages"][page]
    else:
        key = lambda message: tuple(int(part) for part in message["ts"].split("."))
        messages = sorted(thread["messages"], key=key)
        if "oldest" in body and not thread.get("ignore_bounds"):
            boundary = tuple(int(part) for part in body["oldest"].split("."))
            messages = [message for message in messages if key(message) > boundary or
                        (body["inclusive"] and key(message) == boundary)]
        size = min(body["limit"], thread.get("page_size", 200))
        start = page * size
        result = {"ok": True, "messages": messages[start:start + size],
                  "response_metadata": {"next_cursor": f"page-{page + 1}" if start + size < len(messages) else ""}}
elif method in ("conversations.history", "conversations.replies"):
    assert body["oldest"] == body["latest"] == "1700000000.000002"
    assert body["inclusive"] is True
    if method == "conversations.replies":
        assert body["ts"] == "1700000000.000001"
    result = {"ok": True, "messages": [{"ts": "1700000000.000002" if scenario != "nearby_message"
                                       else "1700000000.000003", "user": user, "text": "A carded message"}]}
else:
    raise AssertionError(method)

sys.stdout.write(json.dumps(result) + "\n200")
