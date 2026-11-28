#!/bin/sh
# Tests scripts/fresh-test-accounts.py's retries against a stand-in server on
# this machine, which holds back its first answer to one call past the
# script's time limit. A call safe to send twice (the plan, the mailbox, the
# code) is sent again and the script goes on. A sign-up isn't: a second one
# would be refused as taken, so a lost sign-up still stops the script.
#
#   scripts/fresh-test-accounts-test.sh
set -eu
exec python3 -I - "$(cd "$(dirname "$0")" && pwd)/fresh-test-accounts.py" <<'PY'
import http.server
import importlib.util
import json
import sys
import threading
import time

spec = importlib.util.spec_from_file_location("fresh", sys.argv[1])
fresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fresh)
fresh.REQUEST_SECONDS = 0.5
fresh.RETRY_WAIT = 0

slow = {"path": None}
seen = []


class StandIn(http.server.BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def answer(self, status, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        seen.append(path)
        if slow["path"] == path and seen.count(path) == 1:
            time.sleep(1.5)
        if path == "/api/v2/signup":
            self.answer(200, {"token": "t"})
        elif path == "/test/mailbox":
            self.answer(200, {"code": "ABCD-EFGH"})
        else:
            self.answer(204)

    do_GET = do_POST = handle_any


class Server(http.server.ThreadingHTTPServer):
    # Each answer's thread is waited for when the server closes, so none
    # outlives the test (wellspent-ops#413).
    daemon_threads = False

    def handle_error(self, request, client_address):
        # The script gave up on a late answer and hung up: not a failure.
        if not isinstance(sys.exc_info()[1], ConnectionError):
            super().handle_error(request, client_address)


server = Server(("127.0.0.1", 0), StandIn)
serving = threading.Thread(target=server.serve_forever, daemon=True)
serving.start()
url = f"http://127.0.0.1:{server.server_address[1]}"
failed = 0


def check(got, wanted, what):
    global failed
    print(("pass: " if got == wanted else "FAIL: ") + what + ("" if got == wanted else f": got {got!r}, wanted {wanted!r}"))
    failed |= got != wanted


def run(slow_path, step):
    seen.clear()
    slow["path"] = slow_path
    try:
        step()
        return "went on"
    except SystemExit as stop:
        return f"stopped: {stop}"
    except Exception as error:
        return f"raised {type(error).__name__}"


got = run("/test/plan", lambda: fresh.set_plan(url, "token", "robin@example.com", "portfolio"))
check(got, "went on", "a plan whose first answer is late is sent again, and the script goes on")
check(seen.count("/test/plan"), 2, "the plan was sent twice")

got = run("/api/v2/email/verify", lambda: fresh.make_account(url, "token", "ci", "stamp", "robin"))
check(got, "went on", "a code whose first answer is late is sent again, and the account is made")
check(seen.count("/api/v2/email/verify"), 2, "the code was sent twice")

got = run("/test/mailbox", lambda: fresh.code_for(url, "token", "robin@example.com"))
check(got, "went on", "a mailbox read whose first answer is late is read again")

got = run("/api/v2/signup", lambda: fresh.make_account(url, "token", "ci", "stamp", "robin"))
check(got.startswith("stopped") or got.startswith("raised"), True, "a sign-up whose answer is late stops the script")
check(seen.count("/api/v2/signup"), 1, "and is not sent twice, since a second would be refused as taken")

got = run(None, lambda: fresh.set_plan(url, "token", "robin@example.com", "portfolio"))
check(seen.count("/test/plan"), 1, "an answer in time is sent once")

# A late answer still asleep when the checks end is waited for, so no
# answer is left being written while Python shuts down: one was, and the
# test then crashed after every check had passed (wellspent-ops#413).
run("/test/plan", lambda: fresh.set_plan(url, "token", "robin@example.com", "portfolio"))
server.shutdown()
server.server_close()
serving.join()
left = [t.name for t in threading.enumerate() if t is not threading.main_thread() and t.is_alive()]
check(left, [], "no late answer is still being written when the test ends")
sys.exit(failed)
PY
