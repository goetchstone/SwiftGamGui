"""Generate Tests/Fixtures/catalog_reads.json from frozen GamGUI's generic read builder (invariant 11).

GamGUI makes every confidently read-only catalog command runnable with one generic builder
(`gamgui/core/catalog/readbuilder.py`, gated by `catalog._make_reads_buildable`). The Swift port's builder
(`GamEngine/CommandCatalog.swift`) must give every command the same slots and the same argv. This runs
GamGUI's own code over this repo's vendored catalog (`Vendor/gam7/command_catalog.json`), the same input
the app loads, and records for each command it promotes: its slots, the argv with every slot filled, the
argv with only the required ones, and whether GamGUI calls it sensitive.

Run with GamGUI's interpreter, against a clone checked out at the GamGUI commit wanted (never the shared
`../gamgui` checkout, whose branch another session may be moving):

    ../gamgui/.venv/bin/python -I -B scripts/gen_catalog_reads.py --gamgui <clone>
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--gamgui", required=True, type=Path, help="a GamGUI clone at the commit to hold the port to")
    args = parser.parse_args()
    gamgui = args.gamgui.resolve()
    sys.path.insert(0, str(gamgui))
    from gamgui.core.catalog.catalog import _is_sensitive, _make_reads_buildable  # noqa: PLC0415
    from gamgui.core.catalog.models import CatalogCommand  # noqa: PLC0415

    catalog = json.loads((ROOT / "Vendor" / "gam7" / "command_catalog.json").read_text(encoding="utf-8"))
    commands = [CatalogCommand.from_json(entry) for entry in catalog["commands"]]
    _make_reads_buildable(commands)
    reads = []
    for command in commands:
        if not command.buildable:
            continue
        every = {slot.key: f"<{slot.key}>" for slot in command.slots}
        required = {slot.key: f"<{slot.key}>" for slot in command.slots if slot.required}
        reads.append({
            "id": command.id,
            "slots": [{"key": s.key, "label": s.label, "kind": s.kind.value, "required": s.required, "placeholder": s.placeholder}
                      for s in command.slots],
            "argv": command.build(every),
            "argvRequired": command.build(required),
            "sensitive": _is_sensitive(command),
        })
    commit = subprocess.run(["git", "-C", str(gamgui), "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                            check=True).stdout.strip()
    out = {"source": {"gamgui_commit": commit, "gam_version": catalog["version"], "generator": "scripts/gen_catalog_reads.py"},
           "reads": reads}
    (ROOT / "Tests" / "Fixtures" / "catalog_reads.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n",
                                                                    encoding="utf-8")
    print(f"{len(reads)} reads, {sum(r['sensitive'] for r in reads)} sensitive, from GamGUI {commit} over GAM {catalog['version']}")


if __name__ == "__main__":
    main()
