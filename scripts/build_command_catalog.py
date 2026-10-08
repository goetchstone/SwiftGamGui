#!/usr/bin/env python3
"""Generate Vendor/gam7/command_catalog.json from the vendored GamCommands.txt.

Run on each GAM bump (after scripts/fetch_gam.sh). Until the Swift catalog parser lands (phase 4),
this borrows GamGUI's frozen grammar parser, read-only, so both apps browse the same catalog:

    ../gamgui/.venv/bin/python -I -B scripts/build_command_catalog.py [--gamgui ../gamgui]

The catalog is stamped with the version in Vendor/gam7/VERSION (the pin this repo vendors), not with
GamGUI's frozen EXPECTED_GAM_VERSION.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / "Vendor" / "gam7" / "GamCommands.txt"
OUT = ROOT / "Vendor" / "gam7" / "command_catalog.json"
VERSION = ROOT / "Vendor" / "gam7" / "VERSION"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gamgui", default=str(ROOT.parent / "gamgui"), help="path to the GamGUI checkout")
    args = ap.parse_args()
    sys.path.insert(0, str(Path(args.gamgui).resolve()))
    from gamgui.core.catalog.parser import parse_grammar

    if not REF.exists():
        print(f"error: {REF} not found — run scripts/fetch_gam.sh first", file=sys.stderr)
        return 1
    version = VERSION.read_text().strip().lstrip("v")
    commands = parse_grammar(REF.read_text(errors="replace"))
    data = {"version": version, "commands": [c.to_json() for c in commands]}
    OUT.write_text(json.dumps(data, separators=(",", ":")))
    cats = sorted({c.category for c in commands})
    print(f"wrote {len(commands)} commands in {len(cats)} categories -> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
