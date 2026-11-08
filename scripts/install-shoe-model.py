#!/usr/bin/env python3
"""Install the exact Pose Landmarker Full asset used by the approved local study."""
from pathlib import Path
import hashlib, urllib.request
MODEL_SHA256 = '4eaa5eb7a98365221087693fcc286334cf0858e2eb6e15b506aa4a7ecdcec4ad'
URL = 'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task'
target = Path(__file__).resolve().parents[1] / 'kicklab/Models/pose_landmarker_full.task'
if not target.exists():
    data = urllib.request.urlopen(URL).read()
    assert hashlib.sha256(data).hexdigest() == MODEL_SHA256, 'Unexpected model version'
    target.write_bytes(data)
assert hashlib.sha256(target.read_bytes()).hexdigest() == MODEL_SHA256, 'Model checksum mismatch'
print('Pose Landmarker Full checksum verified')
