"""Mediated file edits and networkless checks; no arbitrary host shell or publish."""

from __future__ import annotations

from contextlib import contextmanager
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tempfile
import time

from .client import AdapterError, private_json, save_private_json
from .context import Context, relative_path, within


def sandbox_command(workspace: Path | None = None) -> list[str]:
    executable = shutil.which("bwrap")
    if executable is None or not Path("/usr").is_dir():
        raise AdapterError("Enforced code work needs Linux bubblewrap. Chat and context remain available.")
    args = [executable, "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
            "--ro-bind", "/usr", "/usr", "--symlink", "usr/bin", "/bin",
            "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--dir", "/tmp/home",
            "--setenv", "HOME", "/tmp/home", "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "TMPDIR", "/tmp", "--setenv", "LC_ALL", "C.UTF-8"]
    if workspace is not None:
        args += ["--ro-bind", str(workspace), "/workspace", "--chdir", "/workspace"]
    return args


def probe_sandbox() -> None:
    try:
        result = subprocess.run(sandbox_command() + ["/usr/bin/true"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                                env={"PATH": "/usr/bin:/bin"})
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AdapterError("The Linux sandbox could not start; code execution is disabled.") from exc
    if result.returncode != 0:
        raise AdapterError("The Linux sandbox is unavailable; code execution is disabled.")


def resource_limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (2 * 1024 ** 3, 2 * 1024 ** 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (2 * 1024 ** 2, 2 * 1024 ** 2))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
    resource.setrlimit(resource.RLIMIT_CPU, (180, 180))


class Worker:
    def __init__(self, service, state_directory):
        self.service = service
        self.root = Path(state_directory).expanduser()

    def directory(self, run_id: str) -> Path:
        from .service import identity
        return self.root / identity(run_id)

    @contextmanager
    def locked(self, directory: Path):
        directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        if directory.is_symlink():
            raise AdapterError("Run directory cannot be a symbolic link.")
        fd = os.open(directory / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise AdapterError("This local run already has an active operation.") from exc
            yield
        finally:
            os.close(fd)

    def checkpoint(self, metadata: dict, operation: str, path: str | None = None):
        run = metadata["run"]
        body = {"fence": run["fence"], "operation": operation}
        if path is not None:
            relative_path(path)
            if not within(path, metadata["allowedPaths"]):
                raise AdapterError("Path is outside the run grant.")
            body["path"] = path
        current = self.service.request("POST", f"/runs/{run['id']}/checkpoint", body)
        if current.get("state") != "active" or current.get("fence") != run["fence"]:
            raise AdapterError("Run is stopped, fenced or no longer authorized.")
        return current

    def start(self, taskID: str, requestID: str, paths: list[str]):
        probe_sandbox()
        snapshot = self.service.snapshot()
        task = next((item for item in snapshot.get("tasks", []) if item["id"].lower() == taskID.lower()), None)
        if task is None or not task.get("grantID"):
            raise AdapterError("Task is not visible or has no human-issued grant.")
        grant = next((item for item in snapshot.get("grants", []) if item["id"] == task["grantID"]), None)
        if grant is None or grant.get("isRevoked") or "editBranch" not in grant.get("capabilities", []):
            raise AdapterError("A current editBranch grant is required for an isolated editing run.")
        source = self.service.source(task["sourceID"], snapshot)
        if not paths or any(not within(path, grant["allowedPaths"]) for path in paths):
            raise AdapterError("Every snapshot file must be inside the current grant.")
        binding = self.service.context.bindings[source["id"].lower()]
        revision = None
        if binding.get("github") and (task.get("prURL") or task.get("headCommit")):
            from .github import GitHub
            revision = GitHub(binding["github"]).revision_snapshot(task, source, self.service.context, paths)
        receipt = revision["receipt"] if revision else self.service.context.receipt(source, paths)
        rules_paths = binding.get("rulesPaths", [])
        startup_paths = list(dict.fromkeys(rules_paths + ([binding["handoffPath"]] if binding.get("handoffPath") else [])))
        rules = self.service.context.receipt(source, startup_paths) if startup_paths else None
        startup_context = [self.service.context.read(source, path) for path in startup_paths]
        if sum(len(item["content"].encode()) for item in startup_context) > 256 * 1024:
            raise AdapterError("Configured startup rules and handoff exceed 256 KiB; narrow the explicit entry points.")
        if rules and {item["path"]: item["sha256"] for item in startup_context} != {item["path"]: item["sha256"] for item in rules["files"]}:
            raise AdapterError("Startup rules changed while preparing context; read them again before claiming work.")
        worker_id = hashlib.sha256((str(self.root.resolve()) + self.service.client.agent_id).encode()).hexdigest()[:32]
        claim = {"taskID": taskID, "requestID": requestID, "workerID": worker_id,
                 "contextReceipt": {"sourceID": source["id"], "sourceRevision": source["revision"],
                                    "revision": "sha256:" + receipt["snapshotSHA256"],
                                    "rulesRevision": "sha256:" + rules["snapshotSHA256"] if rules else "none-configured",
                                    "handoffReference": binding.get("handoffPath", ""),
                                    "patchFingerprint": receipt["snapshotSHA256"]}}
        run = self.service.request("POST", "/runs", claim)
        directory = self.directory(run["id"])
        with self.locked(directory):
            metadata_path = directory / "state.json"
            if metadata_path.exists():
                metadata = private_json(metadata_path)
                if metadata["run"]["requestID"].lower() != requestID.lower():
                    raise AdapterError("Run identity conflicts with an existing local checkout.")
                self.checkpoint(metadata, "readContext")
                return {"run": run, "resumed": True, "receipt": metadata["receipt"], "startupContext": startup_context}
            metadata = {"run": run, "source": source, "receipt": receipt, "allowedPaths": grant["allowedPaths"],
                        "maxRuntimeSeconds": min(grant.get("maxRuntimeSeconds", 180), 180),
                        "checks": binding.get("checks", {}), "startedAt": time.time(), "files": paths}
            try:
                for item in receipt["files"]:
                    path = item["path"]
                    self.checkpoint(metadata, "editBranch", path)
                    data = revision["files"][path] if revision else self.service.context.read_bytes(source, path)
                    if hashlib.sha256(data).hexdigest() != item["sha256"]:
                        raise AdapterError("A source file changed while preparing the run; claim a new receipt.")
                    for folder in ("original", "workspace"):
                        target = directory / folder / path
                        target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
                        target.write_bytes(data)
                        target.chmod(0o600)
                if binding.get("github"):
                    from .github import GitHub
                    metadata["publication"] = revision["publication"] if revision else GitHub(binding["github"]).capture(metadata, directory)
                save_private_json(metadata_path, metadata)
            except Exception:
                # Do not erase evidence or claim a stopped server run if cleanup cannot be confirmed.
                try:
                    self.service.request("POST", f"/runs/{run['id']}/finish",
                                         {"fence": run["fence"], "state": "blocked", "summary": "Local snapshot preparation failed; no checks or publication started."})
                except AdapterError:
                    pass
                raise
        return {"run": run, "receipt": receipt, "startupContext": startup_context,
                "boundary": "Isolated permitted-file snapshot. Tests are networkless and read-only. No host checkout or Git provider credentials are mounted."}

    def _local_context(self, directory, metadata):
        source = dict(metadata["source"], allowedPaths=metadata["allowedPaths"])
        context = Context({"sources": {source["id"]: {"root": str(directory / "workspace"), "allowedPaths": metadata["allowedPaths"]}}})
        return context, source

    def read_work_file(self, runID: str, path: str):
        directory = self.directory(runID)
        with self.locked(directory):
            metadata = private_json(directory / "state.json")
            self.checkpoint(metadata, "readContext", path)
            context, source = self._local_context(directory, metadata)
            return context.read(source, path)

    def write_work_file(self, runID: str, path: str, content: str):
        directory = self.directory(runID)
        data = content.encode("utf-8")
        if len(data) > 1024 * 1024:
            raise AdapterError("Work file exceeds the 1 MiB edit limit.")
        with self.locked(directory):
            metadata = private_json(directory / "state.json")
            self.checkpoint(metadata, "editBranch", path)
            current = os.open(directory / "workspace", os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW)
            try:
                parts = relative_path(path)
                for part in parts[:-1]:
                    try:
                        os.mkdir(part, mode=0o700, dir_fd=current)
                    except FileExistsError:
                        pass
                    child = os.open(part, os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW, dir_fd=current)
                    os.close(current)
                    current = child
                fd = os.open(parts[-1], os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=current)
                with os.fdopen(fd, "wb") as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
            except OSError as exc:
                raise AdapterError("Work path is unavailable; symbolic links are refused.") from exc
            finally:
                os.close(current)
            if path not in metadata["files"]:
                metadata["files"].append(path)
                save_private_json(directory / "state.json", metadata)
            return {"runID": runID, "path": path, "sha256": hashlib.sha256(data).hexdigest(), "saved": True}

    def run_check(self, runID: str, check: str):
        directory = self.directory(runID)
        with self.locked(directory):
            metadata = private_json(directory / "state.json")
            command = metadata["checks"].get(check)
            if not isinstance(command, list) or not command or not all(isinstance(v, str) and "\x00" not in v for v in command):
                raise AdapterError("This check is not in the human-configured local command allowlist.")
            self.checkpoint(metadata, "runChecks")
            probe_sandbox()
            started = time.monotonic()
            with tempfile.TemporaryFile() as output:
                process = subprocess.Popen(sandbox_command(directory / "workspace") + command, stdin=subprocess.DEVNULL,
                                           stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
                                           env={"PATH": "/usr/bin:/bin"}, preexec_fn=resource_limits)
                try:
                    while True:
                        try:
                            result = process.wait(timeout=min(5, metadata["maxRuntimeSeconds"]))
                            break
                        except subprocess.TimeoutExpired:
                            if time.monotonic() - started >= metadata["maxRuntimeSeconds"]:
                                raise AdapterError("Check reached its local runtime limit; its run process was terminated.")
                            self.checkpoint(metadata, "runChecks")
                    self.checkpoint(metadata, "runChecks")
                except BaseException:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)
                    raise
                output.seek(0)
                data = output.read(65537)
            return {"runID": runID, "check": check, "exitCode": result, "passed": result == 0,
                    "output": data[:65536].decode("utf-8", errors="replace"), "truncated": len(data) > 65536,
                    "sourceID": metadata["source"]["id"], "classification": "public" if metadata["source"]["isPublic"] else "restricted",
                    "notice": "Local check output is source-derived. Review it before sharing; no raw output was uploaded."}

    def work_diff(self, runID: str):
        directory = self.directory(runID)
        with self.locked(directory):
            metadata = private_json(directory / "state.json")
            self.checkpoint(metadata, "readContext")
            return self._diff(directory, metadata)

    def _diff(self, directory, metadata):
        context, source = self._local_context(directory, metadata)
        patches = []
        for path in sorted(metadata["files"]):
            before = directory / "original" / path
            original = before.read_text() if before.exists() else ""
            changed = context.read(source, path)["content"]
            lines = difflib.unified_diff(original.splitlines(keepends=True), changed.splitlines(keepends=True),
                                        fromfile="a/" + path, tofile="b/" + path)
            patch = "".join(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n" for line in lines)
            if not before.exists() and not changed:
                patch = f"diff --git a/{path} b/{path}\nnew file mode 100644\n"
            if patch:
                patches.append(patch)
        result = "".join(patches)
        if len(result.encode()) > 1024 * 1024:
            raise AdapterError("Patch exceeds the connector review limit; review smaller changes.")
        return {"runID": metadata["run"]["id"], "sourceID": source["id"], "patch": result,
                "patchSHA256": hashlib.sha256(result.encode()).hexdigest(),
                "classification": "public" if source["isPublic"] else "restricted", "published": False}

    def publish_work(self, runID: str):
        from .github import GitHub
        directory = self.directory(runID)
        with self.locked(directory):
            metadata = private_json(directory / "state.json")
            self.checkpoint(metadata, "openPR")
            binding = self.service.context.bindings.get(metadata["source"]["id"].lower(), {})
            provider = GitHub(binding.get("github", {}))
            difference = self._diff(directory, metadata)
            result = provider.publish(self, metadata, directory, difference["patchSHA256"])
            self.service.request("POST", f"/tasks/{metadata['run']['taskID']}/evidence",
                                 {"runID": runID, "fence": metadata["run"]["fence"], "kind": "pullRequest",
                                  "summary": "Scoped patch published as a draft PR. Provider checks and independent review are required.",
                                  "commit": result["headCommit"], "url": result["url"]})
            return result

    def finish_work(self, runID: str, state: str, summary: str, **optional):
        directory = self.directory(runID)
        with self.locked(directory):
            metadata = private_json(directory / "state.json")
            body = {"fence": metadata["run"]["fence"], "state": state, "summary": summary, **optional}
            result = self.service.request("POST", f"/runs/{runID}/finish", body)
            metadata["finished"] = True
            save_private_json(directory / "state.json", metadata)
            return result
