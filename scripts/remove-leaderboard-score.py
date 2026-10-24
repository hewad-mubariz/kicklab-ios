#!/usr/bin/env python3
"""Take a session's automatic score off the leaderboard, or put it back.

The beta ranks each player's best device-counted streak with no review, so this is the
operator's way to remove a score that breaks the rules or looks impossible. The session
stays in the player's history; only its leaderboard place goes (score_status 'rejected').

Dry run by default. Credentials are read from the operator's environment only:
SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY. Every change is appended to a private log
in config/local (git-ignored).

  python3 scripts/remove-leaderboard-score.py list --period week
  python3 scripts/remove-leaderboard-score.py remove <session-id> --reason "Ball held between touches"
  python3 scripts/remove-leaderboard-score.py remove <session-id> --reason "..." --confirm
  python3 scripts/remove-leaderboard-score.py restore <session-id> --reason "Checked again" --confirm
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
from uuid import UUID

LOG = Path(__file__).resolve().parent.parent / "config" / "local" / "leaderboard-moderation.log"
FIELDS = "id,user_id,touch_count,streak_touches,streak_start_ms,streak_end_ms,completed_at,score_status,source"


class ModerationError(Exception):
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
            raise ModerationError("Set SUPABASE_URL (HTTPS) and SUPABASE_SERVICE_ROLE_KEY in your environment.")

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
            raise ModerationError(f"{method} {path.split('?')[0]} returned HTTP {error.code}.") from None
        except (urllib.error.URLError, TimeoutError):
            raise ModerationError("Request failed. Check connectivity and retry.") from None


def week_start(now):
    """Monday 00:00 UTC, the leaderboard's weekly reset."""
    day = now.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    return day - timedelta(days=day.weekday())


def names(client, user_ids):
    if not user_ids:
        return {}
    wanted = ",".join(sorted(set(user_ids)))
    rows = client.json(f"/rest/v1/profiles?select=id,display_name,leaderboard_visible&id=in.({wanted})")
    return {row["id"]: row for row in rows}


def session(client, session_id):
    rows = client.json(f"/rest/v1/juggling_sessions?select={FIELDS}&id=eq.{session_id}")
    if not rows:
        raise ModerationError("No session with that id.")
    if len(rows) > 1:
        raise ModerationError("That id matches sessions on more than one account; refusing to guess.")
    return rows[0]


def describe(row, profile):
    return {"session_id": row["id"], "user_id": row["user_id"],
            "player": (profile or {}).get("display_name"), "visible": (profile or {}).get("leaderboard_visible"),
            "best_streak": row["streak_touches"], "session_total": row["touch_count"],
            "completed_at": row["completed_at"], "source": row["source"], "score_status": row["score_status"]}


def list_scores(client, period, limit, now=None):
    query = (f"/rest/v1/juggling_sessions?select={FIELDS}&source=eq.recording&streak_touches=gt.0"
             f"&score_status=neq.rejected&order=streak_touches.desc,completed_at.asc&limit={limit}")
    if period == "week":
        query += "&completed_at=gte." + urllib.parse.quote(week_start(now or datetime.now(timezone.utc)).isoformat())
    rows = client.json(query)
    profiles = names(client, [row["user_id"] for row in rows])
    return [describe(row, profiles.get(row["user_id"])) for row in rows]


def change(client, session_id, status, reason, confirm, now=None):
    reason = (reason or "").strip()
    if not 1 <= len(reason) <= 500:
        raise ModerationError("Give a --reason of 1–500 characters; it goes in the moderation log.")
    row = session(client, session_id)
    profile = names(client, [row["user_id"]]).get(row["user_id"])
    before = describe(row, profile)
    if row["score_status"] == status:
        return {"unchanged": before}
    if not confirm:
        return {"dry_run": True, "would_set_score_status": status, "session": before}
    updated = client.json(f"/rest/v1/juggling_sessions?id=eq.{session_id}&user_id=eq.{row['user_id']}", "PATCH",
                          {"score_status": status}, {"Prefer": "return=representation"})
    if not updated or updated[0]["score_status"] != status:
        raise ModerationError("The change was not saved.")
    LOG.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    entry = {"at": (now or datetime.now(timezone.utc)).isoformat(), "action": status, "reason": reason, "session": before}
    descriptor = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "a") as log:
        log.write(json.dumps(entry) + "\n")
    return {"saved": describe(updated[0], profile)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="Show the sessions that rank now, best first")
    listing.add_argument("--period", choices=["week", "all_time"], default="week")
    listing.add_argument("--limit", type=int, default=20)
    for name, text in (("remove", "Take a session's score off the leaderboard"),
                       ("restore", "Put a removed score back on the leaderboard")):
        command = commands.add_parser(name, help=text)
        command.add_argument("session_id", type=uuid)
        command.add_argument("--reason", required=True)
        command.add_argument("--confirm", action="store_true", help="Apply the change; without it, a dry run")
    args = parser.parse_args()
    try:
        client = Client()
        if args.command == "list":
            result = list_scores(client, args.period, max(1, min(args.limit, 200)))
        else:
            status = "rejected" if args.command == "remove" else "device_reported"
            result = change(client, args.session_id, status, args.reason, args.confirm)
        print(json.dumps(result, indent=2))
    except ModerationError as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
