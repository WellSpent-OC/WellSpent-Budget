import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from wartable_adapter.client import AdapterError, Client, private_json, save_private_json, service_url
from wartable_adapter.context import Context
from wartable_adapter.mcp import MCP
from wartable_adapter.service import Service, TOOLS
from wartable_adapter.work import probe_sandbox


GROUP = "00000000-0000-4000-8000-000000000001"
AGENT = "00000000-0000-4000-8000-000000000002"
SOURCE = "00000000-0000-4000-8000-000000000003"
TASK = "00000000-0000-4000-8000-000000000004"
GRANT = "00000000-0000-4000-8000-000000000005"
RUN = "00000000-0000-4000-8000-000000000006"
REQUEST = "00000000-0000-4000-8000-000000000007"
CONVERSATION = "00000000-0000-4000-8000-000000000008"


def source():
    return {"id": SOURCE, "name": "Synthetic source", "allowedPaths": ["src"], "isPublic": False, "revision": 1}


class FakeClient:
    group_id = GROUP
    agent_id = AGENT

    def __init__(self):
        self.calls = []
        self.stopped = False
        self.snapshot_value = {
            "contextSources": [source()], "conversations": [{"id": CONVERSATION}],
            "tasks": [{"id": TASK, "sourceID": SOURCE, "grantID": GRANT}],
            "grants": [{"id": GRANT, "allowedPaths": ["src"], "isRevoked": False,
                        "capabilities": ["readContext", "editBranch", "runChecks"], "maxRuntimeSeconds": 15}]}

    def request(self, method, path, body=None, **kwargs):
        self.calls.append((method, path, body, kwargs))
        if path.endswith("/groups/" + GROUP):
            return self.snapshot_value
        if path.endswith("/checkpoint"):
            if self.stopped:
                raise AdapterError("Stopped by server.")
            return {"id": RUN, "fence": 1, "state": "active"}
        if path.endswith("/runs"):
            return {"id": RUN, "taskID": TASK, "requestID": body["requestID"], "fence": 1, "state": "active"}
        if path.endswith("/finish"):
            return {"id": TASK, "state": body["state"]}
        return {"ok": True}


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        (self.root / "src/test.txt").write_text("hello\n")
        (self.root / "secret.txt").write_text("do not disclose")
        self.context = Context({"sources": {SOURCE: {"root": str(self.root), "allowedPaths": ["src"]}}})

    def tearDown(self):
        self.temp.cleanup()

    def test_private_credential_roundtrip_and_permissions(self):
        path = self.root / "session.json"
        save_private_json(path, {"token": "synthetic-only"})
        self.assertEqual(private_json(path)["token"], "synthetic-only")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        path.chmod(0o644)
        with self.assertRaises(AdapterError):
            private_json(path)

    def test_credentials_refuse_symlink(self):
        original = self.root / "original.json"
        save_private_json(original, {"token": "synthetic-only"})
        linked = self.root / "session.json"
        linked.symlink_to(original)
        with self.assertRaises(AdapterError):
            private_json(linked)
        with self.assertRaises(AdapterError):
            save_private_json(linked, {})

    def test_source_is_scoped_and_provenance_is_retained(self):
        # Scenario WARTABLE-06
        result = self.context.read(source(), "src/test.txt")
        self.assertEqual(result["content"], "hello\n")
        self.assertEqual(result["classification"], "restricted")
        self.assertEqual(len(result["sha256"]), 64)
        for path in ("secret.txt", "src/../secret.txt", "/etc/passwd", "src/.git/config", "src//test.txt"):
            with self.assertRaises(AdapterError):
                self.context.read(source(), path)

    def test_symlink_escape_and_fifo_are_rejected(self):
        (self.root / "src/link").symlink_to(self.root / "secret.txt")
        (self.root / "src/dir").symlink_to(self.root)
        os.mkfifo(self.root / "src/pipe")
        for path in ("src/link", "src/dir/secret.txt", "src/pipe"):
            with self.assertRaises(AdapterError):
                self.context.read(source(), path)

    def test_current_policy_can_narrow_existing_binding(self):
        policy = dict(source(), allowedPaths=["src/elsewhere"])
        with self.assertRaises(AdapterError):
            self.context.read(policy, "src/test.txt")

    def test_receipt_changes_after_file_edit(self):
        first = self.context.receipt(source(), ["src/test.txt"])
        (self.root / "src/test.txt").write_text("changed\n")
        second = self.context.receipt(source(), ["src/test.txt"])
        self.assertNotEqual(first["snapshotSHA256"], second["snapshotSHA256"])
        self.assertNotIn(str(self.root), json.dumps(second))

    def test_urls_require_tls_and_do_not_accept_embedded_credentials(self):
        self.assertEqual(service_url("http://127.0.0.1:8080"), "http://127.0.0.1:8080")
        for value in ("http://example.com", "https://user:secret@example.com", "https://example.com/elsewhere", "https://example.com?token=secret"):
            with self.assertRaises(AdapterError):
                service_url(value)


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.service = Service(self.client, {}, "/unused")

    def test_retries_keep_client_message_id(self):
        # Scenario WARTABLE-04
        args = {"conversationID": CONVERSATION, "clientMessageID": REQUEST, "chainID": TASK, "replyTo": RUN, "text": "Synthetic reply"}
        self.service.call("wartable_send_message", args)
        self.service.call("wartable_send_message", args)
        self.assertEqual(self.client.calls[0][2], self.client.calls[1][2])

    def test_agent_cannot_omit_human_chain(self):
        with self.assertRaises(AdapterError):
            self.service.call("wartable_send_message", {"conversationID": CONVERSATION, "clientMessageID": REQUEST, "text": "Uncaused reply"})
        self.assertEqual(self.client.calls, [])

    def test_type_and_unknown_arguments_do_not_reach_server(self):
        for args in ({"conversationID": CONVERSATION, "after": True}, {"conversationID": CONVERSATION, "after": -1}, {"conversationID": "../bad"}, {"conversationID": CONVERSATION, "admin": True}):
            with self.assertRaises(AdapterError):
                self.service.call("wartable_read_messages", args)
        self.assertEqual(self.client.calls, [])

    def test_no_arbitrary_shell_or_merge_tool(self):
        names = [value["name"] for value in TOOLS]
        self.assertNotIn("wartable_shell", names)
        self.assertNotIn("wartable_merge", names)

    def test_mcp_lifecycle_and_notification_no_response(self):
        protocol = MCP(self.service)
        self.assertIn("error", protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}))
        initial = protocol.handle({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "2026-07-28"}})
        self.assertEqual(initial["result"]["protocolVersion"], "2025-11-25")
        self.assertIsNone(protocol.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        self.assertEqual(len(protocol.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/list"})["result"]["tools"]), len(TOOLS))

    def test_mcp_error_is_data_not_traceback(self):
        protocol = MCP(self.service)
        protocol.ready = True
        response = protocol.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "wartable_send_message", "arguments": {}}})
        self.assertTrue(response["result"]["isError"])
        self.assertNotIn("Traceback", json.dumps(response))


