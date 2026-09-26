"""Public reader state. The calling Zsh session owns the account lock.

No tokens or HTTP enter this helper. A bookmark names delivered Slack content;
looks counts successful outputs, even when no newer content was returned.
"""

import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

from thread import channel_id, reader_name, timestamp, timestamp_key


def load(file, binding):
    if not file.exists() and not file.is_symlink():
        return {"version": 1, "binding": binding, "threads": []}
    info = file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("cursor state must be a regular file owned by this user")
    state = json.loads(file.read_text())
    if not isinstance(state, dict) or state.get("version") != 1 or not isinstance(state.get("threads"), list):
        raise ValueError("invalid cursor state")
    if state.get("binding") != binding:
        raise ValueError("cursor state belongs to a different Slack client, team or user")
    seen = set()
    for entry in state["threads"]:
        address = (channel_id(entry["channel"]), timestamp(entry["ts"]))
        if address in seen:
            raise ValueError("duplicate thread in cursor state")
        seen.add(address)
        if timestamp_key(entry["after"]) < timestamp_key(entry["start_after"]):
            raise ValueError("cursor precedes its declared start")
        if type(entry["looks"]) is not int or entry["looks"] < 1:
            raise ValueError("invalid cursor look count")
    return state


def find(state, address):
    return next((entry for entry in state["threads"]
                 if (entry["channel"], entry["ts"]) == (address["channel"], address["ts"])), None)


def prepare(state, request, binding):
    entry = find(state, request["address"])
    initial = request.get("after")
    if entry is None:
        if initial is None:
            raise ValueError("cursor is not initialized for this thread; read with --cursor NAME --after TIMESTAMP first")
        entry = {**request["address"], "start_after": timestamp(initial), "after": initial, "looks": 0}
    elif initial is not None:
        raise ValueError("cursor is already initialized; omit --after to continue")
    return {"reader": reader_name(request["reader"]), "binding": binding,
            "address": request["address"], "existed": entry["looks"] != 0,
            "start_after": entry["start_after"], "after": entry["after"], "looks": entry["looks"]}


def merge(state, ticket, through, binding):
    if ticket["binding"] != binding:
        raise ValueError("Slack account identity changed during the read")
    entry = find(state, ticket["address"])
    if entry is None:
        if ticket["existed"]:
            raise ValueError("cursor was removed during the read; it was not recreated")
        entry = {**ticket["address"], "start_after": ticket["start_after"],
                 "after": ticket["after"], "looks": 0}
        state["threads"].append(entry)
    if entry["start_after"] != ticket["start_after"]:
        raise ValueError("cursor's declared start changed during the read")
    entry["after"] = max(entry["after"], timestamp(through), key=timestamp_key)
    entry["looks"] += 1


def save(file, state):
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".cursor.", dir=file.parent)
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream, ensure_ascii=True, indent=2)
            stream.write("\n")
        os.replace(temporary, file)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


def retry_after(headers):
    # A proxy may add an earlier response block; use the final HTTP response.
    delay = 0
    for line in headers.splitlines():
        if line.startswith("HTTP/"):
            delay = 0
        match = re.fullmatch(r"retry-after:\s*([0-9]+)\s*", line, re.IGNORECASE)
        if match:
            delay = int(match[1]) if len(match[1]) <= 10 else 0
            if delay > 2147483647:
                delay = 0
    return delay


def main():
    try:
        if sys.argv[1] == "retry-after":
            print(retry_after(sys.stdin.read()))
            return 0
        value = json.load(sys.stdin)
        file = Path(sys.argv[2])
        binding = value["binding"]
        state = load(file, binding)
        if sys.argv[1] == "prepare":
            print(json.dumps(prepare(state, value["request"], binding)))
        elif sys.argv[1] == "commit":
            merge(state, value["ticket"], value["through"], binding)
            save(file, state)
        else:
            raise ValueError("unknown reader operation")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"postcard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
