"""Exact addresses and thread projections. Input contains no credentials.

Zsh owns account selection, storage and Slack requests. This helper only
parses public command arguments and projects already fetched JSON pages.
"""

import argparse
import json
import re
import sys
from urllib.parse import parse_qs, urlsplit


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+\.[0-9]{6}", value):
        raise ValueError("expected an exact Slack timestamp with six fractional digits")
    return value


def timestamp_key(value):
    seconds, fraction = timestamp(value).split(".")
    return int(seconds), int(fraction)


def channel_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[CDG][A-Z0-9]+", value):
        raise ValueError("expected an exact Slack conversation ID")
    return value


def alias_name(value):
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", value):
        raise ValueError("alias names use lowercase letters, numbers, dots, underscores and hyphens")
    return value


def permalink_address(value):
    url = urlsplit(value)
    match = re.fullmatch(r"/archives/([CDG][A-Z0-9]+)/p([0-9]{7,})", url.path)
    if url.scheme != "https" or not url.hostname or url.username or url.password or not match:
        raise ValueError("expected an HTTPS Slack message permalink")
    query = parse_qs(url.query, keep_blank_values=True)
    if "thread_ts" in query:
        if len(query["thread_ts"]) != 1:
            raise ValueError("permalink must have only one thread_ts")
        ts = timestamp(query["thread_ts"][0])
    else:
        packed = match[2]
        ts = timestamp(packed[:-6] + "." + packed[-6:])
    return {"channel": match[1], "ts": ts}


def thread_address(options):
    forms = sum(("alias" in options, "permalink" in options,
                 "channel" in options or "ts" in options))
    if forms != 1:
        raise ValueError("give --alias, --permalink, or both --channel and --ts")
    if "alias" in options:
        return {"alias": alias_name(options["alias"])}
    if "permalink" in options:
        return permalink_address(options["permalink"])
    if "channel" not in options or "ts" not in options:
        raise ValueError("--channel and --ts must be supplied together")
    return {"channel": channel_id(options["channel"]), "ts": timestamp(options["ts"])}


class Once(argparse.Action):
    def __call__(self, parser, namespace, value, option_string=None):
        if hasattr(namespace, self.dest):
            parser.error(f"{option_string} may be supplied only once")
        setattr(namespace, self.dest, value)


def command_options(command, arguments):
    parser = argparse.ArgumentParser(prog=f"postcard {command}", add_help=False, allow_abbrev=False,
                                     argument_default=argparse.SUPPRESS)
    parser.add_argument("-h", "--help", action="store_true")
    if command in ("thread", "alias"):
        for option in ("permalink", "channel", "ts"):
            parser.add_argument("--" + option, action=Once)
    if command == "alias":
        parser.add_argument("name", nargs="?")
        parser.add_argument("--delete", action="store_true")
    elif command == "thread":
        for option in ("alias", "around", "from", "through", "window", "after"):
            parser.add_argument("--" + option, action=Once)
        parser.add_argument("--all", action="store_true")
    elif command == "post":
        parser.add_argument("destination", nargs="?")
        for option in ("alias", "thread", "model"):
            parser.add_argument("--" + option, action=Once)
    else:
        raise ValueError("unknown command")
    options = vars(parser.parse_args(arguments))
    if options.get("help"):
        return {}

    if command == "alias":
        name = options.get("name")
        addressed = any(field in options for field in ("permalink", "channel", "ts"))
        if name is None:
            if addressed or options.get("delete"):
                raise ValueError("binding or deleting an alias requires a name")
            return {"action": "list"}
        alias_name(name)
        if options.get("delete"):
            if addressed:
                raise ValueError("--delete does not take a thread address")
            return {"action": "delete", "name": name}
        if addressed:
            return {"action": "bind", "name": name, "address": thread_address(options)}
        return {"action": "get", "name": name}

    if command == "post":
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._/-]{0,63}", options.get("model", "")):
            raise ValueError("post requires --model with a valid 1–64 character model name")
        if "alias" in options:
            if "destination" in options or "thread" in options:
                raise ValueError("--alias replaces the destination and --thread")
            address = {"alias": alias_name(options["alias"])}
        else:
            destination = options.get("destination", "")
            if destination != "self" and not re.fullmatch(r"[CDGUW][A-Z0-9]+", destination):
                raise ValueError("post needs one exact conversation ID, user ID, or self")
            address = {"channel": destination}
            if "thread" in options:
                address["ts"] = timestamp(options["thread"])
        return {"address": address, "model": options["model"]}

    address = thread_address(options)
    modes = sum((options.get("all", False), "around" in options,
                 "from" in options or "through" in options, "after" in options))
    if modes > 1:
        raise ValueError("--all, --around, --from/--through and --after are mutually exclusive")
    kind = ("all" if options.get("all") else "around" if "around" in options else
            "range" if "from" in options or "through" in options else
            "after" if "after" in options else "ends")
    if "window" in options and kind not in ("ends", "around"):
        raise ValueError(f"--window does not apply to --{kind}")
    projection = {"kind": kind}
    if kind in ("ends", "around"):
        window = options.get("window", "8")
        if not re.fullmatch(r"(?:[1-9][0-9]?|100)", window):
            raise ValueError("--window must be a decimal integer from 1 through 100, without leading zeros")
        projection["window"] = int(window)
    for option, field in (("around", "anchor"), ("from", "oldest"), ("through", "latest"), ("after", "after")):
        if option in options:
            projection[field] = timestamp(options[option])
    if "oldest" in projection and "latest" in projection:
        if timestamp_key(projection["oldest"]) > timestamp_key(projection["latest"]):
            raise ValueError("--from must not be later than --through")
    return {"address": address, "projection": projection}


