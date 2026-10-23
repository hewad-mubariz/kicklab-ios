#!/usr/bin/env python3
"""Wipe one account's juggling records so the reviewed leaderboard can be tested from zero.

Removes the account's juggling sessions (training history and personal best), its
leaderboard submissions with their reviews and reports, and its uploaded originals.
The account, profile, name, photo and leaderboard visibility are kept.

Dry run by default. Credentials are read from the operator's environment only:
SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY. Before deleting, the rows are saved to a
private local backup in config/local (git-ignored). Uploaded videos are not backed up.

  python3 scripts/wipe-juggling-records.py --email you@example.com
  python3 scripts/wipe-juggling-records.py --email you@example.com --confirm
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
from uuid import UUID

BUCKET = "leaderboard-originals"


class WipeError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # An operator's service credential must never follow an external redirect.
        return None


def uuid(value):
    try:
        return str(UUID(value))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Expected a UUID") from error


class Client:
    def __init__(self):
        self.url = os.environ.get("SUPABASE_URL", "").rstrip("/")
        self.key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
        parsed = urllib.parse.urlparse(self.url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.query or not self.key:
            raise WipeError("Set SUPABASE_URL (HTTPS) and SUPABASE_SERVICE_ROLE_KEY in your environment.")

    def json(self, path, method="GET", body=None, headers=None):
        request = urllib.request.Request(self.url + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"apikey": self.key, "Authorization": "Bearer " + self.key,
                     "Content-Type": "application/json", **(headers or {})})
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=60) as response:
                data = response.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            # Do not print credentials or upstream response payloads.
            raise WipeError(f"{method} {path.split('?')[0]} returned HTTP {error.code}.") from None
        except (urllib.error.URLError, TimeoutError):
            raise WipeError("Request failed. Check connectivity and retry.") from None


def find_account(client, email, user_id):
    if user_id:
        user = client.json(f"/auth/v1/admin/users/{user_id}")
        return user["id"], user.get("email") or "(no email)"
    wanted = email.strip().lower()
    page = 1
    while True:
        users = client.json(f"/auth/v1/admin/users?page={page}&per_page=200").get("users", [])
        for user in users:
            if (user.get("email") or "").lower() == wanted:
                return user["id"], user["email"]
        if len(users) < 200:
            raise WipeError("No account with that email.")
        page += 1


def rows(client, table, user_id, select):
    found, offset = [], 0
    while True:
        page = client.json(f"/rest/v1/{table}?user_id=eq.{user_id}&select={select}"
                           f"&order=id.asc&limit=1000&offset={offset}")
        found.extend(page)
        if len(page) < 1000:
            return found
        offset += 1000


def originals(client, user_id):
    found, offset = [], 0
    while True:
        page = client.json(f"/storage/v1/object/list/{BUCKET}", "POST",
                           {"prefix": f"{user_id}/", "limit": 1000, "offset": offset})
        found.extend(f"{user_id}/{item['name']}" for item in page if item.get("id"))
        if len(page) < 1000:
            return found
        offset += 1000


def survey(client, user_id):
    sessions = rows(client, "juggling_sessions", user_id, "*")
    attempts = rows(client, "leaderboard_attempts", user_id, "*")
    return sessions, attempts, originals(client, user_id)


def report(email, user_id, sessions, attempts, videos):
    statuses = {}
    for attempt in attempts:
        statuses[attempt["status"]] = statuses.get(attempt["status"], 0) + 1
    recorded = [s for s in sessions if s["source"] == "recording"]
    print(json.dumps({
        "account": {"email": email, "id": user_id},
        "juggling_sessions": {"total": len(sessions), "recordings": len(recorded),
                              "imports": len(sessions) - len(recorded),
                              "best_touches": max((s["touch_count"] for s in sessions), default=0)},
        "leaderboard_attempts": {"total": len(attempts), "by_status": statuses},
        "uploaded_originals": len(videos),
        "kept": "account, profile, name, photo and leaderboard visibility",
    }, indent=2))


def backup(email, user_id, sessions, attempts, videos):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = Path(__file__).resolve().parent.parent / "config" / "local" / f"juggling-wipe-{stamp}"
    folder.mkdir(parents=True, mode=0o700)
    path = folder / "rows.json"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as target:
        json.dump({"account": {"email": email, "id": user_id}, "captured_at": stamp,
                   "juggling_sessions": sessions, "leaderboard_attempts": attempts,
                   "uploaded_originals": videos}, target, indent=2)
    return path


def wipe(client, user_id, videos):
    # Videos first: deleting the rows does not remove stored bytes.
    for start in range(0, len(videos), 100):
        client.json(f"/storage/v1/object/{BUCKET}", "DELETE", {"prefixes": videos[start:start + 100]})
    # Submissions take their reviews and reports with them; sessions take any leftovers.
    client.json(f"/rest/v1/leaderboard_attempts?user_id=eq.{user_id}", "DELETE")
    client.json(f"/rest/v1/juggling_sessions?user_id=eq.{user_id}", "DELETE")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    who = parser.add_mutually_exclusive_group(required=True)
    who.add_argument("--email", help="The account's sign-in email")
    who.add_argument("--user-id", type=uuid, help="The account's user ID")
    parser.add_argument("--confirm", action="store_true", help="Delete. Without it, only report.")
    args = parser.parse_args()
    try:
        client = Client()
        user_id, email = find_account(client, args.email, args.user_id)
        sessions, attempts, videos = survey(client, user_id)
        report(email, user_id, sessions, attempts, videos)
        if not args.confirm:
            print("Dry run: nothing was deleted. Run again with --confirm to wipe these records.")
            return
        if not (sessions or attempts or videos):
            print("Nothing to wipe.")
            return
        saved = backup(email, user_id, sessions, attempts, videos)
        print(f"Rows backed up to {saved}")
        wipe(client, user_id, videos)
        sessions, attempts, videos = survey(client, user_id)
        if sessions or attempts or videos:
            raise WipeError(f"Some records remain: {len(sessions)} sessions, {len(attempts)} submissions, "
                            f"{len(videos)} originals. Run again to finish.")
        print("Wiped. Remove the app's local history too: delete and reinstall the app, "
              "or the phone keeps showing its own copies.")
    except WipeError as error:
        print(error, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
