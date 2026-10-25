"""Repository-scoped GitHub REST operations. Credentials never enter a worker."""

from __future__ import annotations

from datetime import datetime, timezone
import base64
import hashlib
import json
from pathlib import Path
import re
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, build_opener

from .client import AdapterError, NoRedirects, private_json, save_private_json


class ProviderError(AdapterError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"GitHub operation was not confirmed (HTTP {status}).")


def git_blob(data: bytes):
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def commit_id(value: str):
    if not isinstance(value, str) or not re.fullmatch("[0-9a-f]{40}", value):
        raise AdapterError("Provider commit identity is invalid.")
    return value


class GitHub:
    def __init__(self, config: dict):
        self.config = config
        self.repository = config.get("repository", "")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", self.repository) or self.repository.split("/")[-1] in (".", ".."):
            raise AdapterError("An operator-approved owner/repository binding is required.")
        self.base = config.get("base", "main")
        self.prefix = config.get("branchPrefix", "wartable/")
        for value in (self.base, self.prefix):
            if not re.fullmatch(r"[A-Za-z0-9_/-]+", value) or ".." in value or "//" in value or value.startswith("/"):
                raise AdapterError("Provider base and branch prefix must be safe branch names.")
        if not self.prefix.endswith("/") or self.prefix == "/":
            raise AdapterError("A dedicated branch prefix ending in / is required.")
        credential = private_json(Path(config.get("credentialFile", "")))
        self.token = credential.get("token")
        if not isinstance(self.token, str) or not self.token or "\n" in self.token or "\r" in self.token:
            raise AdapterError("Dedicated GitHub credential is missing or invalid.")
        self.opener = build_opener(NoRedirects())

    def request(self, method, path, body=None, query=None):
        comparison = re.fullmatch(r"/repos/" + re.escape(self.repository) + r"/compare/[a-f0-9]{40}\.\.\.[a-f0-9]{40}", path)
        if not path.startswith("/") or (".." in path and not comparison) or "?" in path or "#" in path:
            raise AdapterError("Invalid provider path.")
        url = "https://api.github.com" + path + ("?" + urlencode(query) if query else "")
        headers = {"Accept": "application/vnd.github+json", "Authorization": "Bearer " + self.token,
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "WellSpent-WarTable/0.1.0"}
        raw = json.dumps(body).encode() if body is not None else None
        if raw is not None:
            headers["Content-Type"] = "application/json"
        try:
            with self.opener.open(Request(url, data=raw, headers=headers, method=method), timeout=20) as response:
                data = response.read(4 * 1024 * 1024 + 1)
                if len(data) > 4 * 1024 * 1024:
                    raise AdapterError("Provider response exceeds the connector limit.")
                return json.loads(data) if data else {}
        except HTTPError as exc:
            status = exc.code
            exc.close()
            raise ProviderError(status) from None
        except (URLError, OSError, ValueError):
            raise AdapterError("GitHub is unavailable or returned an invalid response. State remains unknown.") from None

    def repo(self, method, suffix="", body=None, query=None):
        return self.request(method, "/repos/" + self.repository + suffix, body, query)

    def authorize(self, action):
        if action not in self.config.get("allowedActions", []):
            raise AdapterError("The local operator has not granted this provider action.")

    def base_head(self):
        return commit_id(self.repo("GET", "/git/ref/heads/" + quote(self.base, safe="/"))["object"]["sha"])

    def verify_original(self, base, original, paths):
        for path in paths:
            try:
                entry = self.repo("GET", "/contents/" + quote(path, safe="/"), query={"ref": base})
            except ProviderError as exc:
                if exc.status == 404 and not (original / path).exists():
                    continue
                raise
            if entry.get("type") != "file" or not (original / path).is_file() or entry.get("sha") != git_blob((original / path).read_bytes()):
                raise AdapterError("Local snapshot differs from the authoritative base. Refresh context before publishing.")

    def capture(self, metadata, directory):
        self.authorize("openPR")
        self.source_repository(metadata["source"])
        base = self.base_head()
        self.verify_original(base, directory / "original", metadata["files"])
        return {"repository": self.repository, "base": self.base, "baseCommit": base,
                "branch": self.prefix + metadata["run"]["taskID"].lower(),
                "date": datetime.now(timezone.utc).replace(microsecond=0).isoformat()}

    def source_repository(self, source):
        if source.get("kind") != "repository" or source.get("reference") != "https://github.com/" + self.repository:
            raise AdapterError("The server source and local operator must name the same canonical GitHub repository.")

    def revision_snapshot(self, task, source, context, paths):
        """Resume only the server-recorded task PR, reading exact approved files at its head."""
        self.authorize("openPR")
        self.source_repository(source)
        if not paths or len(paths) > 200:
            raise AdapterError("A revision requires 1 to 200 explicit file paths.")
        match = re.fullmatch(r"https://github\.com/" + re.escape(self.repository) + r"/pull/([1-9][0-9]*)", task.get("prURL", ""))
        if not match:
            raise AdapterError("The previous task PR does not belong to its approved repository.")
        head = commit_id(task.get("headCommit"))
        number = int(match.group(1))
        branch = self.prefix + task["id"].lower()
        pull = self.repo("GET", f"/pulls/{number}")
        base = self.base_head()
        if (pull.get("state") != "open" or pull.get("merged") is not False
                or pull.get("head", {}).get("sha") != head or pull["head"].get("ref") != branch
                or pull["head"].get("repo", {}).get("full_name", "").lower() != self.repository.lower()
                or pull.get("base", {}).get("ref") != self.base or pull["base"].get("sha") != base
                or pull["base"].get("repo", {}).get("full_name", "").lower() != self.repository.lower()):
            raise AdapterError("The task PR, branch or base changed. Refresh authoritative task evidence before revising.")
        ancestry = self.repo("GET", f"/compare/{base}...{head}")
        if ancestry.get("merge_base_commit", {}).get("sha") != base or ancestry.get("status") not in ("ahead", "identical"):
            raise AdapterError("The existing task branch must be brought up to the current base before a new revision can publish.")
        files = {}
        for path in sorted(set(paths)):
            context._binding(source, path)
            self.file_mode(head, path)
            entry = self.repo("GET", "/contents/" + quote(path, safe="/"), query={"ref": head})
            if entry.get("type") != "file" or entry.get("encoding") != "base64" or not isinstance(entry.get("content"), str):
                raise AdapterError("The revision contains an unsupported provider file.")
            try:
                data = base64.b64decode("".join(entry["content"].split()), validate=True)
                data.decode("utf-8")
            except (ValueError, UnicodeError) as exc:
                raise AdapterError("The revision file is not bounded UTF-8 text.") from exc
            if len(data) > 1024 * 1024 or entry.get("sha") != git_blob(data):
                raise AdapterError("The revision file is oversized or its provider hash does not match.")
            files[path] = data
        current = self.repo("GET", f"/pulls/{number}")
        if current.get("head", {}).get("sha") != head or current.get("base", {}).get("sha") != base:
            raise AdapterError("The task PR changed while reading its revision snapshot.")
        hashes = [{"path": path, "sha256": hashlib.sha256(data).hexdigest()} for path, data in files.items()]
        receipt = {"sourceID": source["id"], "files": hashes,
                   "snapshotSHA256": hashlib.sha256(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
                   "policyRevision": source.get("revision"), "classification": "public" if source.get("isPublic") is True else "restricted",
                   "verifiedAt": datetime.now(timezone.utc).isoformat(), "providerCommit": head,
                   "scope": "Explicit approved files at the server-recorded task PR head; the host checkout was not changed."}
        publication = {"repository": self.repository, "base": self.base, "baseCommit": base,
                       "originalCommit": head, "branch": branch, "headCommit": head, "prNumber": number,
                       "date": datetime.now(timezone.utc).replace(microsecond=0).isoformat()}
        return {"files": files, "receipt": receipt, "publication": publication}

    def file_mode(self, base, path):
        tree = self.repo("GET", "/git/commits/" + base)["tree"]["sha"]
        parts = path.split("/")
        for index, part in enumerate(parts):
            listing = self.repo("GET", "/git/trees/" + tree)
            if listing.get("truncated"):
                raise AdapterError("Provider tree listing is incomplete; file mode cannot be verified.")
            entry = next((item for item in listing.get("tree", []) if item.get("path") == part), None)
            if entry is None:
                return "100644"
            if index == len(parts) - 1:
                if entry.get("type") != "blob" or entry.get("mode") not in ("100644", "100755"):
                    raise AdapterError("Only ordinary files can be changed through this provider.")
                return entry["mode"]
            if entry.get("type") != "tree":
                raise AdapterError("A provider path crosses a non-directory entry.")
            tree = entry["sha"]
        raise AdapterError("Invalid provider file path.")

    def publish(self, worker, metadata, directory, patch_sha):
        self.authorize("openPR")
        self.source_repository(metadata["source"])
        publication = metadata.get("publication")
        if not publication or publication.get("repository") != self.repository or publication.get("base") != self.base:
            raise AdapterError("This run has no verified provider base. Start a new run after configuring its repository binding.")
        # Operators may choose an additional exact-patch policy. Routine publication otherwise uses existing scoped grants.
        if "approvedPatchSHA256" in self.config and patch_sha not in self.config["approvedPatchSHA256"]:
            raise AdapterError("The operator must review this exact patch and add its SHA-256 to the local publication allowlist.")
        repository = self.repo("GET")
        if repository.get("private") is False and (metadata["source"].get("isPublic") is not True or self.config.get("publicSource") is not True):
            raise AdapterError("Public publication requires both server and operator source classifications to be public.")
        if repository.get("private") is not False and self.config.get("privateAudienceAuthorized") is not True:
            raise AdapterError("The operator must authorize the destination private repository audience.")
        if self.base_head() != publication["baseCommit"]:
            raise AdapterError("The authoritative base changed. Refresh the run and checks before publication.")
        context, source = worker._local_context(directory, metadata)
        entries = []
        for path in metadata["files"]:
            worker.checkpoint(metadata, "openPR", path)
            value = context.read(source, path)["content"]
            original = directory / "original" / path
            if not original.exists() or original.read_text() != value:
                entries.append({"path": path, "mode": self.file_mode(publication.get("originalCommit", publication["baseCommit"]), path), "type": "blob", "content": value})
        if not entries:
            raise AdapterError("There are no scoped changes to publish.")
        original_commit = publication.get("originalCommit", publication["baseCommit"])
        self.verify_original(original_commit, directory / "original", metadata["files"])
        branch = publication["branch"]
        ref_path = "/git/ref/heads/" + quote(branch, safe="/")
        try:
            current = self.repo("GET", ref_path)["object"]["sha"]
        except ProviderError as exc:
            if exc.status != 404:
                raise
            current = None
        previous_head = publication.get("headCommit")
        if current is not None and current not in (previous_head, publication.get("previousHead")):
            raise AdapterError("The destination branch changed outside this run. Publication stopped.")
        if publication.get("patchSHA256") != patch_sha:
            parent = current or publication["baseCommit"]
            base_tree = self.repo("GET", "/git/commits/" + original_commit)["tree"]["sha"]
            worker.checkpoint(metadata, "openPR")
            tree = self.repo("POST", "/git/trees", {"base_tree": base_tree, "tree": entries})
            worker.checkpoint(metadata, "openPR")
            commit = self.repo("POST", "/git/commits", {"message": "WarTable: apply scoped change", "tree": tree["sha"], "parents": [parent],
                               "author": {"name": "WellSpent", "email": "dev@wellspent.space", "date": publication["date"]},
                               "committer": {"name": "WellSpent", "email": "dev@wellspent.space", "date": publication["date"]}})
            publication.update({"headCommit": commit_id(commit["sha"]), "patchSHA256": patch_sha, "previousHead": current})
            save_private_json(directory / "state.json", metadata)
        expected = publication["headCommit"]
        worker.checkpoint(metadata, "openPR")
        if self.base_head() != publication["baseCommit"]:
            raise AdapterError("The authoritative base changed during publication. The branch was not advanced.")
        if current is None:
            self.repo("POST", "/git/refs", {"ref": "refs/heads/" + branch, "sha": expected})
        elif current != expected:
            # A concurrent extra commit makes this update non-fast-forward. Never force or silently accept a newer head.
            self.repo("PATCH", "/git/refs/heads/" + quote(branch, safe="/"), {"sha": expected, "force": False})
        owner = self.repository.split("/", 1)[0]
        existing = self.repo("GET", "/pulls", query={"state": "all", "head": owner + ":" + branch, "base": self.base, "per_page": 100})
        if existing:
            pr = existing[0]
            if pr.get("head", {}).get("sha") != expected or pr.get("state") == "closed":
                raise AdapterError("Existing pull request no longer matches this open task branch.")
        else:
            worker.checkpoint(metadata, "openPR")
            pr = self.repo("POST", "/pulls", {"title": "WarTable: scoped change for review", "head": branch, "base": self.base,
                           "body": "This pull request contains a scoped change from an isolated WarTable task.\n\nValidation evidence is recorded with the task. Human review and repository checks are required before merging.", "draft": True})
        publication["prNumber"] = pr["number"]
        save_private_json(directory / "state.json", metadata)
        return {"repository": self.repository, "number": pr["number"], "url": f"https://github.com/{self.repository}/pull/{pr['number']}",
                "headCommit": expected, "baseCommit": publication["baseCommit"], "draft": pr.get("draft", True), "merged": False}

    def inspect(self, number: int, expected_head: str | None = None):
        if type(number) is not int or number < 1:
            raise AdapterError("Pull request number must be positive.")
        pr = self.repo("GET", f"/pulls/{number}")
        head = commit_id(pr["head"]["sha"])
        base = commit_id(pr["base"]["sha"])
        if expected_head and head != commit_id(expected_head):
            raise AdapterError("Pull request head changed. Previous review evidence is stale.")
        checks = self.repo("GET", f"/commits/{head}/check-runs", query={"per_page": 100})
        statuses = self.repo("GET", f"/commits/{head}/status", query={"per_page": 100})
        reviews = self.repo("GET", f"/pulls/{number}/reviews", query={"per_page": 100})
        final = self.repo("GET", f"/pulls/{number}")
        if final["head"]["sha"] != head or final["base"]["sha"] != base:
            raise AdapterError("Pull request changed while checking it. State remains unknown; inspect again.")
        return {"repository": self.repository, "number": number, "headCommit": head, "baseCommit": base,
                "merged": final.get("merged") is True, "state": final.get("state"),
                "checks": [{"name": c.get("name"), "status": c.get("status"), "conclusion": c.get("conclusion")} for c in checks.get("check_runs", [])],
                "status": statuses.get("state", "unknown"),
                "reviews": [{"id": r["id"], "reviewer": r.get("user", {}).get("login"), "state": r.get("state"), "headCommit": r.get("commit_id")} for r in reviews],
                "complete": checks.get("total_count", 0) <= 100 and statuses.get("total_count", 0) <= 100 and len(reviews) < 100,
                "providerVerified": True, "mergePolicy": "Manual merge. Check summaries do not establish required-check or branch-protection satisfaction."}

    def review(self, number: int, head: str, base: str, decision: str):
        self.authorize("review")
        observed = self.inspect(number, head)
        if observed["baseCommit"] != commit_id(base):
            raise AdapterError("Pull request base changed; re-review the current base.")
        me = self.request("GET", "/user")
        pr = self.repo("GET", f"/pulls/{number}")
        if pr.get("head", {}).get("sha") != head or pr.get("base", {}).get("sha") != base:
            raise AdapterError("Pull request changed before review submission; review the current commits.")
        if pr.get("user", {}).get("id") == me.get("id") or pr.get("head", {}).get("user", {}).get("id") == me.get("id"):
            return {"providerConfirmed": False, "advisory": True, "reason": "This provider identity authored the change; an independent reviewer must submit the approval."}
        event = {"approve": "APPROVE", "requestChanges": "REQUEST_CHANGES", "comment": "COMMENT"}.get(decision)
        if event is None:
            raise AdapterError("Unsupported review decision.")
        expected_state = {"approve": "APPROVED", "requestChanges": "CHANGES_REQUESTED", "comment": "COMMENTED"}[decision]
        own = [item for item in observed["reviews"] if item.get("reviewer", "").lower() == me.get("login", "").lower()]
        latest_own = max(own, key=lambda item: item["id"], default=None)
        if latest_own and latest_own.get("headCommit") == head and latest_own.get("state") == expected_state and observed["complete"]:
            review = latest_own
        else:
            review = self.repo("POST", f"/pulls/{number}/reviews", {"commit_id": head, "event": event,
                               "body": "Independent WarTable review for the stated commit. Supporting evidence is recorded in the task."})
        confirmed = self.repo("GET", f"/pulls/{number}/reviews/{review['id']}")
        latest = self.repo("GET", f"/pulls/{number}")
        if latest["head"]["sha"] != head or latest["base"]["sha"] != base or confirmed.get("commit_id") != head:
            raise AdapterError("Provider review was recorded, but the pull request changed. Approval is stale; inspect again.")
        if confirmed.get("state") != expected_state or confirmed.get("user", {}).get("id") != me.get("id"):
            raise AdapterError("Provider did not confirm the requested review state and identity.")
        return {"providerConfirmed": True, "reviewID": confirmed["id"], "headCommit": head, "baseCommit": base,
                "reviewer": confirmed.get("user", {}).get("login"), "state": confirmed.get("state"), "merged": False}
