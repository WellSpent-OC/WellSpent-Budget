"""Failure and retry behavior at the connector's real input/output boundaries."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

from wartable_adapter.client import AdapterError, Client, private_json, save_private_json
from wartable_adapter.context import Context
from wartable_adapter.github import GitHub, ProviderError
from wartable_adapter.mcp import MCP
from wartable_adapter.service import Service
from wartable_adapter.work import probe_sandbox
from test_adapter import FakeClient, GROUP, AGENT, SOURCE, TASK, RUN, REQUEST, CONVERSATION


class CLIBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / "session.json"

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, args, input_text=""):
        from wartable_adapter.cli import main
        out, err = io.StringIO(), io.StringIO()
        with patch("sys.stdin", io.StringIO(input_text)), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = main(["--config", str(self.config), *args])
        return result, out.getvalue(), err.getvalue()

    def test_enrollment_hides_tokens_refuses_overwrite_and_incomplete_response(self):
        fake = Mock(url="https://example.test")
        fake.request.return_value = {"groupID": GROUP, "agentID": AGENT, "token": "synthetic-secret"}
        with patch("wartable_adapter.cli.Client", return_value=fake):
            result = self.invoke(["enroll", "--server", "https://example.test", "--code-stdin"], "one-use-code\n")
            self.assertEqual(result[0], 0)
            self.assertNotIn("synthetic-secret", result[1] + result[2])
            self.assertEqual(private_json(self.config)["token"], "synthetic-secret")
            self.assertEqual(self.invoke(["enroll", "--server", "https://example.test", "--code-stdin"], "other-code\n")[0], 1)
            self.config.unlink()
            self.assertEqual(self.invoke(["enroll", "--server", "https://example.test", "--code-stdin"], "\n")[0], 1)
            fake.request.return_value = {"token": "synthetic-secret"}
            with patch("wartable_adapter.cli.getpass.getpass", return_value="hidden-code"):
                self.assertEqual(self.invoke(["enroll", "--server", "https://example.test"])[0], 1)
            self.assertFalse(self.config.exists())

    def test_cli_json_and_mcp_surface_fail_cleanly_and_tools_require_no_credentials(self):
        self.assertEqual(self.invoke(["tools"])[0], 0)
        with patch("wartable_adapter.cli.probe_sandbox"):
            self.assertEqual(self.invoke(["sandbox-check"])[0], 0)
        save_private_json(self.config, {"serverURL": "https://example.test", "groupID": GROUP, "agentID": AGENT, "token": "synthetic-secret"})
        bindings = self.root / "bindings.json"
        save_private_json(bindings, {})
        with patch("wartable_adapter.cli.Service", return_value=Mock(call=lambda *_: {"acknowledged": True})):
            result = self.invoke(["--bindings", str(bindings), "call", "wartable_status"], "{}")
            self.assertEqual(json.loads(result[1]), {"acknowledged": True})
            self.assertEqual(self.invoke(["call", "wartable_status"], "not json")[0], 1)
            self.assertEqual(self.invoke(["call", "wartable_status"], " " * (2 * 1024 * 1024 + 1))[0], 1)
            result = self.invoke(["mcp"], '{"jsonrpc":"2.0","id":1,"method":"ping"}\n')
            self.assertEqual(json.loads(result[1])["result"], {})
        with patch("sys.argv", ["wartable", "tools"]), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as exited:
                runpy.run_module("wartable_adapter", run_name="__main__")
            self.assertEqual(exited.exception.code, 0)


class ProtocolBoundaryTests(unittest.TestCase):
    def test_malformed_requests_and_oversized_frames_do_not_corrupt_next_request(self):
        service = Mock()
        service.call.side_effect = RuntimeError("synthetic-secret-must-not-escape")
        protocol = MCP(service)
        def req(method, params=None, identifier=1):
            return protocol.handle({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}})
        self.assertEqual(protocol.handle([])["error"]["code"], -32600)
        self.assertEqual(req("ping", identifier=True)["error"]["code"], -32600)
        self.assertEqual(req("ping", params=[1])["error"]["code"], -32602)
        self.assertEqual(req("initialize")["error"]["code"], -32602)
        req("initialize", {"protocolVersion": "2025-11-25"})
        self.assertIn("error", req("initialize", {"protocolVersion": "2025-11-25"}))
        protocol.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertIn("error", req("tools/list", {"cursor": "not-a-page"}))
        self.assertIn("error", req("tools/call", {}))
        self.assertEqual(req("unsupported")["error"]["code"], -32601)
        failure = req("tools/call", {"name": "wartable_status"})
        self.assertTrue(failure["result"]["isError"])
        self.assertNotIn("synthetic-secret", json.dumps(failure))
        service.call.side_effect = None
        service.call.return_value = {"ok": True}
        self.assertFalse(req("tools/call", {"name": "wartable_status"})["result"]["isError"])
        input_text = "x" * (2 * 1024 * 1024 + 100) + '\ninvalid\n{"jsonrpc":"2.0","method":"notification"}\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n'
        output = io.StringIO()
        protocol.serve(io.StringIO(input_text), output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[-1], {"jsonrpc": "2.0", "id": 2, "result": {}})


class NetworkBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.credential = Path(self.temp.name) / "github.json"
        save_private_json(self.credential, {"token": "synthetic-provider-secret"})
        self.config = {"repository": "example/project", "credentialFile": str(self.credential), "allowedActions": ["review"]}

    def tearDown(self):
        self.temp.cleanup()

    def response(self, value):
        result = Mock()
        result.__enter__ = Mock(return_value=result)
        result.__exit__ = Mock(return_value=None)
        result.read.return_value = value
        return result

    def test_provider_fixed_host_authenticated_requests_and_safe_failures(self):
        provider = GitHub(self.config)
        opener = Mock()
        provider.opener = opener
        opener.open.return_value = self.response(b'{"ok":true}')
        self.assertEqual(provider.repo("POST", "/pulls", {"draft": True}, {"limit": 1}), {"ok": True})
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.github.com/repos/example/project/pulls?limit=1")
        self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-provider-secret")
        self.assertEqual(json.loads(request.data), {"draft": True})
        for value in (b"invalid", b"x" * (4 * 1024 * 1024 + 1)):
            opener.open.return_value = self.response(value)
            with self.assertRaises(AdapterError):
                provider.repo("GET")
        for error in (HTTPError("https://api.github.com", 302, "sensitive-body", {}, None), URLError("sensitive-host")):
            opener.open.side_effect = error
            with self.assertRaises(AdapterError) as failed:
                provider.repo("GET")
            self.assertNotIn("sensitive", str(failed.exception))
        with self.assertRaises(AdapterError):
            provider.request("GET", "/../escape")
        with self.assertRaises(AdapterError):
            provider.authorize("openPR")

    def test_provider_configuration_requires_exact_safe_scope_and_private_token(self):
        for update in ({"repository": "https://bad/path"}, {"base": "../main"}, {"branchPrefix": "main"}):
            with self.assertRaises(AdapterError):
                GitHub(dict(self.config, **update))
        save_private_json(self.credential, {"token": "bad\nheader"})
        with self.assertRaises(AdapterError):
            GitHub(self.config)

    def test_server_client_rejects_unauthenticated_scope_and_bounds_response(self):
        client = Client({"serverURL": "https://example.test"})
        for path in ("/ok", "/../escape"):
            with self.assertRaises(AdapterError):
                client.request("GET", path)
        client.token = "synthetic-secret"
        client.opener = Mock()
        for raw in (b"invalid", b"x" * (4 * 1024 * 1024 + 1)):
            client.opener.open.return_value = self.response(raw)
            with self.assertRaises(AdapterError):
                client.request("GET", "/messages", query={"after": 1})
        client.opener.open.return_value = self.response(b"")
        self.assertEqual(client.request("POST", "/receipts", {}), {"ok": True})


class ToolRoutingTests(unittest.TestCase):
    def test_supported_tools_keep_installation_scope_and_explicit_arguments(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "src").mkdir()
            (root / "src/app.py").write_text("value = 1\n")
            service = Service(client, {"sources": {SOURCE: {"root": temp, "allowedPaths": ["src"]}}}, root / "runs")
            for name, arguments in (
                ("wartable_status", {}), ("wartable_list_conversations", {}),
                ("wartable_read_messages", {"conversationID": CONVERSATION, "before": 4}),
                ("wartable_create_conversation", {"title": "Synthetic", "participantIDs": [AGENT]}),
                ("wartable_acknowledge", {"conversationID": CONVERSATION, "sequence": 2}),
                ("wartable_presence", {}), ("wartable_read_events", {"after": 1}),
                ("wartable_read_context", {"sourceID": SOURCE, "path": "src/app.py"}),
                ("wartable_context_receipt", {"sourceID": SOURCE, "paths": ["src/app.py"]}),
                ("wartable_propose_task", {"conversationID": CONVERSATION, "sourceID": SOURCE, "title": "Synthetic", "details": "Scoped"}),
                ("wartable_verify_provider", {"taskID": TASK}),
                ("wartable_record_evidence", {"taskID": TASK, "runID": RUN, "fence": 1, "kind": "check", "summary": "Synthetic"}),
                ("wartable_record_review", {"taskID": TASK, "headCommit": "a" * 40, "baseCommit": "b" * 40, "decision": "comment", "summary": "Synthetic"}),
            ):
                self.assertIsNotNone(service.call(name, arguments), name)
            self.assertTrue(all(call[1].startswith("/groups/" + GROUP) for call in client.calls))
            self.assertTrue(any(call[2] == {"busy": False} for call in client.calls))
            with self.assertRaises(AdapterError):
                service.source("00000000-0000-4000-8000-000000000099")
            with self.assertRaises(AdapterError):
                service.call("unsupported", {})
            with self.assertRaises(AdapterError):
                service.call("wartable_send_message", {"conversationID": CONVERSATION, "clientMessageID": REQUEST, "replyTo": REQUEST, "chainID": REQUEST, "text": " "})


class WorkerFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "repo/src").mkdir(parents=True)
        (self.root / "repo/src/app.py").write_text("value = 1\n")
        self.client = FakeClient()
        self.service = Service(self.client, {"sources": {SOURCE: {"root": str(self.root / "repo"), "allowedPaths": ["src"],
            "rulesPaths": ["src/app.py"], "handoffPath": "src/app.py", "checks": {"slow": ["/usr/bin/true"]}}}}, self.root / "runs")

    def tearDown(self):
        self.temp.cleanup()

    def start(self):
        with patch("wartable_adapter.work.probe_sandbox"):
            return self.service.call("wartable_start_work", {"taskID": TASK, "requestID": REQUEST, "paths": ["src/app.py"]})

    def test_rules_context_read_finish_and_preparation_failure_cleanup(self):
        started = self.start()
        self.assertEqual(started["startupContext"][0]["content"], "value = 1\n")
        read = self.service.call("wartable_read_work_file", {"runID": RUN, "path": "src/app.py"})
        self.assertEqual(read["content"], "value = 1\n")
        self.assertEqual(self.service.call("wartable_finish_work", {"runID": RUN, "state": "cancelled", "summary": "Stopped"})["state"], "cancelled")
        self.assertTrue(private_json(self.root / "runs" / RUN / "state.json")["finished"])
        self.service.worker.root = self.root / "failed-runs"
        with patch.object(self.service.context, "read_bytes", side_effect=[b"value = 1\n", b"value = 1\n", b"value = 1\n", b"changed"]):
            with self.assertRaises(AdapterError):
                self.start()
        self.assertTrue(any(call[1].endswith("/finish") and call[2]["state"] == "blocked" for call in self.client.calls))

    def test_check_revocation_terminates_its_process_group_without_success(self):
        self.start()
        process = Mock(pid=987654)
        process.wait.side_effect = [subprocess.TimeoutExpired("synthetic", 5), 0]
        metadata = private_json(self.root / "runs" / RUN / "state.json")
        with patch("wartable_adapter.work.probe_sandbox"), patch("wartable_adapter.work.subprocess.Popen", return_value=process), patch("wartable_adapter.work.os.killpg") as kill:
            with patch.object(self.service.worker, "checkpoint", side_effect=[metadata["run"], AdapterError("Revoked")]):
                with self.assertRaises(AdapterError):
                    self.service.worker.run_check(RUN, "slow")
            kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)

    def test_refused_sandbox_and_stale_run_do_not_execute(self):
        with patch("wartable_adapter.work.shutil.which", return_value=None):
            with self.assertRaises(AdapterError):
                probe_sandbox()
        with patch("wartable_adapter.work.subprocess.run", side_effect=OSError("not available")):
            with self.assertRaises(AdapterError):
                probe_sandbox()
        with patch("wartable_adapter.work.subprocess.run", return_value=Mock(returncode=1)):
            with self.assertRaises(AdapterError):
                probe_sandbox()
        self.start()
        with patch.object(self.service, "request", return_value={"state": "stopped", "fence": 1}):
            with self.assertRaises(AdapterError):
                self.service.worker.read_work_file(RUN, "src/app.py")


if __name__ == "__main__":
    unittest.main()
