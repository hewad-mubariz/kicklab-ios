import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("review", Path(__file__).parents[1] / "review-leaderboard.py")
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class ReviewToolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.file = Path(self.directory.name) / "original.mov"
        self.file.write_bytes(b"test-original")
        self.attempt = {"video_bytes": 13, "video_sha256": hashlib.sha256(b"test-original").hexdigest(), "duration_ms": 5000}
        self.client = Mock()
        self.client.attempt.return_value = self.attempt
        self.args = argparse.Namespace(command="review", id="test-id", decision="approve", file=str(self.file),
            confirm_watched=True, count=4, start_ms=200, end_ms=4500, reason="Four clear contacts", reason_time_ms=None, reviewer="tester")

    def test_altered_original_cannot_be_approved(self):
        self.file.write_bytes(b"changed-file!")
        with self.assertRaises(review.ReviewError):
            review.run(self.args, self.client)
        self.client.json.assert_not_called()

    def test_manual_confirmation_required(self):
        self.args.confirm_watched = False
        with self.assertRaises(review.ReviewError):
            review.run(self.args, self.client)
        self.client.json.assert_not_called()

    def test_approval_uses_downloaded_hash_and_reviewed_segment(self):
        media = {"format": {"duration": "5.0"}, "streams": [{"codec_type": "video"}]}
        with patch.object(review.subprocess, "run", return_value=Mock(stdout=json.dumps(media).encode())), contextlib.redirect_stdout(io.StringIO()):
            review.run(self.args, self.client)
        payload = self.client.json.call_args.args[2]
        self.assertEqual(payload["p_sha256"], self.attempt["video_sha256"])
        self.assertEqual(payload["p_count"], 4)
        self.assertEqual((payload["p_start_ms"], payload["p_end_ms"]), (200, 4500))

    def test_declared_duration_cannot_disguise_a_short_clip(self):
        media = {"format": {"duration": "1.0"}, "streams": [{"codec_type": "video"}]}
        with patch.object(review.subprocess, "run", return_value=Mock(stdout=json.dumps(media).encode())):
            with self.assertRaises(review.ReviewError):
                review.run(self.args, self.client)
        self.client.json.assert_not_called()


if __name__ == "__main__":
    unittest.main()
