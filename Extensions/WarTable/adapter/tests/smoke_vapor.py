"""Opt-in integration smoke against an explicitly supplied disposable server.

Never discovered by unit tests. Uses synthetic example.com accounts and the
server's test mailbox, which production does not provide. No provider/model calls.
"""

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import uuid

from wartable_adapter.client import save_private_json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--mailbox-env-file", type=Path, help="Otherwise uses WELLSPENT_UI_TEST_MAILBOX_TOKEN")
    parser.add_argument("--review-fixture-file", type=Path, help="Optional private JSON output for a repeatable human review UI fixture")
    args = parser.parse_args()
    if urlsplit(args.server).hostname not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit("This smoke script only accepts a loopback disposable server.")
    mailbox = (next(line.split("=", 1)[1].strip() for line in args.mailbox_env_file.read_text().splitlines() if line.startswith("TEST_MAILBOX_TOKEN="))
               if args.mailbox_env_file else os.environ.get("WELLSPENT_UI_TEST_MAILBOX_TOKEN", ""))
    if not mailbox:
        raise SystemExit("A disposable server test mailbox token is required.")

    def request(method, path, body=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        with urlopen(Request(args.server.rstrip("/") + path, data=json.dumps(body).encode() if body is not None else None,
                             method=method, headers=headers), timeout=20) as response:
            data = response.read()
            return json.loads(data) if data else None

    unique = uuid.uuid4().hex
    email = "wartable-adapter-" + unique + "@example.com"
    password = "Fixture-only-" + unique
    owner = request("POST", "/api/v2/signup", {"email": email, "password": password, "deviceLabel": "WarTable connector fixture"})
    message = request("GET", "/test/mailbox?" + urlencode({"address": email}), token=mailbox)
    request("POST", "/api/v2/email/verify", {"code": message["code"]}, owner["token"])
    group = str(uuid.uuid4())
    group_name = "WarTable review " + unique[:8]
    request("POST", "/api/v2/groups", {"id": group}, owner["token"])
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    group_record = {"id": group, "name": group_name, "note": "Synthetic connector integration fixture", "createdAt": stamp, "updatedAt": stamp, "isDeleted": False}
    seeded = request("POST", "/api/v2/groups/" + group + "/push", {"records": [
        {"id": group, "type": "groupMeta", "lamport": 1, "clientID": str(uuid.uuid4()), "isDeleted": False, "body": json.dumps(group_record)}]}, owner["token"])
    assert group.lower() in [value.lower() for value in seeded["accepted"]], "Synthetic group label was not saved"
    prefix = "/extensions/wartable/v1"
    base = prefix + "/groups/" + group
    snapshot = request("PUT", base, {"enabled": True, "displayName": "Fixture owner"}, owner["token"])
    room = snapshot["conversations"][0]["id"]
    results = []
    with tempfile.TemporaryDirectory(prefix="wartable-vapor-smoke-") as temporary:
        root = Path(temporary)
        configs = {}
        credentials = {}
        for name, provider in (("Claude", "Claude Code"), ("Codex", "ChatGPT/Codex"), ("Gemini", "Gemini CLI")):
            enrollment = request("POST", base + "/agents/enroll", {"name": name, "provider": provider, "machine": "Synthetic fixture",
                                 "executionProfile": "enforced-local" if name == "Claude" else "chat-only"}, owner["token"])
            config = root / (name + ".json")
            process = subprocess.run([sys.executable, "-m", "wartable_adapter", "--config", str(config), "enroll", "--server", args.server, "--code-stdin"],
                                     input=enrollment["code"] + "\n", capture_output=True, text=True, timeout=20)
            assert process.returncode == 0, "Enrollment CLI failed"
            credentials[name] = json.loads(config.read_text())
            configs[name] = config
            assert credentials[name]["token"] not in process.stdout + process.stderr
        bindings = root / "bindings.json"
        save_private_json(bindings, {})

        def call(name, tool, arguments, expected_error=False):
            lines = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": name, "version": "synthetic-stdio-smoke"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": arguments}},
            ]
            process = subprocess.run([sys.executable, "-m", "wartable_adapter", "--config", str(configs[name]), "--bindings", str(bindings),
                                      "--state-directory", str(root / "runs"), "mcp"],
                                     input="".join(json.dumps(line) + "\n" for line in lines), capture_output=True, text=True, timeout=40)
            assert process.returncode == 0, "MCP process failed"
            assert credentials[name]["token"] not in process.stdout + process.stderr
            output = [json.loads(line) for line in process.stdout.splitlines()][-1]["result"]
            if expected_error:
                assert output["isError"], "Expected access denial"
                return None
            if output["isError"]:
                raise AssertionError(tool + ": " + output["content"][0]["text"])
            return json.loads(output["content"][0]["text"])

        human = request("POST", base + "/messages", {"conversationID": room, "clientMessageID": str(uuid.uuid4()),
                        "text": "@Claude @Codex @Gemini, acknowledge this synthetic integration request.", "sourceIDs": []}, owner["token"])
        for name in configs:
            assert call(name, "wartable_list_conversations", {})["conversations"]
            call(name, "wartable_presence", {"busy": False})
            assert call(name, "wartable_read_messages", {"conversationID": room, "after": 0})["messages"]
            arguments = {"conversationID": room, "clientMessageID": str(uuid.uuid4()), "text": name + " synthetic acknowledgement",
                         "chainID": human["chainID"], "replyTo": human["id"]}
            sent = call(name, "wartable_send_message", arguments)
            assert sent["id"] == call(name, "wartable_send_message", arguments)["id"]
        results.append("Three provider-labeled MCP sessions enrolled, read, replied and retried without duplicates")
        direct = call("Claude", "wartable_create_conversation", {"title": "Synthetic agent handoff", "participantIDs": [credentials["Codex"]["agentID"]]})
        assert owner["userID"] in direct["audienceIDs"]
        assert credentials["Claude"]["agentID"] in direct["audienceIDs"]
        assert credentials["Codex"]["agentID"] in direct["audienceIDs"]
        assert credentials["Gemini"]["agentID"] not in direct["audienceIDs"]
        handoff = call("Claude", "wartable_send_message", {"conversationID": direct["id"], "clientMessageID": str(uuid.uuid4()), "text": "Synthetic handoff to Codex",
                       "chainID": human["chainID"], "replyTo": human["id"]})
        call("Codex", "wartable_send_message", {"conversationID": direct["id"], "clientMessageID": str(uuid.uuid4()), "text": "Synthetic handoff acknowledged",
             "chainID": human["chainID"], "replyTo": handoff["id"]})
        call("Gemini", "wartable_read_messages", {"conversationID": direct["id"]}, expected_error=True)
        results.append("Agent direct handoff retained owner oversight and denied an unselected agent")
        repo = root / "source"
        (repo / "src").mkdir(parents=True)
        (repo / "src/app.py").write_text("value = 1\n")
        source = request("POST", base + "/context-sources", {"name": "Synthetic public source", "kind": "repository", "reference": "https://github.com/example/synthetic",
                         "allowedPaths": ["src"], "audienceIDs": [owner["userID"]] + [c["agentID"] for c in credentials.values()], "isPublic": True}, owner["token"])
        save_private_json(bindings, {"sources": {source["id"]: {"root": str(repo), "allowedPaths": ["src"],
                          "checks": {"syntax": ["/usr/bin/python3", "-c", "import ast; ast.parse(open('src/app.py').read())"]}}}})
        grant = request("POST", base + "/grants", {"subjectID": credentials["Claude"]["agentID"], "sourceID": source["id"],
                        "capabilities": ["readContext", "editBranch", "runChecks"], "allowedPaths": ["src"],
                        "expiresAt": (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "maxRevisionCycles": 2, "maxRuntimeSeconds": 300}, owner["token"])
        task = request("POST", base + "/tasks", {"conversationID": room, "sourceID": source["id"], "title": "Synthetic scoped edit", "details": "Change value and run syntax check",
                       "assigneeID": credentials["Claude"]["agentID"], "grantID": grant["id"], "reviewerID": owner["userID"], "expectedChecks": ["syntax"]}, owner["token"])
        started = call("Claude", "wartable_start_work", {"taskID": task["id"], "requestID": str(uuid.uuid4()), "paths": ["src/app.py"]})
        run = started["run"]
        call("Claude", "wartable_write_work_file", {"runID": run["id"], "path": "src/app.py", "content": "value = 2\n"})
        request("POST", base + "/agents/" + credentials["Claude"]["agentID"] + "/control", {"action": "pause"}, owner["token"])
        call("Claude", "wartable_read_messages", {"conversationID": room}, expected_error=True)
        checked = call("Claude", "wartable_run_check", {"runID": run["id"], "check": "syntax"})
        assert checked["passed"]
        difference = call("Claude", "wartable_work_diff", {"runID": run["id"]})
        assert "+value = 2" in difference["patch"]
        assert (repo / "src/app.py").read_text() == "value = 1\n"
        call("Claude", "wartable_record_evidence", {"taskID": task["id"], "runID": run["id"], "fence": run["fence"],
             "kind": "check", "summary": "Synthetic isolated edit and networkless syntax check passed. Original source remained unchanged."})
        request("POST", base + "/agents/" + credentials["Claude"]["agentID"] + "/control", {"action": "resume"}, owner["token"])
        assert call("Claude", "wartable_read_messages", {"conversationID": room})["messages"]
        results.append("Pausing agent chat denied messages while the already-authorized local check and evidence continued")
        request("POST", base + "/tasks/" + task["id"] + "/stop", {}, owner["token"])
        call("Claude", "wartable_write_work_file", {"runID": run["id"], "path": "src/app.py", "content": "must not write\n"}, expected_error=True)
        cancelled = call("Claude", "wartable_finish_work", {"runID": run["id"], "state": "cancelled", "summary": "Synthetic fixture stopped and acknowledged cleanup."})
        assert cancelled["state"] == "cancelled"
        results.append("Human-granted isolated file edit, sandbox check, patch/evidence and stop acknowledgement passed")
        request("POST", base + "/agents/" + credentials["Gemini"]["agentID"] + "/control", {"action": "revoke"}, owner["token"])
        call("Gemini", "wartable_read_messages", {"conversationID": room}, expected_error=True)
        results.append("Revoked credential could no longer read messages")
        if args.review_fixture_file:
            review_task = request("POST", base + "/tasks", {"conversationID": room, "sourceID": source["id"],
                                  "title": "Review the synthetic scoped edit", "details": "Review the actual local commit and syntax-check evidence. No GitHub publication was performed.",
                                  "assigneeID": credentials["Claude"]["agentID"], "grantID": grant["id"], "reviewerID": owner["userID"], "expectedChecks": ["syntax"]}, owner["token"])
            review_run = call("Claude", "wartable_start_work", {"taskID": review_task["id"], "requestID": str(uuid.uuid4()), "paths": ["src/app.py"]})["run"]
            call("Claude", "wartable_write_work_file", {"runID": review_run["id"], "path": "src/app.py", "content": "value = 3\n"})
            assert call("Claude", "wartable_run_check", {"runID": review_run["id"], "check": "syntax"})["passed"]
            edited = call("Claude", "wartable_read_work_file", {"runID": review_run["id"], "path": "src/app.py"})["content"]
            fixture_output = args.review_fixture_file.expanduser().absolute()
            fixture_output.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            review_repo = fixture_output.parent / ("review-repo-" + unique)
            (review_repo / "src").mkdir(parents=True, mode=0o700)
            templates = review_repo / "empty-git-template"
            templates.mkdir(mode=0o700)

            def git(*arguments):
                process = subprocess.run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                                          "-c", "user.name=WellSpent", "-c", "user.email=dev@wellspent.space", *arguments],
                                         cwd=review_repo, env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TEMPLATE_DIR": str(templates)},
                                         capture_output=True, text=True, timeout=15)
                assert process.returncode == 0, "Synthetic fixture git operation failed"
                return process.stdout.strip()

            git("init", "--initial-branch=main")
            (review_repo / "src/app.py").write_text("value = 1\n")
            git("add", "src/app.py")
            git("commit", "-m", "Synthetic fixture baseline")
            base_commit = git("rev-parse", "HEAD")
            (review_repo / "src/app.py").write_text(edited)
            git("add", "src/app.py")
            git("commit", "-m", "Synthetic isolated edit for advisory review")
            head_commit = git("rev-parse", "HEAD")
            call("Claude", "wartable_record_evidence", {"taskID": review_task["id"], "runID": review_run["id"], "fence": review_run["fence"],
                 "kind": "check", "summary": "Actual adapter edit and networkless syntax check passed. The fixture copied the exact edited file into a new isolated local Git commit. No branch or PR was published.", "commit": head_commit})
            completed = call("Claude", "wartable_finish_work", {"runID": review_run["id"], "state": "awaitingReview", "headCommit": head_commit,
                             "summary": "Local commit is ready for advisory human review. Provider publication is intentionally absent from this synthetic fixture."})
            assert completed["state"] == "awaitingReview" and not completed.get("prURL")
            save_private_json(fixture_output, {"serverURL": args.server, "email": email, "password": password,
                              "groupID": group, "groupName": group_name, "taskID": review_task["id"], "sourceID": source["id"], "headCommit": head_commit,
                              "baseCommit": base_commit, "repositoryDirectory": str(review_repo), "published": False,
                              "taskState": "awaitingReview", "syntheticFixture": True})
            results.append("A private UI fixture file now identifies an actual local Git commit awaiting advisory review, with no provider publication")
    print(json.dumps({"passed": True, "checks": results, "note": "Synthetic MCP protocol clients; no model turn, live account or GitHub write was used."}, indent=2))


if __name__ == "__main__":
    main()
