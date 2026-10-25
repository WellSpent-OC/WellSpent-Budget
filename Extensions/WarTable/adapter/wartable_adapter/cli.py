"""No credential values are accepted as command-line arguments or printed."""

from __future__ import annotations

import argparse
import getpass
import json
from pathlib import Path
import sys

from .client import AdapterError, Client, private_json, save_private_json
from .mcp import MCP
from .service import Service, TOOLS
from .work import probe_sandbox


def parser():
    result = argparse.ArgumentParser(prog="wartable", description="WarTable local MCP and CLI connector")
    result.add_argument("--config", type=Path, default=Path.home() / ".config/wartable/session.json", help="Private session credential JSON (0600)")
    result.add_argument("--bindings", type=Path, help="Private human-managed source bindings JSON (0600)")
    result.add_argument("--state-directory", type=Path, default=Path.home() / ".local/state/wartable/runs")
    commands = result.add_subparsers(dest="command", required=True)
    enroll = commands.add_parser("enroll", help="Exchange a one-time code; prompts without echo")
    enroll.add_argument("--server", required=True)
    enroll.add_argument("--code-stdin", action="store_true", help="Read the one-time code from stdin for automation")
    commands.add_parser("mcp", help="Serve MCP over newline-delimited JSON-RPC stdio")
    commands.add_parser("tools", help="List supported tool schemas without accessing a server")
    commands.add_parser("sandbox-check", help="Verify the enforced Linux check sandbox can start")
    call = commands.add_parser("call", help="Call a tool using a JSON object from stdin")
    call.add_argument("tool", choices=[item["name"] for item in TOOLS])
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command == "tools":
            print(json.dumps({"tools": TOOLS}, indent=2))
            return 0
        if args.command == "sandbox-check":
            probe_sandbox()
            print("Linux networkless sandbox is available. Native tools outside this connector are not confined by it.")
            return 0
        if args.command == "enroll":
            if args.config.exists():
                raise AdapterError("Session file already exists. Use a separate file for each agent session.")
            code = sys.stdin.readline(4096).strip() if args.code_stdin else getpass.getpass("One-time WarTable enrollment code: ")
            if not code or len(code) > 1024:
                raise AdapterError("Enrollment code is missing or too long.")
            client = Client({"serverURL": args.server})
            credential = client.request("POST", "/agents/connect", {"code": code}, authenticated=False)
            if not all(isinstance(credential.get(key), str) and credential[key] for key in ("groupID", "agentID", "token")):
                raise AdapterError("Enrollment returned an incomplete credential.")
            save_private_json(args.config, {"serverURL": client.url, **credential})
            print("Session enrolled. Credential saved in the selected private file; no token was printed.")
            return 0
        client = Client(private_json(args.config.expanduser()))
        bindings = private_json(args.bindings.expanduser()) if args.bindings else {}
        service = Service(client, bindings, args.state_directory)
        if args.command == "mcp":
            MCP(service).serve(sys.stdin, sys.stdout)
        else:
            raw = sys.stdin.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise AdapterError("Tool arguments exceed the transport limit.")
            value = service.call(args.tool, json.loads(raw or "{}"))
            print(json.dumps(value, ensure_ascii=False, indent=2))
        return 0
    except AdapterError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print("Connector setup or input is invalid. Check private configuration and JSON arguments.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
