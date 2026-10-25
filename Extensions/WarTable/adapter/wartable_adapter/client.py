"""Credential handling and the installation-scoped HTTPS boundary."""

from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
import stat
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class AdapterError(Exception):
    """A safe, user-visible error that never contains credentials."""


def private_json(path: Path) -> dict:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise AdapterError("Configuration must be an owned regular file with mode 0600.")
            if info.st_size > 1024 * 1024:
                raise AdapterError("Configuration is too large.")
            value = json.load(handle)
    except (OSError, ValueError) as exc:
        raise AdapterError("Cannot read private configuration; check its path and JSON format.") from exc
    if not isinstance(value, dict):
        raise AdapterError("Configuration must be a JSON object.")
    return value


def save_private_json(path: Path, value: dict) -> None:
    path = path.expanduser()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise AdapterError("Refusing a symbolic-link credential file.")
    fd, temporary = tempfile.mkstemp(prefix=".wartable-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(value, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def service_url(value: str) -> str:
    parts = urlsplit(value)
    if parts.username or parts.password or parts.query or parts.fragment or parts.path not in ("", "/"):
        raise AdapterError("Service URL must contain only scheme, host and optional port.")
    try:
        loopback = ipaddress.ip_address(parts.hostname or "").is_loopback
    except ValueError:
        loopback = parts.hostname == "localhost"
    if not parts.hostname or parts.scheme not in ("http", "https") or (parts.scheme == "http" and not loopback):
        raise AdapterError("Use HTTPS, or loopback HTTP for an isolated local test server.")
    return value.rstrip("/")


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    prefix = "/extensions/wartable/v1"

    def __init__(self, config: dict):
        self.url = service_url(config.get("serverURL", ""))
        self.group_id = config.get("groupID", "")
        self.agent_id = config.get("agentID", "")
        self.token = config.get("token", "")
        self.opener = build_opener(NoRedirects())

    def request(self, method: str, path: str, body: dict | None = None, *, query: dict | None = None,
                authenticated: bool = True):
        if not path.startswith("/") or ".." in path or "?" in path or "#" in path:
            raise AdapterError("Invalid API path.")
        headers = {"Accept": "application/json", "User-Agent": "WarTableAdapter/0.1.0"}
        if authenticated:
            if not self.token or "\n" in self.token or "\r" in self.token:
                raise AdapterError("Enroll this session before using WarTable.")
            headers["Authorization"] = "Bearer " + self.token
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        suffix = "?" + urlencode(query) if query else ""
        request = Request(self.url + self.prefix + path + suffix, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=15) as response:
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise AdapterError("Server response exceeded the connector limit.")
                return json.loads(raw) if raw else {"ok": True}
        except HTTPError as exc:
            explanations = {401: "Credential expired or revoked. Re-enroll this session.",
                            403: "Current identity is not allowed to perform this action.",
                            404: "The scoped resource is unavailable.",
                            409: "The resource changed or this action conflicts with current state.",
                            429: "The request limit was reached. Wait for an authorized continuation."}
            message = explanations.get(exc.code, f"WarTable request failed (HTTP {exc.code}).")
            exc.close()
            raise AdapterError(message) from None
        except (URLError, TimeoutError, OSError, ValueError) as exc:
            raise AdapterError("WarTable is unavailable or returned an invalid response. No success was confirmed.") from exc
