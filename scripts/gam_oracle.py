#!/usr/bin/env python3
"""What the vendored GAM build itself does, for scripts/gen_fixtures.py: its exit-code table, the CSV it writes,
and its own handling of a signature argument. Standard library only, run under the build's own Python: GAM is a
PyInstaller build, and its marshalled bytecode loads only in the Python that wrote it (7.48.26 is 3.15's, newer
than GamGUI's virtualenv, where gen_fixtures runs and GamGUI's code imports). GamGUI's scripts/gam_rc_table.py
met the same wall for its exit codes.

    python3.X -I -B scripts/gam_oracle.py Vendor/gam7/gam < request.json > answer.json

The request asks for what it names (each key optional):

    {"csv": [rows, ...], "signature": {"bodies": [...], "words": [...]}}

and the answer always carries the build's identity and exit codes:

    {"python": "3.15", "sha256": "...", "rc": {"NAME_RC": int, ...}, "csv": [text, ...],
     "signature": {"file_arguments": [...], "stored": [...], "keyword": [...]}}

`csv` is each set of rows as the build's Python writes it in GAM_DIALECT; `keyword` answers, in order, GAM's own
file arguments and then `words`. It refuses (exit 1, the reason on stderr) another Python than the build's, and a
build that may not write GAM_DIALECT's CSV: setDialect's constants and csv_output_no_escape_char's default, read
from the build. The build is checksum-pinned and runs as the app's own subprocess: trusted, not input.
`build_python` and GAM_DIALECT are also gen_fixtures's, which loads this file for them.
"""

from __future__ import annotations

import builtins
import csv
import dis
import hashlib
import importlib.util
import inspect
import io
import json
import marshal
import struct
import sys
import types
import zlib
from pathlib import Path

# How GAM writes every CSV: setDialect with csv_output_no_escape_char off, its default, lines ending in "\n" on
# stdout (read at 7.48.22: gam/__init__.py:8830-8853, gamlib/glcfg.py:373). `dialect_in_build` refuses a build
# where this moved.
GAM_DIALECT = {"delimiter": ",", "doublequote": True, "escapechar": "\\", "lineterminator": "\n", "quotechar": '"',
               "quoting": csv.QUOTE_MINIMAL, "skipinitialspace": False, "strict": False}

# PyInstaller's CArchive, appended to the executable (PyInstaller/archive/readers.py): a trailing cookie (magic,
# archive length, TOC offset, TOC length, Python version, libpython name), and TOC entries (entry length, data
# offset, data length, uncompressed length, compressed flag, typecode, then the name).
_COOKIE_MAGIC = b"MEI\014\013\012\013\016"
_COOKIE = struct.Struct("!8sIIII64s")
_TOC_ENTRY = struct.Struct("!IIIIBc")


class Refused(Exception):
    """The build can't answer for GAM here: the reason, in words."""


def _cookie(blob: bytes):
    at = blob.rfind(_COOKIE_MAGIC)
    if at < 0:
        raise Refused("no PyInstaller archive cookie in the vendored gam")
    return at, _COOKIE.unpack_from(blob, at)


def build_python(blob: bytes) -> str:
    """The Python the build was frozen with, as "3.15" (the cookie stores 315). Runs under any Python."""
    pyvers = _cookie(blob)[1][4]
    return f"{pyvers // 100}.{pyvers % 100}"


def module_code(blob: bytes, name: str):
    """The code object of the module `name` ("gam", "gamlib.glcfg"), from the PYZ inside the CArchive."""
    at, (_, length, toc_offset, toc_length, _, _) = _cookie(blob)
    start = at + _COOKIE.size - length
    pos, end, pyz = start + toc_offset, start + toc_offset + toc_length, None
    while pos < end and pyz is None:
        size, offset, *_, typecode = _TOC_ENTRY.unpack_from(blob, pos)
        pyz = start + offset if typecode == b"z" else None
        pos += size
    # The PYZ (pyimod01_archive.py): magic, the bytecode's Python magic number, TOC offset, then entries of
    # zlib-compressed marshalled code, and the TOC as a marshalled [(name, (typecode, offset, length))].
    if pyz is None or blob[pyz:pyz + 4] != b"PYZ\0":
        raise Refused("no PYZ archive in the vendored gam's CArchive")
    if blob[pyz + 4:pyz + 8] != importlib.util.MAGIC_NUMBER:
        raise Refused(f"the build's bytecode is Python {build_python(blob)}'s; run this under that Python, "
                      f"not {sys.version_info[0]}.{sys.version_info[1]}")
    (pyz_toc,) = struct.unpack_from("!i", blob, pyz + 8)
    _, offset, size = dict(marshal.loads(blob[pyz + pyz_toc:]))[name]  # noqa: S302
    return marshal.loads(zlib.decompress(blob[pyz + offset:pyz + offset + size]))  # noqa: S302


