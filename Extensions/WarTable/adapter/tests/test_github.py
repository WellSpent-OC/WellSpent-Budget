import json
import base64
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from wartable_adapter.client import AdapterError, private_json
from wartable_adapter.context import Context
from wartable_adapter.github import GitHub, ProviderError, git_blob
from wartable_adapter.service import Service

BASE = "a" * 40
HEAD = "b" * 40
OTHER = "c" * 40
SOURCE = "00000000-0000-4000-8000-000000000003"
TASK = "00000000-0000-4000-8000-000000000004"
RUN = "00000000-0000-4000-8000-000000000006"
PATCH = "d" * 64


class MockGitHub(GitHub):
    def __init__(self):
        self.repository = "example/project"
        self.base = "main"
        self.prefix = "wartable/"
        self.config = {"allowedActions": ["openPR", "review"], "publicSource": True}
        self.base_value = BASE
        self.branch = None
        self.calls = []
        self.pull = None
        self.public = True
        self.pr_head = HEAD
        self.review_author = 2
        self.original = b"value = 1\n"
        self.created_review = None
        self.race_after_review = False
        self.revision_content = b"value = 2\n"
        self.revision_request = False
        self.commit_value = HEAD
        self.head_ref = "wartable/" + TASK
        self.ancestor = BASE
        self.fail_review_confirmation = False

    def request(self, method, path, body=None, query=None):
        self.calls.append((method, path, body, query))
        if path == "/user":
            return {"id": self.review_author, "login": "reviewer"}
        suffix = path.removeprefix("/repos/" + self.repository)
        if suffix == "":
            return {"private": not self.public}
        if suffix == "/git/ref/heads/main":
            return {"object": {"sha": self.base_value}}
        if suffix.startswith("/git/ref/heads/wartable/"):
            if self.branch is None:
                raise ProviderError(404)
            return {"object": {"sha": self.branch}}
        if suffix.startswith("/contents/"):
            data = self.revision_content if query and query.get("ref") == HEAD and self.revision_request else self.original
            return {"type": "file", "sha": git_blob(data), "encoding": "base64", "content": base64.b64encode(data).decode()}
        if suffix.startswith("/compare/"):
            return {"merge_base_commit": {"sha": self.ancestor}, "status": "ahead"}
        if suffix.startswith("/git/commits/") and method == "GET":
            return {"tree": {"sha": "root-tree"}}
        if suffix == "/git/trees/root-tree":
            return {"tree": [{"path": "src", "type": "tree", "mode": "040000", "sha": "src-tree"}]}
        if suffix == "/git/trees/src-tree":
            return {"tree": [{"path": "app.py", "type": "blob", "mode": "100755", "sha": git_blob(self.original)}]}
        if suffix == "/git/trees" and method == "POST":
            return {"sha": "new-tree"}
        if suffix == "/git/commits" and method == "POST":
            return {"sha": self.commit_value}
        if suffix == "/git/refs" and method == "POST":
            self.branch = body["sha"]
            if self.pull:
                self.pull["head"]["sha"] = self.branch
            return {"ref": body["ref"], "object": {"sha": self.branch}}
        if suffix.startswith("/git/refs/heads/") and method == "PATCH":
            if body.get("force") is not False:
                raise AssertionError("force update was attempted")
            self.branch = body["sha"]
            if self.pull:
                self.pull["head"]["sha"] = self.branch
            return {"object": {"sha": self.branch}}
        if suffix == "/pulls":
            if method == "GET":
                return [self.pull] if self.pull else []
            self.pull = {"number": 42, "draft": True, "state": "open", "head": {"sha": self.branch}}
            return self.pull
        if suffix == "/pulls/42":
            return {"number": 42, "head": {"sha": self.pr_head, "user": {"id": 1}, "ref": self.head_ref, "repo": {"full_name": self.repository}},
                    "base": {"sha": self.base_value, "ref": self.base, "repo": {"full_name": self.repository}},
                    "user": {"id": 1}, "state": "open", "merged": False}
        if suffix.endswith("/check-runs"):
            return {"total_count": 1, "check_runs": [{"name": "Synthetic checks", "status": "completed", "conclusion": "success"}]}
        if suffix.endswith("/status"):
            return {"state": "success", "total_count": 0}
        if suffix == "/pulls/42/reviews":
            if method == "GET":
                return [self.created_review] if self.created_review else []
            self.created_review = {"id": 7, "commit_id": body["commit_id"], "state": {"APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED", "COMMENT": "COMMENTED"}[body["event"]], "user": {"login": "reviewer", "id": self.review_author}}
            if self.race_after_review:
                self.pr_head = OTHER
            return self.created_review
        if suffix == "/pulls/42/reviews/7":
            if self.fail_review_confirmation:
                self.fail_review_confirmation = False
                raise ProviderError(503)
            return self.created_review
        raise AssertionError((method, suffix, body, query))


