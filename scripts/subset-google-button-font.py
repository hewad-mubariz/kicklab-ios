#!/usr/bin/env python3
"""Keep Google Sans's Latin coverage and all variable axes for the sign-in button.

Requires fonttools==4.68.0. Input must be the original full Google Sans TTF, e.g.
the font in the archived 1.2.0 (77) app. Output remains a native TTF with the same
font names, outlines, hints and variation axes; no app font-loading code changes.
"""
import argparse
import hashlib
import json
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
RANGES = [(0x20, 0x24F), (0x300, 0x36F), (0x1E00, 0x1EFF),
          (0x2000, 0x206F), (0x20AC, 0x20AC), (0x2122, 0x2122)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.output.resolve():
        parser.error("Use a separate output so the original source remains available.")
    localizations = json.loads((ROOT / "kicklab/Localizable.xcstrings").read_text())["strings"]["Continue with Google"]["localizations"]
    labels = {locale: value["stringUnit"]["value"] for locale, value in localizations.items()}
    characters = {ord(c) for text in labels.values() for c in text}
    requested = {cp for low, high in RANGES for cp in range(low, high + 1)} | characters
    font = TTFont(args.source, recalcTimestamp=False)
    original_cmap = font.getBestCmap()
    if characters - original_cmap.keys():
        raise ValueError("Source font does not cover all localized button labels")
    options = subset.Options()
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.name_legacy = True
    options.layout_features = ["*"]
    options.glyph_names = True
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=requested)
    subsetter.subset(font)
    if characters - font.getBestCmap().keys():
        raise ValueError("Subset lost a localized button character")
    font.save(args.output)
    reopened = TTFont(args.output)
    if reopened.getBestCmap() != {cp: glyph for cp, glyph in original_cmap.items() if cp in requested}:
        raise ValueError("Subset character mapping changed")
    print(json.dumps({
        "source_bytes": args.source.stat().st_size,
        "output_bytes": args.output.stat().st_size,
        "source_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
        "output_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "retained_characters": len(reopened.getBestCmap()),
        "retained_glyphs": len(reopened.getGlyphOrder()),
        "labels": labels,
        "axes": [(axis.axisTag, axis.minValue, axis.defaultValue, axis.maxValue) for axis in reopened["fvar"].axes]
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
