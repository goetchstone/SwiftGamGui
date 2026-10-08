#!/usr/bin/env python3
"""Generate the parity fixtures SwiftGamGui's tests hold the Swift code to.

GamGUI (the Python app) is frozen and its argv builders are live-proven, so they are the reference:

  Tests/Fixtures/argv.json        every GAMCommands builder, called over GamGUI's own test inputs
                                  (the grammar contract's enumeration, the mock tests' concrete calls)
                                  plus deterministic edge cases from its property-test specs. Each case
                                  records the full keyword arguments and either the argv or the error.
  Tests/Fixtures/exit_codes.json  the vendored GAM build's *_RC exit-code table, read from the binary
                                  the way GamGUI's tests/test_gam_exit_codes.py does, plus GamGUI's own
                                  constants that branch on it.

Run it with GamGUI's virtualenv Python (it imports GamGUI's package and test modules, read-only;
nothing is written into GamGUI):

    ../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py [--gamgui ../gamgui]

Re-run on every GAM bump (scripts/bump_gam.py does).
"""

from __future__ import annotations

import argparse
import dis
import inspect
import itertools
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Tests" / "Fixtures"

# Deterministic edge values for free-text and identifier parameters (GamGUI's property tests draw
# these classes at random; here they are fixed so the fixture is stable).
EDGES = (
    "Zoë Ångström",
    "日本語のテキスト",
    "-leading-dash",
    "--double-dash",
    "",
    "  padded  ",
    "semi;colon|pipe & $(cmd) `tick`",
    "quote\"and'apos",
    "line\nbreak",
    "{token}",
    "x" * 512,
)


# Values no validator accepts in any spelling: empties, an unknown word, a Cyrillic look-alike.
BOUNDARY = ("", " ", "\xa0", "admin", "own\u0435r", "null")
# Every character Python's str.isspace() is true for (what GamGUI's validators strip): derived, not typed.
PY_WHITESPACE = "".join(c for c in map(chr, range(0x110000)) if c.isspace())


def variants(value: str) -> list:
    """Spellings of an accepted value an operator, a paste or a voice transcript could produce."""
    out = [value.upper(), value.title(), f"  {value}\t\n", f"{PY_WHITESPACE}{value}{PY_WHITESPACE}",
           f"{value}\u200b", f"{value}x", value.replace("e", "e\u0301")]
    if "k" in value:
        out.append(value.replace("k", "\u212a"))  # KELVIN SIGN: lowercases to "k" in Python and Swift
    return out


def jsonable(value):
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    return value


def call(fn, name: str, kwargs: dict) -> dict:
    case = {"builder": name, "kwargs": {k: jsonable(v) for k, v in kwargs.items()}}
    try:
        case["argv"] = list(fn(**kwargs))
    except Exception as exc:  # the Swift builder must refuse the same inputs
        case["error"] = f"{type(exc).__name__}: {exc}"
    return case


def full_kwargs(fn, args: tuple, kwargs: dict) -> dict:
    bound = inspect.signature(fn).bind(*args, **kwargs)
    bound.apply_defaults()
    return dict(bound.arguments)


