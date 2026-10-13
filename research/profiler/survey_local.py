"""Builds a camera-pair set for `redlamp recipe profile` from raw files downloaded by hand.

DPReview and Imaging Resource refuse automated requests, so their sample galleries' RAF files
are saved by hand into build/profiler/manual/ (any subfolders, any names). This reads each
file's settings from its maker notes, as fetch_review_pairs.py does, keeps the files whose
other settings are neutral, drops copies by SHA-256, and writes manual-pairs.json beside it.
The files are copyrighted: references only, never shipped or committed (DEC-17).

    python3 -I research/profiler/survey_local.py
"""

from __future__ import annotations

import collections
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "build" / "profiler" / "manual"
MANIFEST = Path(__file__).resolve().parent / "manual-pairs.json"


def review_survey():
    """fetch_review_pairs.py's maker-note reader, loaded from beside this file."""
    spec = importlib.util.spec_from_file_location("review", Path(__file__).resolve().parent / "fetch_review_pairs.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if not FOLDER.is_dir():
        print(f"Nothing to survey: save RAF files into {FOLDER.relative_to(ROOT)}/ first.")
        return 0
    review = review_survey()
    seen: set[str] = set()
    pairs = []
    skipped = collections.Counter()
    for path in sorted(FOLDER.rglob("*")):
        if path.suffix.lower() != ".raf" or not path.is_file():
            continue
        data = path.read_bytes()
        if data[:15] != b"FUJIFILMCCD-RAW":
            skipped["not a RAF"] += 1
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest in seen:
            skipped["a copy"] += 1
            continue
        seen.add(digest)
        try:
            record = review.settings(data[:524288])
        except Exception as error:
            skipped[f"unreadable ({type(error).__name__})"] += 1
            continue
        slot = review.SLOTS.get(record.get("look", ""))
        if not slot:
            skipped[f"no slot for {record.get('look')}"] += 1
            continue
        if not review.neutral(record):
            skipped["settings not neutral"] += 1
            continue
        model = record.get("model", "unknown")
        pairs.append({
            "slot": slot, "camera": f"Fujifilm {model}", "look": record["look"],
            "file": str(path.relative_to(FOLDER)), "sha256": digest, "iso": record.get("iso"),
            "generation": record.get("generation"), "whiteBalance": record.get("whiteBalance"),
            "source": "downloaded by hand", "license": "Copyright; reference only, never shipped or committed (DEC-17)",
        })
    MANIFEST.write_text(json.dumps({
        "version": 1, "description": __doc__.strip().splitlines()[0],
        "folder": str(FOLDER.relative_to(ROOT)), "pairs": pairs,
    }, indent=1) + "\n")
    counts = collections.Counter(p["slot"] for p in pairs)
    print(f"{len(pairs)} pairs written to {MANIFEST.relative_to(ROOT)}")
    for slot, count in counts.most_common():
        print(f"  {slot}: {count} files from {len({p['camera'] for p in pairs if p['slot'] == slot})} cameras")
    for reason, count in skipped.most_common():
        print(f"  skipped {count}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
