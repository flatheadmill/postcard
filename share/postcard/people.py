#!/usr/bin/env python3
"""Validate and project Slack's paginated user directory."""

import json
import re
import sys
import unicodedata


USER_ID = re.compile(r"^[UW][A-Z0-9]+$")
FIELDS = ("username", "display_name", "real_name")


def canonical(value):
    return unicodedata.normalize("NFKC", " ".join(value.split())).casefold()


def optional_text(value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("invalid Slack user name")
    value = " ".join(value.split())
    return value or None


def optional_bool(member, name):
    value = member.get(name)
    if value is not None and not isinstance(value, bool):
        raise ValueError("invalid Slack user status")
    return value


def inspect_page(page):
    if not isinstance(page, dict) or not isinstance(page.get("members"), list):
        raise ValueError("invalid people response")
    metadata = page.get("response_metadata")
    if metadata is None:
        metadata = {}
    if not isinstance(metadata, dict):
        raise ValueError("invalid people pagination")
    cursor = metadata.get("next_cursor")
    if cursor is None:
        cursor = ""
    if not isinstance(cursor, str) or (page.get("has_more") is True and not cursor):
        raise ValueError("invalid people pagination cursor")
    return cursor


def person(member):
    if not isinstance(member, dict):
        raise ValueError("invalid Slack user")
    user_id = member.get("id")
    if not isinstance(user_id, str) or not USER_ID.fullmatch(user_id):
        raise ValueError("invalid Slack user ID")
    profile = member.get("profile")
    if profile is None:
        profile = {}
    if not isinstance(profile, dict):
        raise ValueError("invalid Slack user profile")
    return {
        "id": user_id,
        "username": optional_text(member.get("name")),
        "display_name": optional_text(profile.get("display_name")),
        "real_name": optional_text(profile.get("real_name", member.get("real_name"))),
        "deleted": optional_bool(member, "deleted"),
        "is_bot": optional_bool(member, "is_bot"),
        "is_app_user": optional_bool(member, "is_app_user"),
        "is_restricted": optional_bool(member, "is_restricted"),
        "is_ultra_restricted": optional_bool(member, "is_ultra_restricted"),
    }


def options(query, count):
    if not query or query != query.strip() or not query.strip():
        raise ValueError("--query must be non-whitespace without leading or trailing whitespace")
    if not re.fullmatch(r"(?:[1-9][0-9]?|100)", count):
        raise ValueError("--count must be a canonical decimal integer from 1 to 100")
    return {"query": query, "count": int(count)}


def project(value):
    request, context, pages = value["request"], value["context"], value["pages"]
    if not isinstance(request, dict) or not isinstance(context, dict) or not isinstance(pages, list):
        raise ValueError("invalid people projection")
    request = options(request.get("query"), str(request.get("count")))
    if not isinstance(context.get("account"), str) or not context["account"]:
        raise ValueError("invalid people context")
    if not isinstance(context.get("team"), dict) or not isinstance(context.get("user"), dict):
        raise ValueError("invalid people context")

    query = canonical(request["query"])
    seen = set()
    matches = []
    for page in pages:
        inspect_page(page)
        for raw in page["members"]:
            candidate = person(raw)
            if candidate["id"] in seen:
                raise ValueError("duplicate Slack user ID")
            seen.add(candidate["id"])
            matched = [name for name in FIELDS
                       if candidate[name] is not None and query in canonical(candidate[name])]
            if not matched:
                continue
            exact = any(canonical(candidate[name]) == query for name in matched)
            candidate["matched"] = matched
            order = tuple(canonical(candidate[name] or "") for name in
                          ("display_name", "real_name", "username"))
            matches.append(((0 if exact else 1, *order, candidate["id"]), candidate))

    matches.sort(key=lambda item: item[0])
    candidates = [item[1] for item in matches[:request["count"]]]
    return {
        **context,
        "query": request["query"],
        "matched_count": len(matches),
        "returned": len(candidates),
        "truncated": len(candidates) < len(matches),
        "candidates": candidates,
    }


def main():
    try:
        if sys.argv[1] == "options":
            result = options(sys.argv[2], sys.argv[3])
        elif sys.argv[1] == "page":
            result = {"cursor": inspect_page(json.load(sys.stdin))}
        else:
            result = project(json.load(sys.stdin))
        print(json.dumps(result, ensure_ascii=True, indent=None if sys.argv[1] == "options" else 2))
    except (IndexError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"postcard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
