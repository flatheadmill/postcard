#!/usr/bin/env python3
"""Checked Slack person discovery with fictional directory responses."""

import json
import re
import time

from test_postcard import PostcardHarness


def member(user_id, username, display, real, **status):
    return {
        "id": user_id, "name": username, "real_name": real,
        "deleted": status.get("deleted", False), "is_bot": status.get("is_bot", False),
        "is_app_user": status.get("is_app_user", False),
        "is_restricted": status.get("is_restricted", False),
        "is_ultra_restricted": status.get("is_ultra_restricted", False),
        "profile": {"display_name": display, "real_name": real},
    }


class PeopleTests(PostcardHarness):
    def pages(self, values):
        pages = []
        for index, members in enumerate(values):
            cursor = f"people-page-{index + 1}" if index + 1 < len(values) else ""
            pages.append({"ok": True, "members": members,
                          "response_metadata": {"next_cursor": cursor}})
        (self.directory / "people.json").write_text(json.dumps(pages))

    def test_people_traverses_complete_directory_and_bounds_candidates(self):
        self.login()
        self.pages([
            [member("U100AAA", "not.jane", "Elsewhere", "Someone Else"),
             member("U200BBB", "jane", "J. Doe", "Jane Doe")],
            [],
            [member("U300CCC", "jane.doe", "Jane Doe", "Jane Doe Example"),
             member("U400DDD", "doctor.jane", "Dr. Jane Doe", "Doctor Jane Doe",
                    is_restricted=True),
             member("U500EEE", "jane.bot", "Jane Doe Helper", "Jane Doe Helper",
                    is_bot=True, is_app_user=True)],
        ])
        result = self.run_cli("people", "--query", "JANE DOE", "--count", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["account"], "workshop")
        self.assertEqual(value["query"], "JANE DOE")
        self.assertEqual((value["matched_count"], value["returned"], value["truncated"]), (4, 2, True))
        self.assertEqual([candidate["id"] for candidate in value["candidates"]],
                         ["U200BBB", "U300CCC"])
        self.assertEqual(value["candidates"][0]["matched"], ["real_name"])
        requests = [request for request in self.requests() if request["method"] == "users.list"]
        self.assertEqual([request["body"]["cursor"] for request in requests],
                         ["", "people-page-1", "people-page-2"])
        self.assertTrue(all(request["encoding"] == "form" for request in requests))
        self.assertTrue(all(set(request["body"]) == {"limit", "cursor"} for request in requests))

    def test_people_unicode_matching_and_status_facts(self):
        self.login()
        self.pages([[member("U600FFF", "street", "Straße", "Example Person", deleted=True)]])
        result = self.run_cli("people", "--query", "STRASSE")
        self.assertEqual(result.returncode, 0, result.stderr)
        candidate = json.loads(result.stdout)["candidates"][0]
        self.assertEqual(candidate["id"], "U600FFF")
        self.assertEqual(candidate["matched"], ["display_name"])
        self.assertTrue(candidate["deleted"])
        self.assertNotIn("email", candidate)

    def test_people_empty_result_is_complete_and_read_only(self):
        self.login()
        before = len(self.requests())
        result = self.run_cli("people", "--query", "Nobody Here")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["matched_count"], value["returned"], value["truncated"]), (0, 0, False))
        self.assertEqual(value["candidates"], [])
        self.assertEqual([request["method"] for request in self.requests()[before:]], ["users.list"])

    def test_people_uses_selected_account_and_renews_its_grant(self):
        self.login("rotating_login")
        record = json.loads(self.credentials.read_text())
        record["grant"]["expires_at"] = time.time() - 1
        self.credentials.write_text(json.dumps(record))
        before = len(self.requests())
        result = self.run_cli("--account", "workshop", "people", "--query", "Jane Doe")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["account"], value["candidates"][0]["id"]),
                         ("workshop", "U123ABC"))
        requests = self.requests()[before:]
        self.assertEqual([request["method"] for request in requests],
                         ["oauth.v2.access", "users.list"])
        self.assertTrue(all(request["connection"] == "workshop" for request in requests))
        self.assertEqual(json.loads(self.credentials.read_text())["grant"]["refresh_token"],
                         "fixture-refresh-new")

        other = self.run_cli("--account", "archive", "login", "--client-id", "789.012")
        self.assertEqual(other.returncode, 0, other.stderr)
        result = self.run_cli("--account", "archive", "people", "--query", "John Doe")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["account"], value["candidates"][0]["id"]),
                         ("archive", "U789DEF"))
        self.assertEqual(self.requests()[-1]["connection"], "archive")

    def test_people_rejects_repeated_cursor_and_malformed_later_page_atomically(self):
        self.login()
        first = {"ok": True, "members": [member("U200BBB", "jane", "Jane", "Jane Doe")],
                 "response_metadata": {"next_cursor": "people-page-1"}}
        cases = [
            [first, {"ok": True, "members": [],
                     "response_metadata": {"next_cursor": "people-page-1"}}],
            [first, {"ok": True, "response_metadata": {"next_cursor": ""}}],
            [first, {"ok": True, "members": [member("U200BBB", "jane", "Jane", "Jane Doe")],
                     "response_metadata": {"next_cursor": ""}}],
        ]
        for pages in cases:
            with self.subTest(pages=pages):
                (self.directory / "people.json").write_text(json.dumps(pages))
                result = self.run_cli("people", "--query", "Jane")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_people_options_and_help_are_local(self):
        invalid = [(), ("Jane",), ("--query",), ("--count",), ("--query", ""),
                   ("--query", "   "), ("--query", " Jane"), ("--query", "Jane "),
                   ("--query", "Jane", "--count", "0"),
                   ("--query", "Jane", "--count", "01"),
                   ("--query", "Jane", "--count", "101"),
                   ("--query", "Jane", "--query", "Doe"),
                   ("--query", "Jane", "--count", "2", "--count", "3")]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                result = self.run_cli("people", *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.requests(), [])
                self.assertFalse(self.credentials.parent.exists())
        help_result = self.run_cli("people", "--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        rendered = re.sub(r".\x08", "", help_result.stdout)
        self.assertIn("--query", rendered)
        self.assertIn("--count", rendered)
        self.assertEqual(self.requests(), [])
