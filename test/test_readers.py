"""Named reader and foreground watcher acceptance tests with fictional Slack."""

import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time
import unittest

from test_postcard import PostcardHarness, ROOT
import test_threads as threads

CHANNEL, PARENT, ts, messages, page = threads.CHANNEL, threads.PARENT, threads.ts, threads.messages, threads.page


class ReaderTests(PostcardHarness):
    save_account = threads.ThreadTests.save_account
    bind = threads.ThreadTests.bind

    def setUp(self):
        super().setUp()
        self.save_account("workshop", "123.456", "T123ABC", "U123ABC", "fixture-access-old")
        self.bind()
        self.state = self.home / ".local/state/postcard/accounts/workshop/cursors/desk.json"
        self.children = []
        self.addCleanup(self.stop_children)
        self.fixture(messages=messages(1))

    def stop_children(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            try:
                child.communicate(timeout=6)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate()

    def fixture(self, **value):
        temporary = self.directory / "thread.new"
        temporary.write_text(json.dumps(value))
        temporary.replace(self.directory / "thread.json")

    def plan(self, steps, method="conversations.replies"):
        (self.directory / "responses.json").write_text(json.dumps({method: steps}))

    def read(self, *args, reader="desk", alias="planning", account="workshop"):
        return self.run_cli("--account", account, "thread", "--alias", alias, "--cursor", reader, *args)

    def good(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def entry(self, index=0):
        return json.loads(self.state.read_text())["threads"][index]

    def initialize(self, boundary=PARENT):
        return self.good(self.read("--after", boundary))

    def start(self, command="watch", args=(), stdout=subprocess.PIPE, account=True):
        prefix = ["--account", "workshop"] if account else []
        child = subprocess.Popen([str(ROOT / "bin/postcard"), *prefix, command,
                                  "--alias", "planning", "--cursor", "desk", *args],
                                 env=self.env, stdin=subprocess.DEVNULL, stdout=stdout,
                                 stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def await_condition(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.01)
        self.fail("condition did not become true")

    def line(self, child, timeout=8):
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout), "watcher did not emit a line")
        line = child.stdout.readline()
        self.assertTrue(line, child.stderr.read() if child.poll() is not None else "watcher closed stdout")
        return line

    def probes(self):
        return [item for item in self.requests() if item["method"] == "conversations.replies"]

    def test_initialization_catchup_and_empty_looks(self):
        for result in (self.read(), self.run_cli("watch", "--alias", "planning", "--cursor", "desk")):
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not initialized", result.stderr)
            self.assertEqual(result.stdout, "")
        self.assertFalse(self.state.exists())
        self.assertEqual(self.initialize()["messages"], [])
        state = json.loads(self.state.read_text())
        self.assertEqual(state["binding"], {"client_id": "123.456", "team_id": "T123ABC", "user_id": "U123ABC"})
        self.assertEqual(self.entry(), {"channel": CHANNEL, "ts": PARENT, "start_after": PARENT, "after": PARENT, "looks": 1})
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.fixture(messages=messages(451))
        result = self.good(self.read())
        self.assertEqual(len(result["messages"]), 450)
        self.assertEqual((self.entry()["after"], self.entry()["looks"]), (ts(450), 2))
        self.assertEqual(self.good(self.read())["messages"], [])
        self.assertEqual((self.entry()["after"], self.entry()["looks"]), (ts(450), 3))
        self.assertNotEqual(self.read("--after", PARENT).returncode, 0)
        before = self.state.read_bytes()
        self.good(self.run_cli("thread", "--alias", "planning", "--after", ts(450)))
        self.assertEqual(self.state.read_bytes(), before)

    def test_watch_coalesces_and_empty_look_releases_deleted_message(self):
        self.initialize()
        self.fixture(messages=messages(2))
        watch = self.start(args=("--interval", "1"), account=False)
        self.assertEqual(self.line(watch), "You have messages: `postcard --account workshop thread --alias planning --cursor desk`.\n")
        # The watcher keeps the account it resolved before a second is added.
        self.save_account("archive", "789.012", "T789DEF", "U789DEF", "fixture-access-other-old")
        count = len(self.probes())
        profiles = len([r for r in self.requests() if r["method"] == "users.info"])
        self.fixture(messages=messages(4))
        time.sleep(1.4)
        self.assertEqual(len(self.probes()), count)
        self.assertEqual(len([r for r in self.requests() if r["method"] == "users.info"]), profiles)
        self.fixture(messages=messages(1))  # All observed replies disappeared.
        self.assertEqual(self.good(self.read())["messages"], [])
        self.assertEqual(self.entry()["after"], PARENT)
        self.fixture(messages=messages(5))
        self.assertEqual(self.line(watch), "You have messages: `postcard --account workshop thread --alias planning --cursor desk`.\n")
        watch.terminate()
        watch.communicate(timeout=5)
        restarted = self.start(args=("--interval", "1"))
        self.assertIn("--cursor desk", self.line(restarted))
        self.assertTrue(all(call["connection"] == "workshop" for call in self.requests()))

    def test_probe_follows_empty_pages_and_stops_at_first_evidence(self):
        self.initialize()
        self.fixture(pages=[page([], "page-1"), page(messages(1), "page-2"),
                            page(messages(2)[1:], "page-3"), {"ok": False, "error": "invalid_auth"}])
        before = len(self.probes())
        watch = self.start(args=("--interval", "1"))
        self.line(watch)
        self.assertEqual(len(self.probes()) - before, 3)
        self.assertEqual(self.entry()["looks"], 1)

    def test_transient_probe_failures_retry_with_delay_then_ring(self):
        self.initialize()
        # Script indexes count prior calls, so reserve the initialization slot.
        self.plan([None, {"exit": 28}, {"status": 429, "retry_after": "2"},
                   {"status": 503, "raw": "maintenance"},
                   {"body": {"ok": False, "error": "internal_error"}},
                   {"body": page(messages(2)[1:])}])
        before = self.state.read_bytes()
        watch = self.start(args=("--interval", "1"))
        self.line(watch, timeout=12)
        self.assertEqual(self.state.read_bytes(), before)
        calls = self.probes()
        self.assertGreaterEqual(calls[3]["at"] - calls[2]["at"], 2)
        self.assertEqual(len(calls), 6)

    def test_permanent_failures_and_refresh_uncertainty_terminate(self):
        self.initialize()
        for response in ({"raw": "broken"}, {"body": {"ok": True, "messages": "wrong"}},
                         {"body": {"ok": False, "error": "request_timeout"}},
                         {"body": {"ok": False, "error": "invalid_auth"}}):
            with self.subTest(response=response):
                self.plan([response])
                watch = self.start(args=("--interval", "1"))
                stdout, stderr = watch.communicate(timeout=6)
                self.assertNotEqual(watch.returncode, 0)
                self.assertEqual(stdout, "")
                self.assertTrue(stderr)
        self.plan([{"exit": 28}], method="oauth.v2.access")
        credentials = json.loads(self.credentials.read_text())
        credentials["grant"].update(expires_at=1, refresh_token="fixture-refresh-old")
        self.credentials.write_text(json.dumps(credentials))
        watch = self.start(args=("--interval", "1"))
        stdout, _ = watch.communicate(timeout=6)
        self.assertNotEqual(watch.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertTrue(json.loads(self.credentials.read_text())["grant"]["refresh_uncertain"])
        self.assertEqual(len([r for r in self.requests() if r["method"] == "oauth.v2.access"]), 1)

    def test_identity_binding_and_independent_thread_looks(self):
        self.initialize()
        self.good(self.read("--after", PARENT, reader="colleague"))
        self.bind("other", "--channel", CHANNEL, "--ts", ts(9))
        self.fixture(parent=ts(9), messages=[{"ts": ts(9), "user": "U456DEF"}])
        self.good(self.read("--after", ts(9), alias="other"))
        self.assertEqual(len(json.loads(self.state.read_text())["threads"]), 2)
        self.good(self.read(alias="other"))
        self.assertEqual((self.entry(0)["looks"], self.entry(1)["looks"]), (1, 2))
        record = json.loads(self.credentials.read_text())
        record["user"]["id"] = "U999ZZZ"
        self.credentials.write_text(json.dumps(record))
        result = self.read()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different Slack", result.stderr)

    def test_concurrent_output_merges_and_holds_no_account_lock(self):
        self.initialize()
        large = messages(2)
        large[1]["text"] = "x" * 1000000
        self.fixture(messages=large)
        first = self.start("thread")  # Its undrained stdout blocks after fetch.
        self.await_condition(lambda: any(r["method"] == "users.info" for r in self.requests()))
        self.fixture(messages=messages(3))
        self.good(self.read())
        self.assertEqual((self.entry()["after"], self.entry()["looks"]), (ts(2), 2))
        output, error = first.communicate(timeout=6)
        self.assertEqual(first.returncode, 0, error)
        self.assertEqual(json.loads(output)["messages"][-1]["ts"], ts(1))
        self.assertEqual((self.entry()["after"], self.entry()["looks"]), (ts(2), 3))

    def test_concurrent_initialization_agrees_on_declared_start(self):
        for boundary in (PARENT, ts(1)):
            with self.subTest(winning_boundary=boundary):
                self.state.unlink(missing_ok=True)
                large = messages(2)
                large[1]["text"] = "x" * 1000000
                self.fixture(messages=large)
                first = self.start("thread", args=("--after", PARENT))
                with selectors.DefaultSelector() as selector:
                    selector.register(first.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(6))
                self.assertFalse(self.state.exists())
                self.fixture(messages=messages(3))
                self.good(self.read("--after", boundary))
                output, error = first.communicate(timeout=6)
                self.assertEqual(json.loads(output)["messages"][-1]["ts"], ts(1))
                self.assertEqual(self.entry()["after"], ts(2))
                self.assertEqual(self.entry()["start_after"], boundary)
                if boundary == PARENT:
                    self.assertEqual(first.returncode, 0, error)
                    self.assertEqual(self.entry()["looks"], 2)
                else:
                    self.assertNotEqual(first.returncode, 0)
                    self.assertIn("declared start changed", error)
                    self.assertEqual(self.entry()["looks"], 1)

    def test_failed_stdout_and_removed_cursor_do_not_commit(self):
        self.initialize()
        large = messages(2)
        large[1]["text"] = "x" * 1000000
        self.fixture(messages=large)
        before = self.state.read_bytes()
        child = self.start("thread")
        child.stdout.close()
        child.wait(timeout=6)
        self.assertNotEqual(child.returncode, 0)
        self.assertEqual(self.state.read_bytes(), before)
        child.stdout = None
        child = self.start("thread")
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(6))
        self.state.unlink()
        output, error = child.communicate(timeout=6)
        self.assertTrue(json.loads(output)["messages"])
        self.assertNotEqual(child.returncode, 0)
        self.assertIn("removed", error)
        self.assertFalse(self.state.exists())

    def test_signals_stop_sleep_and_owned_http_children(self):
        self.initialize()
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            for phase in ("sleep", "http"):
                with self.subTest(number=number, phase=phase):
                    ready = self.directory / "http-waiting"
                    ready.unlink(missing_ok=True)
                    self.plan([{"wait": True}] if phase == "http" else [{"body": page(messages(2)[1:])}])
                    child = self.start(args=("--interval", "30"))
                    if phase == "http":
                        self.await_condition(ready.exists)
                        http_pid = int(ready.read_text())
                    else:
                        self.line(child)
                    child.send_signal(number)
                    child.communicate(timeout=6)
                    self.assertEqual(child.returncode, 128 + number)
                    if phase == "http":
                        with self.assertRaises(ProcessLookupError):
                            os.kill(http_pid, 0)
        self.assertEqual(self.run_cli("alias", "planning").returncode, 0)

    def test_repeated_signals_allow_shutdown_to_finish(self):
        self.initialize()
        self.plan([{"wait": True, "stop_wait": True}])
        child = self.start()
        ready = self.directory / "http-waiting"
        release = self.directory / "http-release"
        try:
            self.await_condition(ready.exists)
            http_pid = int(ready.read_text())
            child.send_signal(signal.SIGINT)
            self.await_condition((self.directory / "http-stopping").exists)
            child.send_signal(signal.SIGHUP)
            child.send_signal(signal.SIGTERM)
        finally:
            release.touch()
        output, error = child.communicate(timeout=6)
        self.assertEqual(child.returncode, 130, error)
        self.assertEqual(output, "")
        self.assertNotIn("Traceback", error)
        self.assertEqual(self.entry()["looks"], 1)
        with self.assertRaises(ProcessLookupError):
            os.kill(http_pid, 0)

    def test_signal_during_lock_wait_and_blocked_nudge_stdout(self):
        self.initialize()
        lock = self.credentials.parent / ".lock"
        holder = subprocess.Popen(["zsh", "-fc", 'zmodload zsh/system; zsystem flock -f held "$1"; print ready; read release',
                                   "lock-holder", str(lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline(), "ready\n")
            watch = self.start(args=("--interval", "1"))
            time.sleep(0.3)
            watch.send_signal(signal.SIGINT)
            watch.communicate(timeout=6)
            self.assertEqual(watch.returncode, 130)
        finally:
            holder.communicate("release\n", timeout=6)
        self.fixture(messages=messages(2))
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            read_fd, write_fd = os.pipe()
            try:
                os.set_blocking(write_fd, False)
                try:
                    while True:
                        os.write(write_fd, b"x" * 4096)
                except BlockingIOError:
                    pass
                os.set_blocking(write_fd, True)
                count = len(self.probes())
                watch = self.start(args=("--interval", "1"), stdout=write_fd)
                self.await_condition(lambda: len(self.probes()) > count)
                self.assertEqual(self.run_cli("alias", "planning").returncode, 0)
                time.sleep(0.1)
                watch.send_signal(number)
                watch.communicate(timeout=6)
                self.assertEqual(watch.returncode, 128 + number)
            finally:
                os.close(read_fd)
                os.close(write_fd)

    def test_pagination_and_profile_failure_preserve_cursor(self):
        self.initialize()
        before = self.state.read_bytes()
        self.fixture(messages=messages(451), fail_page=1)
        result = self.read()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.state.read_bytes(), before)
        self.fixture(messages=messages(2))
        self.plan([{"body": {"ok": False, "error": "user_not_found"}}], method="users.info")
        result = self.read()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.state.read_bytes(), before)

    def test_options_are_local_and_help_documents_initialization(self):
        for args in (("watch",), ("watch", "--alias", "planning"),
                     ("watch", "--alias", "planning", "--cursor", "../desk"),
                     ("watch", "--alias", "planning", "--cursor", "desk", "--interval", "0"),
                     ("thread", "--alias", "planning", "--cursor", "desk", "--all"),
                     ("thread", "--alias", "planning", "--cursor", "desk", "--window", "1")):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertEqual(self.requests(), [])
        self.assertIn("--cursor", re.sub(r".\x08", "", self.run_cli("watch", "--help").stdout))


if __name__ == "__main__":
    unittest.main()
