"""Extract existing licensed goalkeeper articulation for embedded Learn use.

Run from any directory. The source stays in KeeperAssets.bundle; no network or
external package is required. Preserve Mixamo-usage.txt with the generated data.
"""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / 'kicklab/Debug/VirtualPenalties/KeeperAssets.bundle/motion-library.json'
destination = root / 'kicklab/Learning/CoachAssets.bundle/CatchMotion.json'
library = json.loads(source.read_text())
names = [name.rsplit('/', 1)[-1] for name in library['names']]
indices = [i for i, name in enumerate(names)
           if any(part in name for part in ('_UpperArm', '_Forearm', '_Hand', '_Finger'))]
result = {'names': [names[i] for i in indices], 'clips': {}}
for name in ('ready', 'low'):
    clip = library['clips'][name]
    # Only rotations are needed. Keep the original sampling and finger curves.
    result['clips'][name] = {
        'fps': clip['fps'],
        'frames': [[frame[i][3:7] for i in indices] for frame in clip['frames']]
    }
destination.write_text(json.dumps(result, separators=(',', ':')) + '\n')
print(f'Extracted {len(indices)} arm/hand joints to {destination}')