class WorkerTests(unittest.TestCase):
    def setUp(self):
        try:
            probe_sandbox()
        except AdapterError:
            if os.environ.get("WARTABLE_REQUIRE_SANDBOX") == "1":
                self.fail("bubblewrap sandbox is required in this validation environment")
            self.skipTest("bubblewrap namespaces unavailable")
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "repo/src").mkdir(parents=True)
        (self.root / "repo/src/app.py").write_text("value = 1\n")
        self.client = FakeClient()
        self.service = Service(self.client, {"sources": {SOURCE: {
            "root": str(self.root / "repo"), "allowedPaths": ["src"],
            "checks": {"syntax": ["/usr/bin/python3", "-c", "import ast; ast.parse(open('src/app.py').read())"],
                       "isolation": ["/usr/bin/python3", "-c", "import os,socket; assert not os.path.exists('/home'); assert 'WARTABLE_SECRET_FIXTURE' not in os.environ; s=socket.socket(); assert s.connect_ex(('127.0.0.1',9)) != 0"],
                       "readonly": ["/usr/bin/python3", "-c", "open('src/app.py','w').write('bad')"]}}}}, self.root / "state")
        self.service.worker.start(TASK, REQUEST, ["src/app.py"])

    def tearDown(self):
        if hasattr(self, "temp"):
            self.temp.cleanup()

    def test_snapshot_edits_do_not_touch_original_and_resume_is_idempotent(self):
        self.service.worker.write_work_file(RUN, "src/app.py", "value = 2\n")
        resumed = self.service.worker.start(TASK, REQUEST, ["src/app.py"])
        self.assertTrue(resumed["resumed"])
        self.assertEqual((self.root / "repo/src/app.py").read_text(), "value = 1\n")
        self.assertIn("+value = 2", self.service.worker.work_diff(RUN)["patch"])

    def test_lease_revocation_blocks_writes(self):
        # Scenario WARTABLE-07
        self.client.stopped = True
        with self.assertRaises(AdapterError):
            self.service.worker.write_work_file(RUN, "src/app.py", "bad\n")
        self.assertEqual((self.root / "state" / RUN / "workspace/src/app.py").read_text(), "value = 1\n")

    def test_review_patch_distinguishes_new_empty_file_and_final_newline(self):
        before = self.service.worker.work_diff(RUN)["patchSHA256"]
        self.service.worker.write_work_file(RUN, "src/empty.py", "")
        added = self.service.worker.work_diff(RUN)
        self.assertNotEqual(before, added["patchSHA256"])
        self.assertIn("new file mode 100644", added["patch"])
        self.service.worker.write_work_file(RUN, "src/app.py", "value = 2")
        no_newline = self.service.worker.work_diff(RUN)
        self.assertIn("\\ No newline at end of file", no_newline["patch"])
        self.service.worker.write_work_file(RUN, "src/app.py", "value = 2\n")
        self.assertNotEqual(no_newline["patchSHA256"], self.service.worker.work_diff(RUN)["patchSHA256"])

    def test_path_and_named_command_boundaries(self):
        with self.assertRaises(AdapterError):
            self.service.worker.write_work_file(RUN, "secrets.txt", "no")
        with self.assertRaises(AdapterError):
            self.service.worker.run_check(RUN, "sh -c arbitrary")
        self.assertTrue(self.service.worker.run_check(RUN, "syntax")["passed"])
        self.assertFalse(self.service.worker.run_check(RUN, "readonly")["passed"])

    def test_actual_sandbox_hides_home_network_and_environment(self):
        os.environ["WARTABLE_SECRET_FIXTURE"] = "synthetic-only"
        try:
            self.assertTrue(self.service.worker.run_check(RUN, "isolation")["passed"])
        finally:
            del os.environ["WARTABLE_SECRET_FIXTURE"]