def _nested(parent):
    for const in parent.co_consts:
        if inspect.iscode(const):
            yield const
            yield from _nested(const)


def _loads(code) -> list:
    """What a function loads, in order, each as (kind, value): a constant (however this Python's compiler stores
    it), a local, a closure cell, a global or an attribute."""
    out = []
    for ins in dis.get_instructions(code):
        name = ins.opname
        if name in ("LOAD_CONST", "LOAD_SMALL_INT", "LOAD_COMMON_CONSTANT"):
            out.append(("const", ins.argval))
        elif name.startswith("LOAD_FAST"):
            out += [("fast", value) for value in (ins.argval if isinstance(ins.argval, tuple) else (ins.argval,))]
        elif name in ("LOAD_DEREF", "LOAD_GLOBAL", "LOAD_NAME", "LOAD_ATTR"):
            out.append(({"LOAD_DEREF": "deref", "LOAD_ATTR": "attr"}.get(name, "global"), ins.argval))
    return out


def dialect_in_build(blob: bytes, code) -> None:
    """Refuse a build that may not write its CSV as GAM_DIALECT says: setDialect's constants (quotes doubled, a
    backslash escape unless noEscapeChar, then QUOTE_MINIMAL) and csv_output_no_escape_char's default (FALSE). A
    bump that trips this: read the source of the new tag, update GAM_DIALECT, the Swift reader and the mock's
    gam_cell, then regenerate."""
    dialect = [c for c in _nested(code) if c.co_name == "setDialect"]
    # The dictionary it builds, as the values it loads in order: by what each load reads, not how this Python's
    # compiler stores a constant (3.15 loads True, False and None with LOAD_COMMON_CONSTANT, not from co_consts).
    expected = [("const", "delimiter"), ("deref", "self"), ("attr", "columnDelimiter"),
                ("const", "doublequote"), ("const", True),
                ("const", "escapechar"), ("fast", "noEscapeChar"), ("const", "\\"), ("const", None),
                ("const", "lineterminator"), ("fast", "lineterminator"),
                ("const", "quotechar"), ("deref", "self"), ("attr", "quoteChar"),
                ("const", "quoting"), ("global", "csv"), ("attr", "QUOTE_MINIMAL"),
                ("const", "skipinitialspace"), ("const", False), ("const", "strict"), ("const", False)]
    if len(dialect) != 1 or _loads(dialect[0])[:len(expected)] != expected:
        raise Refused("GAM's setDialect changed: read it at the new tag before regenerating")
    found = [i for i in dis.get_instructions(module_code(blob, "gamlib.glcfg")) if i.opname != "EXTENDED_ARG"]
    after = [(b.opname, b.argval) for a, b in zip(found, found[1:])
             if a.opname == "LOAD_NAME" and a.argval == "CSV_OUTPUT_NO_ESCAPE_CHAR"]
    if after != [("LOAD_NAME", "FALSE"), ("LOAD_NAME", "VAR_TYPE")]:   # Defaults = {...: FALSE}, then VAR_INFO
        raise Refused("GAM's csv_output_no_escape_char default changed: read gamlib/glcfg.py at the new tag")


