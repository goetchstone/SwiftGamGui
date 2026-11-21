"""Generate Tests/Fixtures/catalog_glosses.json from GamGUI's gloss() (invariant 11, plan F5a).

GamGUI describes each catalog command the catalog doesn't (which is every one: its grammar parser writes no descriptions) with a
one-line gloss made from the grammar line (`gamgui/core/catalog/describe.py`). The Swift port (`GamEngine/CommandGloss.swift`)
must say the same, byte for byte. This runs GamGUI's own `gloss()` over this repo's vendored catalog
(`Vendor/gam7/command_catalog.json`), the same input the app loads, and records each command's gloss, and every noun of
GamGUI's tables as its `_humanize` reads it (the Swift table is those, merged).

The catalog here is GamGUI's first-line parse; GamGUI's own catalog joins the grammar's continuation lines (GamGUI #132), which
changes one gloss (`gam <CrOSTypeEntity> info`). The glosses are recorded over this repo's catalog, as the app reads it.

Run with GamGUI's interpreter, against a clone checked out at the GamGUI commit wanted (never the shared `../gamgui` checkout,
whose branch another session may be moving):

    ../gamgui/.venv/bin/python -I -B scripts/gen_catalog_glosses.py --gamgui <clone>
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
    from gamgui.core.catalog import describe  # noqa: PLC0415
    from gamgui.core.catalog.models import CatalogCommand  # noqa: PLC0415
    from gamgui.core.catalog.nouns import NOUNS  # noqa: PLC0415

    catalog = json.loads((ROOT / "Vendor" / "gam7" / "command_catalog.json").read_text(encoding="utf-8"))
    commands = [CatalogCommand.from_json(entry) for entry in catalog["commands"]]
    # GamGUI glosses only a command the catalog doesn't describe (`load_catalog`); the port glosses every one.
    described = [command.id for command in commands if command.description]
    if described:
        sys.exit(f"the catalog describes {len(described)} commands ({described[0]}, ...): port GamGUI's vendored-description rule first")
    glosses = [{"id": command.id, "gloss": describe.gloss(command)} for command in commands]
    keys = sorted(set(describe._OVERRIDE) | set(NOUNS) | set(describe._NOUN))  # noqa: SLF001
    nouns = {key: describe._humanize(key) for key in keys}  # noqa: SLF001
    commit = subprocess.run(["git", "-C", str(gamgui), "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                            check=True).stdout.strip()
    source = {"gamgui_commit": commit, "gam_version": catalog["version"], "generator": "scripts/gen_catalog_glosses.py"}
    out = {"source": source, "nouns": nouns, "glosses": glosses}
    (ROOT / "Tests" / "Fixtures" / "catalog_glosses.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n",
                                                                      encoding="utf-8")
    print(f"{len(glosses)} glosses, {len(nouns)} nouns, from GamGUI {commit} over GAM {catalog['version']}")


if __name__ == "__main__":
    main()