class HTTPStdioIntegrationTests(unittest.TestCase):
    def test_enroll_and_stdio_tools_use_scoped_token_without_logging_it(self):
        captured = []
        token = "wt_synthetic-test-only"

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                captured.append((self.path, self.headers.get("Authorization"), body))
                if self.path.endswith("/agents/connect"):
                    value = {"groupID": GROUP, "agentID": AGENT, "token": token}
                else:
                    value = {"ok": True}
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(value).encode())

            def do_GET(self):
                captured.append((self.path, self.headers.get("Authorization"), None))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"conversations": [{"id": CONVERSATION}]}).encode())

        with tempfile.TemporaryDirectory() as temporary, ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            config = Path(temporary) / "session.json"
            command = [sys.executable, "-m", "wartable_adapter", "--config", str(config)]
            enrolled = subprocess.run(command + ["enroll", "--server", f"http://127.0.0.1:{server.server_port}", "--code-stdin"],
                                      input="synthetic-code\n", text=True, capture_output=True, timeout=10)
            self.assertEqual(enrolled.returncode, 0, enrolled.stderr)
            self.assertNotIn(token, enrolled.stdout + enrolled.stderr)
            for client in ("claude-code", "codex", "gemini-cli"):
                requests = [
                    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": client, "version": "fixture"}}},
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "wartable_list_conversations", "arguments": {}}},
                ]
                result = subprocess.run(command + ["mcp"], input="".join(json.dumps(item) + "\n" for item in requests),
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(token, result.stdout + result.stderr)
                responses = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(len(responses), 3)
                self.assertFalse(responses[-1]["result"]["isError"])
            self.assertIsNone(captured[0][1])
            self.assertTrue(all(call[1] == "Bearer " + token for call in captured[1:]))
            server.shutdown()
            thread.join(timeout=5)

    def test_redirect_does_not_forward_bearer(self):
        class Redirect(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "https://example.com/never-follow")
                self.end_headers()

        with ThreadingHTTPServer(("127.0.0.1", 0), Redirect) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            client = Client({"serverURL": f"http://127.0.0.1:{server.server_port}", "token": "synthetic-only"})
            with self.assertRaises(AdapterError):
                client.request("GET", "/test")
            server.shutdown()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
