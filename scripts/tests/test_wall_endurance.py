import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("endurance", Path(__file__).parents[1] / "wall-endurance.py")
endurance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(endurance)


def session():
    return [{"run": "run-a", "event": "sample", "uptime": t, "wallTime": 1792700000 + t,
             "processID": 10, "appState": "active", "context": "memory-strike-v1",
             "power": {"batteryPercent": 80 - int(t / 150), "charging": "unplugged", "lowPowerMode": False},
             "brightness": .4, "thermalState": int(t >= 900), "memoryMiB": 200 + t / 1800,
             "cameraResting": False, "analysisFPS": 20, "captureFPS": 60, "inferenceMS": 35,
             "cpuSeconds": t * 1.5, "environment": {"hardware": "iPhone12,5", "buildFingerprint": "f" * 64},
             "gameplay": {"phase": "playing", "recording": False, "macPreview": False},
             "displayCount": 2, "screenCaptured": True} for t in range(0, 1801, 5)]


class EnduranceReportTests(unittest.TestCase):
    def test_complete_unplugged_run_has_rate_but_no_beta_pass(self):
        report = endurance.summarize_run(session())
        self.assertTrue(report["battery"]["comparableRun"])
        self.assertEqual(report["battery"]["percentagePointsPerHour"], 24)
        self.assertEqual(report["thermalSeconds"], {"0": 900, "1": 900})
        self.assertEqual(report["cpuAverageCores"], 1.5)
        self.assertIn("NOT_ACCEPTED", report["qualification"])

    def test_charging_even_once_invalidates_drain_comparison(self):
        rows = session()
        rows[100]["power"]["charging"] = "charging"
        battery = endurance.summarize_run(rows)["battery"]
        self.assertIn("charging_or_unknown_power", battery["ineligibleReasons"])
        self.assertIsNone(battery["percentagePointsPerHour"])

    def test_gaps_do_not_inflate_playing_time_or_assume_thermal_state(self):
        rows = [r for r in session() if not 600 <= r["uptime"] < 900]
        report = endurance.summarize_run(rows)
        self.assertEqual(report["gapSeconds"], 305)
        self.assertEqual(report["playingSeconds"], 1495)
        self.assertEqual(sum(report["thermalSeconds"].values()), 1495)
        self.assertFalse(report["battery"]["comparableRun"])

    def test_background_and_resting_are_not_gameplay(self):
        rows = session()
        for row in rows[:120]:
            row["appState"] = "background"
            row["cameraResting"] = True
        report = endurance.summarize_run(rows)
        self.assertEqual(report["activeCameraSeconds"], 1200)
        self.assertEqual(report["playingSeconds"], 1200)
        self.assertIn("not_continuously_foreground", report["battery"]["ineligibleReasons"])

    def test_changed_brightness_display_and_low_power_are_visible(self):
        rows = session()
        rows[-1].update(brightness=.8, displayCount=1)
        rows[-1]["power"]["lowPowerMode"] = True
        reasons = endurance.summarize_run(rows)["battery"]["ineligibleReasons"]
        for expected in ("brightness_changed", "display_state_changed", "low_power_mode_or_unknown"):
            self.assertIn(expected, reasons)

    def test_legacy_missing_phase_is_unknown_not_zero(self):
        rows = session()
        for row in rows:
            del row["gameplay"]
            del row["environment"]
        report = endurance.summarize_run(rows)
        self.assertIsNone(report["playingSeconds"])
        self.assertIn("build_identity_unavailable", report["battery"]["ineligibleReasons"])
        self.assertIsNone(report["fiveMinuteWindows"][0]["playingAnalysisFPS"])

    def test_single_sample_unknown_battery_cannot_qualify(self):
        rows = session()[:1]
        rows[0]["power"]["batteryPercent"] = None
        report = endurance.summarize_run(rows)
        self.assertFalse(report["battery"]["comparableRun"])
        self.assertIsNone(report["battery"]["percentagePointsPerHour"])
        self.assertIsNone(report["cpuAverageCores"])

    def test_unexpanded_build_setting_is_not_a_build_identity(self):
        rows = session()
        rows[-1]["environment"]["buildFingerprint"] = "$(WALL_ENDURANCE_BUILD)"
        self.assertIn("build_identity_unavailable", endurance.summarize_run(rows)["battery"]["ineligibleReasons"])

    def test_post_round_recovery_does_not_erase_late_play_memory(self):
        rows = session()
        for t in range(1805, 2101, 5):
            row = copy.deepcopy(rows[-1])
            row.update(uptime=t, wallTime=1792700000+t, cameraResting=True, memoryMiB=60)
            row["gameplay"]["phase"] = "results"
            rows.append(row)
        report = endurance.summarize_run(rows)
        self.assertIsNotNone(report["playingEarlyToLateMemoryDeltaMiB"])
        self.assertEqual(report["postPlayRestingMemoryMiB"]["median"], 60)

    def test_rotated_files_deduplicate_and_keep_restarts_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            rows = session()
            next_run = copy.deepcopy(rows[0])
            next_run.update(run="run-b", uptime=9000, wallTime=1792800000)
            Path(directory, "power-0.jsonl").write_text("\n".join(map(json.dumps, rows[150:] + [next_run])))
            Path(directory, "power-1.jsonl").write_text("\n".join(map(json.dumps, rows[:160])))
            report = endurance.make_report(directory, "all")
            self.assertEqual([r["samples"] for r in report["runs"]], [361, 1])
            self.assertEqual(endurance.make_report(directory)["runs"][0]["run"], "run-b")

    def test_truncated_or_nonfinite_input_cannot_produce_clean_comparison(self):
        for bad in ('{"run":', '{"run":"bad","uptime":1,"wallTime":2,"memoryMiB":NaN}'):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as directory:
                Path(directory, "power-0.jsonl").write_text("\n".join(map(json.dumps, session())) + "\n" + bad)
                report = endurance.make_report(directory)
                self.assertEqual(len(report["inputIssues"]), 1)
                self.assertIn("malformed_input", report["runs"][0]["battery"]["ineligibleReasons"])


if __name__ == "__main__":
    unittest.main()
