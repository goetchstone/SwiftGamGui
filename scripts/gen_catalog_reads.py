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
    from gamgui.core.catalog.catalog import _curated, _is_sensitive, _make_reads_buildable  # noqa: PLC0415
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
    source = {"gamgui_commit": commit, "gam_version": catalog["version"], "generator": "scripts/gen_catalog_reads.py"}
    out = {"source": source, "reads": reads}
    (ROOT / "Tests" / "Fixtures" / "catalog_reads.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n",
                                                                    encoding="utf-8")
    print(f"{len(reads)} reads, {sum(r['sensitive'] for r in reads)} sensitive, from GamGUI {commit} over GAM {catalog['version']}")
    curated = [_curated_entry(command) for command in _curated()]
    (ROOT / "Tests" / "Fixtures" / "catalog_curated.json").write_text(
        json.dumps({"source": source, "commands": curated}, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(curated)} curated commands")


# A value for each kind of slot, as the Builder's form posts it once `_assemble` has stripped it. The text has a line break,
# markup characters and an ampersand, so the auto-reply's HTML (`autoreply_html`) is held too.
_SAMPLE = {"target_user": "{key}@example.com", "user": "{key}@example.com", "group": "{key}@example.com",
           "email": "{key}@example.com", "text": "{key} one\nA < B & C"}


def _curated_entry(command) -> dict:
    """GamGUI's curated command (`catalog._curated`) as the Swift port must declare it, and the argv its `build` makes: with every
    slot filled as `routes/builder.py::_assemble` hands it (stripped, once per choice of each choice slot), and with only the
    required text and address slots filled, an optional one and every choice left empty. `_assemble` itself would refuse an empty
    choice (every choice slot is required); that case holds the build's own defaults (`or "keep"`), which the Swift form applies
    to an empty choice as its picker does. `_assemble`'s stripping and required check aren't run here: the Swift tests hold them."""
    def filled(choice_key: str = "", choice: str = "") -> dict:
        values = {}
        for slot in command.slots:
            if slot.kind.value == "choice":
                values[slot.key] = choice if slot.key == choice_key else (slot.default or slot.choices[0])
            else:
                values[slot.key] = _SAMPLE[slot.kind.value].format(key=slot.key)
        return values

    cases = [filled()]
    for slot in command.slots:
        if slot.kind.value == "choice":
            cases += [filled(slot.key, choice) for choice in slot.choices]
    cases.append({slot.key: (filled()[slot.key] if slot.required and slot.kind.value != "choice" else "") for slot in command.slots})
    unique = []
    for values in cases:
        if values not in unique:
            unique.append(values)
    return {
        "id": command.id, "category": command.category, "subcategory": command.subcategory, "name": command.name,
        "risk": int(command.risk), "raw": command.raw_syntax, "description": command.description,
        "slots": [{"key": s.key, "label": s.label, "kind": s.kind.value, "required": s.required, "choices": s.choices or [],
                   "default": s.default, "placeholder": s.placeholder, "hints": s.hints, "hintNote": s.hint_note}
                  for s in command.slots],
        "cases": [{"values": values, "argv": list(command.build(values))} for values in unique],
    }


if __name__ == "__main__":
    main()