class Worker:
    def __init__(self):
        self.checkpoints = []

    def checkpoint(self, metadata, operation, path=None):
        self.checkpoints.append((operation, path))

    def _local_context(self, directory, metadata):
        policy = metadata["source"]
        return Context({"sources": {SOURCE: {"root": str(directory / "workspace"), "allowedPaths": ["src"]}}}), policy


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        for name in ("original", "workspace"):
            (self.directory / name / "src").mkdir(parents=True)
        (self.directory / "original/src/app.py").write_text("value = 1\n")
        (self.directory / "workspace/src/app.py").write_text("value = 2\n")
        self.metadata = {"run": {"id": RUN, "taskID": TASK, "fence": 1}, "files": ["src/app.py"],
                         "source": {"id": SOURCE, "kind": "repository", "reference": "https://github.com/example/project", "allowedPaths": ["src"], "isPublic": True}}
        self.provider = MockGitHub()
        self.metadata["publication"] = self.provider.capture(self.metadata, self.directory)
        self.worker = Worker()

    def tearDown(self):
        self.temp.cleanup()

    def test_draft_publication_is_scoped_and_retries_reuse_branch_pr(self):
        # Scenario WARTABLE-12
        result = self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        repeated = self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.assertEqual(result["number"], repeated["number"])
        self.assertEqual(result["headCommit"], HEAD)
        self.assertFalse(result["merged"])
        writes = [call for call in self.provider.calls if call[0] == "POST"]
        self.assertEqual(sum(call[1].endswith("/pulls") for call in writes), 1)
        self.assertEqual(sum(call[1].endswith("/git/commits") for call in writes), 1)
        tree = next(call[2] for call in writes if call[1].endswith("/git/trees"))
        self.assertEqual(tree["tree"][0]["mode"], "100755")
        self.assertNotIn(str(self.directory), json.dumps(writes))
        self.assertIn(("openPR", "src/app.py"), self.worker.checkpoints)

    def test_optional_strict_publication_policy_requires_exact_reviewed_patch(self):
        self.provider.config["approvedPatchSHA256"] = [PATCH]
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, "e" * 64)
        self.assertFalse(any(call[0] == "POST" for call in self.provider.calls))

    def test_public_destination_requires_both_source_classifications(self):
        self.provider.config.pop("publicSource")
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.assertFalse(any(call[0] == "POST" for call in self.provider.calls))

    def test_restricted_source_never_goes_to_public_repository(self):
        self.metadata["source"]["isPublic"] = False
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.assertFalse(any(call[0] == "POST" for call in self.provider.calls))

    def test_changed_base_or_foreign_branch_is_not_overwritten(self):
        # Scenario WARTABLE-12
        self.provider.base_value = OTHER
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.provider.base_value = BASE
        self.provider.branch = OTHER
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.assertFalse(any(call[0] in ("POST", "PATCH") for call in self.provider.calls))

    def test_changed_original_does_not_pass_as_current(self):
        self.provider.original = b"changed upstream\n"
        with self.assertRaises(AdapterError):
            self.provider.capture(self.metadata, self.directory)

    def test_fresh_revision_uses_recorded_pr_head_preserves_previous_work(self):
        # Scenario WARTABLE-12
        self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.provider.revision_request = True
        task = {"id": TASK, "headCommit": HEAD, "prURL": "https://github.com/example/project/pull/42"}
        context = Context({"sources": {SOURCE: {"root": str(self.directory), "allowedPaths": ["src"]}}})
        revision = self.provider.revision_snapshot(task, self.metadata["source"], context, ["src/app.py"])
        self.assertEqual(revision["files"]["src/app.py"], b"value = 2\n")
        self.assertEqual(revision["receipt"]["providerCommit"], HEAD)
        (self.directory / "original/src/app.py").write_bytes(revision["files"]["src/app.py"])
        (self.directory / "workspace/src/app.py").write_text("value = 3\n")
        self.metadata["publication"] = revision["publication"]
        self.provider.commit_value = OTHER
        result = self.provider.publish(self.worker, self.metadata, self.directory, "e" * 64)
        self.assertEqual(result["number"], 42)
        self.assertEqual(result["headCommit"], OTHER)
        commits = [call for call in self.provider.calls if call[0] == "POST" and call[1].endswith("/git/commits")]
        self.assertEqual(commits[-1][2]["parents"], [HEAD])
        self.assertEqual(sum(call[0] == "POST" and call[1].endswith("/pulls") for call in self.provider.calls), 1)
        self.assertTrue(any(call[0] == "PATCH" and call[2]["force"] is False for call in self.provider.calls))

    def test_revision_refuses_unrelated_changed_or_outdated_branches(self):
        # Scenario WARTABLE-12
        task = {"id": TASK, "headCommit": HEAD, "prURL": "https://github.com/example/project/pull/42"}
        context = Context({"sources": {SOURCE: {"root": str(self.directory), "allowedPaths": ["src"]}}})
        for attribute, value in (("head_ref", "someone-else"), ("pr_head", OTHER), ("ancestor", OTHER)):
            old = getattr(self.provider, attribute)
            setattr(self.provider, attribute, value)
            with self.assertRaises(AdapterError):
                self.provider.revision_snapshot(task, self.metadata["source"], context, ["src/app.py"])
            setattr(self.provider, attribute, old)
        self.provider.revision_request = True
        revision = self.provider.revision_snapshot(task, self.metadata["source"], context, ["src/app.py"])
        self.metadata["publication"] = revision["publication"]
        (self.directory / "original/src/app.py").write_bytes(revision["files"]["src/app.py"])
        (self.directory / "workspace/src/app.py").write_text("value = 3\n")
        self.provider.branch = OTHER
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, PATCH)
        self.assertFalse(any(call[0] in ("POST", "PATCH") for call in self.provider.calls))

    def test_new_worker_claim_hashes_provider_revision_without_mutating_local_source(self):
        # Scenario WARTABLE-12
        source = dict(self.metadata["source"], revision=1)
        grant_id = "00000000-0000-4000-8000-000000000005"
        task = {"id": TASK, "sourceID": SOURCE, "grantID": grant_id, "headCommit": HEAD,
                "prURL": "https://github.com/example/project/pull/42"}
        class RevisionClient:
            group_id = "00000000-0000-4000-8000-000000000001"
            agent_id = "00000000-0000-4000-8000-000000000002"
            claim = None
            def request(self, method, path, body=None, **kwargs):
                if path.endswith("/runs"):
                    self.claim = body
                    return {"id": RUN, "taskID": TASK, "requestID": body["requestID"], "fence": 1, "state": "active"}
                if path.endswith("/checkpoint"):
                    return {"id": RUN, "fence": 1, "state": "active"}
                return {"contextSources": [source], "tasks": [task], "grants": [{"id": grant_id,
                    "capabilities": ["readContext", "editBranch", "openPR"], "allowedPaths": ["src"]}]}
        client = RevisionClient()
        self.provider.revision_request = True
        service = Service(client, {"sources": {SOURCE: {"root": str(self.directory / "original"), "allowedPaths": ["src"], "github": {"synthetic": True}}}}, self.directory / "runs")
        with patch("wartable_adapter.github.GitHub", return_value=self.provider), patch("wartable_adapter.work.probe_sandbox"):
            result = service.worker.start(TASK, "00000000-0000-4000-8000-000000000007", ["src/app.py"])
        self.assertEqual(result["receipt"]["providerCommit"], HEAD)
        self.assertEqual(client.claim["contextReceipt"]["revision"], "sha256:" + result["receipt"]["snapshotSHA256"])
        self.assertEqual((self.directory / "runs" / RUN / "workspace/src/app.py").read_text(), "value = 2\n")
        self.assertEqual((self.directory / "original/src/app.py").read_text(), "value = 1\n")

    def test_provider_binding_cannot_publish_a_different_server_source(self):
        self.metadata["source"]["reference"] = "https://github.com/example/other"
        with self.assertRaises(AdapterError):
            self.provider.publish(self.worker, self.metadata, self.directory, PATCH)

    def test_same_provider_identity_is_advisory_and_does_not_approve(self):
        self.provider.review_author = 1
        result = self.provider.review(42, HEAD, BASE, "approve")
        self.assertFalse(result["providerConfirmed"])
        self.assertIsNone(self.provider.created_review)

    def test_independent_provider_review_is_confirmed_at_exact_head(self):
        # Scenario WARTABLE-07
        result = self.provider.review(42, HEAD, BASE, "approve")
        self.assertTrue(result["providerConfirmed"])
        self.assertEqual(result["headCommit"], HEAD)
        self.assertFalse(result["merged"])

    def test_head_change_during_review_is_stale(self):
        self.provider.race_after_review = True
        with self.assertRaises(AdapterError):
            self.provider.review(42, HEAD, BASE, "approve")

    def test_failed_provider_confirmation_keeps_task_reviewable_and_retry_reuses_review(self):
        # Scenario WARTABLE-07
        source = self.metadata["source"]
        class ReviewClient:
            group_id = "00000000-0000-4000-8000-000000000001"
            agent_id = "00000000-0000-4000-8000-000000000002"
            def __init__(self):
                self.recorded = []
                self.authorizations = 0
                self.fail_record = False
                self.authorized = True
            def request(self, method, path, body=None, **kwargs):
                if path.endswith("/reviews/authorize"):
                    self.authorizations += 1
                    return {"authorized": self.authorized}
                if path.endswith("/reviews"):
                    if self.fail_record:
                        raise AdapterError("Current task changed")
                    self.recorded.append(body)
                    return {"providerConfirmed": False}
                return {"contextSources": [source], "tasks": [{"id": TASK, "sourceID": SOURCE, "headCommit": HEAD,
                                                               "prURL": "https://github.com/example/project/pull/42"}]}
        client = ReviewClient()
        service = Service(client, {"sources": {SOURCE: {"github": {}}}}, self.directory / "runs")
        arguments = {"taskID": TASK, "headCommit": HEAD, "baseCommit": BASE, "decision": "requestChanges", "summary": "Synthetic review"}
        self.provider.fail_review_confirmation = True
        with patch("wartable_adapter.github.GitHub", return_value=self.provider):
            with self.assertRaises(AdapterError):
                service.call("wartable_submit_provider_review", arguments)
            self.assertEqual(client.recorded, [])
            result = service.call("wartable_submit_provider_review", arguments)
            client.fail_record = True
            uncertain_copy = service.call("wartable_submit_provider_review", arguments)
            self.assertTrue(uncertain_copy["providerConfirmed"])
            self.assertFalse(uncertain_copy["taskRecorded"])
            client.authorized = False
            before = len(self.provider.calls)
            with self.assertRaises(AdapterError):
                service.call("wartable_submit_provider_review", arguments)
            self.assertEqual(before, len(self.provider.calls))
        self.assertEqual(client.authorizations, 4)
        self.assertEqual(len(client.recorded), 1)
        self.assertTrue(result["providerConfirmed"])
        self.assertTrue(result["taskRecorded"])
        self.assertEqual(sum(call[0] == "POST" and call[1].endswith("/reviews") for call in self.provider.calls), 1)

    def test_provider_read_never_infers_merged_from_successful_checks(self):
        result = self.provider.inspect(42, HEAD)
        self.assertTrue(result["providerVerified"])
        self.assertFalse(result["merged"])
        self.assertNotIn("readyToMerge", result)


if __name__ == "__main__":
    unittest.main()