def strategy_values(strategy) -> list:
    inner = getattr(strategy, "wrapped_strategy", strategy)
    kind = type(inner).__name__
    if kind == "BooleansStrategy":
        return [True, False]
    if hasattr(inner, "value"):
        return [inner.value]
    if hasattr(inner, "elements"):
        return [list(inner.elements)[0]]
    raise SystemExit(f"unhandled hypothesis strategy in a Spec: {kind}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gamgui", default=str(ROOT.parent / "gamgui"), help="path to the GamGUI checkout")
    ap.add_argument("--gam-binary", default=str(ROOT / "Vendor" / "gam7" / "gam"))
    args = ap.parse_args()
    gamgui = Path(args.gamgui).resolve()
    sys.path.insert(0, str(gamgui))

    from gamgui.core.gam import commands as commands_mod
    from gamgui.core.gam.commands import EXPECTED_GAM_VERSION, GAMCommands

    builders = sorted(n for n, v in vars(GAMCommands).items() if isinstance(v, staticmethod))
    originals = {n: getattr(GAMCommands, n) for n in builders}
    cases: list = []

    # 1. The concrete calls GamGUI's mock tests make, recorded as they are evaluated at import time.
    recorded: list = []

    def recorder(name, fn):
        def wrapped(*a, **kw):
            recorded.append((name, full_kwargs(fn, a, kw)))
            return fn(*a, **kw)
        return staticmethod(wrapped)

    for n in builders:
        setattr(GAMCommands, n, recorder(n, originals[n]))
    try:
        import tests.test_mock_gam  # noqa: F401  (WRITES and READS call the builders at import)
    finally:
        for n in builders:
            setattr(GAMCommands, n, staticmethod(originals[n]))
    cases += [call(originals[n], n, kw) for n, kw in recorded]

    # 2. The grammar contract's enumeration (tests/test_command_contract.py::builder_argvs), with the
    #    keyword arguments kept: placeholders, both bools, every accepted enum, optionals given/omitted.
    from tests.test_command_contract import ENUM_ARGS

    for name in builders:
        fn, choices = originals[name], []
        for p in inspect.signature(fn).parameters.values():
            if p.kind is p.VAR_KEYWORD:
                continue
            if (name, p.name) in ENUM_ARGS:
                vals = list(ENUM_ARGS[name, p.name])
            elif "bool" in str(p.annotation):
                vals = [True, False]
            else:
                vals = [[f"<{p.name}>"]] if "Sequence" in str(p.annotation) else [f"<{p.name}>"]
                if p.default is not p.empty and not p.default:
                    vals.append(p.default)
            choices.append([(p.name, v) for v in vals])
        for combo in itertools.product(*choices):
            cases.append(call(fn, name, full_kwargs(fn, (), dict(combo))))

    # 3. Edge cases from the property-test specs: every text parameter set to each edge value.
    from tests.test_props_argv import FREE_TEXT, IDENTIFIERS

    for spec in (*FREE_TEXT, *IDENTIFIERS):
        fn = originals[spec.name]
        other = {k: strategy_values(s) for k, s in (spec.other or {}).items()}
        for edge in EDGES:
            for other_combo in itertools.product(*[[(k, v) for v in vs] for k, vs in other.items()]):
                kw = {p: edge for p in spec.text}
                kw.update({p: edge for p in spec.optional})
                kw.update(dict(other_combo))
                cases.append(call(fn, spec.name, full_kwargs(fn, (), kw)))

    # 4. The validators' boundaries. The enumeration above feeds only accepted values, so these add
    #    case, whitespace (including the Unicode whitespace str.strip() removes), look-alikes, empties
    #    and unknowns: the Swift port must accept, normalize and refuse exactly what GamGUI does.
    for name, param, accepted in (("add_group_member", "role", commands_mod.GROUP_ROLES),
                                  ("add_calendar_acl", "role", commands_mod.CALENDAR_ACL_ROLES),
                                  ("add_calendar_acl_cal", "role", commands_mod.CALENDAR_ACL_ROLES),
                                  ("set_forward", "action", GAMCommands.FORWARD_ACTIONS),
                                  ("create_datatransfer", "privacy", GAMCommands.TRANSFER_PRIVACY),
                                  ("search_messages", "detail", GAMCommands.MESSAGE_DETAIL)):
        fn = originals[name]
        required = {p.name: f"<{p.name}>" for p in inspect.signature(fn).parameters.values() if p.default is p.empty}
        for value in [*BOUNDARY, *(v for a in accepted for v in variants(a))]:
            cases.append(call(fn, name, full_kwargs(fn, (), required | {param: value})))
    cases.append(call(originals["check_svcacct"], "check_svcacct", {"admin": "<admin>", "scopes": []}))

    # 5. Defaults: each builder that has them, called with only its required arguments, so a Swift
    #    default that differs from GamGUI's fails (the cases above always pass every argument).
    defaults = {}
    for name in builders:
        params = inspect.signature(originals[name]).parameters.values()
        if any(p.default is not p.empty for p in params):
            required = {p.name: (["<" + p.name + ">"] if "Sequence" in str(p.annotation) else "<" + p.name + ">")
                        for p in params if p.default is p.empty}
            defaults[name] = {"kwargs": required, "argv": list(originals[name](**required))}

    # Stable order, no duplicates.
    seen, unique = set(), []
    for c in cases:
        key = json.dumps(c, sort_keys=True, ensure_ascii=False)
        if key not in seen:
            seen.add(key)
            unique.append(c)
    unique.sort(key=lambda c: (c["builder"], json.dumps(c["kwargs"], sort_keys=True, ensure_ascii=False)))

    signatures = {}
    for name in builders:
        params = []
        for p in inspect.signature(originals[name]).parameters.values():
            entry = {"name": p.name}
            if p.default is not p.empty:
                entry["default"] = jsonable(p.default)
            params.append(entry)
        signatures[name] = params

    commit = subprocess.run(["git", "-C", str(gamgui), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True, check=True).stdout.strip()
    argv_doc = {
        "source": {"gamgui_commit": commit, "gam_version": EXPECTED_GAM_VERSION,
                   "generator": "scripts/gen_fixtures.py"},
        "builders": builders,
        "signatures": signatures,
        "constants": {k: jsonable(getattr(GAMCommands, k)) for k in ("TRANSFER_PRIVACY", "FORWARD_ACTIONS",
                                                                      "MESSAGE_DETAIL")}
        | {k: jsonable(getattr(commands_mod, k)) for k in ("GROUP_ROLES", "CALENDAR_ACL_ROLES", "USER_LIST_FIELDS",
                                                           "USER_DETAIL_FIELDS", "GROUP_LIST_FIELDS",
                                                           "CROS_LIST_FIELDS", "FILE_LIST_FIELDS", "CACHE_FIELDS")}
        | {"PY_WHITESPACE": [ord(c) for c in PY_WHITESPACE]},
        "cases": unique,
        "defaults": defaults,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "argv.json").write_text(json.dumps(argv_doc, indent=1, ensure_ascii=False) + "\n")
    covered = {c["builder"] for c in unique}
    print(f"argv.json: {len(unique)} cases over {len(covered)}/{len(builders)} builders")

    # Exit codes: the build's *_RC table, read like tests/test_gam_exit_codes.py's build_rc fixture.
    from gamgui.core.setup import CHECK_ANSWER_RCS, OAUTH2SERVICE_JSON_REQUIRED_RC, SCOPES_NOT_AUTHORIZED_RC
    from tests.test_gam_exit_codes import _gam_module_code

    code = _gam_module_code(Path(args.gam_binary).read_bytes())
    table, prev = {}, None
    for ins in dis.get_instructions(code):
        if ins.opname == "EXTENDED_ARG":
            continue
        if ins.opname == "STORE_NAME" and str(ins.argval).endswith("_RC") and isinstance(getattr(prev, "argval", None), int):
            table[ins.argval] = prev.argval
        prev = ins
    if table.get("UNKNOWN_ERROR_RC") != 1 or len(set(table.values())) <= 10:
        raise SystemExit("the build's RC table did not parse")
    rc_doc = {
        "source": {"gam_version": EXPECTED_GAM_VERSION, "gamgui_commit": commit,
                   "generator": "scripts/gen_fixtures.py"},
        "build_rc": dict(sorted(table.items())),
        "gamgui": {"SCOPES_NOT_AUTHORIZED_RC": SCOPES_NOT_AUTHORIZED_RC,
                   "OAUTH2SERVICE_JSON_REQUIRED_RC": OAUTH2SERVICE_JSON_REQUIRED_RC,
                   "CHECK_ANSWER_RCS": list(CHECK_ANSWER_RCS)},
    }
    (OUT / "exit_codes.json").write_text(json.dumps(rc_doc, indent=1) + "\n")
    print(f"exit_codes.json: {len(table)} *_RC constants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
