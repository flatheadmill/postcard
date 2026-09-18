#!/usr/bin/env python3
"""Run with python3 -m unittest discover -s test -v. No Slack account needed."""

import concurrent.futures
import importlib.util
import json
import os
import signal
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("callback", ROOT / "share/postcard/callback.py")
callback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(callback)


class PostcardHarness(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="postcard-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        binaries = self.directory / "bin"
        binaries.mkdir()
        for name in ("curl", "open", "xdg-open"):
            (binaries / name).symlink_to(ROOT / "test/fake_slack.py")
        self.env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                        POSTCARD_DIRECTORY=str(self.directory / "config"),
                        POSTCARD_TEST_DIR=str(self.directory))
        self.credentials = self.directory / "config/accounts/workshop/credentials.json"

    def run_cli(self, *args, scenario="success", message=None):
        process = subprocess.run([str(ROOT / "bin/postcard"), *args], env=dict(
            self.env, POSTCARD_TEST_SCENARIO=scenario), text=True, input=message,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        for secret in ("fixture-access", "fixture-refresh", "fixture-authorization-code"):
            self.assertNotIn(secret, process.stdout + process.stderr)
        return process

    def login(self, scenario="success"):
        result = self.run_cli("--account", "workshop", "login", "--client-id", "123.456", scenario=scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["account"], "workshop")
        return json.loads(result.stdout)

    def requests(self):
        log = self.directory / "requests.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def search_fixture(self, name="dm"):
        # The two captured response shapes contain only fictional identities
        # and text. Credential files and OAuth fixtures remain temporary.
        return json.loads((ROOT / f"test/fixtures/search_{name}.json").read_text())

    def run_search(self, *args, response=None, scenario="success", refresh=False):
        response_file = self.directory / "search-response.json"
        if response is None:
            response_file.unlink(missing_ok=True)
        else:
            response_file.write_text(json.dumps(response))
        before = len(self.requests())
        result = self.run_cli("search", *args, scenario=scenario)
        expected = (["oauth.v2.access"] if refresh else []) + ["search.messages"]
        self.assertEqual([r["method"] for r in self.requests()[before:]], expected)
        return result


class PostcardTests(PostcardHarness):
    def test_search_request_encoding_defaults_and_explicit_bounds(self):
        self.login()
        queries = ("multiword in:#general", "-excluded term", "--page", "café & + = 雪\nsecond line\n",
                   "  leading and trailing  ", "literal $(false) and `false`")
        for query in queries:
            with self.subTest(query=query):
                result = self.run_search("--query", query)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertEqual(value["requested_query"], query)
                self.assertEqual(value["query"], query)
                self.assertEqual(self.requests()[-1]["body"], {
                    "query": query, "count": "20", "page": "1",
                    "sort": "timestamp", "sort_dir": "desc", "highlight": "false"})
        for count, page in ((1, 1), (5, 2), (100, 100)):
            with self.subTest(count=count, page=page):
                result = self.run_search("--query=-excluded café", f"--count={count}", "--page", str(page))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.requests()[-1]["body"], {
                    "query": "-excluded café", "count": str(count), "page": str(page),
                    "sort": "timestamp", "sort_dir": "desc", "highlight": "false"})

    def test_search_local_validation_precedes_credentials_and_network(self):
        invalid = [(), ("words",), ("--query",), ("--count",), ("--page",),
                   ("--query=",), ("--query", " \t\n"), ("--query", "\u2003"),
                   ("--query", "ok", "--count"), ("--query", "ok", "--page"),
                   ("--query", "ok", "extra"), ("--query", "ok", "--", "extra"),
                   ("--query", "ok", "--unknown"), ("--query", "one", "--query", "two"),
                   ("--query=one", "--query=two"), ("--query=one", "--query", "two"),
                   ("--query", "one", "--query=two")]
        for option in ("--count", "--page"):
            for value in ("", "0", "101", "-1", "+1", "01", "1.0", "1e1", " 1", "1\n", "١", "9" * 100):
                invalid.append(("--query", "ok", option, value))
        for args in invalid:
            with self.subTest(args=args):
                result = self.run_cli("search", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.credentials.parent.exists())
                self.assertEqual(self.requests(), [])

    def test_search_sanitized_live_shapes_and_literal_text(self):
        self.login()
        for name, count in (("empty", 5), ("dm", 20)):
            with self.subTest(name=name):
                response = self.search_fixture(name)
                result = self.run_search("--query", "requested query", "--count", str(count), response=response)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertEqual(value["team"], {"id": "T123ABC", "name": "Amalgamated Widgets"})
                self.assertEqual(value["user"], {"id": "U123ABC", "name": "Jane Doe", "username": "jane.doe"})
                self.assertEqual(value["query"], response["query"])
                self.assertEqual(value["requested_query"], "requested query")
                self.assertEqual(value["text_format"], "slack")
                self.assertEqual((value["sort"], value["sort_dir"]), ("timestamp", "desc"))
                self.assertEqual(value["pagination"], {
                    "page": 1, "per_page": count, "returned": 0 if name == "empty" else 1,
                    "total": response["messages"]["total"], "pages": 0 if name == "empty" else 1,
                    "has_more": False, "next_page": None})
                if name == "empty":
                    self.assertEqual(value["matches"], [])
                else:
                    raw = response["messages"]["matches"][0]
                    self.assertEqual(value["matches"], [{
                        "channel": "D123ABC", "channel_name": "U456DEF", "ts": raw["ts"],
                        "sender": "U456DEF", "permalink": raw["permalink"], "text": raw["text"],
                        "type": "im", "thread_ts": None, "subtype": None, "bot_id": None, "app_id": None}])

    def test_search_equivalent_pagination_shapes_and_legacy_count(self):
        self.login()
        for name, count in (("empty", 5), ("dm", 20)):
            baseline = None
            for shape in ("both", "paging", "pagination"):
                with self.subTest(name=name, shape=shape):
                    response = self.search_fixture(name)
                    if shape != "both":
                        del response["messages"]["pagination" if shape == "paging" else "paging"]
                    result = self.run_search("--query", "query", "--count", str(count), response=response)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    value = json.loads(result.stdout)
                    if baseline is None:
                        baseline = value
                    self.assertEqual(value, baseline)
        response = self.search_fixture()
        response["messages"]["paging"]["count"] = 1
        response["messages"]["pagination"]["per_page"] = 5
        result = self.run_search("--query", "query", response=response)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["pagination"]["per_page"], 5)

    def test_search_unknown_and_capped_continuation(self):
        self.login()
        cases = [
            ({}, 1, 20, None, None, None, None),
            ({"total": 41}, 1, 20, 41, None, True, 2),
            ({"total": 0}, 1, 20, 0, None, False, None),
            ({"paging": {"page": 3, "pages": 3, "total": 41}}, 3, 20, 41, 3, False, None),
            ({"paging": {"page": 100, "pages": 101, "total": 2010}}, 100, 20, 2010, 101, True, None),
            ({"pagination": {"page": 2, "per_page": 5, "page_count": 3}}, 2, 5, None, 3, True, 3),
        ]
        for metadata, page, count, total, pages, more, next_page in cases:
            with self.subTest(metadata=metadata):
                response = {"ok": True, "messages": {"matches": [], **metadata}}
                result = self.run_search("--query", "query", "--page", str(page), "--count", str(count), response=response)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertIsNone(value["query"])
                self.assertEqual(value["pagination"], {
                    "page": page, "per_page": count, "returned": 0, "total": total,
                    "pages": pages, "has_more": more, "next_page": next_page})

    def test_search_conflicting_or_invalid_metadata_fails_atomically(self):
        self.login()
        changes = [("total", None, 2), ("paging", "total", 2), ("pagination", "total_count", 2),
                   ("paging", "page", 2), ("pagination", "page", 2),
                   ("paging", "pages", 2), ("pagination", "page_count", 2)]
        for group, field in (("paging", "page"), ("pagination", "per_page"),
                             ("pagination", "page_count"), ("paging", "total")):
            for value in ("1", -1, 1.5, True, [], {}):
                changes.append((group, field, value))
        changes += [("pagination", "per_page", 0), ("paging", "page", 0),
                    ("paging", None, []), ("pagination", None, "invalid")]
        for group, field, invalid in changes:
            with self.subTest(group=group, field=field, invalid=invalid):
                response = self.search_fixture()
                if field is None:
                    response["messages"][group] = invalid
                else:
                    response["messages"][group][field] = invalid
                result = self.run_search("--query", "query", response=response)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("invalid search response", result.stderr)

    def test_search_optional_fields_and_explicit_parent(self):
        self.login()
        response = self.search_fixture()
        raw = response["messages"]["matches"][0]
        for prefix in ("C", "D", "G"):
            with self.subTest(channel_prefix=prefix):
                raw.update(channel={"id": prefix + "123ABC"}, thread_ts="1700000000.000001",
                           user="W123ABC", subtype="bot_message", bot_id="B123ABC", app_id="A123ABC", text="")
                result = self.run_search("--query", "query", response=response)
                self.assertEqual(result.returncode, 0, result.stderr)
                match = json.loads(result.stdout)["matches"][0]
                self.assertEqual(match["channel"], prefix + "123ABC")
                self.assertIsNone(match["channel_name"])
                self.assertEqual(match["thread_ts"], raw["thread_ts"])
                self.assertEqual(match["sender"], raw["user"])
                for key in ("text", "subtype", "bot_id", "app_id"):
                    self.assertEqual(match[key], raw[key])
        raw = {"channel": {"id": "D123ABC", "name": []}, "ts": "1700000000.000002",
               "thread_ts": "1700000000.000001\n", "user": "", "permalink": {},
               "text": False, "type": [], "subtype": 4, "bot_id": "U123ABC", "app_id": ""}
        response["messages"]["matches"] = [raw]
        response["query"] = []
        result = self.run_search("--query", "query", response=response)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertIsNone(value["query"])
        self.assertEqual(value["matches"][0], {
            "channel": "D123ABC", "ts": "1700000000.000002", "channel_name": None,
            "thread_ts": None, "sender": None, "permalink": None, "text": None,
            "type": None, "subtype": None, "bot_id": None, "app_id": None})

    def test_search_malformed_matches_and_overlimit_fail_atomically(self):
        self.login()
        raw = self.search_fixture()["messages"]["matches"][0]
        bad_matches = [None, [], "invalid", {}, {**raw, "channel": None}]
        for channel in ("U123ABC", "D123ABC\n", "D", "d123ABC", 123):
            bad_matches.append({**raw, "channel": {"id": channel}})
        for ts in ("1700000000.000002\n", "1700000000.2", "1700000000x000002", 1700000000.000002, None):
            bad_matches.append({**raw, "ts": ts})
        responses = [{"ok": True}, {"ok": True, "messages": []},
                     {"ok": True, "messages": {}},
                     *({"ok": True, "messages": {"matches": value}} for value in (None, {}, "bad")),
                     *({"ok": True, "messages": {"matches": [raw, bad]}} for bad in bad_matches),
                     {"ok": True, "messages": {"matches": [raw] * 21}}]
        for response in responses:
            with self.subTest(response=response):
                result = self.run_search("--query", "query", response=response)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("invalid search response", result.stderr)

    def test_search_refreshes_once_without_identity_enrichment(self):
        self.login("rotating_login")
        record = json.loads(self.credentials.read_text())
        record["grant"]["expires_at"] = 1
        self.credentials.write_text(json.dumps(record))
        result = self.run_search("--query", "query", refresh=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["user"]["id"], "U123ABC")
        saved = json.loads(self.credentials.read_text())
        self.assertEqual(saved["grant"]["refresh_token"], "fixture-refresh-new")

    def test_search_api_and_transport_errors_are_not_retried(self):
        self.login()
        result = self.run_search("--query", "query", response={"ok": False, "error": "ratelimited"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("ratelimited", result.stderr)
        result = self.run_search("--query", "query", scenario="search_timeout")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("No retry", result.stderr)

    def test_search_help_is_local(self):
        result = self.run_cli("search", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--query", result.stdout)
        self.assertIn("--count", result.stdout)
        self.assertIn("--page", result.stdout)
        self.assertEqual(self.requests(), [])
        self.assertFalse(self.credentials.parent.exists())

    def test_login_pkce_permissions_and_identity(self):
        result = self.login()
        self.assertEqual(result["user"]["name"], "Jane Doe")
        self.assertEqual(result["team"]["id"], "T123ABC")
        self.assertIsNone(result["expires_at"])
        self.assertFalse(result["refreshable"])
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.credentials.parent.stat().st_mode & 0o777, 0o700)
        who = self.run_cli("whoami")
        self.assertEqual(who.returncode, 0, who.stderr)
        self.assertEqual(json.loads(who.stdout)["user"]["id"], "U123ABC")

    def test_failed_login_preserves_previous_grant(self):
        self.login()
        old = self.credentials.read_bytes()
        for scenario in ("denied", "missing_scope", "identity_mismatch", "bot_grant"):
            with self.subTest(scenario=scenario):
                result = self.run_cli("--account", "workshop", "login", scenario=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(old, self.credentials.read_bytes())
                with socket.socket() as probe:
                    self.assertNotEqual(probe.connect_ex(("127.0.0.1", 8765)), 0)

    def test_rotating_grant_metadata_and_concurrent_renewal(self):
        result = self.login("rotating_login")
        self.assertTrue(result["refreshable"])
        self.assertGreater(result["refresh_expires_at"], result["expires_at"])
        record = json.loads(self.credentials.read_text())
        record["grant"]["expires_at"] = time.time() - 1
        self.credentials.write_text(json.dumps(record))
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.run_cli("whoami"), range(2)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        refreshes = [r for r in self.requests() if r["body"].get("grant_type") == "refresh_token"]
        self.assertEqual(len(refreshes), 1)
        record = json.loads(self.credentials.read_text())
        self.assertEqual(record["grant"]["refresh_token"], "fixture-refresh-new")

    def test_uncertain_refresh_requires_new_login(self):
        self.login("rotating_login")
        record = json.loads(self.credentials.read_text())
        record["grant"]["expires_at"] = 1
        self.credentials.write_text(json.dumps(record))
        failed = self.run_cli("whoami", scenario="refresh_failure")
        self.assertNotEqual(failed.returncode, 0)
        count = len(self.requests())
        next_call = self.run_cli("whoami")
        self.assertNotEqual(next_call.returncode, 0)
        self.assertIn("uncertain", next_call.stderr)
        self.assertEqual(len(self.requests()), count)
        self.login()
        self.assertEqual(self.run_cli("whoami").returncode, 0)

    def test_carded_self_post_and_permalink_failure(self):
        self.login()
        result = self.run_cli("post", "--model", "Codex", "self", message="Hello, <@U123ABC>!")
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["channel"], "D123ABC")
        self.assertTrue(receipt["permalink"].startswith("https://"))
        sent = json.loads((self.directory / "message.json").read_text())
        self.assertEqual(sent["text"], "Jane Doe's Codex, via Postcard\n\nHello, &lt;@U123ABC&gt;!")
        self.assertFalse(sent["mrkdwn"])
        self.assertFalse(sent["unfurl_links"])
        result = self.run_cli("post", "--model", "Codex", "--thread", "1700000000.000001",
                              "D123ABC", message="Reply", scenario="permalink_failure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["permalink"])
        self.assertIn("Do not repost", result.stderr)

    def test_post_transport_failure_is_not_retried(self):
        self.login()
        result = self.run_cli("post", "--model", "Codex", "D123ABC", message="Hello", scenario="post_timeout")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("may have succeeded", result.stderr)
        self.assertEqual(len([r for r in self.requests() if r["method"] == "chat.postMessage"]), 1)

    def test_other_user_is_opened_and_identity_mismatch_cannot_post(self):
        self.login()
        result = self.run_cli("post", "--model", "Codex", "U456DEF", message="Hello")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["channel"], "D456DEF")
        count = len([r for r in self.requests() if r["method"] == "chat.postMessage"])
        result = self.run_cli("post", "--model", "Codex", "D123ABC", message="Hello", scenario="identity_mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([r for r in self.requests() if r["method"] == "chat.postMessage"]), count)

    def test_interrupted_login_closes_listener_and_releases_lock(self):
        process = subprocess.Popen([str(ROOT / "bin/postcard"), "--account", "workshop", "login", "--no-browser",
                                    "--client-id", "123.456"], env=self.env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            # The first line is printed only after the helper has bound.
            self.assertIn("Authorize Postcard", process.stderr.readline())
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        with socket.socket() as probe:
            self.assertNotEqual(probe.connect_ex(("127.0.0.1", 8765)), 0)
        self.login()

    def test_exact_read_and_thread_read(self):
        self.login()
        for args in ((), ("--thread", "1700000000.000001")):
            result = self.run_cli("read", *args, "D123ABC", "1700000000.000002")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["sender"], "U123ABC")
        result = self.run_cli("read", "D123ABC", "1700000000.000002", scenario="nearby_message")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


class CallbackTests(unittest.TestCase):
    def test_path_state_duplicates_and_valid_callback(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        ready = threading.Event()
        state = "a" * 64
        with concurrent.futures.ThreadPoolExecutor(1) as pool:
            future = pool.submit(callback.receive, state, port, 3, ready.set)
            self.assertTrue(ready.wait(1))
            for suffix, expected in (("/wrong?state=" + state, 404),
                                     ("/auth?state=wrong&code=fixture", 400),
                                     ("/auth?state=" + state + "&state=" + state + "&code=fixture", 400),
                                     ("/auth?state=" + state + "&code=one&code=two", 400)):
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}{suffix}", timeout=2)
                self.assertEqual(failure.exception.code, expected)
                failure.exception.close()
                self.assertFalse(future.done())
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/auth?state={state}&code=fixture", timeout=2) as reply:
                self.assertEqual(reply.status, 200)
            self.assertEqual(future.result(timeout=2), {"code": "fixture"})
        with socket.socket() as probe:
            self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0)

    def test_callback_timeout_closes_listener(self):
        self.assertEqual(callback.receive("a" * 64, port=0, timeout=0.05), {"error": "callback_timeout"})


if __name__ == "__main__":
    unittest.main()
