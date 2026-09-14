#!/usr/bin/env python3
"""One temporary IPv4 loopback callback. Private state enters over stdin."""

import argparse
import hmac
import http.server
import json
import socket
import sys
import time
import urllib.parse


def receive(state, port=8765, timeout=300, ready=lambda: None):
    result = None

    class Callback(http.server.BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(2)
            super().setup()

        def log_message(self, *_):
            pass  # A callback URL contains the authorization code.

        def reply(self, code, message):
            content = message.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            nonlocal result
            url = urllib.parse.urlsplit(self.path)
            if url.path != "/auth" or url.scheme or url.netloc:
                self.reply(404, "Unknown callback path.")
                return
            try:
                query = urllib.parse.parse_qs(
                    url.query, keep_blank_values=True, max_num_fields=20
                )
            except ValueError:
                self.reply(400, "Invalid callback.")
                return
            supplied = query.get("state", [])
            if (len(supplied) != 1 or not hmac.compare_digest(
                supplied[0].encode(), state.encode()
            )):
                self.reply(400, "Login state did not match. Use the current login tab.")
                return
            code, error = query.get("code", []), query.get("error", [])
            if len(error) == 1 and error[0] and not code:
                result = {"error": "authorization_denied"}
                self.reply(400, "Slack authorization was declined. Return to Postcard.")
            elif (len(code) == 1 and code[0] and not error
                  and len(code[0]) < 4096 and not any(ord(c) < 33 for c in code[0])):
                result = {"code": code[0]}
                self.reply(200, "Authorization received. Return to Postcard to finish login.")
            else:
                self.reply(400, "Invalid callback.")

    class Server(http.server.HTTPServer):
        def handle_error(self, *_):
            pass  # No tracebacks containing untrusted HTTP input.

    with Server(("127.0.0.1", port), Callback) as server:
        server.timeout = min(timeout, 0.2)
        ready()
        deadline = time.monotonic() + timeout
        while result is None and time.monotonic() < deadline:
            server.handle_request()
    return result or {"error": "callback_timeout"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--timeout", type=float, default=300)
    options = parser.parse_args()
    state = sys.stdin.readline().strip()
    if len(state) < 32:
        return 1
    try:
        result = receive(state, options.port, options.timeout,
                         lambda: print("ready", flush=True))
    except (OSError, socket.error):
        print(json.dumps({"error": "callback_bind_failed"}), flush=True)
        return 1
    print(json.dumps(result), flush=True)
    return 0 if "code" in result else 1


if __name__ == "__main__":
    sys.exit(main())
