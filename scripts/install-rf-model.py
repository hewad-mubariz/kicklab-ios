#!/usr/bin/env python3
"""Install the manifest-pinned RF package; preserve any previous local payload."""
import argparse
import hashlib
import json
import shutil
import time
from pathlib import Path


def verify(folder, manifest):
    for entry in manifest["files"]:
        path = folder / entry["path"]
        if not path.is_file() or path.stat().st_size != entry["bytes"]:
            raise ValueError(f"Missing or wrong-sized model file: {path}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"Model checksum mismatch: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", help="Shared RF .mlpackage; defaults to the local manifest path")
    parser.add_argument("--check", action="store_true", help="Verify the app's installed model without changing files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "config/RFDETRSmall-model.json").read_text())
    source = Path(args.source or manifest["source_package"]).resolve()
    target = root / "kicklab/Models" / (manifest["resource"] + ".mlpackage")
    if args.check:
        verify(target, manifest)
        print("Pinned shared RF model verified.")
        return
    verify(source, manifest)
    try:
        verify(target, manifest)
        print("Pinned shared RF model is already installed.")
        return
    except ValueError:
        pass
    if target.exists():
        backup = root / "resource-backups" / f"rf-model-{time.time_ns()}.mlpackage"
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(target), backup)
        print(f"Previous model preserved at {backup}")
    shutil.copytree(source, target)
    verify(target, manifest)
    print(f"Installed and verified {target}")


if __name__ == "__main__":
    main()