def rc_table(code) -> dict:
    """NAME_RC -> int for every module-level `NAME_RC = <int>` in the `gam` package."""
    table, prev = {}, None
    for ins in dis.get_instructions(code):
        if ins.opname == "EXTENDED_ARG":   # pairing through it reads its argument, not the constant's
            continue
        if ins.opname == "STORE_NAME" and str(ins.argval).endswith("_RC") and isinstance(getattr(prev, "argval", None), int):
            table[ins.argval] = prev.argval
        prev = ins
    if table.get("UNKNOWN_ERROR_RC") != 1 or len(set(table.values())) <= 10:
        raise Refused("the build's RC table did not parse")
    return dict(sorted(table.items()))


def gam_csv(rows) -> str:
    """Rows as GAM prints them, by this (the build's) Python's csv module."""
    out = io.StringIO()
    csv.writer(out, **GAM_DIALECT).writerows(rows)
    return out.getvalue()


def function(code, name: str, **names):
    """One of GAM's own functions, by name. `names` are the globals it reads; a call that needs any other fails
    with NameError, so the oracle can't quietly take a path the fixture doesn't model."""
    found = [c for c in _nested(code) if c.co_name == name]
    if len(found) != 1:
        raise Refused(f"GAM's {name} wasn't found once in the build: read it at the new tag")
    return types.FunctionType(found[0], {"__builtins__": builtins} | names)


def constant(code, name: str):
    """A module-level frozenset GAM builds as `NAME = {…}` (BUILD_SET, its frozenset, SET_UPDATE)."""
    found = [i for i in dis.get_instructions(code) if i.opname != "EXTENDED_ARG"]
    values = [found[n - 2].argval for n, i in enumerate(found)
              if i.opname == "STORE_NAME" and i.argval == name and found[n - 1].opname == "SET_UPDATE"]
    if len(values) != 1 or not isinstance(values[0], frozenset):
        raise Refused(f"GAM's {name} isn't a set literal in the build: read it at the new tag")
    return values[0]


def signature(code, bodies: list, words: list) -> dict:
    """GAM's own handling of a signature argument: _processSignature's stored form of each body, and whether
    checkArgumentPresent reads a body as one of SORF_FILE_ARGUMENTS (a file or document keyword) instead."""
    process = function(code, "_processSignature")
    keywords = constant(code, "SORF_FILE_ARGUMENTS")

    class Command:
        """checkArgumentPresent's view of the command line: one argument left, the body."""
        def __init__(self, body):
            self.body, self.taken = body, False

        def ArgumentsRemaining(self):   # noqa: N802 (GAM's names)
            return True

        def Current(self):   # noqa: N802
            return self.body

        def Advance(self):   # noqa: N802
            self.taken = True

    def read_as_keyword(body):
        command = Command(body)
        present = function(code, "checkArgumentPresent", Cmd=command)
        # At run time the name holds a set (BUILD_SET, then SET_UPDATE from the frozenset constant), and
        # checkArgumentPresent treats anything but a list or a set as one choice. getStringOrFile passes no
        # `required`: False.
        return present(set(keywords), False) and command.taken

    if not all(read_as_keyword(w) for w in keywords) or read_as_keyword("Best, Al"):
        raise Refused("the keyword oracle doesn't read GAM's own keywords as keywords: check checkArgumentPresent")
    own = sorted(keywords)
    return {"file_arguments": own, "stored": [process({"tags": {}}, b, True) for b in bodies],
            "keyword": [read_as_keyword(w) for w in own + list(words)]}


def answer(gam: Path, request: dict) -> dict:
    blob = gam.read_bytes()
    code = module_code(blob, "gam")
    dialect_in_build(blob, code)
    out = {"python": build_python(blob), "sha256": hashlib.sha256(blob).hexdigest(), "rc": rc_table(code)}
    if "csv" in request:
        out["csv"] = [gam_csv(rows) for rows in request["csv"]]
    if "signature" in request:
        out["signature"] = signature(code, request["signature"]["bodies"], request["signature"]["words"])
    return out


def main(argv: list | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: gam_oracle.py <vendored gam> < request.json", file=sys.stderr)
        return 2
    try:
        print(json.dumps(answer(Path(args[0]), json.load(sys.stdin))))
    except (OSError, ValueError, Refused) as e:
        print(f"gam_oracle: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
