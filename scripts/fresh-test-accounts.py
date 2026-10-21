#!/usr/bin/env python3
"""Makes two new staging accounts for one UI test run, through staging's test mailbox.

    python3 -I scripts/fresh-test-accounts.py LABEL FILE

Signs up two accounts at example.com, confirms each with the code staging emails it, and
writes the four WELLSPENT_UI_TEST_ variables for them to FILE, readable by its owner only,
for the run to source. Runs at the same time then never share an account, so one run's
groups never crowd another's screens. LABEL, such as mac-ci-1, goes into the addresses,
so an account on staging says which run made it.

Reads WELLSPENT_UI_TEST_MAILBOX_TOKEN, and WELLSPENT_UI_TEST_SERVER when it is set. The
token and the passwords never reach a command line or the output. In GitHub Actions each
password is masked before anything else is done with it.
"""

import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def call(method, url, body=None, token=None):
    """The status and the JSON answer, or None when there is no body to read."""
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    # Staging's front door turns away Python's own user agent (Cloudflare's
    # error 1010), so the script names itself.
    request.add_header("User-Agent", "WellSpent-UI-test-setup/1.0")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            text = response.read()
            return response.status, json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        return error.code, None


def code_for(server, mailbox, address, timeout=15):
    """The code staging emailed to address, asked for again until it comes."""
    url = f"{server}/test/mailbox?address={urllib.parse.quote(address, safe='')}"
    deadline = time.monotonic() + timeout
    last = "nothing yet"
    while time.monotonic() < deadline:
        try:
            status, message = call("GET", url, token=mailbox)
        except urllib.error.URLError as error:
            status, message, last = 0, None, f"staging could not be reached: {error.reason}"
        if status == 200 and message and message.get("code"):
            return message["code"]
        if status == 401:
            sys.exit("fresh-test-accounts: the test mailbox turned the token down")
        if status:
            last = f"the test mailbox answered {status}"
        time.sleep(0.5)
    sys.exit(f"fresh-test-accounts: no code reached {address} in {timeout} seconds: {last}")


def make_account(server, mailbox, label, stamp, who):
    address = f"{label}-{stamp}-{secrets.token_hex(2)}-{who}@example.com".lower()
    password = secrets.token_urlsafe(18) + "Aa1!"
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{password}")
    status, session = call("POST", f"{server}/api/v2/signup",
                           {"email": address, "password": password, "deviceLabel": f"UI test setup, {label}"})
    if status != 200 or not session:
        sys.exit(f"fresh-test-accounts: staging answered {status} to the sign-up for {address}")
    code = code_for(server, mailbox, address)
    status, _ = call("POST", f"{server}/api/v2/email/verify", {"code": code}, token=session["token"])
    if status not in (200, 204):
        sys.exit(f"fresh-test-accounts: staging answered {status} to the code for {address}")
    # Signs this session out, so the account's list of devices holds only the tests' own.
    call("POST", f"{server}/api/v2/signout", token=session["token"])
    print(f"fresh-test-accounts: made {address}")
    return address, password


def main(arguments):
    if len(arguments) != 2:
        sys.exit("usage: python3 -I scripts/fresh-test-accounts.py LABEL FILE")
    label, path = arguments
    if not label.replace("-", "").isalnum():
        sys.exit("fresh-test-accounts: LABEL takes letters, digits and dashes only, such as mac-ci-1")
    server = (os.environ.get("WELLSPENT_UI_TEST_SERVER") or "https://staging.wellspent.space").rstrip("/")
    mailbox = os.environ.get("WELLSPENT_UI_TEST_MAILBOX_TOKEN")
    if not mailbox:
        sys.exit("fresh-test-accounts: WELLSPENT_UI_TEST_MAILBOX_TOKEN is not set")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    (email, password), (email_2, password_2) = (make_account(server, mailbox, label, stamp, who)
                                                for who in ("robin", "leslie"))
    lines = [f"WELLSPENT_UI_TEST_EMAIL='{email}'", f"WELLSPENT_UI_TEST_PASSWORD='{password}'",
             f"WELLSPENT_UI_TEST_EMAIL_2='{email_2}'", f"WELLSPENT_UI_TEST_PASSWORD_2='{password_2}'"]
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
