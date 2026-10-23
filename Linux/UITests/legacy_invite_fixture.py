"""Create an old-style link through the retained public API.

This is setup for legacy-link and shared-data tests, not a test of creating
an invitation in the current UI. Email invitation tests use the real form.
No app database or test-only app endpoint is used here.
"""

import datetime
import hashlib
import json
import urllib.parse
import urllib.request
import uuid


def create_legacy_invite(base_url, email, password, group_name, inviter_name,
                         level="Add", history="all"):
    token = None

    def request(method, path, body=None):
        headers = {"User-Agent": "WellSpent-Linux-UI-tests", "Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode()
        call = urllib.request.Request(f"{base_url}/api/v2/{path}", data=data,
                                      headers=headers, method=method)
        with urllib.request.urlopen(call, timeout=30) as reply:
            raw = reply.read()
            return json.loads(raw) if raw else None

    session = request("POST", "signin", {"email": email, "password": password,
                                           "deviceLabel": "Legacy invite fixture"})
    token = session["token"]
    try:
        matches = []
        for group in request("GET", "groups"):
            if group["deleted"]:
                continue
            records, cursor = [], 0
            while True:
                page = request("GET", f"groups/{group['id']}/pull?since={cursor}&limit=500")
                records.extend(page["records"])
                if not page["hasMore"]:
                    break
                cursor = page["serverSeq"]
            if any(record["type"] == "groupMeta" and not record["isDeleted"]
                   and json.loads(record["body"])["name"] == group_name for record in records):
                matches.append((group["id"], records))
        if len(matches) != 1:
            raise AssertionError(f"expected one fixture group named {group_name!r}, found {len(matches)}")
        group_id, records = matches[0]

        # A link made by the previous app also saved the inviter's group
        # name. Reproduce that public sync write, so existing member and
        # attribution scenarios retain their original assertions.
        user_id = session["userID"]
        digest = bytearray(hashlib.sha256(uuid.UUID(group_id).bytes + uuid.UUID(user_id).bytes).digest()[:16])
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        profile_id = str(uuid.UUID(bytes=bytes(digest))).upper()
        profile = {"id": profile_id, "groupID": group_id, "userID": user_id,
                   "displayName": inviter_name, "isDeleted": False,
                   "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        pushed = request("POST", f"groups/{group_id}/push", {"records": [{
            "id": profile_id, "type": "memberProfile", "lamport": max(r["lamport"] for r in records) + 1,
            "clientID": str(uuid.uuid4()), "isDeleted": False, "body": json.dumps(profile),
        }]})
        if profile_id.lower() not in [value.lower() for value in pushed["accepted"]]:
            raise AssertionError("the public API refused the legacy inviter's member profile")

        made = request("POST", f"groups/{group_id}/invites", {
            "level": {"View": 3, "Add": 5, "Manage": 7}[level], "historyAccess": history,
        })
        fragment = urllib.parse.urlencode({"s": made["token"], "g": group_name, "f": inviter_name},
                                          quote_via=urllib.parse.quote)
        return "wellspent-staging://join#" + fragment
    finally:
        request("POST", "signout")
