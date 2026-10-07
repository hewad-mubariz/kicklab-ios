#!/usr/bin/env python3
"""Remove known generated intermediates. Default: dry run; --apply deletes them.

Retains review pages and linked media, tracks, reports, model/source files,
the latest Fire evidence and its two active Xcode build directories.
"""
import argparse
import html
import json
import os
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / 'artifacts'
MEDIA = {'.png', '.jpg', '.jpeg', '.mp4', '.mov', '.mkv', '.lzfse'}
OLD_BUILDS = ['metal-device', 'player-effects', 'design-check', 'stadium-device', 'player-effects-device']
OLD_MATTING_RUNS = ['park', 'park-no-temporal', 'park-stable', 'park-refined', 'park-premult',
                    'park-selected', 'indoor', 'indoor-stable', 'indoor-selected']


def files_under(folder):
    if not folder.is_dir() or folder.is_symlink():
        return
    for directory, dirs, files in os.walk(folder, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink():
                yield path


def referenced_files():
    protected = set()
    for folder in [ROOT / 'docs', ROOT / 'design', ARTIFACTS]:
        for path in files_under(folder):
            if path.suffix.lower() not in {'.md', '.html'}:
                continue
            contents = path.read_text(errors='replace')
            links = re.findall(r'''(?:src|href)=["']([^"']+)["']''', contents)
            links += [a or b for a, b in re.findall(r'\]\((?:<([^>]+)>|([^\)]+))\)', contents)]
            for link in links:
                url = urlsplit(html.unescape(link))
                if url.scheme not in {'', 'file'} or not url.path:
                    continue
                target = (path.parent / unquote(url.path)).resolve()
                if target.is_relative_to(ROOT) and target.exists():
                    protected.add(target)
    # Preserve explicit source-frame inputs used by reproduction scripts too.
    for path in files_under(ROOT / 'scripts'):
        if path.suffix not in {'.py', '.sh', '.swift'}:
            continue
        for match in re.findall(r'artifacts/[\w./-]+\.(?:png|jpg|jpeg|mp4|mov|mkv|lzfse)', path.read_text(errors='replace')):
            protected.add((ROOT / match).resolve())
    return protected


def plan():
    protected = referenced_files()
    candidates = {}

    def add(path, reason, protect_links=True):
        path = path.absolute()
        if not path.is_file() or path.is_symlink() or path.resolve() != path:
            return
        if not (path.is_relative_to(ARTIFACTS) or path.is_relative_to(ROOT / 'build')
                or path.is_relative_to(ROOT / 'scripts/__pycache__')):
            raise RuntimeError(f'Outside cleanup scope: {path}')
        if protect_links and any(p in protected for p in [path, *path.parents]):
            return
        stat = path.stat()
        candidates[path] = (reason, stat.st_size, stat.st_mtime_ns)

    for path in files_under(ARTIFACTS):
        relative = path.relative_to(ARTIFACTS)
        if any(part.endswith('.xcresult') for part in relative.parts):
            if relative.parts[:2] != ('fire-procedural', 'StrengthTests.xcresult'):
                add(path, 'Older test result bundles')
        elif '__pycache__' in relative.parts:
            add(path, 'Python bytecode caches')
        elif ('stages' in relative.parts or 'prepared' in relative.parts) and path.suffix.lower() in MEDIA:
            add(path, 'Intermediate frames and repeated preparation media')
        elif relative.parts[:2] == ('fire-procedural', 'rejected-texture-materials'):
            add(path, 'Rejected flame image materials', protect_links=False)
        elif relative.parts[0] == 'fire-procedural' and len(relative.parts) == 2 and re.fullmatch(r'fire-(?:v\d+|stronger)\.png', path.name):
            add(path, 'Superseded Fire iteration stills')
        elif relative.parts[0] == 'fire-implementation' and len(relative.parts) == 2 and path.suffix == '.png':
            add(path, 'Superseded Fire iteration stills')
        elif relative.parts[0] != 'fire-procedural' and path.suffix in {'.metallib', '.air'}:
            add(path, 'Rebuildable shader binaries')
        elif relative.parts[0] != 'fire-procedural' and not path.suffix and os.access(path, os.X_OK):
            with path.open('rb') as stream:
                magic = stream.read(4)
            if magic in {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}:
                add(path, 'Rebuildable native tools')

    for name in OLD_MATTING_RUNS:
        for path in files_under(ARTIFACTS / 'matting-strategy-study' / name):
            if path.suffix.lower() in MEDIA:
                add(path, 'Superseded matting preparation runs')
    # ExportSource.swift recreates this lossless crop from the retained input11.
    if Path('/Users/hewadmubariz/Downloads/input/input-positive/input11.mp4').is_file():
        add(ARTIFACTS / 'input11-matanyone2/person-source.mkv', 'Rebuildable lossless source crop')
    for name in OLD_BUILDS:
        for path in files_under(ROOT / 'build' / name):
            add(path, 'Obsolete Xcode derived data', protect_links=False)
    for path in files_under(ROOT / 'scripts/__pycache__'):
        add(path, 'Python bytecode caches')
    return candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Delete the listed generated intermediates.')
    args = parser.parse_args()
    candidates = plan()
    groups = defaultdict(lambda: {'files': 0, 'bytes': 0})
    for reason, size, _ in candidates.values():
        groups[reason]['files'] += 1
        groups[reason]['bytes'] += size
    total = sum(item['bytes'] for item in groups.values())
    print('DELETE' if args.apply else 'DRY RUN — no files changed')
    for reason, item in sorted(groups.items()):
        print(f"{item['bytes'] / 1024**3:6.2f} GiB  {item['files']:6} files  {reason}")
    print(f'Total: {len(candidates):,} files, {total / 1024**3:.2f} GiB')
    if not args.apply:
        return
    removed_bytes = 0
    removed_files = 0
    skipped = []
    for path, (_, size, modified) in candidates.items():
        stat = path.stat()
        if stat.st_size != size or stat.st_mtime_ns != modified:
            skipped.append(str(path.relative_to(ROOT)))
            continue
        path.unlink()
        removed_bytes += size
        removed_files += 1
    for folder in [ARTIFACTS, ROOT / 'scripts/__pycache__', *[ROOT / 'build' / name for name in OLD_BUILDS]]:
        if not folder.exists():
            continue
        for directory, _, _ in os.walk(folder, topdown=False, followlinks=False):
            path = Path(directory)
            if path == ARTIFACTS or path.is_symlink():
                continue
            try:
                path.rmdir()
            except OSError:
                pass  # Retained reports, source, linked media or models remain.
    report = {'time_utc': datetime.now(timezone.utc).isoformat(), 'removed_files': removed_files,
              'removed_bytes': removed_bytes, 'categories': dict(groups), 'changed_files_skipped': skipped,
              'retained': ['current Fire review and baseline', 'linked review media', 'detector tracks and reports',
                           'source and model files', 'approved designs', 'current Fire builds', 'phone CLI build']}
    (ARTIFACTS / 'cleanup-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Removed {removed_bytes / 1024**3:.2f} GiB; report: artifacts/cleanup-report.json')


if __name__ == '__main__':
    main()
