"""Account-local aliases and exact thread projections using fictional Slack."""

import concurrent.futures
import importlib.util
import json
import re

from test_postcard import PostcardHarness, ROOT

spec = importlib.util.spec_from_file_location("thread_projection", ROOT / "share/postcard/thread.py")
thread_projection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(thread_projection)

PARENT = "1700000000.000000"
CHANNEL = "C123ABC"


def ts(index):
    return f"1700000000.{index:06d}"


def messages(count):
    return [{"ts": ts(index), "thread_ts": PARENT, "user": "U456DEF", "text": f"Message {index}"}
            for index in range(count)]


def page(values, cursor=""):
    return {"ok": True, "messages": values, "response_metadata": {"next_cursor": cursor}}


class ThreadTests(PostcardHarness):
    def setUp(self):
        super().setUp()
        # These tests start with already authorized, fictional local grants.
        # OAuth and renewal continue to be exercised by the original suite.
        self.save_account("workshop", "123.456", "T123ABC", "U123ABC", "fixture-access-old")

    def save_account(self, name, client, team, user, token):
        file = self.config / "accounts" / name / "credentials.json"
        file.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        file.write_text(json.dumps({
            "version": 1, "client_id": client, "app_id": "A123ABC", "team": {"id": team},
            "user": {"id": user}, "grant": {"token_type": "user", "access_token": token,
                                            "scope": "channels:history,chat:write,users:read"}}))
        file.chmod(0o600)
        return file

    def fixture(self, **value):
        (self.directory / "thread.json").write_text(json.dumps(value))

    def thread(self, *options, address=None, account=None):
        prefix = ("--account", account) if account else ()
        address = address or ("--channel", CHANNEL, "--ts", PARENT)
        before = len(self.requests())
        result = self.run_cli(*prefix, "thread", *address, *options)
        # Reading a thread does not perform identity/profile enrichment.
        self.assertTrue(all(request["method"] == "conversations.replies"
                            for request in self.requests()[before:]))
        return result

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["account"], "workshop")
        self.assertEqual(value["team"]["id"], "T123ABC")
        self.assertEqual(value["user"]["id"], "U123ABC")
        self.assertEqual(value["channel"], CHANNEL)
        self.assertEqual(value["ts"], PARENT)
        self.assertEqual(value["text_format"], "slack")
        return value

    def failed(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def bind(self, name="planning", *options, account=None):
        prefix = ("--account", account) if account else ()
        options = options or ("--channel", CHANNEL, "--ts", PARENT)
        result = self.run_cli(*prefix, "alias", name, *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_alias_lifecycle_is_local_and_preserves_credentials(self):
        record = json.loads(self.credentials.read_text())
        record["grant"].update(expires_at=1, refresh_uncertain=True)
        self.credentials.write_text(json.dumps(record))
        before = self.credentials.read_bytes()
        self.assertEqual(json.loads(self.run_cli("alias").stdout)["aliases"], [])
        value = self.bind()
        self.assertEqual((value["name"], value["channel"], value["ts"]), ("planning", CHANNEL, PARENT))
        self.assertEqual(value["account"], "workshop")
        self.assertEqual(json.loads(self.run_cli("alias", "planning").stdout), value)
        file = self.credentials.parent / "aliases.json"
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.bind("planning", "--channel", "D456DEF", "--ts", ts(2))
        self.bind("a")
        listed = json.loads(self.run_cli("alias").stdout)
        self.assertEqual([alias["name"] for alias in listed["aliases"]], ["a", "planning"])
        self.assertEqual(listed["aliases"][1]["ts"], ts(2))
        deleted = self.run_cli("alias", "planning", "--delete")
        self.assertEqual(deleted.returncode, 0, deleted.stderr)
        self.assertTrue(json.loads(deleted.stdout)["deleted"])
        self.failed(self.run_cli("alias", "planning"))
        self.failed(self.run_cli("alias", "planning", "--delete"))
        self.assertEqual(self.credentials.read_bytes(), before)
        self.assertEqual(self.requests(), [])

    def test_aliases_are_scoped_to_account_even_with_same_name(self):
        other = self.save_account("archive", "789.012", "T789DEF", "U789DEF", "fixture-access-other-old")
        self.bind(account="workshop")
        self.bind("planning", "--channel", "D789DEF", "--ts", ts(7), account="archive")
        self.failed(self.run_cli("alias", "planning"))
        self.failed(self.run_cli("--account", "missing", "alias", "planning"))
        for account, channel, parent, team in (("workshop", CHANNEL, PARENT, "T123ABC"),
                                               ("archive", "D789DEF", ts(7), "T789DEF")):
            self.fixture(channel=channel, parent=parent, messages=[{"ts": parent, "text": "Parent"}])
            result = self.thread("--all", address=("--alias", "planning"), account=account)
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual((value["account"], value["channel"], value["ts"], value["team"]["id"]),
                             (account, channel, parent, team))
            self.assertEqual(self.requests()[-1]["connection"], account)
            before = len(self.requests())
            posted = self.run_cli("--account", account, "post", "--alias", "planning", "--model", "Codex", message="Hi")
            self.assertEqual(posted.returncode, 0, posted.stderr)
            sent = json.loads((self.directory / "message.json").read_text())
            self.assertEqual((sent["channel"], sent["thread_ts"]), (channel, parent))
            self.assertTrue(all(request["connection"] == account for request in self.requests()[before:]))
        original = (other.parent / "aliases.json").read_bytes()
        self.run_cli("--account", "workshop", "alias", "planning", "--delete")
        self.assertEqual((other.parent / "aliases.json").read_bytes(), original)
        before = self.requests()
        self.failed(self.thread(address=("--alias", "planning"), account="workshop"))
        self.assertEqual(self.requests(), before)

    def test_aliases_stay_separate_for_two_accounts_in_one_workspace(self):
        self.save_account("colleague", "123.456", "T123ABC", "U456DEF", "fictional-colleague-token")
        self.bind(account="workshop")
        self.bind("planning", "--channel", "D456DEF", "--ts", ts(2), account="colleague")
        first = self.run_cli("--account", "workshop", "alias", "planning")
        second = self.run_cli("--account", "colleague", "alias", "planning")
        self.assertEqual(json.loads(first.stdout)["channel"], CHANNEL)
        self.assertEqual(json.loads(second.stdout)["channel"], "D456DEF")
        self.assertEqual(self.requests(), [])

    def test_thread_renewal_preserves_aliases_and_other_accounts(self):
        self.bind()
        alias_file = self.credentials.parent / "aliases.json"
        aliases = alias_file.read_bytes()
        other = self.save_account("archive", "789.012", "T789DEF", "U789DEF", "fixture-access-other-old")
        untouched = other.read_bytes()
        record = json.loads(self.credentials.read_text())
        record["grant"].update(expires_at=1, expires_in=43200, refresh_token="fixture-refresh-old")
        self.credentials.write_text(json.dumps(record))
        self.fixture(messages=messages(3))
        result = self.run_cli("--account", "workshop", "thread", "--alias", "planning", "--after", PARENT)
        self.assertEqual(self.success(result)["shown_count"], 2)
        self.assertEqual([request["method"] for request in self.requests()], ["oauth.v2.access", "conversations.replies"])
        self.assertEqual(alias_file.read_bytes(), aliases)
        self.assertEqual(other.read_bytes(), untouched)

    def test_concurrent_alias_updates_share_the_account_lock(self):
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda name: self.run_cli("alias", name, "--channel", CHANNEL, "--ts", PARENT),
                                    ("planning", "review")))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([item["name"] for item in json.loads(self.run_cli("alias").stdout)["aliases"]],
                         ["planning", "review"])

    def test_alias_permalinks_and_explicit_addresses_are_equivalent(self):
        for suffix in ("p1700000000000000", "p1700000000000002?thread_ts=" + PARENT + "&cid=" + CHANNEL):
            url = "https://widgets.slack.com/archives/" + CHANNEL + "/" + suffix
            value = self.bind("planning", "--permalink", url)
            self.assertEqual((value["channel"], value["ts"]), (CHANNEL, PARENT))
            self.fixture(messages=messages(4))
            direct = self.success(self.thread("--all"))
            self.assertEqual(self.success(self.thread("--all", address=("--permalink", url))), direct)
            self.assertEqual(self.success(self.thread("--all", address=("--alias", "planning"))), direct)

    def test_alias_post_uses_exact_coordinates_and_checked_plain_text_card(self):
        self.bind()
        result = self.run_cli("post", "--alias", "planning", "--model", "Example Model/2", message="Hi <@U456DEF> & all")
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        card = "Jane Doe's Example Model/2, from Postcard 📮"
        self.assertEqual(receipt["card"], card)
        sent = json.loads((self.directory / "message.json").read_text())
        self.assertEqual((sent["channel"], sent["thread_ts"]), (CHANNEL, PARENT))
        self.assertEqual(sent["text"], card + "\n\nHi &lt;@U456DEF&gt; &amp; all")
        for flag in ("mrkdwn", "link_names", "unfurl_links", "unfurl_media", "reply_broadcast"):
            self.assertFalse(sent[flag])
        self.assertEqual(sent["parse"], "none")
        for scenario, name in (("renamed_profile", "Updated profile"),
                               ("literal_profile", "Jane <@U456DEF> & *Doe*")):
            result = self.run_cli("post", "--alias", "planning", "--model", "Codex", message="Body", scenario=scenario)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["card"], name + "'s Codex, from Postcard 📮")
            text = json.loads((self.directory / "message.json").read_text())["text"]
            self.assertEqual(text, (name + "'s Codex, from Postcard 📮\n\nBody")
                             .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

    def test_invalid_alias_file_and_invalid_commands_do_not_touch_slack(self):
        self.bind()
        file = self.credentials.parent / "aliases.json"
        for data in ("{broken", '{"version":1,"aliases":[]}',
                     '{"version":1,"aliases":{"planning":{"channel":"U456DEF","ts":"1700000000.000000"}}}'):
            file.write_text(data)
            self.failed(self.run_cli("alias"))
            self.failed(self.run_cli("alias", "other", "--channel", CHANNEL, "--ts", PARENT))
            self.failed(self.thread(address=("--alias", "planning")))
            self.failed(self.run_cli("post", "--alias", "planning", "--model", "Codex", message="Hi"))
            self.assertEqual(file.read_text(), data)
        file.unlink()
        file.symlink_to(self.credentials)
        self.failed(self.run_cli("alias"))
        self.assertEqual(self.requests(), [])

    def test_option_errors_are_local_and_do_not_publish_partial_results(self):
        invalid = [
            ("alias", "../elsewhere"), ("alias", "Upper"), ("alias", "a", "b"), ("alias", "--delete"),
            ("alias", "planning", "--channel", CHANNEL), ("alias", "planning", "--permalink"),
            ("alias", "planning", "--permalink", "https://example.test/not-a-message"),
            ("alias", "planning", "--permalink", f"https://widgets.slack.com/archives/{CHANNEL}/p1700000000000001?thread_ts="),
            ("alias", "planning", "--delete", "--channel", CHANNEL, "--ts", PARENT),
            ("post", "--model", "Codex", "--alias", "planning", CHANNEL),
            ("post", "--model", "Codex", "--alias", "planning", "--thread", PARENT),
            ("post", "--alias", "planning", "--model"),
            ("thread",), ("thread", "--channel", CHANNEL), ("thread", "--alias", "planning", "--ts", PARENT),
            ("thread", "--permalink", f"https://widgets.slack.com/archives/{CHANNEL}/p1700000000000000", "--channel", CHANNEL),
        ]
        address = ("thread", "--channel", CHANNEL, "--ts", PARENT)
        for option in ("--after", "--around", "--from", "--through", "--window"):
            invalid.extend((address + (option,), address + (option, ""),
                            address + (option, "1\n"), address + (option, "value", option, "value")))
        for value in ("0", "101", "01", "1.0", "-1"):
            invalid.append(address + ("--window", value))
        for mode in (("--all",), ("--around", ts(1)), ("--from", ts(1)), ("--through", ts(2)), ("--window", "8")):
            invalid.append(address + ("--after", ts(1)) + mode)
        invalid.extend((address + ("--all", "--window", "8"), address + ("--from", ts(1), "--window", "8"),
                        address + ("--from", ts(2), "--through", ts(1)),
                        address + ("--around", ts(1), "--all")))
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                self.failed(self.run_cli(*arguments, message="Body"))
        self.assertEqual(self.requests(), [])
        self.assertFalse((self.credentials.parent / "aliases.json").exists())

    def test_default_true_tail_and_inclusive_gap_reconstruction(self):
        collection = messages(451)
        collection[0]["reply_count"] = 2  # Deliberately wrong: count fetched objects.
        self.fixture(messages=collection)
        value = self.success(self.thread())
        self.assertEqual([message["ts"] for message in value["messages"]],
                         [ts(i) for i in [*range(9), *range(443, 451)]])
        self.assertEqual((value["fetched_count"], value["shown_count"]), (451, 17))
        self.assertEqual(value["omission"], {"after": ts(8), "before": ts(443), "before_index": 9, "count": 434})
        self.assertEqual([request["body"] for request in self.requests()], [
            {"channel": CHANNEL, "ts": PARENT, "limit": 200},
            {"channel": CHANNEL, "ts": PARENT, "limit": 200, "cursor": "page-1"},
            {"channel": CHANNEL, "ts": PARENT, "limit": 200, "cursor": "page-2"}])
        gap = self.success(self.thread("--from", value["omission"]["after"], "--through", value["omission"]["before"]))
        self.assertEqual((gap["fetched_count"], gap["shown_count"]), (451, 436))
        self.assertEqual(len({message["ts"] for message in value["messages"] + gap["messages"]}), 451)
        self.assertIsNone(gap["omission"])

    def test_around_uses_nearest_replies_with_parent_and_edge_cases(self):
        self.fixture(messages=messages(451))
        for anchor, expected in ((300, [299, 300, 301]), (1, [1, 2]), (450, [449, 450]), (0, [0, 1])):
            value = self.success(self.thread("--around", ts(anchor), "--window", "1"))
            self.assertEqual([message["ts"] for message in value["messages"]], [ts(i) for i in expected])
            self.assertIn("outside this window", value["summary"])
            self.assertIsNone(value["omission"])
        self.failed(self.thread("--around", ts(500)))

    def test_short_ends_overlap_and_window_counts_replies(self):
        for count in (1, 2, 3, 4):
            self.fixture(messages=messages(count))
            value = self.success(self.thread("--window", "1"))
            self.assertEqual([message["ts"] for message in value["messages"]],
                             [ts(i) for i in ([0, 1, 3] if count == 4 else range(count))])
            if count == 4:
                self.assertEqual(value["omission"]["count"], 1)
            else:
                self.assertIsNone(value["omission"])
        self.assertEqual(self.success(self.thread("--window", "100"))["shown_count"], 4)

    def test_all_range_and_last_whole_duplicate_payload(self):
        first = messages(3)
        first[2].update(text="Earlier copy", edited={"user": "U456DEF", "ts": ts(100)})
        last = {"ts": ts(2), "thread_ts": PARENT, "bot_id": "B123ABC", "app_id": "A123ABC",
                "text": "Literal <@U456DEF> &amp; *body*", "blocks": [{"type": "rich_text"}],
                "files": [{"id": "F123ABC", "name": "note.txt", "mimetype": "text/plain", "size": 12}]}
        self.fixture(pages=[page(first, "page-1"), page([last, messages(4)[3]])])
        value = self.success(self.thread("--all"))
        self.assertEqual((value["fetched_count"], value["shown_count"]), (4, 4))
        observed = value["messages"][2]
        self.assertEqual(observed["text"], last["text"])
        self.assertEqual(observed["blocks"], last["blocks"])
        self.assertEqual(observed["files"], last["files"])
        self.assertIsNone(observed["sender"])
        self.assertIsNone(observed["edited"])
        self.assertNotIn("attribution", observed)
        value = self.success(self.thread("--through", ts(1)))
        self.assertEqual((value["fetched_count"], value["shown_count"]), (4, 2))
        value = self.success(self.thread("--from", ts(4)))
        self.assertEqual((value["fetched_count"], value["shown_count"]), (4, 0))

    def test_exact_parent_refusals_and_unthreaded_message(self):
        self.fixture(messages=[{"ts": PARENT, "text": "Unthreaded"}])
        self.assertEqual(self.success(self.thread())["shown_count"], 1)
        self.fixture(messages=messages(3)[1:])
        result = self.thread()
        self.failed(result)
        self.assertIn("parent message", result.stderr)
        self.fixture(parent=ts(1), messages=messages(3)[1:])
        result = self.thread(address=("--channel", CHANNEL, "--ts", ts(1)))
        self.failed(result)
        self.assertIn(f"--channel {CHANNEL} --ts {PARENT}", result.stderr)
        self.fixture(parent=ts(1), ignore_bounds=True, messages=messages(3)[1:])
        self.failed(self.thread("--after", ts(2), address=("--channel", CHANNEL, "--ts", ts(1))))

    def test_after_returns_entire_burst_and_keeps_bound_on_every_page(self):
        self.fixture(messages=messages(451))
        self.bind()
        value = self.success(self.thread("--after", ts(1), address=("--alias", "planning")))
        self.assertEqual((value["fetched_count"], value["shown_count"]), (449, 449))
        self.assertEqual([message["ts"] for message in value["messages"]], [ts(i) for i in range(2, 451)])
        self.assertEqual(len(self.requests()), 3)
        for request in self.requests():
            self.assertEqual(request["body"]["oldest"], ts(1))
            self.assertIs(request["body"]["inclusive"], False)
            self.assertEqual(request["body"]["limit"], 200)
        empty = self.success(self.thread("--after", value["messages"][-1]["ts"]))
        self.assertEqual(empty["messages"], [])
        self.assertEqual(empty["summary"], "0 messages fetched after " + ts(450))
        self.assertEqual(empty["projection"]["after"], ts(450))

    def test_after_filters_old_parent_boundary_and_edits_locally(self):
        collection = messages(5)
        collection[1]["edited"] = {"ts": ts(999), "user": "U456DEF"}
        self.fixture(messages=collection, ignore_bounds=True)
        value = self.success(self.thread("--after", ts(2)))
        self.assertEqual([message["ts"] for message in value["messages"]], [ts(3), ts(4)])
        self.assertEqual(value["fetched_count"], 2)
        self.fixture(messages=[collection[0], collection[3], collection[4]])  # Boundary was deleted.
        self.assertEqual(self.success(self.thread("--after", ts(2)))["shown_count"], 2)
        value = self.success(self.thread("--after", "1699999999.999999"))
        self.assertEqual(value["messages"][0]["ts"], PARENT)

    def test_after_short_empty_pages_and_duplicate_payload(self):
        first = messages(2)[1]
        replacement = {**first, "text": "Replacement"}
        self.fixture(pages=[page([], "page-1"), page([first], "page-2"),
                            page([replacement, messages(3)[2]])])
        value = self.success(self.thread("--after", PARENT))
        self.assertEqual(value["fetched_count"], 2)
        self.assertEqual(value["messages"][0]["text"], "Replacement")
        self.assertEqual(len(self.requests()), 3)

    def test_page_failures_and_cursor_cycles_emit_nothing(self):
        for mode in ((), ("--after", PARENT)):
            for failure in ("fail_page", "timeout_page"):
                self.fixture(messages=messages(451), **{failure: 1})
                before = len(self.requests())
                self.failed(self.thread(*mode))
                self.assertEqual(len(self.requests()) - before, 2)
            for pages in ([page(messages(2), "page-1"), page([], "page-1")],
                          [page(messages(2), "page-1"), page([], "page-2"), page([], "page-1")],
                          [page(messages(2), "page-1"), page([{"ts": "broken"}])],
                          [page(messages(2), "page-1"), page([{"ts": ts(2), "files": ["broken"]}])],
                          [page(messages(2), "page-1"), {"ok": True}],
                          [page(messages(2), "page-1"), {"ok": True, "messages": [], "has_more": True}],
                          [page(messages(2), "page-1"), {"ok": True, "messages": [], "response_metadata": False}],
                          [page(messages(2), "page-1"), {"ok": True, "messages": [], "response_metadata": {"next_cursor": False}}],
                          [page(messages(2), "page-1"), {"ok": True, "messages": [], "response_metadata": {"next_cursor": 4}}]):
                self.fixture(pages=pages)
                self.failed(self.thread(*mode))

    def test_timestamp_sorting_is_exact_across_second_and_large_integer_boundaries(self):
        parent = "9.999999"
        values = [{"ts": value} for value in ("9007199254740993.000002", parent, "10.000000", "9007199254740993.000001")]
        request = {"address": {"channel": CHANNEL, "ts": parent}, "projection": {"kind": "all"}}
        projected = thread_projection.project(request, [page(values)])
        self.assertEqual([message["ts"] for message in projected["messages"]],
                         [parent, "10.000000", "9007199254740993.000001", "9007199254740993.000002"])

    def test_help_is_local(self):
        for command in ("alias", "thread", "post"):
            result = self.run_cli(command, "--help")
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = re.sub(r".\x08", "", result.stdout)
            self.assertIn("--alias" if command != "alias" else "--permalink", rendered)
            self.assertIn("OPTIONS", rendered)
        self.assertIn("--after", re.sub(r".\x08", "", self.run_cli("thread", "--help").stdout))
        self.assertEqual(self.requests(), [])
