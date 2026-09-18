"""Named-account acceptance tests. All grants and Slack calls are fictional."""

import concurrent.futures
import json
import subprocess
import time

from test_postcard import PostcardHarness, ROOT


class AccountTests(PostcardHarness):
    def account_file(self, name):
        return self.directory / "config/accounts" / name / "credentials.json"

    def login_account(self, name, client="789.012", scenario="success"):
        result = self.run_cli("--account", name, "login", "--client-id", client, scenario=scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["account"], name)
        return value

    def expire(self, name):
        file = self.account_file(name)
        record = json.loads(file.read_text())
        record["grant"]["expires_at"] = 1
        file.write_text(json.dumps(record))

    def make_legacy(self):
        self.login("rotating_login")
        record = json.loads(self.credentials.read_text())
        record["grant"]["expires_at"] = 1
        record["grant"]["refresh_uncertain"] = True
        # Preserve noncanonical whitespace too, not just equivalent JSON.
        self.credentials.write_text(json.dumps(record, indent=4) + "\n\n")
        legacy = self.directory / "config/credentials.json"
        self.credentials.rename(legacy)
        return legacy

    def test_root_option_validation_position_and_failure_status(self):
        self.login()
        before = self.requests()
        invalid = [
            ("--account",), ("--account=", "whoami"),
            ("--account", "workshop", "--account", "archive", "whoami"),
            ("--account=workshop", "--account=archive", "whoami"),
            ("--unknown", "whoami"), ("whoami", "--account", "workshop"),
            ("login", "--account", "archive"),
            ("read", "--account", "workshop", "D123ABC", "1700000000.000002"),
            ("post", "--model", "Codex", "--account", "workshop", "D123ABC"),
            ("search", "--query", "query", "--account", "workshop"),
        ]
        for args in invalid:
            with self.subTest(args=args):
                result = self.run_cli(*args, message="message")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.requests(), before)
        result = self.run_cli("--account=workshop", "whoami")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["account"], "workshop")

    def test_name_grammar_and_case_collision(self):
        self.login()
        before = self.requests()
        for name in ("", ".", "..", "../elsewhere", "a/b", "-name", "_name", "a b", "雪", "name\n", "x" * 65):
            with self.subTest(name=name):
                result = self.run_cli("--account", name, "login", "--client-id", "789.012")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.requests(), before)
        for command in ("login", "whoami"):
            result = self.run_cli("--account", "Workshop", command)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("spelling", result.stderr)
            self.assertEqual(self.requests(), before)
        name = "A" + "x" * 60 + "._-"
        self.assertEqual(len(name), 64)
        self.login_account(name)
        result = self.run_cli("account", "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(name, [entry["account"] for entry in json.loads(result.stdout)["accounts"]])

    def test_login_always_requires_an_explicit_name(self):
        for existing in (False, True):
            if existing:
                self.login()
            before = self.requests()
            result = self.run_cli("login", "--client-id", "123.456")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--account NAME login", result.stderr)
            self.assertEqual(self.requests(), before)

    def test_selection_requires_exactly_one_saved_connection(self):
        commands = [("whoami",), ("search", "--query", "query"),
                    ("read", "D123ABC", "1700000000.000002"),
                    ("post", "--model", "Codex", "D123ABC")]
        for args in commands:
            result = self.run_cli(*args, message="message")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--account NAME", result.stderr)
        self.assertEqual(self.requests(), [])
        self.login()
        before = self.requests()
        result = self.run_cli("--account", "missing", "whoami")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests(), before)
        self.assertFalse(self.account_file("missing").parent.exists())
        self.login_account("archive")
        for damaged in (False, True):
            if damaged:
                self.account_file("archive").write_text("{broken")
            before = self.requests()
            for args in commands:
                result = self.run_cli(*args, message="message")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--account NAME", result.stderr)
                self.assertEqual(self.requests(), before)
            result = self.run_cli("--account", "workshop", "whoami")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(all(request["connection"] == "workshop" for request in self.requests()[len(before):]))

    def test_every_account_result_names_its_authorization_context(self):
        self.login()
        for explicit in (False, True):
            if explicit:
                self.login_account("archive")
            prefix = ("--account", "archive") if explicit else ()
            expected = ("archive", "T789DEF", "U789DEF") if explicit else ("workshop", "T123ABC", "U123ABC")
            for args in (("whoami",), ("search", "--query", "query"),
                         ("read", "D123ABC", "1700000000.000002"),
                         ("post", "--model", "Codex", "D123ABC")):
                with self.subTest(explicit=explicit, command=args[0]):
                    before = len(self.requests())
                    result = self.run_cli(*prefix, *args, message="message")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    value = json.loads(result.stdout)
                    self.assertEqual((value["account"], value["team"]["id"], value["user"]["id"]), expected)
                    self.assertTrue(all(r["connection"] == expected[0] for r in self.requests()[before:]))

    def test_list_is_local_and_preserves_broken_and_uncertain_entries(self):
        self.login("rotating_login")
        self.login_account("archive", scenario="rotating_login")
        self.expire("archive")
        root = self.directory / "config/accounts"
        uncertain = root / "uncertain"
        uncertain.mkdir()
        record = json.loads(self.credentials.read_text())
        record["grant"]["refresh_uncertain"] = True
        record["grant"]["expires_at"] = 1
        (uncertain / "credentials.json").write_text(json.dumps(record))
        (root / "empty").mkdir()
        (root / "broken").mkdir()
        (root / "broken/credentials.json").write_text("invalid JSON")
        (root / "dangling").mkdir()
        (root / "dangling/credentials.json").symlink_to(self.directory / "absent")
        (root / "not-a-file/credentials.json").mkdir(parents=True)
        before = self.requests()
        original = {file: file.read_bytes() for file in (self.credentials, self.account_file("archive"), uncertain / "credentials.json")}
        result = self.run_cli("account", "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = {item["account"]: item for item in json.loads(result.stdout)["accounts"]}
        self.assertEqual({name: item["state"] for name, item in entries.items()}, {
            "workshop": "ready", "archive": "expired", "uncertain": "refresh-uncertain",
            "broken": "error", "dangling": "error", "not-a-file": "error"})
        self.assertEqual(entries["archive"]["team"]["id"], "T789DEF")
        self.assertIsNone(entries["broken"]["team"])
        self.assertEqual(self.requests(), before)
        self.assertEqual({file: file.read_bytes() for file in original}, original)

    def test_empty_directories_do_not_count_but_broken_entries_do(self):
        self.login()
        empty = self.directory / "config/accounts/empty"
        empty.mkdir()
        result = self.run_cli("whoami")
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.requests()
        (empty / "credentials.json").symlink_to(self.directory / "absent")
        result = self.run_cli("whoami")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests(), before)
        result = self.run_cli("--account", "empty", "whoami")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests(), before)

    def test_two_grants_refresh_independently(self):
        self.login("rotating_login")
        self.login_account("archive", scenario="rotating_login")
        for name in ("workshop", "archive"):
            self.expire(name)
        before = len(self.requests())
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda name: self.run_cli("--account", name, "whoami", scenario="refresh_barrier"),
                                    ("workshop", "archive")))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        refreshes = [r for r in self.requests()[before:] if r["method"] == "oauth.v2.access"]
        self.assertCountEqual([r["connection"] for r in refreshes], ["workshop", "archive"])
        records = [json.loads(self.account_file(name).read_text()) for name in ("workshop", "archive")]
        self.assertEqual([r["grant"]["refresh_token"] for r in records],
                         ["fixture-refresh-new", "fixture-refresh-other-new"])
        self.assertEqual([r["user"]["id"] for r in records], ["U123ABC", "U789DEF"])

    def test_failed_refresh_and_uncertainty_do_not_affect_another_account(self):
        self.login("rotating_login")
        self.login_account("archive", scenario="rotating_login")
        self.expire("workshop")
        other = self.account_file("archive").read_bytes()
        result = self.run_cli("--account", "workshop", "whoami", scenario="refresh_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.account_file("archive").read_bytes(), other)
        uncertain = self.credentials.read_bytes()
        before = self.requests()
        result = self.run_cli("--account", "workshop", "whoami")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncertain", result.stderr)
        self.assertEqual(self.requests(), before)
        result = self.run_cli("--account", "archive", "whoami")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["user"]["id"], "U789DEF")
        self.assertEqual(self.credentials.read_bytes(), uncertain)
        self.assertEqual(self.account_file("archive").read_bytes(), other)

    def test_relogin_preserves_binding_but_updates_display_metadata(self):
        self.login()
        self.login_account("archive")
        original = self.credentials.read_bytes()
        other = self.account_file("archive").read_bytes()
        for client, scenario in (("789.012", "success"), ("123.456", "different_team"), ("123.456", "different_user")):
            with self.subTest(client=client, scenario=scenario):
                result = self.run_cli("--account", "workshop", "login", "--client-id", client, scenario=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("binding", result.stderr)
                self.assertEqual(self.credentials.read_bytes(), original)
                self.assertEqual(self.account_file("archive").read_bytes(), other)
        result = self.run_cli("--account", "workshop", "login", scenario="renamed_profile")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["user"]["name"], "Updated profile")
        self.assertEqual((value["client_id"], value["team"]["id"], value["user"]["id"]),
                         ("123.456", "T123ABC", "U123ABC"))

    def test_legacy_refusal_and_byte_preserving_adoption(self):
        legacy = self.make_legacy()
        original = legacy.read_bytes()
        inode = legacy.stat().st_ino
        root_lock = legacy.parent / ".lock"
        lock_inode = root_lock.stat().st_ino
        before = self.requests()
        for args in (("whoami",), ("--account", "workshop", "whoami"),
                     ("--account", "archive", "login", "--client-id", "789.012"),
                     ("search", "--query", "query"), ("account", "list")):
            result = self.run_cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("account adopt NAME", result.stderr)
            self.assertEqual(legacy.read_bytes(), original)
            self.assertEqual(self.requests(), before)
        result = self.run_cli("account", "adopt", "workshop")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["account"], value["team"]["id"], value["user"]["id"]),
                         ("workshop", "T123ABC", "U123ABC"))
        self.assertTrue(value["adopted"])
        self.assertFalse(legacy.exists())
        self.assertEqual(self.credentials.read_bytes(), original)
        self.assertEqual(self.credentials.stat().st_ino, inode)
        self.assertEqual(root_lock.stat().st_ino, lock_inode)
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.requests(), before)
        result = self.run_cli("account", "list")
        self.assertEqual(json.loads(result.stdout)["accounts"][0]["state"], "refresh-uncertain")
        repeated = self.run_cli("account", "adopt", "workshop")
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(self.credentials.read_bytes(), original)

    def test_adoption_refuses_occupied_and_malformed_entries(self):
        legacy = self.make_legacy()
        original = legacy.read_bytes()
        destination = self.credentials
        before = self.requests()
        for kind in ("file", "directory", "symlink"):
            if kind == "file":
                destination.write_bytes(b"occupied")
            elif kind == "directory":
                destination.mkdir()
            else:
                destination.symlink_to(self.directory / "absent")
            result = self.run_cli("account", "adopt", "workshop")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("occupied", result.stderr)
            self.assertEqual(legacy.read_bytes(), original)
            if kind == "directory":
                destination.rmdir()
            else:
                if kind == "file":
                    self.assertEqual(destination.read_bytes(), b"occupied")
                destination.unlink()
        legacy.write_bytes(b"invalid JSON")
        result = self.run_cli("account", "adopt", "workshop")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(legacy.read_bytes(), b"invalid JSON")
        self.assertFalse(destination.exists())
        self.assertEqual(self.requests(), before)
        legacy.unlink()
        legacy.symlink_to(self.directory / "absent")
        for args in (("whoami",), ("account", "adopt", "workshop")):
            result = self.run_cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(legacy.is_symlink())
            self.assertFalse(destination.exists())
            self.assertEqual(self.requests(), before)

    def test_damaged_identity_is_not_a_usable_account(self):
        self.login()
        original = json.loads(self.credentials.read_text())
        before = self.requests()
        for field in ("client_id", "team", "user"):
            record = json.loads(json.dumps(original))
            if field == "client_id":
                record[field] += "\n"
            else:
                record[field]["id"] += "\n"
            self.credentials.write_text(json.dumps(record))
            result = self.run_cli("account", "list")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["accounts"][0]["state"], "error")
            result = self.run_cli("whoami")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.requests(), before)

    def test_adoption_waits_for_the_legacy_writer_before_reading(self):
        legacy = self.make_legacy()
        lock = legacy.parent / ".lock"
        holder = subprocess.Popen(["zsh", "-f", "-c",
                                   'zmodload zsh/system; zsystem flock -f held "$1" || exit; print ready; read release',
                                   "lock-holder", str(lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        adopter = None
        try:
            self.assertEqual(holder.stdout.readline().strip(), "ready")
            before = self.requests()
            adopter = subprocess.Popen([str(ROOT / "bin/postcard"), "account", "adopt", "workshop"],
                                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(0.1)
            self.assertIsNone(adopter.poll())
            # Model the final atomic save of the writer holding the old lock.
            record = json.loads(legacy.read_text())
            record["grant"]["issued_at"] = 42
            legacy.write_text(json.dumps(record) + "\n\n")
            expected = legacy.read_bytes()
            holder.communicate("release\n", timeout=5)
            stdout, stderr = adopter.communicate(timeout=10)
            self.assertEqual(adopter.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)["account"], "workshop")
            self.assertEqual(self.credentials.read_bytes(), expected)
            self.assertEqual(self.requests(), before)
        finally:
            for process in (adopter, holder):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_account_help_and_empty_list_are_local(self):
        for args in (("--help",), ("account", "--help"), ("account", "list", "--help"), ("account", "adopt", "--help")):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli("account", "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"accounts": []})
        self.assertEqual(self.requests(), [])
