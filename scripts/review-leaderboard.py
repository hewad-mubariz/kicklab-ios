#!/usr/bin/env python3
"""Private beta review tool. Credentials are read from the operator's environment only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from uuid import UUID


class ReviewError(Exception):
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
            raise ReviewError("Set SUPABASE_URL (HTTPS) and SUPABASE_SERVICE_ROLE_KEY in your environment.")

    def request(self, path, method="GET", body=None):
        request = urllib.request.Request(self.url + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"apikey": self.key, "Authorization": "Bearer " + self.key,
                     "Content-Type": "application/json"})
        try:
            return urllib.request.build_opener(NoRedirect).open(request, timeout=60)
        except urllib.error.HTTPError as error:
            # Do not print credentials, signed URLs or upstream response payloads.
            raise ReviewError(f"Server returned HTTP {error.code}. Check the attempt and operator permissions.") from None
        except (urllib.error.URLError, TimeoutError):
            raise ReviewError("Request failed. Check connectivity and retry.") from None

    def json(self, path, method="GET", body=None):
        with self.request(path, method, body) as response:
            data = response.read()
            return json.loads(data) if data else None

    def attempt(self, ident):
        rows = self.json(f"/rest/v1/leaderboard_attempts?id=eq.{ident}&select=*")
        if not rows:
            raise ReviewError("Attempt unavailable.")
        return rows[0]


def fingerprint(path):
    digest, size = hashlib.sha256(), 0
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def verify_bytes(path, attempt):
    size, digest = fingerprint(path)
    if size != attempt["video_bytes"] or digest != attempt["video_sha256"]:
        raise ReviewError("Original bytes do not match the submission. Do not approve this file.")
    return digest


def inspect_video(path, attempt, end_ms):
    try:
        result = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
            "format=duration:stream=codec_type", "-of", "json", str(path)],
            capture_output=True, check=True, timeout=30)
        media = json.loads(result.stdout)
        duration = float(media["format"]["duration"]) * 1000
        if not any(stream.get("codec_type") == "video" for stream in media["streams"]):
            raise ValueError("no video")
        if not duration > 0 or end_ms > duration + 250:
            raise ReviewError("The reviewed segment extends past the actual video.")
        if abs(duration - attempt["duration_ms"]) > max(2000, duration * .01):
            raise ReviewError("Actual video duration differs from the submitted session. Investigate before approval.")
    except (FileNotFoundError, subprocess.SubprocessError, KeyError, ValueError):
        raise ReviewError("ffprobe must be installed and able to read the original before approval.") from None


def run(args, client):
    if args.command == "queue":
        condition = "appeal_at=not.is.null" if args.appeals else "status=eq.pending"
        rows, offset = [], 0
        while len(rows) < 500:
            page = client.json(f"/rest/v1/leaderboard_attempts?{condition}&order=submitted_at.asc,id.asc&limit=500&offset={offset}")
            rows.extend(row for row in page if not args.appeals or (
                row["status"] in ("approved", "rejected")
                and row["appeal_at"] > (row["reviewed_at"] or "")
                and row["video_delete_requested_at"] is None))
            if len(page) < 500:
                break
            offset += 500
        rows = rows[:500]
        fields = ("id", "user_id", "submitted_at", "status", "proposed_count", "proposed_start_ms",
                  "proposed_end_ms", "duration_ms", "reviewed_count", "review_reason", "appeal_text")
        print(json.dumps([{key: row[key] for key in fields} for row in rows], indent=2))
    elif args.command == "download":
        attempt = client.attempt(args.id)
        if attempt["video_delete_requested_at"] or attempt["video_deleted_at"] or attempt["status"] in ("uploading", "withdrawn"):
            raise ReviewError("No submitted original is available for this attempt.")
        path = Path(args.output).expanduser().resolve()
        partial = path.with_name(path.name + ".partial")
        if path.exists() or partial.exists():
            raise ReviewError("Choose a new output path; an existing original will not be overwritten.")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            with client.request("/storage/v1/object/authenticated/leaderboard-originals/" +
                    urllib.parse.quote(attempt["object_path"], safe="/")) as response:
                descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as target:
                    total = 0
                    while chunk := response.read(1024 * 1024):
                        total += len(chunk)
                        if total > attempt["video_bytes"]:
                            raise ReviewError("Downloaded size exceeds the declared original.")
                        target.write(chunk)
            verify_bytes(partial, attempt)
            partial.rename(path)
        finally:
            partial.unlink(missing_ok=True)
        print(f"Verified original saved to {path}. Watch the full recording before reviewing; delete this local copy afterward.")
    elif args.command == "review":
        if not args.confirm_watched:
            raise ReviewError("Watch the original and pass --confirm-watched to attest to manual review.")
        attempt = client.attempt(args.id)
        path = Path(args.file).expanduser().resolve()
        digest = verify_bytes(path, attempt)
        approved = args.decision == "approve"
        if approved:
            if args.count is None or args.start_ms is None or args.end_ms is None:
                raise ReviewError("Approval requires --count, --start-ms and --end-ms for one uninterrupted streak.")
            if args.count < 1 or args.start_ms < 0 or args.end_ms <= args.start_ms:
                raise ReviewError("Invalid reviewed streak.")
            inspect_video(path, attempt, args.end_ms)
        client.json("/rest/v1/rpc/review_leaderboard_attempt", "POST", {
            "p_id": args.id, "p_approved": approved, "p_count": args.count if approved else None,
            "p_start_ms": args.start_ms if approved else None, "p_end_ms": args.end_ms if approved else None,
            "p_reason": args.reason, "p_reason_time_ms": args.reason_time_ms,
            "p_sha256": digest, "p_reviewer": args.reviewer})
        print("Decision saved. Remove the local original when review is complete.")
    elif args.command == "reports":
        print(json.dumps(client.json("/rest/v1/leaderboard_reports?resolved_at=is.null&order=created_at.asc&limit=500"), indent=2))
    elif args.command == "resolve-report":
        from datetime import datetime, timezone
        if not 1 <= len(args.reason.strip()) <= 1000:
            raise ReviewError("Resolution must be 1–1,000 characters.")
        client.json(f"/rest/v1/leaderboard_reports?id=eq.{args.id}", "PATCH", {
            "resolved_at": datetime.now(timezone.utc).isoformat(), "resolution": args.reason.strip()})
        print("Report resolved. A score changes only through a separate review decision.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    queue = commands.add_parser("queue", help="List pending attempts, or unresolved appeals")
    queue.add_argument("--appeals", action="store_true")
    download = commands.add_parser("download", help="Download and hash-check a private original")
    download.add_argument("id", type=uuid)
    download.add_argument("--output", required=True)
    review = commands.add_parser("review", help="Record a manual decision after watching the original")
    review.add_argument("id", type=uuid)
    review.add_argument("decision", choices=["approve", "reject"])
    review.add_argument("--file", required=True)
    review.add_argument("--reviewer", required=True)
    review.add_argument("--reason", required=True)
    review.add_argument("--reason-time-ms", type=int)
    review.add_argument("--count", type=int)
    review.add_argument("--start-ms", type=int)
    review.add_argument("--end-ms", type=int)
    review.add_argument("--confirm-watched", action="store_true")
    commands.add_parser("reports", help="List unresolved player reports")
    resolve = commands.add_parser("resolve-report")
    resolve.add_argument("id", type=uuid)
    resolve.add_argument("--reason", required=True)
    args = parser.parse_args()
    try:
        run(args, Client())
    except (ReviewError, OSError) as error:
        print(f"Review stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
