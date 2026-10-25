#!/usr/bin/env python3
"""Run a command against a matching, disposable WellSpent server.

Build the server from the same checkout first, then:
  python3 Server/scripts/with-ui-fixture.py --server Server/.build/debug/WellSpentServer -- Linux/UITests/run.sh

The service binds only to loopback, owns a fresh SQLite database, logs no
credentials to the caller's console, and disappears with its child command.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def stop(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    except ProcessLookupError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("supply a child command after --")
    binary = args.server.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--server must name the executable built from this checkout")

    server = None
    child = None
    interrupted = 0
    temporary = None

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = signum
        raise KeyboardInterrupt

    previous = {number: signal.signal(number, interrupt) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        temporary = tempfile.TemporaryDirectory(prefix="wellspent-ui-fixture-")
        root = Path(temporary.name)
        root.chmod(0o700)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        url = f"http://127.0.0.1:{port}"
        token = secrets.token_hex(32)
        server_env = dict(os.environ)
        # Never inherit a database, provider credential or real mail sender.
        for name in list(server_env):
            if name in {"DATABASE_URL", "SKIP_AUTO_MIGRATE", "TRUSTED_PROXY", "RESEND_API_KEY", "EMAIL_FROM", "EMAIL_CODE_KEY"} or name.startswith(("SMTP_", "WARTABLE_GITHUB_", "MAIL_")):
                del server_env[name]
        server_env.update({
            "WELLSPENT_ENVIRONMENT": "staging",
            "WELLSPENT_SQLITE_PATH": str(root / "fixture.sqlite"),
            "TEST_MAILBOX_TOKEN": token,
            "EMAIL_CODE_KEY": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
            "LLVM_PROFILE_FILE": str(root / "server-%p.profraw"),
        })
        log_path = root / "server.log"
        descriptor = os.open(log_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "wb") as log:
            server = subprocess.Popen(
                [str(binary), "serve", "--env", "development", "--hostname", "127.0.0.1", "--port", str(port)],
                cwd=root, env=server_env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )
            ready = False
            deadline = time.monotonic() + 30
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            while time.monotonic() < deadline and server.poll() is None:
                try:
                    with opener.open(url + "/health", timeout=1) as response:
                        health = json.load(response)
                    if health == {"status": "ok", "environment": "staging"}:
                        ready = True
                        break
                except (OSError, urllib.error.URLError, ValueError):
                    time.sleep(0.1)
            if not ready:
                print("Disposable UI server did not become ready; private logs were not published.", file=sys.stderr)
                return 1
            child_env = dict(os.environ)
            child_env.update({
                "WELLSPENT_UI_SERVER_URL": url,
                "WELLSPENT_UI_TEST_MAILBOX_TOKEN": token,
                "WELLSPENT_UI_NO_SKIPS": "true",
            })
            print("Disposable matching UI server is ready on loopback.", flush=True)
            child = subprocess.Popen(command, env=child_env, start_new_session=True)
            result = child.wait()
            return result if result >= 0 else 128 - result
    except KeyboardInterrupt:
        return 128 + (interrupted or signal.SIGINT)
    finally:
        stop(child)
        stop(server)
        if temporary is not None:
            temporary.cleanup()
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