def message_facts(message, channel, parent):
    # Keep sender-provided text and Slack's provenance as data. A card-shaped
    # string is not evidence of which application or person sent a message.
    files = message.get("files")
    if files is None:
        files = []
    if not isinstance(files, list) or any(not isinstance(file, dict) for file in files):
        raise ValueError("invalid Slack message files")
    return {
        "channel": channel, "ts": message["ts"], "thread_ts": message.get("thread_ts", parent),
        "sender": message.get("user"), "text": message.get("text"), "blocks": message.get("blocks"),
        "subtype": message.get("subtype"), "app_id": message.get("app_id"),
        "bot_id": message.get("bot_id"), "edited": message.get("edited"),
        "files": [{key: file.get(key) for key in ("id", "name", "mimetype", "size")}
                  for file in files],
    }


def project(request, pages):
    channel, parent = request["address"]["channel"], request["address"]["ts"]
    projection = request["projection"]
    kind = projection["kind"]
    by_timestamp = {}
    for page in pages:
        for message in page["messages"]:
            if not isinstance(message, dict):
                raise ValueError("invalid Slack thread message")
            ts = timestamp(message.get("ts"))
            thread_ts = message.get("thread_ts")
            if thread_ts is not None:
                timestamp(thread_ts)
            if ts == parent and thread_ts is not None and thread_ts != parent:
                raise ValueError(f"requested parent is a reply; use --channel {channel} --ts {thread_ts}")
            by_timestamp[ts] = message
    ordered = sorted(by_timestamp.values(), key=lambda message: timestamp_key(message["ts"]))
    if kind != "after" and parent not in by_timestamp:
        raise ValueError("Slack did not return the requested parent message")

    omission = None
    if kind == "after":
        ordered = [message for message in ordered
                   if timestamp_key(message["ts"]) > timestamp_key(projection["after"])]
        selected = ordered
    elif kind == "ends":
        replies = [message for message in ordered if message["ts"] != parent]
        window = projection["window"]
        chosen = {parent, *(message["ts"] for message in replies[:window] + replies[-window:])}
        selected = [message for message in ordered if message["ts"] in chosen]
        if len(selected) < len(ordered):
            before = replies[-window]["ts"]
            omission = {"after": replies[window - 1]["ts"], "before": before,
                        "before_index": next(i for i, message in enumerate(selected) if message["ts"] == before),
                        "count": len(ordered) - len(selected)}
    elif kind == "around":
        anchor, window = projection["anchor"], projection["window"]
        if anchor not in by_timestamp:
            raise ValueError("Slack did not return the requested anchor message")
        replies = [message for message in ordered if message["ts"] != parent]
        if anchor == parent:
            selected = [by_timestamp[parent], *replies[:window]]
        else:
            index = next(i for i, message in enumerate(replies) if message["ts"] == anchor)
            selected = replies[max(0, index - window):index + window + 1]
    elif kind == "range":
        selected = [message for message in ordered
                    if ("oldest" not in projection or timestamp_key(message["ts"]) >= timestamp_key(projection["oldest"]))
                    and ("latest" not in projection or timestamp_key(message["ts"]) <= timestamp_key(projection["latest"]))]
    else:
        selected = ordered

    summary = (f"{len(ordered)} messages fetched after {projection['after']}" if kind == "after" else
               f"{len(ordered)} unique messages fetched; {len(selected)} shown")
    if kind == "around":
        summary += "; messages outside this window are excluded"
    return {"channel": channel, "ts": parent, "projection": projection,
            "text_format": "slack", "fetched_count": len(ordered), "shown_count": len(selected),
            "omission": omission, "summary": summary,
            "messages": [message_facts(message, channel, parent) for message in selected]}


def main():
    try:
        if sys.argv[1] == "options":
            result = command_options(sys.argv[2], sys.argv[3:])
        else:
            value = json.load(sys.stdin)
            result = project(value["request"], value["pages"])
        print(json.dumps(result, ensure_ascii=True))
    except (ValueError, KeyError, TypeError) as error:
        print(f"postcard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
