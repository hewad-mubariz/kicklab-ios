#!/usr/bin/env python3
"""Install or verify Counter V2's pinned, unmodified Google Full pose model."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
import urllib.request

URL = "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task"
SHA256 = "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"


def verify(path):
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != SHA256:
        raise ValueError(f"Missing or unexpected Counter V2 pose model: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    target = Path(__file__).resolve().parents[1] / "kicklab/Models/pose_landmarker_full.task"
    if args.check or target.exists():
        verify(target)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=target.parent) as temporary:
            download = Path(temporary) / target.name
            urllib.request.urlretrieve(URL, download)
            verify(download)
            os.replace(download, target)
    print("Pinned Counter V2 Full pose model verified.")


if __name__ == "__main__":
    main()
