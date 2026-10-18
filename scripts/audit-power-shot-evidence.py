#!/usr/bin/env python3
"""Read-only audit of saved Power Shot bundles. No inference or physical-accuracy claim."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import statistics


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def audit(folder):
    manifest = json.loads((folder / 'manifest.json').read_text())
    hashes = {}
    for key, name in [('video', 'video.mov'), ('frames', 'frames.jsonl'),
                      ('roll_distance', 'roll-distance.jsonl'), ('roll_calibration_image', 'roll-calibration.png')]:
        if key in manifest:
            if manifest[key] != name:
                raise ValueError(f'{folder.name}: unexpected {key} path')
            actual = digest(folder / name)
            if actual != manifest[key + '_sha256']:
                raise ValueError(f'{folder.name}: SHA-256 mismatch for {name}')
            hashes[name] = actual
    frames = rows(folder / 'frames.jsonl')
    samples = rows(folder / 'roll-distance.jsonl') if manifest.get('roll_distance') else []
    times = [f['capture_timestamp_s'] for f in frames]
    if len(frames) != manifest['recorded_frames'] or any(b <= a for a, b in zip(times, times[1:])):
        raise ValueError(f'{folder.name}: inconsistent count or nonmonotonic frame clock')
    intervals = [b - a for a, b in zip(times, times[1:])]
    origin = previous = previous_time = None
    left_start = False
    first_rejected = None
    last_accepted = None
    raw_distances = []
    comparable = mismatches = 0
    stopped = False
    for row in samples:
        if row.get('event') == 'set_start':
            origin = previous = row.get('world_contact_m')
            previous_time = row['capture_timestamp_s']
            left_start = stopped = False
            last_accepted = 0.0
            continue
        point = row.get('world_contact_m')
        if row.get('event') != 'sample' or origin is None or point is None:
            continue
        t = row['capture_timestamp_s']
        distance = math.dist(point, origin)
        raw_distances.append(distance)
        if not stopped:
            dt, step = t - previous_time, math.dist(point, previous)
            recover = (0.8 < dt <= 2 and not left_start and distance <= 0.08
                       and math.dist(previous, origin) <= 0.08 and step <= 0.03)
            # Replay only the historical ground-roll movement/gap policy. Camera
            # and calibration states remain captured observations, not inferred.
            if (dt > 0.8 and not recover) or step > dt * 6 + 0.12:
                stopped = True
                first_rejected = first_rejected or {
                    'source_frame': row.get('source_frame'), 'time_s': row.get('time_s'),
                    'reason': 'observation_gap' if dt > 0.8 and not recover else 'movement_limit',
                    'step_m': step, 'allowed_step_m': dt * 6 + 0.12, 'interval_s': dt,
                    'ball_detected': 'sensor_box_normalized' in row}
            elif dt > 0:
                last_accepted = distance
                previous, previous_time = point, t
                left_start |= distance > 0.08
        if 'last_display_distance_m' in row:
            comparable += 1
            mismatches += abs(row['last_display_distance_m'] - last_accepted) > 1e-4
    reference_file = folder / 'field-reference.json'
    reference = json.loads(reference_file.read_text()) if reference_file.exists() else None
    return {
        'id': folder.name, 'recorded_at': manifest.get('recorded_at'), 'source': str(folder.resolve()),
        'source_hashes': hashes, 'manifest_sha256': digest(folder / 'manifest.json'), 'integrity': 'passed',
        'model': manifest.get('roll_distance_model'), 'frames': len(frames),
        'median_capture_fps': 1 / statistics.median(intervals) if intervals else None,
        'max_frame_gap_s': max(intervals, default=None),
        'limited_frames': manifest.get('limited_tracking_frames'),
        'writer_drops': manifest.get('writer_dropped_frames'),
        'samples': sum(r.get('event') == 'sample' for r in samples),
        'logged_gates': dict(Counter(r['measurement_gate'] for r in samples if 'measurement_gate' in r)),
        'first_movement_or_gap_rejection': first_rejected,
        'historical_gate_replay_comparisons': comparable, 'historical_gate_replay_mismatches': mismatches,
        'saved_last_estimate_m': manifest.get('roll_distance_last_estimate_m'),
        'unvalidated_raw_last_projection_m': raw_distances[-1] if raw_distances else None,
        'unvalidated_raw_peak_projection_m': max(raw_distances, default=None),
        'saved_speed_sample_count': sum('rolling_speed_kmh' in r for r in samples),
        'observer_reference': reference, 'physical_accuracy_established': False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path, help='Recording directory or parent containing recording directories')
    parser.add_argument('--output', type=Path, required=True, help='New report path; existing reports are not overwritten')
    args = parser.parse_args()
    folders = [args.root] if (args.root / 'manifest.json').is_file() else sorted(p.parent for p in args.root.glob('*/manifest.json'))
    if not folders:
        parser.error('No capture manifests found')
    results = [audit(folder) for folder in folders]
    report = {
        'schema': 'kicklab.power-shot-evidence-audit.v1',
        'mode': 'historical_saved_observations_no_new_inference',
        'scope': 'Hash verification, capture timing, and movement/gap gate replay. Gate replay does not recreate camera/calibration invalidations; report mismatches explicitly.',
        'accuracy_note': 'Raw ground projections and old model output are not ground truth. No launch speed or independent physical accuracy established.',
        'recordings': results,
        'totals': {'recordings': len(results), 'frames': sum(r['frames'] for r in results),
                   'samples': sum(r['samples'] for r in results),
                   'movement_or_gap_rejections': sum(r['first_movement_or_gap_rejection'] is not None for r in results),
                   'comparisons': sum(r['historical_gate_replay_comparisons'] for r in results),
                   'mismatches': sum(r['historical_gate_replay_mismatches'] for r in results)},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps(report['totals'], indent=2))


if __name__ == '__main__':
    main()
