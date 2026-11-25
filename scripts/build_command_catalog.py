#!/usr/bin/env python3
"""Generate Vendor/gam7/command_catalog.json from the vendored GamCommands.txt.

Run on each GAM bump (after scripts/fetch_gam.sh). Until the Swift catalog parser lands (phase 4),
this borrows GamGUI's frozen grammar parser, read-only, so both apps browse the same catalog:

    ../gamgui/.venv/bin/python -I -B scripts/build_command_catalog.py [--gamgui ../gamgui]

The catalog is stamped with the version in Vendor/gam7/VERSION (the pin this repo vendors), not with
GamGUI's frozen EXPECTED_GAM_VERSION.

Each command's syntax is its grammar entry's first line. GamGUI's parser joins the continuation lines since its #132, which
this app hasn't ported (docs/domains/catalog-builder.md): #132 changes only `raw_syntax` (verb, risk and name still come from
the first line), so the line its id names is put back, and any GamGUI makes the same catalog.
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
    text = REF.read_text(errors="replace")
    lines = text.splitlines()
    commands = parse_grammar(text)
    rows = []
    for c in commands:
        row = c.to_json()
        first = lines[int(row["id"].removeprefix("raw."))].strip()
        if not row["raw_syntax"].startswith(first):
            raise SystemExit(f"{row['id']}: GamGUI's syntax doesn't start with its grammar line: {row['raw_syntax'][:80]}")
        row["raw_syntax"] = first
        rows.append(row)
    data = {"version": version, "commands": rows}
    OUT.write_text(json.dumps(data, separators=(",", ":")))
    cats = sorted({c.category for c in commands})
    print(f"wrote {len(commands)} commands in {len(cats)} categories -> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
