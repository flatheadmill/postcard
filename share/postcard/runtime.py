"""Foreground cursor-read/watch lifecycle; credentials and HTTP stay in Zsh.

Each worker owns a process group so signals reach its shell, curl and helpers.
The parent waits for the worker, including on cancellation. No daemon survives.
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


WORKER = r'''
typeset -gA postcard=(root "$1" directory "$HOME/.config/postcard" account "$2")
for part in postcard accounts threads readers; do source "$1/share/postcard/$part.zsh" || exit; done
request=$(cat) || exit
postcard_session "postcard_$3" "$request"
'''


class Interrupted(Exception):
    def __init__(self, number):
        self.number = number


class Runtime:
    def __init__(self, root, account):
        self.root = str(root)
        self.account = account
        self.child = None
        self.starting = False
        self.cancelled = None

    def interrupt(self, number, _frame):
        # The first signal owns shutdown. Further signals must not interrupt
        # group termination, reaping, or discarding blocked stdout.
        for stop in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(stop, signal.SIG_IGN)
        if self.starting:
            self.cancelled = number
            return
        raise Interrupted(number)

    def call(self, operation, value):
        child = None
        self.starting = True
        try:
            child = subprocess.Popen(
                ["zsh", "-f", "-c", WORKER, "postcard-worker", self.root, self.account, operation],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True,
            )
            self.child = child
            self.starting = False
            if self.cancelled is not None:
                raise Interrupted(self.cancelled)
            output, _ = child.communicate(json.dumps(value).encode())
        except BaseException:
            # A shell may defer its trap while waiting for curl. Signal every
            # member of this owned group, then reap its leader before returning.
            if child is not None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                while True:
                    try:
                        child.communicate()
                        break
                    except Interrupted:
                        continue
            raise
        finally:
            self.starting = False
            self.child = None
        if child.returncode:
            raise SystemExit(child.returncode if child.returncode > 0 else 128 - child.returncode)
        return json.loads(output) if output.strip() else None

    def read(self, request):
        envelope = self.call("reader_read", request)
        result, ticket = envelope["result"], envelope["ticket"]
        self.account = result["account"]
        sys.stdout.write(json.dumps(result, ensure_ascii=True, indent=2) + "\n")
        sys.stdout.flush()
        through = result["messages"][-1]["ts"] if result["messages"] else ticket["after"]
        self.call("reader_commit", {"ticket": ticket, "through": through})

    def watch(self, request):
        pending = None
        while True:
            value = self.call("watch_probe", {"request": request, "pending": pending})
            self.account = value["account"]
            if value.get("found"):
                # Names have a restricted ASCII grammar; this is a copyable
                # command, and no Slack sender content enters the instruction.
                print(f"You have messages: `postcard --account {self.account} thread "
                      f"--alias {request['address']['alias']} --cursor {request['reader']}`.", flush=True)
                pending = value["key"]
            time.sleep(max(request["interval"], value.get("retry_after", 0)))


def main():
    runtime = Runtime(Path(sys.argv[1]), sys.argv[4])
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, runtime.interrupt)
    try:
        request = json.loads(sys.argv[3])
        if sys.argv[2] == "read":
            runtime.read(request)
        else:
            runtime.watch(request)
    except Interrupted as error:
        discard_stdout()
        return 128 + error.number
    except BrokenPipeError:
        # Suppress a second flush error during interpreter shutdown.
        discard_stdout()
        return 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"postcard: {error}", file=sys.stderr)
        return 1
    return 0


def discard_stdout():
    # Cancellation during a blocked flush must not block again at shutdown.
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), sys.stdout.fileno())


if __name__ == "__main__":
    sys.exit(main())
