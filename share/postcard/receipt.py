#!/usr/bin/env python3
"""Persist and check exact public facts about locally sent Slack messages."""

import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


CLIENT = re.compile(r"^[0-9]+\.[0-9]+$")
TEAM = re.compile(r"^T[A-Z0-9]+$")
CHANNEL = re.compile(r"^[CDG][A-Z0-9]+$")
USER = re.compile(r"^[UW][A-Z0-9]+$")
TIMESTAMP = re.compile(r"^[0-9]+\.[0-9]{6}$")


def checked(value, pattern, name):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ValueError(f"invalid {name}")
    return value


def record_from(value):
    response = value["response"]
    expected = value["expected"]
    origin = value["origin"]
    if not all(isinstance(item, dict) for item in (response, expected, origin)):
        raise ValueError("invalid local send receipt")
    team = checked(expected.get("team"), TEAM, "Slack workspace ID")
    channel = checked(response.get("channel"), CHANNEL, "Slack conversation ID")
    if channel != checked(expected.get("channel"), CHANNEL, "expected Slack conversation ID"):
        raise ValueError("Slack returned a different conversation for the post")
    message_ts = checked(response.get("ts"), TIMESTAMP, "Slack message timestamp")
    thread = expected.get("thread")
    if thread is not None:
        thread = checked(thread, TIMESTAMP, "Slack thread timestamp")
    parent = thread or message_ts
    message = response.get("message")
    if message is None:
        message = {}
    if not isinstance(message, dict):
        raise ValueError("invalid Slack posted message")
    if message.get("ts") is not None and message["ts"] != message_ts:
        raise ValueError("Slack returned contradictory message timestamps")
    if message.get("thread_ts") is not None and message["thread_ts"] != parent:
        raise ValueError("Slack returned a contradictory thread timestamp")
    user = checked(expected.get("user"), USER, "authenticated Slack user ID")
    if message.get("user") is not None and message["user"] != user:
        raise ValueError("Slack returned a contradictory message sender")
    binding = {
        "client_id": checked(origin.get("client_id"), CLIENT, "Slack client ID"),
        "team_id": checked(origin.get("team_id"), TEAM, "sending workspace ID"),
        "user_id": checked(origin.get("user_id"), USER, "sending user ID"),
    }
    if binding["team_id"] != team or binding["user_id"] != user:
        raise ValueError("sending identity does not match the checked post")
    return {
        "version": 1,
        "team": team,
        "channel": channel,
        "ts": message_ts,
        "thread_ts": parent,
        "sender": user,
        "origin": binding,
    }


def validate_record(value):
    if not isinstance(value, dict) or value.get("version") != 1:
        raise ValueError("invalid local send receipt version")
    record = {
        "version": 1,
        "team": checked(value.get("team"), TEAM, "receipt workspace ID"),
        "channel": checked(value.get("channel"), CHANNEL, "receipt conversation ID"),
        "ts": checked(value.get("ts"), TIMESTAMP, "receipt message timestamp"),
        "thread_ts": checked(value.get("thread_ts"), TIMESTAMP, "receipt thread timestamp"),
        "sender": checked(value.get("sender"), USER, "receipt sender ID"),
    }
    origin = value.get("origin")
    if not isinstance(origin, dict):
        raise ValueError("invalid receipt origin")
    record["origin"] = {
        "client_id": checked(origin.get("client_id"), CLIENT, "receipt client ID"),
        "team_id": checked(origin.get("team_id"), TEAM, "receipt origin workspace ID"),
        "user_id": checked(origin.get("user_id"), USER, "receipt origin user ID"),
    }
    if record["origin"]["team_id"] != record["team"]:
        raise ValueError("receipt origin belongs to another workspace")
    if record["origin"]["user_id"] != record["sender"]:
        raise ValueError("receipt origin belongs to another sender")
    return record


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("receipt must be a private regular file owned by this user")


def receipt_path(root, team, channel, message_ts):
    return root / team / channel / f"{message_ts}.json"


def publish(root, value):
    record = validate_record(record_from(value))
    path = receipt_path(root, record["team"], record["channel"], record["ts"])
    encoded = json.dumps(record, ensure_ascii=True, sort_keys=True, indent=2) + "\n"
    if path.exists() or path.is_symlink():
        private_file(path)
        existing = validate_record(json.loads(path.read_text()))
        if existing != record:
            raise ValueError("conflicting local send receipt was preserved")
        return
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=".receipt.", dir=path.parent)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(encoded)
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, path)
        except FileExistsError:
            private_file(path)
            existing = validate_record(json.loads(path.read_text()))
            if existing != record:
                raise ValueError("conflicting local send receipt was preserved")
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def candidate_proven(root, team, channel, parent, candidate):
    if not isinstance(candidate, dict):
        raise ValueError("invalid observed Slack message")
    message_ts = checked(candidate.get("ts"), TIMESTAMP, "observed message timestamp")
    observed_parent = candidate.get("thread_ts", parent)
    if observed_parent is None:
        observed_parent = parent
    observed_parent = checked(observed_parent, TIMESTAMP, "observed thread timestamp")
    sender = candidate.get("sender")
    if sender is not None:
        sender = checked(sender, USER, "observed sender ID")
    path = receipt_path(root, team, channel, message_ts)
    if not path.exists() and not path.is_symlink():
        return False
    private_file(path)
    record = validate_record(json.loads(path.read_text()))
    if (record["team"], record["channel"], record["ts"], record["thread_ts"]) != (
            team, channel, message_ts, observed_parent):
        raise ValueError("local send receipt contradicts the observed message address")
    if sender is not None and sender != record["sender"]:
        raise ValueError("local send receipt contradicts the observed sender")
    return True


def classify(root, value):
    team = checked(value.get("team"), TEAM, "Slack workspace ID")
    channel = checked(value.get("channel"), CHANNEL, "Slack conversation ID")
    parent = checked(value.get("thread_ts"), TIMESTAMP, "Slack thread timestamp")
    candidates = value.get("candidates")
    if not isinstance(candidates, list):
        raise ValueError("invalid observed Slack candidates")
    for candidate in candidates:
        try:
            if not candidate_proven(root, team, channel, parent, candidate):
                return {"found": True}
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            print(f"postcard: unusable local send receipt: {error}; notifying normally", file=sys.stderr)
            return {"found": True}
    return {"found": False}


def main():
    try:
        operation, root = sys.argv[1], Path(sys.argv[2])
        value = json.load(sys.stdin)
        if operation == "publish":
            publish(root, value)
        elif operation == "classify":
            print(json.dumps(classify(root, value)))
        else:
            raise ValueError("unknown receipt operation")
    except (IndexError, OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"postcard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
