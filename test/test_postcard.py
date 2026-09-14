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


class PostcardTests(unittest.TestCase):
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
        self.credentials = self.directory / "config/credentials.json"

    def run_cli(self, *args, scenario="success", message=None):
        process = subprocess.run([str(ROOT / "bin/postcard"), *args], env=dict(
            self.env, POSTCARD_TEST_SCENARIO=scenario), text=True, input=message,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        for secret in ("fixture-access", "fixture-refresh", "fixture-authorization-code"):
            self.assertNotIn(secret, process.stdout + process.stderr)
        return process

    def login(self, scenario="success"):
        result = self.run_cli("login", "--client-id", "123.456", scenario=scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def requests(self):
        return [json.loads(line) for line in (self.directory / "requests.jsonl").read_text().splitlines()]

    def test_login_pkce_permissions_and_identity(self):
        result = self.login()
        self.assertEqual(result["user"]["name"], "Robin")
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
                result = self.run_cli("login", scenario=scenario)
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
        self.assertEqual(sent["text"], "Robin's Codex, via Postcard\n\nHello, &lt;@U123ABC&gt;!")
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
        process = subprocess.Popen([str(ROOT / "bin/postcard"), "login", "--no-browser",
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
