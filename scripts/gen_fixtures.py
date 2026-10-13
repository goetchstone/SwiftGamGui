#!/usr/bin/env python3
"""Generate the parity fixtures SwiftGamGui's tests hold the Swift code to.

GamGUI (the Python app) is frozen and its argv builders are live-proven, so they are the reference:

  Tests/Fixtures/argv.json        every GAMCommands builder, called over GamGUI's own test inputs
                                  (the grammar contract's enumeration, the mock tests' concrete calls)
                                  plus deterministic edge cases from its property-test specs. Each case
                                  records the full keyword arguments and either the argv or the error.
  Tests/Fixtures/gam_errors.json  GamGUI's classification, message and scrubbing of failed GAM runs
                                  (core/gam/errors.py) over its own and generated stderr, with the
                                  Unicode tables its regexes use. GAM's progress lines are read as GAM
                                  writes them, which GamGUI's rule isn't (gam_progress); each case it
                                  reads differently keeps its reading too.
  Tests/Fixtures/gam_output.json  GamGUI's parse_records over the mock's output for every read, its
                                  property tests' JSON/CSV shapes and noise, and the inputs its
                                  failure log names. CSV is read in GAM's dialect, which GamGUI's
                                  reader isn't (gam_reader); each case it reads differently keeps its
                                  records too.
  Tests/Fixtures/gam_models.json  GamGUI's user, group and member models over the mock's records and
                                  seeded variants.
  Tests/Fixtures/guard.json       GamGUI's guard (evaluate, enforce, alias_deletes) over seeded change
                                  sets and confirmations.
  Tests/Fixtures/audit.json       GamGUI's audit log: the line each record writes, and what its reader
                                  finds across generations.
  Tests/Fixtures/reports.json     GamGUI's directory reports over the mock's users and seeded variants.
  Tests/Fixtures/audit_screen.json  GamGUI's Audit screen over a log of odd records: the filter and the
                                  page each query shows, the header's counts, and the CSV export's bytes.
  Tests/Fixtures/usage_report.json  GamGUI's storage and mail usage: the progress lines dropped before the
                                  CSV, the rows parsed and ordered, and the dates its walk back asks for.
  Tests/Fixtures/setup.json       GamGUI's guided setup: the delegation step's client ID, Admin-console
                                  link and sign-out-scope note, and the fresh-setup Terminal commands.
  Tests/Fixtures/vacation.json    GamGUI's auto-reply helpers: show vacation parsed, the body to and from
                                  the operator's text (Python's HTMLParser and html.unescape beneath).
  Tests/Fixtures/signatures.json  GamGUI's signature render, curly-quote warning and show-signature reader,
                                  and GAM's own handling of a signature argument (the stored form; the
                                  bodies it reads as a file keyword), run from the vendored build.
  Tests/Fixtures/offboarding.json GamGUI's offboarding routine: each step's command lines and what it
                                  needs, the address checks, and the preview's names and warnings.
  Tests/Fixtures/onboarding.json  GamGUI's onboarding core: the temporary password's alphabet, split_name,
                                  the calls provision_hire makes for a hire (title, order, gates), the
                                  new-account wait's words and test, and its role file's load and migration.
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
import contextlib
import csv
import dis
import functools
import inspect
import io
import itertools
import json
import re
import subprocess
import sys
import types
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

# How GAM 7.48.22 writes every CSV: setDialect (gam/__init__.py:8830-8839) with csv_output_no_escape_char
# off, its default (gamlib/glcfg.py:373), lines ending in "\n" on stdout (:8849-8853). CPython 3.14's writer
# in this dialect doubles each backslash in a value and quotes a value holding a comma, quote, CR or LF.
# gam_dialect_in_build refuses a build where this moved.
GAM_DIALECT = {"delimiter": ",", "doublequote": True, "escapechar": "\\", "lineterminator": "\n", "quotechar": '"',
               "quoting": csv.QUOTE_MINIMAL, "skipinitialspace": False, "strict": False}


def gam_csv(rows) -> str:
    """Rows as GAM prints them."""
    out = io.StringIO()
    csv.writer(out, **GAM_DIALECT).writerows(rows)
    return out.getvalue()


@contextlib.contextmanager
def gam_reader():
    """GamGUI's parse_records reading CSV in GAM's dialect: its parser module's csv swapped, in memory only,
    for one whose DictReader knows GAM's escape character. Frozen GamGUI reads GAM's CSV without it, so a
    JSON cell holding an escaped quote is dropped, a backslash comes back doubled and an escaped newline as
    "\\n" (failure-log 2026-10-10, "GAM's CSV escapes"). The Swift reader reads it as GAM wrote it; the
    fixtures are generated with this, and gam_output.json keeps frozen GamGUI's records beside each case
    where the two differ."""
    from gamgui.core.gam import parser

    frozen = parser.csv
    parser.csv = types.SimpleNamespace(DictReader=functools.partial(csv.DictReader, escapechar="\\"),
                                       field_size_limit=csv.field_size_limit)
    try:
        yield parser.parse_records
    finally:
        parser.csv = frozen


# GAM 7.48.22's progress lines (show_gettings, on by default): every one its printers write starts with
# Msg.GETTING or Msg.GOT and a count (gam/__init__.py:2681-2722, the page counts :2736-2763), and no error it
# writes starts with "Getting " (those start "ERROR:", "WARNING:" or an entity's name).
GAM_PROGRESS = r"(Getting |Got \d+ )"


@contextlib.contextmanager
def gam_progress():
    """GamGUI's GAMError reading GAM's progress lines as GAM writes them: its errors module's _PROGRESS_LINE
    swapped, in memory only, for GAM_PROGRESS. Frozen GamGUI knows only "Getting all " and "Got <n> ", so a
    per-entity line ("Getting Reports for all users", "Getting Group sales@example.com (1/3)") reads as an
    unknown failure that outranks the real one beside it (failure-log 2026-10-13, "GAM's progress read as an
    error"). The Swift GamError reads it as progress; gam_errors.json is generated with this and keeps frozen
    GamGUI's reading beside each case where the two differ."""
    import re

    from gamgui.core.gam import errors

    frozen = errors._PROGRESS_LINE
    errors._PROGRESS_LINE = re.compile(GAM_PROGRESS)
    try:
        yield frozen
    finally:
        errors._PROGRESS_LINE = frozen


def gam_dialect_in_build(blob: bytes, code) -> None:
    """Refuse a GAM build that may not write its CSV as GAM_DIALECT says, read from the build the way its
    exit codes are: setDialect's constants (quotes doubled, a backslash escape unless noEscapeChar, then
    QUOTE_MINIMAL), csv_output_no_escape_char's default (FALSE), and the bundled Python, whose csv module
    writes the bytes (macOS's 3.9 doesn't double a backslash; 3.14 does). This script's own Python writes
    the reference bytes, so it must be the same minor version. A bump that trips this: read the source of
    the new tag, update GAM_DIALECT, the Swift reader and the mock's gam_cell, then regenerate."""
    from tests.test_gam_exit_codes import _COOKIE, _COOKIE_MAGIC, _TOC_ENTRY

    at = blob.rfind(_COOKIE_MAGIC)
    _, length, toc_offset, toc_length, pyvers, _ = _COOKIE.unpack_from(blob, at)
    if pyvers != 314 or sys.version_info[:2] != (3, 14):
        raise SystemExit(f"GAM's Python is {pyvers}, this script's {sys.version_info[:2]}: GAM_DIALECT is 3.14's")

    def nested(parent):
        for const in parent.co_consts:
            if inspect.iscode(const):
                yield const
                yield from nested(const)

    dialect = [c for c in nested(code) if c.co_name == "setDialect"]
    expected = ("delimiter", "doublequote", True, "escapechar", "\\", None, "lineterminator", "quotechar", "quoting",
                "skipinitialspace", False, "strict")
    if len(dialect) != 1 or dialect[0].co_consts != expected or "QUOTE_MINIMAL" not in dialect[0].co_names:
        raise SystemExit("GAM's setDialect changed: read it at the new tag before regenerating")
    # gamlib.glcfg from the PYZ, found as tests/test_gam_exit_codes.py's _gam_module_code finds `gam`.
    import marshal
    import struct
    import zlib

    start = at + _COOKIE.size - length
    pos, end, pyz = start + toc_offset, start + toc_offset + toc_length, None
    while pos < end and pyz is None:
        size, offset, *_, typecode = _TOC_ENTRY.unpack_from(blob, pos)
        pyz = start + offset if typecode == b"z" else None
        pos += size
    (pyz_toc,) = struct.unpack_from("!i", blob, pyz + 8)
    # The vendored binary is checksum-pinned and runs as the app's own subprocess: trusted, not input.
    _, offset, size = dict(marshal.loads(blob[pyz + pyz_toc:]))["gamlib.glcfg"]  # noqa: S302
    glcfg = marshal.loads(zlib.decompress(blob[pyz + offset:pyz + offset + size]))  # noqa: S302
    found = [i for i in dis.get_instructions(glcfg) if i.opname != "EXTENDED_ARG"]
    after = [(b.opname, b.argval) for a, b in zip(found, found[1:])
             if a.opname == "LOAD_NAME" and a.argval == "CSV_OUTPUT_NO_ESCAPE_CHAR"]
    if after != [("LOAD_NAME", "FALSE"), ("LOAD_NAME", "VAR_TYPE")]:   # Defaults = {...: FALSE}, then VAR_INFO
        raise SystemExit("GAM's csv_output_no_escape_char default changed: read gamlib/glcfg.py at the new tag")


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


def ranges(predicate) -> list:
    """The code points `predicate` holds for, as [first, last] ranges."""
    out, start = [], None
    for point in range(0x110001):
        inside = point < 0x110000 and predicate(chr(point))
        if inside and start is None:
            start = point
        elif not inside and start is not None:
            out.append([start, point - 1])
            start = None
    return out


def errors_fixture() -> dict:
    """GamGUI's GAMError.from_run, reading GAM's progress lines as GAM writes them (gam_progress), over GAM's
    known stderr lines and their case, indent and counter variants, mixed stderrs, progress chatter in each
    shape GAM prints it and instructions, timeouts, missing-scope lines, echoed passwords, Unicode and
    boundary edges, and seeded random text: what the Swift GamError must say. A case frozen GamGUI reads
    differently also holds its reading, as `gamgui`: a missed progress line is the only difference."""
    import random
    import re
    import unicodedata

    from gamgui.core.audit import _SENSITIVE_KEYS
    from gamgui.core.gam.errors import _REMEDIATION, _SEVERITY, ACCOUNT_WIDE_KINDS, GAMError
    from tests.test_props_errors import _KNOWN, _gam_usage_error

    def read(err) -> dict:
        return {"kind": err.kind.value, "kinds": sorted(k.value for k in err.kinds), "message": err.message,
                "remediation_suffix": err.remediation[len(_REMEDIATION[err.kind]):]}

    def run(exit_code, stderr, argv=None, stdout=""):
        frozen = read(GAMError.from_run(exit_code, stderr, argv, stdout=stdout))
        with gam_progress() as frozen_rule:
            err = GAMError.from_run(exit_code, stderr, argv, stdout=stdout)
            ours = read(err)
            case = {"exit_code": exit_code, "stderr": stderr, "argv": argv, "stdout": stdout,
                    "kind": ours["kind"], "kinds": ours["kinds"], "message": ours["message"],
                    "scrubbed_stderr": err.stderr, "scrubbed_stdout": err.stdout, "redacted_argv": err.argv,
                    "remediation_suffix": ours["remediation_suffix"]}
        if frozen != {k: case[k] for k in frozen}:
            missed = [line for line in (raw.strip() for raw in stderr.splitlines())
                      if re.match(GAM_PROGRESS, line) and not frozen_rule.match(line)]
            if not missed:   # nothing else was swapped: a missed progress line is the only difference
                raise SystemExit(f"the two progress rules differ without a line GamGUI misses: {stderr[:80]!r}")
            case["gamgui"] = frozen
        return case

    cases = []
    known = [line for line, _ in _KNOWN]
    for line in known:
        for shape in (str, str.upper, str.lower, str.swapcase):
            for indent in ("", "    ", "\t"):
                for count in ("", " (403/1200)", " (0/5)"):
                    cases.append(run(1, indent + shape(line) + count))
    for first in known:
        for second in known:
            cases.append(run(1, first + "\n" + second))
    chatter = ["Getting all Users, may take some time on a large Google Workspace Account...",
               "Got 150 Users: a@example.com - z@example.com", "", "   "]
    instructions = ["Please run", "gam create|use project", "gam user <user> update serviceaccount",
                    "to create and authorize a Service account."]
    for extra in chatter + instructions:
        for line in known[:6] + known[-4:]:
            cases.append(run(50, extra + "\n" + line + "\n" + extra))
        cases.append(run(1, extra))
    cases.append(run(1, ""))
    cases.append(run(1, "\n".join(chatter)))
    # GAM's progress in each shape its printers write (gam/__init__.py:2681-2722), with the per-entity counter
    # where they print one (currentCountNL), alone and before a real failure, as GAM lays them out (an
    # "ERROR:" line after a blank one), and in case and position variants GAM never writes, which are errors.
    # Frozen GamGUI misses every "Getting <item> …" line (gam_progress).
    progress = [
        ("Getting all Users, may take some time on a large Google Workspace Account...", False),
        ("Got 3 Groups", False),
        ("Getting all Users in the Organizational Unit for /Sales, may take some time on a large "
         "Organizational Unit...", True),
        ("Got 12 Users in the Organizational Unit for /Sales", False),
        ("Getting Group sales@example.com", True),
        ("Getting Reports for all users", True),
        ("Getting Access Tokens for alice@example.com", True),
        ("Getting Calendars for carol@example.com", True),
        ("Getting Application Specific Password IDs for dave@example.com", True),
    ]
    failures = [("User: alice@example.com, Gmail Service/App not enabled", 73),
                ("User: bob@example.com, Service not applicable/Does not exist", 50),
                ("ERROR: 404: Resource Not Found: groupKey - notFound", 1),
                ("ERROR: 403: forbidden - insufficientPermissions", 1),
                ("ERROR: 403: Request had insufficient authentication scopes", 1),
                ("ERROR: Customer ID: my_customer, Domain: example.com, User: admin@example.com, Access Forbidden", 61)]
    for line, counted in progress:
        for counter in (("", " (2/4)") if counted else ("",)):
            cases.append(run(1, line + counter + "\n"))
            for lookalike in (str.upper, str.lower, "User: alice@example.com, {}".format):
                cases.append(run(1, lookalike(line + counter) + "\n"))
            for failure, code in failures:
                blank = "\n" if failure.startswith("ERROR:") else ""
                cases.append(run(code, line + counter + "\n" + blank + failure + "\n"))
    # A page count as GAM writes it with show_gettings_got_nl off (:5260-5271, :5620-5623).
    cases.append(run(1, "Getting Reports for all users\n\rGot 3 Reports for all users on 2026-06-16...\r\n"))
    for stderr in ("", known[0], "\n".join(known)):
        cases.append(run(None, stderr, stdout="the table"))
    for code in (0, 2, 10, 16, 50, 73, -9, 255):
        cases.append(run(code, known[3]))

    scopes = ["https://mail.google.com/", "https://www.googleapis.com/auth/gmail.settings.sharing",
              "https://www.googleapis.com/auth/admin.directory.user.security",
              "https://www.googleapis.com/auth/a/b-c_d", "https://www.googleapis.com/auth/",
              "https://www.googleapis.com/auth/x.", "https://www.googleapis.com/auth/caf" + chr(0xE9),
              "https://www.googleapis.com/auth/e" + chr(0x301)]
    base = "ERROR: 403: Request had insufficient authentication scopes"
    for separator in (" ", ", ", ": "):
        for punctuation in ("", ".", ",", ";", ")", "]"):
            for url in scopes:
                cases.append(run(1, base + separator + url + punctuation))
    cases.append(run(1, base + " " + " ".join(scopes)))
    cases.append(run(1, base + " " + scopes[1] + " " + scopes[1] + " " + scopes[0]))
    cases.append(run(1, base + " " + scopes[1] + "\nERROR: invalid_grant: Token has been expired or revoked"))

    argvs = [
        ["gam", "create", "user", "new.hire@example.com", "firstname", "Ada", "lastname", "Lovelace", "password",
         "S3cr3t!x", "changepassword", "on", "notify", "boss@example.com", "notifypassword", "S3cr3t!x"],
        ["gam", "create", "user", "o@example.com", "firstname", "O'Brien", "lastname", "Smith, Jr", "PassWord",
         "a,b'c", "org", "/Staff/New Hires"],
        ["gam", "update", "user", "x@example.com", "NOTIFYPASSWORD", "x" + chr(0x3000) + "y", "password", "z"],
        ["gam", "user", "x@example.com", "signature", "<b>Hi</b>", "html"],
        ["gam", "update", "user", "x@example.com", "recoveryemail", "me@home.example", "recoveryphone", "+1 555",
         "alternateemail", "alt@example.com", "password"],
        ["gam", "password", "password", "secret"],
    ]
    for argv in argvs:
        for form in ("bad", "extraneous", "missing"):
            for at in sorted({1, len(argv) // 2, len(argv) - 1}):
                stderr = _gam_usage_error(argv, at, form)
                cases.append(run(2, stderr, argv, stdout=stderr))

    kelvin, long_s, dotless_i, dotted_i = chr(0x212A), chr(0x17F), chr(0x131), chr(0x130)
    arabic_403 = chr(0x664) + chr(0x660) + chr(0x663)
    edges = [
        "ERROR: invalid_grant: To" + kelvin + "en has been expired or revoked",
        "pa" + long_s + long_s + "word hunter2",
        "not" + dotless_i + "fypassword hunter2",
        "not" + dotted_i + "fypassword hunter2",
        dotted_i + "nvalid_grant",
        "e" + chr(0x301) + "password hunter2",
        "_password hunter2",
        "changepassword on",
        "x-password hunter2",
        "password" + chr(0x1F) + "hunter2",
        "password" + chr(0x2028) + "hunter2",
        "password\n\nhunter2 more",
        "password   ",
        "password",
        "Calendar: a@example.com, Delete Failed: 403" + chr(0x301),
        "Delete Failed: x403x",
        "Delete Failed: " + arabic_403,
        "Delete Failed: Forbidden (" + arabic_403 + "/" + chr(0x661) + "2)",
        "User: a@example.com, Got 5 things",
        "Got 5 Users: a - b",
        "got 5 users: a - b",
        "Got Users",
        "  Getting all Users",
        "ERROR: Rate" + chr(0xE9) + "Limit hit",
        "oauth2service.jsonx does not exist",
        "oauth2.txt" + chr(0xE9) + " not found",
        "oauth2.txt: not found",
        "Client OAUTH2 File: /x, Does Not Exist",
        "no credentials",
        "No API credentials",
        "a\x0bb\x0cc\x1cd\x1de\x1ef\x85g" + chr(0x2028) + "h" + chr(0x2029) + "i\r\nj\rk",
        "ERROR: 404: notFound" + chr(0x1F),
        chr(0x3000) + "ERROR: quota exceeded" + chr(0x3000),
    ]
    # One line per branch of a rule that only that branch matches, so dropping any branch fails a test
    # (PR #5's review found 14 branches every fixture line reached some other way).
    unicode17 = (chr(0x10940), chr(0x11DE0))   # unassigned in Python's Unicode 16, letters/digits in 17
    edges += [
        "Too many requests", "ERROR: access_denied for scope x", "ERROR: Not Authorized to access this resource/api",
        "ERROR: Token has been expired or revoked.", "ERROR: Permission denied", "ERROR: insufficientPermissions",
        "Delete Failed: cannotChangeOwnAcl", "ERROR: notFound", "ERROR: userRateLimitExceeded",
        "ERROR: rateLimitExceeded", "ERROR: rate-limit hit", "ERROR: rate  limit", "ERROR: insufficientscope",
        "oauth2.json does not exist", "oauth2service.txt not found", "oauth2.txt does not exist",
        "oauth2service.json: not found", "oauth2.txt not found oauth2.txt", "Client OAuth2 File: x, does not exist",
        "Delete Failed: 4 (" + chr(0x663) + "/" + chr(0x661) + ")04", "please run", "PLEASE RUN",
        "Gam create|use project", "to create and authorize a service account.", "ERROR: quota exceeded",
        "ERROR: no valid credentials", "please run gam oauth create", "ERROR: uses a service account",
        "User: a@example.com, Calendar Service/App not enabled", "Create Failed: Domain user limit reached",
        "ERROR: name " + unicode17[0] + "password hunter2", "Delete Failed: " + unicode17[0] + "403",
        "x" + unicode17[1] + "429", unicode17[0] + "notifypassword hunter2",
    ]
    for line in edges:
        cases.append(run(1, line, stdout=line))
    for argv in (None, [], ["password"], ["PASSWORD", "x"], ["pa" + long_s + long_s + "word", "x"],
                 ["signature", "signature", "x"], ["x", "notifypassword", "y", "z"]):
        cases.append(run(1, "ERROR: x", argv))

    rng = random.Random(20261008)
    fragments = known + chatter + instructions + [
        "password", "notifypassword", " (403/1200)", "(1/2)", "403", "404", "429", "not found", "invalid_grant",
        "https://www.googleapis.com/auth/", "https://mail.google.com/", "quota", "Service/App not enabled",
        "insufficient", "scope", "Domain user limit reached", "rate limit", "OAuth2 File:", "does not exist",
        "oauth2.txt", "Got 7 ", "Getting all "]
    pool = [chr(c) for c in [*range(0x20, 0x7F), 0x09, 0x0B, 0x0C, 0x1C, 0x1F, 0x85, 0xA0, 0x2028, 0x3000,
                             0x212A, 0x17F, 0x130, 0x131, 0x301, 0xE9, 0x664, 0x660, 0x4E00, 0x1F600]]
    for _ in range(400):
        lines = []
        for _ in range(rng.randint(1, 4)):
            parts = [rng.choice(fragments) if rng.random() < 0.5
                     else "".join(rng.choice(pool) for _ in range(rng.randint(0, 6)))
                     for _ in range(rng.randint(1, 5))]
            lines.append(rng.choice(["", " "]).join(parts))
        stderr = rng.choice(["\n", "\r\n", "\r", "\n\n"]).join(lines)
        cases.append(run(rng.choice([1, 2, 50, None]), stderr, stdout=stderr if rng.random() < 0.3 else ""))

    seen, unique = set(), []
    for case in cases:
        key = json.dumps(case, sort_keys=True)
        if key not in seen:
            seen.add(key)
            unique.append(case)

    folds = [[point, ord(letter)] for letter in "abcdefghijklmnopqrstuvwxyz"
             for point in range(0x80, 0x110000) if re.fullmatch("(?i)" + letter, chr(point))]
    return {
        "constants": {
            "unicode_version": unicodedata.unidata_version,
            "IGNORECASE_FOLDS": folds,
            "WORD": ranges(lambda c: re.match(r"\w", c) is not None),
            "DECIMAL": ranges(lambda c: re.match(r"\d", c) is not None),
            "UNASSIGNED": ranges(lambda c: unicodedata.category(c) in ("Cn", "Cs")),
            "LINE_BREAKS": [p for p in range(0x110000) if len(("a" + chr(p) + "b").splitlines()) == 2],
            "SENSITIVE_KEYS": sorted(_SENSITIVE_KEYS),
            "SEVERITY": [kind.value for kind in _SEVERITY],
            "ACCOUNT_WIDE": sorted(kind.value for kind in ACCOUNT_WIDE_KINDS),
        },
        "cases": unique,
    }


def output_fixture(mock: Path) -> dict:
    """GamGUI's parse_records, reading CSV in GAM's dialect (gam_reader), over GAM's output shapes: what
    the strict mock prints for every read the app makes; the JSON, CSV and formatjson shapes and the noise
    GamGUI's property tests generate (drawn deterministically, the CSV ones printed by GAM's writer); the
    inputs its failure log names (a long cell, a bare CR, deep nesting, raw line separators in NDJSON, an
    empty header) with JSON's and CSV's own edges; and GAM's escaping. The records are stored as Python's
    json.dumps text, NaN and Infinity included. A case frozen GamGUI reads differently also holds its
    records, as `gamgui`: the escape character is the only difference, so each holds a backslash."""
    from hypothesis import HealthCheck, Phase, given, seed, settings
    from hypothesis import strategies as st

    from gamgui.core.gam.parser import parse_records
    from tests import test_props_parsing as props

    cases = []

    def add(stdout: str) -> None:
        frozen = json.dumps(parse_records(stdout), ensure_ascii=True)
        with gam_reader() as read:
            case = {"stdout": stdout, "records": json.dumps(read(stdout), ensure_ascii=True)}
        if frozen != case["records"]:
            if "\\" not in stdout:   # nothing else was swapped: an escape character is the only difference
                raise SystemExit(f"the two readers differ on text without a backslash: {stdout[:80]!r}")
            case["gamgui"] = frozen
        cases.append(case)

    def as_gam_prints(draw) -> str:
        """A drawn CSV as GAM prints it. GamGUI's test writer (props._csv) leaves a backslash single, which
        GAM never does: its rows, read back in the dialect they were written in, are written again in GAM's.
        Read in GAM's dialect they must give the draw's own records, an oracle neither reader made."""
        text, expected = draw
        printed = gam_csv(csv.reader(io.StringIO(text, newline="")))
        with gam_reader() as read:
            if read(printed) != expected:
                raise SystemExit(f"a draw printed as GAM prints it reads back wrong: {printed[:80]!r}")
        return printed

    for stdouts in mock_outputs(mock).values():
        for stdout in stdouts:
            add(stdout)

    # Hypothesis also draws string constants it finds in local source, this script's included, so an
    # unrelated edit here changed the drawn cases. Only the seed decides them.
    from hypothesis.internal.conjecture import providers

    empty = providers.Constants(integers=providers.SortedSet(), floats=providers.SortedSet(key=providers.float_to_int),
                                bytes=providers.SortedSet(), strings=providers.SortedSet())
    providers._get_local_constants = lambda: empty

    def drawn(strategy, count: int) -> list:
        found = []

        # An explicit seed: `derandomize` seeds from the function's digest, which moves with any edit
        # to this file and would churn the fixture.
        @seed(20261008)
        @settings(max_examples=count, database=None, deadline=None,
                  phases=[Phase.generate], suppress_health_check=list(HealthCheck))
        @given(strategy)
        def collect(value):
            found.append(value)

        collect()
        return found

    for text, _ in drawn(props._json_output(), 120):
        add(text)
    for draw in drawn(props._plain_csv(), 120):
        add(as_gam_prints(draw))
    for draw in drawn(props._formatjson_csv(), 120):
        add(as_gam_prints(draw))
    noise = st.one_of(st.text(props._ANY), props._noise()).map(lambda s: s.replace("\r", "\r\n"))
    for text in drawn(noise, 200):
        add(text)

    record = json.dumps({"primaryEmail": "a@example.com", "name": {"fullName": "Zo" + chr(0xEB)}})
    big = "x" * 131_073
    for separator in (chr(0x2028), chr(0x2029), chr(0x85)):
        add(json.dumps({"note": "a" + separator + "b"}, ensure_ascii=False) + "\n" + record)
    edges = [
        props._csv([["primaryEmail", "notes"], ["a@example.com", big]]),
        props._csv([["primaryEmail", "JSON"], ["a@example.com", json.dumps({"notes": big})]]),
        "primaryEmail,notes\na@example.com,x\ry\n",
        "primaryEmail,notes\na@example.com,\"x\ry\"\n",
        "[" * 200_000,
        "[" * 300 + "]" * 300,
        '{"a": ' + "[" * 600 + "]" * 600 + "}",
        "primaryEmail,,orgUnitPath\na@example.com,blank,/\n",
        "primaryEmail,name\na@example.com\nb@example.com,B,extra,more\n",
        "id,id,name\n1,2,x\n",
        chr(0xFEFF) + record,
        chr(0xFEFF) + "primaryEmail\na@example.com\n",
        "NaN",
        "[NaN, Infinity, -Infinity, 1E400, -0, 12345678901234567890123456789]",
        '{"n": NaN, "i": -Infinity, "big": 1e400, "neg0": -0.0}\n{"x": 1}',
        '"' + chr(92) + "ud800" + '"',
        '{"a": "' + chr(92) + "ud83d" + chr(92) + "ude00" + chr(92) + "ud800x" + '"}',
        '{"a": 1, "a": 2, "b": [1, 2,]}',
        '{"a": 1,}',
        '{"a": "tab' + chr(9) + 'raw"}',
        chr(0x0B) + record,
        record + "\n" + chr(0x0B) + record,
        record + "\r\n" + record + "\r\n",
        record + "\n\n   \n" + record,
        record + "\nnot json",
        "primaryEmail,JSON\na@example.com," + '"' + json.dumps({"x": 1}).replace('"', '""') + '"' + "\n",
        "primaryEmail,JSON\na@example.com,\nb@example.com,[1, {\"y\": 2}]\n",
        "primaryEmail,JSON\n,\"{\"\"primaryEmail\"\": \"\"wins@example.com\"\"}\"\n",
        'a,b\n"unterminated,1\n',
        'a,b\n"x"y,2\n',
        'a,b\nx"y,"z""w"\n',
        "a,b\n" + chr(0) + ",1\n",
        "a,b\n\n\n1,2\n",
        "a\n" + '""' + "\n",
        "  " + chr(0x3000) + "primaryEmail\na@example.com" + chr(0x3000) + " ",
        "true",
        "null",
        "null\n" + record,
        record + "\nnull\n" + record,
        "[]",
        "{}",
        "[1, \"x\", null, {\"k\": \"v\"}]",
        "{\"a\": 1} {\"b\": 2}",
        "{\"a\": 1}\n[{\"b\": 2}, 3]\n\"s\"\n",
    ]
    # PR #7's review: one input for each defect it proved, and for each change that slipped past.
    backslash, nfc, nfd = chr(92), chr(0xE9), "e" + chr(0x301)
    edges += [
        '{"a": 1E2, "b": 1e+2, "c": 1E-2, "d": -0.5e-1}',
        '{"a": 1e}', '{"a": 1.}', '{"a": 1e+}', '{"a": +1}', '{"a": 01}', '{"a": -}',
        '{"a": "' + backslash + "/" + backslash + "f" + backslash + "b" + '"}',
        '{"a": "' + backslash + "u00E9" + backslash + "u00e9" + '"}',
        '{"a": "x\ny"}',
        '{"a": "' + backslash + "ud800" + backslash + "ud800" + '"}',
        '{"a":' + chr(12) + '1}',
        "primaryEmail,JSON,JSON\na@example.com," + '"{""x"": 1}","{""y"": 2}"' + "\n",
        "a,a,JSON\n1,," + '"{""z"": 1}"' + "\n",
        '{"' + nfc + '": 1, "' + nfd + '": 2}',
        '{"K": 1, "' + chr(0x212A) + '": 2}',
        nfc + "," + nfd + "\nx,y\n",
        '{"a": ' + "1" * 4300 + '}', '{"a": ' + "1" * 4301 + '}', '{"a": -' + "1" * 4301 + '}',
        '{"a": ' + "1" * 4301 + '.5}', '[{"a": 1}, ' + "9" * 5000 + ']',
        ",".join(["h"] * 2000) + "\n" + "\n".join(["x"] * 200) + "\n",
        "h,h,JSON\n" + "x,y," + '"{}"' + "\n",
    ]
    # GAM's escaping (failure-log 2026-10-10): values holding a quote, a backslash, CR, LF, a tab, non-ASCII,
    # as GAM prints them in a formatjson cell and in plain CSV; then the reader's own edges after a header,
    # inputs GAM's writer never makes (an escape at the end, before CR, LF or CRLF, a comma or a quote, and
    # after a closing quote) that CPython still reads one way.
    values = ['Ann "Q" Lee', "C:" + backslash + "dir", "l1\nl2", "a\rb", "tab\tend", "ends" + backslash,
              backslash + '"', "Zo" + chr(0xEB) + " " + chr(0x1F600), '""', ""]
    edges += [gam_csv([["primaryEmail", "JSON"]] + [[f"u{n}@example.com", json.dumps(
        {"name": {"fullName": value}, "primaryEmail": f"u{n}@example.com"}, ensure_ascii=False, sort_keys=True)]
        for n, value in enumerate(values)])]
    edges += [gam_csv([["primaryEmail", "notes"]] + [[f"u{n}@example.com", value] for n, value in enumerate(values)])]
    escapes = ["a" + backslash, "a" + backslash + "\nb\n", '"a' + backslash, '"a' + backslash + '"b"',
               backslash + '"x,y', "a" + backslash + ",b", '"x"' + backslash + "y", "a" + backslash + "\r\nb",
               "a" + backslash + "\rb", backslash, backslash * 2, '"' + backslash * 2 + '"', "a," + backslash + "\n",
               '"a' + backslash + '\nb"', "x" + backslash + "\r", backslash + "\n", '"' + backslash + '\r\n"',
               '"a""b' + backslash + '"c"', "a" + backslash + "\r\r\nb", "x,y" + backslash + "\n" + "z,w\n"]
    edges += ["a,b\n" + text for text in escapes]
    for text in edges:
        add(text)

    seen, unique = set(), []
    for case in cases:
        key = json.dumps(case, sort_keys=True)
        if key not in seen:
            seen.add(key)
            unique.append(case)
    dialect = GAM_DIALECT | {"quoting": "QUOTE_MINIMAL",
                             "source": "GAM 7.48.22 setDialect (gam/__init__.py:8830-8839), csv_output_no_escape_char "
                                       "off (gamlib/glcfg.py:373), written by CPython 3.14's csv module"}
    return {"dialect": dialect, "cases": unique}


# GamGUI's reads whose GAM shape the mock doesn't model (they printed NDJSON, which GAM never prints for
# them): the mock refuses them, and they have no case here. No SwiftGamGui screen reads them yet.
NOT_MODELLED = {"print_filelist", "print_all_calendars", "print_events", "get_event"}


def _keyed(key: str, name: str):
    """A read whose one key column is a value in each record: (header, data file, row)."""
    return lambda argv: ([key, "JSON"], name, lambda record: [record[key]])


# The `formatjson` reads the mock models, by builder: GAM's header, the data file holding each record as GAM
# prints it in the JSON cell, and the key columns GAM writes before it.
GAM_PRINTED = {
    "print_users": _keyed("primaryEmail", "print_users.json"), "print_groups": _keyed("email", "groups.json"),
    "print_group_members": _keyed("group", "group_members.json"), "print_domains": _keyed("domainName", "domains.json"),
    "print_cros": _keyed("deviceId", "cros.json"),
    # printShowCalendars (:55800-55818): the person, then the calendar's id.
    "print_user_calendars": lambda argv: (["primaryEmail", "calendarId", "JSON"], f"user_calendars/{argv[1]}.json",
                                          lambda record: [argv[1], record["id"]]),
    # _printShowCalendarACLs (:41869-41884): the person, then `primary` read as the person (:55338-55339).
    "print_calendar_acls": lambda argv: (["primaryEmail", "calendarId", "JSON"], f"calendar_acls/{argv[1]}.json",
                                         lambda record: [argv[1], argv[1]]),
    "print_calendar_acls_cal": lambda argv: (["calendarId", "JSON"], f"calendar_acls/{argv[1]}.json",
                                             lambda record: [argv[1]]),
    # doPrintShowResourceCalendars (:41543-41546).
    "print_resources": lambda argv: (["resourceId", "resourceName", "JSON"], "resources.json",
                                     lambda record: [record["resourceId"], record["resourceName"]]),
}


def mock_outputs(mock: Path) -> dict:
    """What the strict mock prints for every read the app makes, by builder. Refuses a mock whose
    formatjson output isn't what GAM prints: a data line not in json.dumps(ensure_ascii=False,
    sort_keys=True) form, or bytes other than Python's csv writer in GAM's dialect writes for its records
    (the mock escapes in POSIX sh; this is the check that it escapes as GAM does)."""
    import subprocess
    import tempfile

    from gamgui.core.gam.runner import strip_cfgdir_noise
    from tests.test_mock_gam import READS

    data = mock.parent / "mock_gam"
    for path in sorted(data.rglob("*.json")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line != json.dumps(json.loads(line), ensure_ascii=False, sort_keys=True):
                raise SystemExit(f"{path.name}: a record not in the form GAM prints it: {line[:80]}")
    outputs = {}
    with tempfile.TemporaryDirectory() as config:
        for name in ("oauth2service.json", "oauth2.txt"):
            Path(config, name).write_text('{"placeholder": true}')
        environment = {"PATH": "/usr/bin:/bin", "GAMCFGDIR": config, "GAM_MOCK_FIXTURES": str(data)}
        for builder, argvs in READS.items():
            for argv in argvs:
                run = subprocess.run([str(mock), *argv], capture_output=True, text=True, env=environment)
                if builder in NOT_MODELLED:
                    if run.returncode != 2 or "isn't modelled" not in run.stderr:
                        raise SystemExit(f"the mock answered a read it doesn't model: {argv}")
                    continue
                if run.returncode != 0:
                    raise SystemExit(f"the mock refused a read: {argv}")
                # As GamGUI's runner hands it on: without the first-run banner naming the config dir.
                stdout = strip_cfgdir_noise(run.stdout, Path(config))
                if builder in GAM_PRINTED:   # its bytes after the banner, the last line ending kept
                    printed = "\n".join(line for line in run.stdout.split("\n") if config not in line)
                    header, name, keys = GAM_PRINTED[builder](argv)
                    records = [line for line in (data / name).read_text(encoding="utf-8").splitlines()
                               if builder != "print_group_members" or json.loads(line)["group"] == argv[3].lower()]
                    if printed != gam_csv([header] + [keys(json.loads(line)) + [line] for line in records]):
                        raise SystemExit(f"the mock's bytes aren't GAM's for {argv}")
                outputs.setdefault(builder, []).append(stdout)
    return outputs


def models_fixture(mock: Path) -> dict:
    """GamGUI's GAMUser, GAMGroup and GroupMember.from_json over the mock's records and seeded variants
    of them: the alternate keys GAM uses across commands, flags as booleans, words or numbers, counts
    as numbers or text, primary entries in Directory lists. String fields hold strings (or nothing):
    that is how GAM sends them. And its calendar models (CalendarACL with who, role_label and
    scope_token; UserCalendar; ResourceCalendar) over the mock's calendar reads and seeded variants."""
    import dataclasses
    import random

    from gamgui.core.gam.models import GAMGroup, GAMUser, GroupMember

    outputs = mock_outputs(mock)
    with gam_reader() as read:
        records = {name: [r for out in found for r in read(out)] for name, found in outputs.items()}
    rng = random.Random(20261008)
    flags = [True, False, "TRUE", "false", " yes ", "1", "0", "on", "off", "", None, 0, 1, 2]
    texts = ["", None, "Zo" + chr(0xEB) + " " + chr(0xC5) + "ngstr" + chr(0xF6) + "m", "a@example.com", " padded "]

    def maybe(record: dict, key: str, values: list) -> None:
        if rng.random() < 0.7:
            record[key] = rng.choice(values)

    def entries(fields: list) -> list:
        items = []
        for _ in range(rng.randint(0, 3)):
            if rng.random() < 0.15:
                items.append(rng.choice(["not a dict", None, 7]))
                continue
            item = {key: rng.choice(texts[2:] + ["", "HQ", "Sales"]) for key in fields if rng.random() < 0.7}
            if rng.random() < 0.4:
                item["primary"] = rng.choice([True, False, 1, 0, "", "yes"])
            items.append(item)
        return items

    users = records["print_users"] + records["info_user"]
    for _ in range(250):
        record = {}
        maybe(record, rng.choice(["primaryEmail", "email", "User"]), texts)
        if rng.random() < 0.6:
            record["name"] = rng.choice([{"givenName": rng.choice(texts), "familyName": rng.choice(texts)},
                                         {}, "not a dict", None, {"givenName": "Ada"}])
        maybe(record, rng.choice(["givenName", "First Name"]), texts)
        maybe(record, rng.choice(["familyName", "Last Name"]), texts)
        for key in ("suspended", "Suspended", "isAdmin", "Is Admin", "isDelegatedAdmin", "isEnrolledIn2Sv"):
            maybe(record, key, flags)
        maybe(record, rng.choice(["orgUnitPath", "OrgUnitPath"]), ["/", "/Staff/New Hires", "", None])
        maybe(record, "organizations", [entries(["title", "department"]), [], None, "x"])
        maybe(record, "locations", [entries(["buildingName", "buildingId"]), []])
        maybe(record, "phones", [entries(["value"]), []])
        maybe(record, rng.choice(["Organization Title", "Organization Department"]), texts)
        maybe(record, "recoveryEmail", texts)
        maybe(record, rng.choice(["lastLoginTime", "Last Login Time"]), ["2026-06-18T08:00:00Z", "", None, "Never"])
        maybe(record, rng.choice(["aliases", "Aliases"]),
              [["a@example.com", "b@example.com"], [], "a@example.com, b@example.com",
               " a@example.com\tb@example.com ,," + chr(0x3000) + "c@example.com", "", None])
        users.append(record)

    groups = records["print_groups"]
    members = records["print_group_members"]
    counts = [12, 0, "12", " 7 ", "1_000", "3.7", 3.7, True, "x", "", None, chr(0x661) + chr(0x662), "-4", "+5"]
    for _ in range(120):
        group = {}
        maybe(group, rng.choice(["email", "Email", "Group"]), texts)
        maybe(group, rng.choice(["name", "Name"]), texts)
        maybe(group, rng.choice(["description", "Description"]), texts)
        maybe(group, rng.choice(["directMembersCount", "Members"]), counts)
        groups.append(group)
        member = {}
        maybe(member, rng.choice(["email", "Email"]), texts)
        maybe(member, rng.choice(["role", "Role"]), ["owner", "MANAGER", "member", "", None, "stra" + chr(0xDF) + "e"])
        maybe(member, rng.choice(["type", "Type"]), ["user", "GROUP", "customer", "", None])
        maybe(member, rng.choice(["status", "Status"]), ["ACTIVE", "suspended", "", None])
        members.append(member)

    # PR #7's review: numbers where GamGUI prints Python's str() of them, NaN's truthiness, falsy values
    # that fall through to the next key, int()'s edges, and roles Unicode 17 uppercases differently.
    raw_users = [
        '{"primaryEmail": "n1@example.com", "organizations": [{"title": 1.50, "department": 1E2, "primary": true}],'
        ' "phones": [{"value": -0}], "locations": [{"buildingName": NaN}]}',
        '{"primaryEmail": "n2@example.com", "suspended": NaN, "isAdmin": 0.0, "isEnrolledIn2Sv": -0.0,'
        ' "aliases": [null, true, 1.0, 12345678901234567890]}',
        '{"primaryEmail": "n3@example.com", "organizations": [{"title": 1e16, "department": 1e15, "primary": 1}],'
        ' "phones": [{"value": 0.0001}], "locations": [{"buildingId": 1e-05}]}',
        '{"primaryEmail": "n4@example.com", "organizations": [{"title": 123456789012345678, "department": -1.5e-7}],'
        ' "recoveryEmail": 0}',
        '{"primaryEmail": "n5@example.com", "name": {"givenName": 0, "familyName": false},'
        ' "givenName": "Flat", "Last Name": "Name", "orgUnitPath": 5, "lastLoginTime": 1.5}',
    ]
    raw_groups = ['{"email": "g@example.com", "directMembersCount": ' + count + '}' for count in
                  ['"' + chr(92) + 'u001c5"', '"5' + chr(92) + 'u001f"', "-3.7", "1e2", '"1__0"', '"_1"', '"1_"',
                   '"  ' + chr(92) + 'u0663 "', "NaN", "-0.0", "true", '"' + chr(92) + 'u30005' + chr(92) + 'u3000"']]
    raw_members = ['{"email": "m@example.com", "role": ' + json.dumps(role) + ', "type": "user"}' for role in
                   ["owner" + chr(0xA7D3), "member" + chr(0x16EBB), "stra" + chr(0xDF) + "e", chr(0x1F1) + "x"]]
    users += [json.loads(text) for text in raw_users]
    groups += [json.loads(text) for text in raw_groups]
    members += [json.loads(text) for text in raw_members]

    # Calendars. Text where GAM sends text, or a scalar (Python's str() of it); never a list or object where
    # text belongs (GamGUI would print its repr, the port reads it as empty).
    from gamgui.core.gam.models import CalendarACL, ResourceCalendar, UserCalendar

    acls = records["print_calendar_acls"] + records["print_calendar_acls_cal"]
    scalars = ["", None, 0, 1.5, True, False, " padded ", "Zo" + chr(0xEB), chr(0x3000) + "x" + chr(0x3000)]
    scope_types = ["user", "USER", " group ", "domain", "Domain", "default", "custom"] + scalars
    scope_values = ["bob@example.com", "sales@example.com", "example.com", " bob@example.com "] + scalars
    rule_ids = ["user:bob@example.com", "group:g@example.com", "domain:example.com", "domain:", "domain", "default",
                "nocolon@example.com", "a:b:c", " user:x@example.com ", ":lead", "GROUP:G@example.com"] + scalars
    roles = ["owner", "WRITER", " reader ", "freeBusyReader", "freebusy", "editor", "writerWithoutPrivateAccess",
             "none", "strange", "own" + chr(0x0435) + "r", chr(0x130), chr(0x1F1)] + scalars
    for _ in range(160):
        rule = {}
        shape = rng.random()
        if shape < 0.6:
            scope = {}
            maybe(scope, "type", scope_types)
            maybe(scope, "value", scope_values)
            rule["scope"] = scope
        elif shape < 0.75:
            rule["scope"] = rng.choice(["user", None, 7, ["user", "x"]])
        maybe(rule, rng.choice(["id", "Id"]), rule_ids)
        maybe(rule, rng.choice(["role", "Role"]), roles)
        acls.append(rule)
    calendars = records["print_user_calendars"]
    for _ in range(150):
        entry = {}
        maybe(entry, rng.choice(["id", "calendarId"]), ["c_x@group.calendar.google.com", "a@example.com"] + scalars)
        maybe(entry, rng.choice(["summary", "Summary"]), ["Team", 'Rota "B" C:' + chr(92) + "x"] + scalars)
        maybe(entry, rng.choice(["accessRole", "accessrole"]), ["owner", "freeBusyReader", "reader"] + scalars)
        maybe(entry, "primary", flags + [[1], [], {}])
        calendars.append(entry)
    rooms = records["print_resources"]
    for _ in range(150):
        room = {}
        maybe(room, rng.choice(["resourceId", "id", "ResourceID"]), ["1001", 1002] + scalars)
        maybe(room, rng.choice(["resourceName", "name", "Name"]), ["Aspen", "Birch Huddle, 2nd floor"] + scalars)
        maybe(room, rng.choice(["resourceEmail", "email", "Email"]), ["aspen@resource.calendar.google.com"] + scalars)
        maybe(room, rng.choice(["resourceType", "type"]), ["Conference Room", 'Huddle "Pod"'] + scalars)
        maybe(room, "buildingId", ["id:hq", "hq"] + scalars)
        rooms.append(room)

    def calendar_fields(model) -> dict:
        found = dataclasses.asdict(model)
        found.pop("raw")
        if isinstance(model, CalendarACL):
            found |= {"who": model.who, "role_label": model.role_label, "scope_token": model.scope_token}
        return found

    text_fields = {"primary_email", "given_name", "family_name", "org_unit_path", "title", "department", "location",
                   "phone", "recovery_email", "last_login_time", "email", "name", "description", "role",
                   "member_type", "status"}

    def fields(model) -> dict:
        found = dataclasses.asdict(model)
        found.pop("raw")
        # GamGUI keeps a value that isn't text as it came (an OU of 5) and its pages print str() of it.
        for key in text_fields & found.keys():
            if found[key] is not None and not isinstance(found[key], str):
                found[key] = str(found[key])
        if isinstance(model, GAMUser):
            found["full_name"] = model.full_name
        return found

    # Records go in as JSON text, read back through the Swift JSON reader: a number keeps the form it
    # was written in (1.50, 1E2), which is what str() of it depends on.
    texts = {id(r): t for r, t in zip(users[-len(raw_users):], raw_users)} | \
        {id(r): t for r, t in zip(groups[-len(raw_groups):], raw_groups)} | \
        {id(r): t for r, t in zip(members[-len(raw_members):], raw_members)}

    def entry(record, model) -> dict:
        return {"record": texts.get(id(record)) or json.dumps(record), "model": fields(model)}

    return {
        "constants": {"PY_UPPER": [[p, [ord(c) for c in chr(p).upper()]] for p in range(0x110000)
                                   if chr(p).upper() != chr(p)]},
        "users": [entry(r, GAMUser.from_json(r)) for r in users],
        "groups": [entry(r, GAMGroup.from_json(r)) for r in groups],
        "members": [entry(r, GroupMember.from_json(r)) for r in members],
        "calendar_acls": [{"record": json.dumps(r), "model": calendar_fields(CalendarACL.from_json(r))} for r in acls],
        "user_calendars": [{"record": json.dumps(r), "model": calendar_fields(UserCalendar.from_json(r))} for r in calendars],
        "resources": [{"record": json.dumps(r), "model": calendar_fields(ResourceCalendar.from_json(r))} for r in rooms],
    }


def guard_fixture() -> dict:
    """GamGUI's guard.evaluate and enforce over seeded change sets and confirmations: counts either side
    of the bulk threshold (10), the typed-count opt-in (25) and the hard cap (200); every risk; account
    deletes in GAM's exact argv shape and near it; confirmations typed with case, spaces, look-alikes.
    And alias_deletes over resolved addresses."""
    import random

    from gamgui.core import guard
    from gamgui.core.connectors.base import ChangePreview, ConnectorID, RiskLevel
    from gamgui.core.gam.commands import GAMCommands

    rng = random.Random(20261008)
    words = ["confirm", " Confirm ", "CONFIRM", chr(0x3000) + "confirm" + chr(0x3000), "confirmed", "", "conf",
             "CONF" + chr(0x130) + "RM", "conf" + chr(0x131) + "rm", "confirm" + chr(0x1F)]
    cases = []
    for _ in range(700):
        n = rng.choice([0, 1, 2, 9, 10, 11, 24, 25, 26, 199, 200, 201])
        previews, spec = [], []
        # A third of the sets share one risk: mixed risks of ten or more nearly always include a
        # destructive one, which hid the rule for a bulk change that is all LOW.
        uniform = rng.choice(list(RiskLevel)) if rng.random() < 0.35 else None
        for i in range(n):
            risk = uniform if uniform is not None else rng.choice(list(RiskLevel))
            target = rng.choice([f"u{i}@example.com", f"U{i}@Example.com ", f" u{i}@example.com"])
            shape = rng.random()
            if shape < 0.15:
                argv = GAMCommands.delete_user(target)
            elif shape < 0.2:
                argv = ["delete", "user", target, "extra"]
            elif shape < 0.25:
                argv = ["Delete", "user", target]
            elif shape < 0.3:
                argv = None
            else:
                argv = GAMCommands.set_suspended(target, True)
            previews.append(ChangePreview(connector_id=ConnectorID.GOOGLE_WORKSPACE, target=target, summary="x",
                                          risk=risk, argv=argv))
            spec.append({"target": target, "risk": int(risk), "argv": argv})
        deletes = [a for a in map(guard.deleted_account, previews) if a]
        form = {}
        if rng.random() < 0.7:
            form["confirmed"] = rng.choice(["1", "0", "", "yes", " 1", "1"])
        if rng.random() < 0.5:
            form["confirm"] = rng.choice(words)
        if rng.random() < 0.5:
            form["confirm_count"] = rng.choice([str(n), f" {n} ", f"0{n}", str(n + 1), "", chr(0x3000) + str(n)])
        if deletes and rng.random() < 0.8:
            typed = [rng.choice([a, a.upper(), " " + a.strip() + " ", a + "x"]) for a in deletes if rng.random() < 0.9]
            form["confirm_email"] = typed
        confirm_step = rng.random() < 0.3
        above = rng.choice([None, guard.COUNT_CONFIRM_ABOVE])
        decision = guard.evaluate(previews, typed_count_above=above)
        cases.append({
            "changes": spec, "form": form, "confirm_step": confirm_step, "typed_count_above": above,
            "decision": {"max_risk": int(decision.max_risk), "affected": decision.affected,
                         "requires_confirmation": decision.requires_confirmation,
                         "requires_typed_confirmation": decision.requires_typed_confirmation,
                         "over_hard_cap": decision.over_hard_cap, "summary": decision.summary,
                         "warnings": decision.warnings, "requires_typed_count": decision.requires_typed_count,
                         "typed_emails": decision.typed_emails},
            "refusal": guard.enforce(previews, form, confirm_step=confirm_step, typed_count_above=above),
        })
    aliases = []
    for _ in range(80):
        resolved = {}
        for i in range(rng.randint(0, 3)):
            address = rng.choice([f"a{i}@example.com", f" A{i}@Example.com", f"a{i}@example.com "])
            resolved[address] = rng.choice([None, "", address, address.upper(), f"primary{i}@example.com",
                                             " " + address.strip() + " "])
        aliases.append({"resolved": [[k, v] for k, v in resolved.items()], "problems": guard.alias_deletes(resolved)})
    return {"constants": {"DEFAULT_BULK_THRESHOLD": guard.DEFAULT_BULK_THRESHOLD, "DEFAULT_HARD_CAP": guard.DEFAULT_HARD_CAP,
                          "COUNT_CONFIRM_ABOVE": guard.COUNT_CONFIRM_ABOVE, "TYPED_WORD": guard.TYPED_WORD},
            "cases": cases, "aliases": aliases}
def audit_fixture() -> dict:
    """GamGUI's AuditLog.record, at fixed times, writing real files: the exact line each call writes
    (redaction by keyword and by value included). And its iter_records over generations holding
    blank and malformed lines: the records, newest first."""
    import tempfile
    from datetime import datetime, timezone
    from unittest import mock

    from gamgui.core import audit

    calls = [
        dict(action="create_user", target="new@example.com",
             argv=["create", "user", "new@example.com", "lastname", "Password", "password", "S3cret-pw",
                   "notify", "boss@example.com", "notifypassword", "S3cret-pw"],
             ok=True, exit_code=0, secrets=["S3cret-pw"]),
        dict(action="set_signature", target="a@example.com", argv=["user", "a@example.com", "signature", "<b>Hi</b>", "html"],
             ok=False, exit_code=50, actor="admin@example.com",
             extra={"error": "line\nbreak \"quoted\" back\\slash", "n": 3, "f": 1.5, "big": 1e16, "none": None,
                    "flags": [True, False], "nested": {"k": ["v", 2]}}),
        dict(action="suspend", target="Zo" + chr(0xEB) + "@example.com", argv=None, ok=None,
             extra={"controls": "".join(chr(c) for c in range(0, 32)) + chr(0x7F) + chr(0x2028) + chr(0x85)}),
        dict(action="delete_user", target="abcd@example.com", argv=["delete", "user", "abcd@example.com"],
             ok=True, exit_code=0, secrets=["abc", "abcd", "bc", "", "cd@"]),
        dict(action="x", connector="mdm", target=None, argv=[], extra={}, secrets=["x"]),
        dict(action="recovery", argv=["update", "user", "a@example.com", "RecoveryEmail", "me@home.example",
                                      "recoveryphone", "+1 555", "PASSWORD"], exit_code=-9, ok=False),
    ]
    times = [datetime(2026, 10, 8, 12, 0, 0, 0, tzinfo=timezone.utc),
             datetime(2026, 10, 8, 12, 0, 0, 123456, tzinfo=timezone.utc),
             datetime(1999, 12, 31, 23, 59, 59, 1, tzinfo=timezone.utc),
             datetime(2028, 2, 29, 0, 0, 0, 500000, tzinfo=timezone.utc),
             datetime(2026, 10, 8, 12, 0, 0, 999999, tzinfo=timezone.utc),
             datetime(2000, 1, 1, tzinfo=timezone.utc)]
    written = []
    with tempfile.TemporaryDirectory() as folder:
        log = audit.AuditLog(Path(folder) / "audit.jsonl")
        for call, at in zip(calls, times, strict=True):
            with mock.patch.object(audit, "datetime", mock.Mock(now=lambda tz=None, at=at: at)):
                log.record(**call)
            written.append({"call": {**call, "ts": at.isoformat()},
                            # "\n" only: a record keeps U+2028 raw, and splitlines() would break it there.
                            "line": (Path(folder) / "audit.jsonl").read_text().split("\n")[-2]})
        files = {
            "audit.jsonl": '{"action": "newest", "ts": "3"}\n\n   \nnot json\n["a list"]\n{"action": "second", "ts": "2"}\n',
            "audit.jsonl.1": '{"action": "third"}\n{"action": "fourth"}',
            "audit.jsonl.2": '{"action": "fifth", "note": "' + "x" * 70000 + '"}\n{"broken": \n{"action": "sixth"}\n',
            "audit.jsonl.4": '{"action": "after a gap"}\n',
        }
        reader = Path(folder) / "reader"
        reader.mkdir()
        for name, text in files.items():
            (reader / name).write_text(text)
        read = list(audit.iter_records(reader / "audit.jsonl"))
        limited = list(audit.iter_records(reader / "audit.jsonl", limit=3))
    return {"written": written, "files": files, "records": read, "limited": limited,
            "constants": {"MAX_LOG_BYTES": audit.MAX_LOG_BYTES, "RETENTION_GENERATIONS": audit.RETENTION_GENERATIONS}}
def reports_fixture(mock: Path) -> dict:
    """GamGUI's build_reports over the mock's users and seeded variants, at a fixed time: each report's
    key, title and members in order. Logins are written the ways GAM writes them (and a few it doesn't)."""
    import random
    from datetime import datetime, timezone

    from gamgui.core.gam.models import GAMUser
    from gamgui.core.reports import build_reports

    now = datetime(2026, 10, 8, 12, 0, tzinfo=timezone.utc)
    with gam_reader() as read:
        records = [r for out in mock_outputs(mock)["print_users"] for r in read(out)]
    rng = random.Random(20261008)
    logins = ["2026-10-01T09:30:00.000Z", "2026-07-10T12:00:00.000Z", "2026-07-10T11:59:59Z", "2026-07-10T12:00:00Z",
              "1970-01-01T00:00:00.000Z", "2026-09-30T23:00:00+02:00", "2026-09-30", "2026-09-30 08:00:00",
              "2026-09-30T08:00:00.123456Z", "Never", "", None, "not a date", " 2026-10-01T09:30:00Z "]
    flags = [True, False, "true", "false", ""]
    words = ["", "  ", "Sales", None]
    for n in range(200):
        record = {"primaryEmail": f"user{n}@example.com"}
        for key in ("suspended", "isAdmin", "isDelegatedAdmin", "isEnrolledIn2Sv"):
            if rng.random() < 0.8:
                record[key] = rng.choice(flags)
        if rng.random() < 0.8:
            record["lastLoginTime"] = rng.choice(logins)
        if rng.random() < 0.6:
            record["recoveryEmail"] = rng.choice(["", "me@home.example", None, "  "])
        if rng.random() < 0.7:
            record["organizations"] = [{"title": rng.choice(words), "department": rng.choice(words), "primary": True}]
        if rng.random() < 0.5:
            record["phones"] = [{"value": rng.choice(words)}]
        if rng.random() < 0.5:
            record["locations"] = [{"buildingName": rng.choice(words)}]
        records.append(record)
    reports = build_reports([GAMUser.from_json(r) for r in records], now=now)
    # The Users list's search over those users, as GamGUI's _filter_users finds them, and Python's
    # str.lower() (with its final-sigma rule) on its own.
    from gamgui.web.routes.users import _filter_users

    people = [
        {"primaryEmail": "nikos@example.com", "name": {"givenName": "ΝΙΚΟΣ", "familyName": "ΠΑΠΑΣ"}},
        {"primaryEmail": "ramu@example.com", "name": {"givenName": "रामू", "familyName": "सिंह"}},
        {"primaryEmail": "kitti@example.com", "name": {"givenName": "กิตติ", "familyName": "x"}},
        {"primaryEmail": "ipek@example.com", "name": {"givenName": chr(0x130) + "pek", "familyName": "Y"}},
        {"primaryEmail": "flag@example.com", "name": {"givenName": chr(0x1F1FA) + chr(0x1F1F8), "familyName": "Z"}},
        {"primaryEmail": "zoe@example.com", "name": {"givenName": "Zo" + chr(0xEB), "familyName": "e" + chr(0x301)},
         "organizations": [{"title": "IT Director", "department": "Sales", "primary": True}], "orgUnitPath": "/Staff",
         "suspended": True},
    ]
    users = [GAMUser.from_json(p) for p in people]
    queries = ["νικος", "ΝΙΚΟΣ", "νικοσ", "παπας", "राम", "स", "ก", "i", "İ", "pek", chr(0x1F1FA), "flag@", "e",
               chr(0xE9), "e" + chr(0x301), "director", " /STAFF ", chr(0x3000) + "sales", "", "   ", "nobody"]
    filters = [{"query": q, "scope": scope, "matches": [u.primary_email for u in _filter_users(users, q, scope)]}
               for q in queries for scope in ("all", "active", "suspended")]
    sigma = ["ΑΣ", "ΑΣ Β", "Σ", "ΑΣΑ", "Α'Σ", "Α.Σ", "ΝΙΚΟΣ", "ΟΔΥΣΣΕΥΣ", "ΑΣ'", "ΑΣ" + chr(0x301), "ΑΣ1", "1Σ"]
    from datetime import timedelta
    from gamgui.core.reports import _parse_dt

    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    login_forms = [
        "2026-10-01T09:30:00.000Z", "1970-01-01T00:00:00.000Z", "2026-10-08T12:00:00Z", "2026-10-08T14:00:00+02:00",
        "2026-10-08", "2026-10-08 12:00:00", " 2026-10-08T12:00:00.5Z ", "Never", "", "not a date",
        "2026-10-08T24:00", "2026-10-08T24:00:00", "2026-10-08T24:00:00Z", "2026-10-08T24:00:01",
        "2026-10-08T24:00:00.000001", "2026-07-10T11:59:59.9999999Z", "2026-10-08T12:00:00+05",
        "2026-10-08T12:00:00+05:30:15", "2026-10-08T12:00:00+05:30:15.123456", "2026-10-08T12:00:00 +05:30",
        "2026-10-08T12:00:00.Z", "2026-10-08T12:00:00+0530:00", "2026-10-08T12:00:00+0530",
        "2026-10-08T12:00:00+053015", "2026-10-08T12:00:00,5Z", "1969-12-31T23:59:59Z", "0001-01-01T00:00:00Z",
        "2026-02-29T00:00:00Z", "2028-02-29T00:00:00Z", "2026-10-08T12", "2026-10-08T12:30", "2026-10-08T1230",
        "2026-10-08T123000", "20261008T120000Z", "20261008", "2026-W41-4", "2026-281", "2026-10-08T12:00:00.123",
        "2026-10-08T12:00:00.1234567890Z", chr(0x662) + chr(0x660) + chr(0x662) + chr(0x666) + "-10-08",
        "2026-10-08t12:00:00z", "2026-10-08T12:00:00-00:00", "2026-10-08T12:00:00+24:00",
        "2026-10-08T12:00:00+23:59", "2026-10-08T12:00:00.", "2026-10-08X12:00", "2026-10-08T12:00:00Z ",
        "2026-13-01", "2026-10-08T12:60", "2026-10-08T12:00:60",
    ]

    def micros(text):
        found = _parse_dt(text)
        return None if found is None else (found - epoch) // timedelta(microseconds=1)

    return {"people": people, "filters": filters, "logins": [[text, micros(text)] for text in login_forms],
            "lower": [[text, text.lower()] for text in sigma]
            + [[chr(p), chr(p).lower()] for p in range(0x110000) if 0xD800 > p or p > 0xDFFF if chr(p).lower() != chr(p)],
            "now": now.isoformat(), "inactive_days": 90, "records": records,
            "reports": [{"key": r.key, "title": r.title, "description": r.description,
                         "members": [u.primary_email for u in r.users]} for r in reports]}


def audit_screen_fixture() -> dict:
    """GamGUI's Audit screen (web/routes/audit.py) over a log written across two generations: records as
    both apps write them (this app's begin and end records too) and fields of every type json.loads makes
    where text is expected. For each query, the page _rows_context shows (each row by its place in the
    newest-first log), the header's counts, and the bytes _export_csv streams. Lists and objects where text
    is expected are left out: Python prints their repr, which the Swift screen doesn't reproduce."""
    import tempfile

    from gamgui.core.audit import read_records
    from gamgui.web.routes import audit as route

    def stamp(n: int) -> str:
        return f"2026-10-{1 + n // 24:02d}T{n % 24:02d}:00:00.{n * 1000:06d}+00:00"

    preview = "6F1D2C3B-0000-4000-8000-00000000000"
    swift = [
        # This app's write: a begin with no result, then its end (ChangeCore.swift).
        {"connector": "google_workspace", "action": "updateOrganization", "target": "alice@example.com",
         "argv": ["update", "user", "alice@example.com", "organization", "title", "IT Director", "primary"],
         "exit_code": None, "ok": None, "actor": "admin@example.com",
         "extra": {"preview": preview + "1", "digest": "ab12", "origin": "form", "step": 0, "phase": "begin"}},
        {"connector": "google_workspace", "action": "updateOrganization", "target": "alice@example.com",
         "argv": ["update", "user", "alice@example.com", "organization", "title", "IT Director", "primary"],
         "exit_code": 0, "ok": True, "actor": "admin@example.com",
         "extra": {"preview": preview + "1", "digest": "ab12", "origin": "form", "step": 0, "phase": "end"}},
        {"connector": "google_workspace", "action": "addGroupMember", "target": "bob@example.com",
         "argv": ["update", "group", "sales@example.com", "add", "member", "bob@example.com"],
         "exit_code": 50, "ok": False, "actor": "admin@example.com",
         "extra": {"group": "sales@example.com", "error": "Member already exists.", "kind": "duplicate",
                   "preview": preview + "2", "step": 0, "phase": "end"}},
        # A begin whose end never came, then the operator's acknowledgement of it.
        {"connector": "google_workspace", "action": "suspendUser", "target": "carol@example.com",
         "argv": ["update", "user", "carol@example.com", "suspended", "on"], "exit_code": None, "ok": None,
         "actor": "admin@example.com", "extra": {"preview": preview + "3", "step": 0, "phase": "begin"}},
        {"connector": "google_workspace", "action": "suspendUser", "target": "carol@example.com", "argv": None,
         "exit_code": None, "ok": None, "actor": None,
         "extra": {"preview": preview + "3", "step": 0, "phase": "end", "acknowledged": True}},
    ]
    gamgui = [
        {"connector": "google_workspace", "action": "add_group_member", "target": "dana@example.com",
         "argv": ["update", "group", "sales@example.com", "add", "member", "dana@example.com"], "exit_code": 0,
         "ok": True, "actor": None, "extra": {"group": "sales@example.com"}},
        {"connector": "keychain", "action": "remove_domain", "target": "example.org", "argv": None, "exit_code": None,
         "ok": True, "actor": None, "extra": {"detail": "Deleted example.org's credentials from the Keychain.",
                                              "outcome": "deleted"}},
        {"connector": "google_workspace", "action": "set_signature", "target": "erin@example.com",
         "argv": ["user", "erin@example.com", "signature", "***redacted***", "html"], "exit_code": 1, "ok": False,
         "actor": "admin@example.com", "extra": {"error": 'GAM said: "no", then\nmore\r\nlines, and a\rcarriage'}},
    ]
    # Each value a spreadsheet reads as a formula is prefixed; a comma, quote, CR or LF is quoted.
    leads = ["=HYPERLINK(\"http://x.example\")", "+1 555", "-9", "@SUM(1)", "\tTab", "\rCR", " space", "'quote"]
    odd = [{"action": "export", "target": f"lead{n}@example.com", "ok": False, "exit_code": -9,
            "extra": {"error": lead}} for n, lead in enumerate(leads)]
    odd += [
        {"action": "rename", "target": "ΟΔΥΣΣΕΥΣ@example.com", "ok": True, "argv": ["user", "ΟΔΥΣΣΕΥΣ@example.com"]},
        {"action": "rename", "target": chr(0x130) + "pek@example.com", "ok": True, "exit_code": 0},
        {"action": "rename", "target": "straße@example.com", "ok": True, "extra": {"detail": "Zo" + chr(0xEB) + " " + chr(0x1F1FA) + chr(0x1F1F8)}},
        {"action": "line", "target": "sep@example.com", "ok": False, "extra": {"error": "a" + chr(0x2028) + "b" + chr(0x85) + "c\x00d"}},
        # ok as json.loads leaves it: only false is a failure, only true a success.
        {"action": "flag", "target": "zero@example.com", "ok": 0},
        {"action": "flag", "target": "one@example.com", "ok": 1},
        {"action": "flag", "target": "text@example.com", "ok": "false"},
        {"action": "flag", "target": "missing@example.com"},
        # exit codes and times of every type.
        {"ts": None, "action": "code", "target": "a@example.com", "exit_code": 1.5, "ok": False},
        {"ts": 1.5, "action": "code", "target": "b@example.com", "exit_code": "x", "ok": True},
        {"ts": 20261008, "action": "code", "target": "c@example.com", "exit_code": 12345678901234567890, "ok": True},
        {"action": "code", "target": "d@example.com", "exit_code": 1e16, "ok": True},
        {"action": "code", "target": "e@example.com", "exit_code": -0.0, "ok": True},
        # extra that isn't an object, and errors and details that aren't text.
        {"action": "extra", "target": "list@example.com", "ok": False, "extra": ["error", "x"]},
        {"action": "extra", "target": "text@example.com", "ok": False, "extra": "error"},
        {"action": "extra", "target": "null@example.com", "ok": False, "extra": None},
        {"action": "extra", "target": "none@example.com", "ok": False, "extra": {"error": None, "detail": None}},
        {"action": "extra", "target": "falsy@example.com", "ok": False, "extra": {"error": 0, "detail": False}},
        {"action": "extra", "target": "num@example.com", "ok": False, "extra": {"error": 404, "detail": 5}},
        {"action": "extra", "target": "empty@example.com", "ok": False, "extra": {"error": "", "detail": "only detail"}},
        # argv as json.loads leaves it: its items joined by a space, a string's characters, an object's keys.
        {"action": "argv", "target": "mixed@example.com", "ok": True, "argv": ["a", 5, None, True, 1.0]},
        {"action": "argv", "target": "string@example.com", "ok": True, "argv": "str"},
        {"action": "argv", "target": "object@example.com", "ok": True, "argv": {"k1": 1, "k2": 2}},
        {"action": "argv", "target": "empty@example.com", "ok": True, "argv": []},
        # action and target of other types.
        {"action": None, "target": None, "ok": True},
        {"action": "", "target": 7, "ok": True},
        {"action": 0, "target": False, "ok": True},
        {"action": True, "target": True, "ok": False},
        {"action": 5, "target": 0.5, "ok": False},
    ]
    filler = [{"connector": "google_workspace", "action": ["vacationOff", "set_vacation", "signOutUser"][n % 3],
               "target": f"user{n}@example.com", "argv": ["user", f"user{n}@example.com", "vacation", "off"],
               "exit_code": 0 if n % 4 else 50, "ok": bool(n % 4), "actor": "admin@example.com"} for n in range(24)]
    records = []
    for n, record in enumerate(filler[:12] + gamgui + swift + odd + filler[12:]):
        records.append(record if "ts" in record else {"ts": stamp(n), **record})
    lines = [json.dumps(r, ensure_ascii=False) for r in records]
    files = {"audit.jsonl.1": "\n".join(lines[:20]) + "\nnot json\n",
             "audit.jsonl": "\n".join(lines[20:]) + "\n\n"}
    queries = ["", "  ", "alice", " ALICE ", "ΟΔΥΣΣΕΥΣ", "οδυσσευς", "Σ", chr(0x130), "i" + chr(0x307), "STRASSE",
               "straße", "member already", "=hyperlink", "keychain", "credentials", "true", "5", "none", "s t r",
               "k1 k2", "update user", "sales", "user1", chr(0x2028), "\x00", "\t", "nomatch"]
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            Path(folder, name).write_text(text, encoding="utf-8")
        log = Path(folder, "audit.jsonl")
        newest_first = read_records(log)
        place = {id(r): n for n, r in enumerate(newest_first)}
        pages = []
        for q in queries:
            for failed in (False, True):
                for page in (1, 2, 3, 0, -1, 99):
                    shown = route._rows_context(newest_first, q, failed, page)
                    pages.append({"q": q, "failed": failed, "page": page, "rows": [place[id(r)] for r in shown["rows"]],
                                  "shown_page": shown["page"], "pages": shown["pages"], "total": shown["total"]})
        exports = [{"q": q, "failed": failed, "csv": "".join(route._export_csv(log, q, failed))}
                   for q in ("", "alice", "ΟΔΥΣΣΕΥΣ", "true", "nomatch") for failed in (False, True)]
    return {"constants": {"PAGE_SIZE": route.PAGE_SIZE}, "files": files, "read": len(newest_first),
            "header": {"total": len(newest_first), "failures": sum(1 for r in newest_first if r.get("ok") is False)},
            "pages": pages, "exports": exports}


def usage_fixture(mock: Path) -> dict:
    """GamGUI's storage and mail usage (core/reports.py, the connector's usage_report, the route's top 25):
    _csv_from over GAM's output with progress before its CSV; parse_usage over the mock's report and rows
    of every value float() reads or refuses (none it raises on); and usage_report's walk back, the argv of
    each call made with a fake runner at a fixed date (no rows at all, rows on the third call, a failure on
    the second)."""
    import asyncio
    from datetime import datetime, timezone
    from unittest import mock as patching

    from gamgui.core import reports
    from gamgui.core.connectors import gam_connector

    def row(u) -> dict:
        return {"email": u.email, "quota_mb": u.quota_mb, "storage_gb": u.storage_gb, "received": u.received,
                "sent": u.sent, "drive_created": u.drive_created, "storage": "%.1f" % u.storage_gb}

    header = "email,date,accounts:used_quota_in_mb,drive:num_items_created,gmail:num_emails_received,gmail:num_emails_sent"
    outputs = ["Getting Reports for all users\nGot 3 Reports for all users on 2026-06-16...\n" + header + "\na@example.com,2026-06-16,1,2,3,4\n",
               "  Email,date\r\nb@example.com,2026-06-16\r\n", chr(0x3000) + "EMAIL,x\nrow", "x" + chr(0x2028) + "email,date" + chr(0x2028) + "a,b",
               "progress\nemail\nx", "emails,date\nrow", "no header here", "", "\n\nemail,date\n\na@example.com,1\n\n",
               "email,date\x1cc@example.com,2\x0bd", "e-mail,x\nemail,y"]
    csv_from = [[out, gam_connector._csv_from(out)] for out in outputs]
    report = mock_outputs(mock)["report_users"][0]
    with gam_reader() as read:
        mocked = read(gam_connector._csv_from(report))
    values = ["608873", "", None, "12.7", "-5", " 42 ", "1e3", "1.5E+2", "+.5e1", "nan", "-NaN", "abc", "1_000", "1__0",
              "_1", "1_", "١٢", "١٢.٥", "0x10", "9007199254740993", "-0.5", "1.", ".", "\x1c7",
              "7\x0c", "\xa07" + chr(0x3000), "7 7", "1e", "infinite", "256", "768", "1126", "51", "52", "1048576"]
    rows = []
    for n, value in enumerate(values):
        record = {"email": f"user{n}@example.com", "date": "2026-06-16", "accounts:used_quota_in_mb": value,
                  "gmail:num_emails_received": values[(n + 3) % len(values)], "gmail:num_emails_sent": values[(n + 7) % len(values)],
                  "drive:num_items_created": values[(n + 11) % len(values)]}
        if n % 9 == 4:
            del record["gmail:num_emails_sent"]   # a column GAM didn't print
        if n == 5:
            record["email"] = None                  # DictReader's restval for a short row
        if n == 6:
            del record["email"]
        rows.append(record)
    rows += [{"email": f"tie{n}@example.com", "accounts:used_quota_in_mb": "100"} for n in range(4)]
    parsed = [{"rows": records, "usage": [row(u) for u in reports.parse_usage(records)]} for records in (mocked, rows)]

    class Runner:
        def __init__(self, answers):
            self.answers, self.calls = list(answers), []

        async def run_authenticated(self, domain, argv):
            self.calls.append(list(argv))
            answer = self.answers.pop(0) if self.answers else ""
            if isinstance(answer, Exception):
                raise answer
            return answer

    walks = []
    for today in (datetime(2026, 10, 8, 23, 59, tzinfo=timezone.utc), datetime(2028, 3, 2, 0, 30, tzinfo=timezone.utc)):
        for name, answers in (("empty", []), ("third", ["", "email,date\n", report]), ("fails", ["", RuntimeError("gam")])):
            connector = object.__new__(gam_connector.GAMConnector)
            connector.runner, connector.domain = Runner(answers), "example.com"
            clock = patching.Mock(wraps=datetime)
            clock.now = lambda tz=None, today=today: today
            with patching.patch.object(gam_connector, "datetime", clock), gam_reader():
                try:
                    found = asyncio.run(connector.usage_report(reports.USAGE_PARAMS))
                    result = {"date": found["date"], "emails": [r.get("email") for r in found["rows"]]}
                except RuntimeError:
                    result = None
            walks.append({"today": today.isoformat(), "answers": name, "argv": connector.runner.calls, "result": result})
    import inspect

    lookback = inspect.signature(gam_connector.GAMConnector.usage_report).parameters["max_lookback"].default
    return {"constants": {"USAGE_PARAMS": list(reports.USAGE_PARAMS), "max_lookback": lookback},
            "csv_from": csv_from, "parse_usage": parsed, "walks": walks}


def setup_fixture() -> dict:
    """GamGUI's guided setup (core/setup.py): the delegation step's facts and link (dwd_details,
    dwd_auth_url) and the fresh-setup Terminal commands (setup_commands), over chosen inputs."""
    import json as _json
    from types import SimpleNamespace

    from gamgui.core import setup

    service_jsons = ['{"client_id": "123456789012345678901"}', '{"client_id": 1234567890}', '{"client_id": ""}',
                     '{"client_id": null}', '{}', '[]', 'not json', '', '{"client_id": "a&b=c d"}']
    oauth_jsons = [_json.dumps({"scopes": [setup.USER_SECURITY_SCOPE, "https://mail.google.com/"]}),
                   _json.dumps({"scopes": ["https://mail.google.com/"]}), _json.dumps({"scopes": []}),
                   _json.dumps({"scopes": setup.USER_SECURITY_SCOPE}), '{}', 'not json', '']
    facts = []
    for service in service_jsons:
        client_id = str(setup._json_field(service, "client_id") or "")
        for domain in ("", "example.com"):
            facts.append({"oauth2service": service, "domain": domain, "client_id": client_id,
                          "auth_url": setup.dwd_auth_url(client_id, [s for s, _ in setup.DWD_SCOPES], domain)})
    security = []
    for oauth in oauth_jsons:
        granted = setup._json_field(oauth, "scopes")
        security.append({"oauth2": oauth,
                         "user_security": (setup.USER_SECURITY_SCOPE in granted) if isinstance(granted, list) else None})
    commands = []
    for admin in ("admin@example.com", "it.admin+gam@sub.example.org"):
        for cfgdir, gam in (("/Users/operator/GAM Setup/setup", "/Applications/GAM Tools/gam7/gam"),
                            ("/tmp/setup", "/opt/gam7/gam")):
            fake = SimpleNamespace(runner=SimpleNamespace(gam_binary=gam))
            commands.append({"admin": admin, "cfgdir": cfgdir, "gam": gam}
                            | setup.SetupService.setup_commands(fake, admin, cfgdir))
    # GamGUI's address check for writes that take an address (groups, delegates, calendars): GAM reads a
    # bare name, `@domain` or a comma-joined list as something else entirely.
    from gamgui.core.onboarding import looks_like_email
    ws = [chr(c) for c in (0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2028, 0x3000)]
    emails = ["a@example.com", "first.last+tag@sub.example.co.uk", "a@b", "@example.com", "a@", "a@@example.com",
              "a@example..com", "a@.example.com", "a@example.com.", "a,b@example.com", "a@example.com,b@example.com",
              "oauthuser", "admin", "a b@example.com", "a@exa mple.com", "", "   ", "\u00e9l\u00e8ve@\u00e9cole.fr",
              "a@example.com\n", "a@b.c", "a\u200b@example.com"]
    emails += [f"{w}a@example.com{w}" for w in ws] + [f"a{w}b@example.com" for w in ws]
    checks = [{"value": e, "ok": looks_like_email(e)} for e in emails]
    return {"looks_like_email": checks, "dwd_scopes": [list(pair) for pair in setup.DWD_SCOPES],
            "user_security_scope": setup.USER_SECURITY_SCOPE,
            "admin_console_dwd_url": setup.ADMIN_CONSOLE_DWD_URL,
            "facts": facts, "user_security": security, "setup_commands": commands}


def vacation_fixture(mock: Path) -> dict:
    """GamGUI's auto-reply helpers: Vacation.from_show_text over the mock's show vacation and crafted
    texts; autoreply_html; autoreply_text and _looks_like_html (Python's HTMLParser and html.unescape
    beneath them) over curated and seeded random bodies; html.unescape over every HTML5 name."""
    import html
    import random
    import subprocess
    import tempfile
    from html.entities import html5

    from gamgui.core import lifecycle
    from gamgui.core.gam.models import Vacation
    from gamgui.core.gam.runner import strip_cfgdir_noise

    def vac(v):
        return {"enabled": v.enabled, "subject": v.subject, "message": v.message, "contacts_only": v.contacts_only,
                "domain_only": v.domain_only, "start": v.start, "end": v.end}

    texts = []
    with tempfile.TemporaryDirectory() as config:
        for name in ("oauth2service.json", "oauth2.txt"):
            Path(config, name).write_text('{"placeholder": true}')
        environment = {"PATH": "/usr/bin:/bin", "GAMCFGDIR": config, "GAM_MOCK_FIXTURES": str(mock.parent / "mock_gam")}
        for user in ("alice@example.com", "bob@example.com", "carol@example.com"):
            run = subprocess.run([str(mock), "user", user, "show", "vacation"], capture_output=True, text=True, env=environment)
            if run.returncode != 0:
                raise SystemExit(f"the mock refused show vacation for {user}")
            texts.append(strip_cfgdir_noise(run.stdout, Path(config)))
    texts += [
        "",
        "User: a@example.com, Vacation:\n  Enabled: True\n  Contacts Only: False\n  Domain Only: True\n"
        "  Subject: Out of office\n  Start Date: 2026-10-01\n  End Date: NotSpecified\n  Message:\n"
        "    Back Monday.\n\n    <b>Urgent?</b> Call the desk.\n",
        "  Enabled: true\r\n  Subject:   Away  \r\n  Message:\r\n   line one\r\n   line two\r\n  Enabled: False\r\n",
        "Enabled: TRUE\nMessage:\nhello\nCreated: /tmp/gamcache\nConfig File: /tmp/gam.cfg, Initialized\n",
        "Start Date: 2026-1-01\nEnd Date: \u0661\u0662\u0663\u0664-10-10\nStart Date: 2026-12-31 \n",
        "Subject: \u00e9t\u00e9\u2028Message:\nx\u2029y\x85z\x1cw\n",
        "Message:\n  only a message, no fields\n",
        "Enabled: falsetrue\nContacts Only: True\nDomain Only: no\n",
    ]
    show = [{"text": t} | vac(Vacation.from_show_text(t)) for t in texts]

    rng = random.Random(20261009)
    plain = ["Back Monday.\nCall the desk.", "a & b < c > d", "C:\\Users\\n", "line\r\nCRLF\rCR", "", "\n\n",
             "\u00e9\u2028x", "&amp; already", "tab\there"]
    tokens = ["<br>", "<BR/>", "<br />", "<div>", "</div>", "<DIV class='x'>", "<p>", "</p >", "<li>", "</li>", "<ul>",
              "<b>", "</b>", "<a href=\"x\">", "<a href=x>", "<img src='y'/>", "<span style=\"a:b\">", "<x>", "</x>",
              "<script>", "</script>", "<SCRIPT>", "</scripT >", "<style>", "</style>", "<title>", "</title>",
              "<textarea>", "</textarea>", "<plaintext>", "<xmp>", "</xmp>", "<iframe>", "<noembed>", "<noframes>",
              "<!--", "-->", "--!>", "->", "<!-- c -->", "<!doctype html>", "<!DOCTYPE", "<![CDATA[", "]]>", "<?xml ?>",
              "<?", "<!", "</", "</>", "< b>", "<a b c>", "<a / >", "<li/>", "<P>", "<Div>", "<blockquote>",
              "&amp;", "&amp", "&lt;", "&gt", "&#92;", "&#x5c;", "&#X5C", "&#0;", "&#1;", "&#128;", "&#xD800;",
              "&#1114112;", "&#99999999999999999999;", "&notit;", "&notin;", "&ampx", "&nbsp", "&nbsp;", "&#", "&#x",
              "&", "<", ">", "=", "\"", "'", "/", "a", "b", "word", " ", "  ", "\n", "\r\n", "\r", "\t", "\x0c",
              "\u00a0", "\u2028", "\u00e9", "\u212a", "\u017f", "\u0131", "\u0130", "<\u0130>", "<l\u0130>",
              "<a\u00a0b=c>", "<b x='1' y=\"2\" z=3>", "<b x=>", "<b x='>", "<em>", "</em>", "<h1>", "<h7>"]
    bodies = list(plain) + ["<div>Back Monday.</div><div><br></div><div>Call the desk.</div>",
                            "Line one<br/>Line two &amp; three &#92;n", "<p>a</p><p>b</p>", "x<!-- hidden -->y",
                            "<script>alert(1)</script>after", "<title>&amp;</title>", "a <b and c> d"]
    for _ in range(1500):
        bodies.append("".join(rng.choice(tokens) for _ in range(rng.randint(1, 14))))
    names = sorted(html5)
    for _ in range(300):
        bodies.append("<br>" + "".join(rng.choice(["&" + rng.choice(names), "x", ";", " ", "<b>"]) for _ in range(rng.randint(1, 6))))
    texts_html = [{"body": b, "text": lifecycle.autoreply_text(b), "html": lifecycle._looks_like_html(b)} for b in bodies]
    replies = [{"text": t, "html": lifecycle.autoreply_html(t)} for t in plain + bodies[:400]]
    unescapes = []
    for name in names:
        for ref in ("&" + name, "&" + name + "x", "&" + name.rstrip(";") + "Z;"):
            unescapes.append({"in": ref, "out": html.unescape(ref)})
    for number in list(range(0, 200)) + [0xD7FF, 0xD800, 0xDFFF, 0xE000, 0xFFFE, 0x10FFFF, 0x110000, 10 ** 30]:
        for ref in (f"&#{number};", f"&#x{number:x};", f"&#{number}", f"&#X{number:X}z"):
            unescapes.append({"in": ref, "out": html.unescape(ref)})
    return {"show_vacation": show, "autoreply_text": texts_html, "autoreply_html": replies, "unescape": unescapes}


def gam_function(code, name: str, **names):
    """One of the vendored GAM's own functions, by name, to run as the oracle for what GAM does: the
    build is checksum-pinned and trusted. `names` are the globals it reads; a call that needs any other
    fails with NameError, so the oracle can't quietly take a path the fixture doesn't model."""
    import builtins

    found = []

    def walk(parent):
        for const in parent.co_consts:
            if inspect.iscode(const):
                if const.co_name == name:
                    found.append(const)
                walk(const)

    walk(code)
    if len(found) != 1:
        raise SystemExit(f"GAM's {name} wasn't found once in the build: read it at the new tag")
    return types.FunctionType(found[0], {"__builtins__": builtins} | names)


def gam_constant(code, name: str):
    """A module-level frozenset GAM builds as `NAME = {\u2026}` (BUILD_SET, its frozenset, SET_UPDATE)."""
    found = [i for i in dis.get_instructions(code) if i.opname != "EXTENDED_ARG"]
    values = [found[n - 2].argval for n, i in enumerate(found)
              if i.opname == "STORE_NAME" and i.argval == name and found[n - 1].opname == "SET_UPDATE"]
    if len(values) != 1 or not isinstance(values[0], frozenset):
        raise SystemExit(f"GAM's {name} isn't a set literal in the build: read it at the new tag")
    return values[0]


def signature_fixture(mock: Path, code) -> dict:
    """GamGUI's signature helpers (core/signatures.py) and its reader of `show signature`
    (gam_connector._parse_signature), and what the vendored GAM does with a signature argument, from its
    own functions: _processSignature, the stored form, and checkArgumentPresent over SORF_FILE_ARGUMENTS,
    the bodies it reads as a file or document keyword. Never constructs a SignatureStore, which reads the
    operator's GamGUI data by default (failure-log 2026-09-25)."""
    import random
    import subprocess
    import tempfile

    from gamgui.core import signatures
    from gamgui.core.connectors.gam_connector import _parse_signature
    from gamgui.core.gam.models import GAMUser
    from gamgui.core.gam.runner import strip_cfgdir_noise

    # The people a template renders for: the mock's directory as GAM prints it, then crafted records.
    with gam_reader() as read:
        records = [r for out in mock_outputs(mock)["print_users"] for r in read(out)]
    records += [
        {"primaryEmail": "a@e.com", "name": {"givenName": "Al", "familyName": "Ant"},
         "organizations": [{"title": "Director", "primary": True}]},
        {"primaryEmail": "b@e.com"},   # no name: the full name falls back to the address
        {"primaryEmail": "c@e.com", "orgUnitPath": "", "phones": [{"value": "860.388.0891", "type": "work", "primary": True}],
         "locations": [{"buildingId": "B-12", "type": "desk"}]},
        {"primaryEmail": "d@e.com", "name": {"fullName": "{phone} [[x]]", "givenName": "{name}", "familyName": "]]"},
         "organizations": [{"title": "{title}", "department": "[[", "primary": True}],
         "phones": [{"value": "{email}"}], "orgUnitPath": "/{ou}"},
        {"primaryEmail": "e@e.com", "name": {"givenName": "Zo\u00eb", "familyName": "e\u0301"},
         "organizations": [{"title": "Lead \u201cOps\u201d", "department": "R&D <b>"}, {"title": "Other", "primary": True}],
         "locations": [{"buildingName": "Riverside", "buildingId": "R1", "primary": True}], "orgUnitPath": "/Sales/East"},
        {"primaryEmail": "f@e.com", "name": {"givenName": "", "familyName": ""}, "suspended": True},
    ]
    users = [GAMUser.from_json(r) for r in records]

    tokens = list(signatures.VARIABLES) + ["{x}", "{", "}", "{{name}}", "{name", "name}", "[[", "]]", "[", "]", "[[[",
                                           "]]]", "<", ">", "<div>", "</div>", '<a href="x">', "<a href=\u201cx\u201d>",
                                           "\u201c", "\u201d", "\u2018", "\u2019", '"', "'", "\n", "\r\n", "\r", "\\n",
                                           "\u00e9", "\u0301", "}\u0301", "]]\u0301", "[[\u0301", "a", " ", " \u00b7 ",
                                           "\u2028", "<br>", "Your Company", "\U0001F600"]
    curated = ["{name} | {role} | {email}", "{title}={role}", "Call {phone}", "{name}[[ \u2014 {title}]] \u00b7 Example Co",
               "[[{title}/{phone}]]x", "[[{title}]]x", "Visit us in {location}", "", "[[", "]]", "[[]]", "[[ a ]] [[ b",
               "x]][[y", "[[{phone}]] [[{title}]]", "{phone}{phone}", "{nam{name}e}", "<div style=\u201ccolor:#000\u201d>{name}</div>",
               "<a<b \u2019 >", "<div\n style=\u2019x\u2019>", "<a>b \u2019 c>", "<x \u2019 y", "\u2019<div>",
               "<div>we\u2019re hiring \u201cnow\u201d</div>", '<div style="color:#000">{name}</div>',
               "[[{title} \u00b7 ]]{name}\n[[{department}]]", "{ou}{ou}[[{ou}]]", "{location}[[ in {location}]]"]
    rng = random.Random(20261010)
    generated = ["".join(rng.choice(tokens) for _ in range(rng.randint(1, 16))) for _ in range(1500)]

    render = []
    for template in list(signatures._DEFAULT_TEMPLATES.values()) + curated:
        for index, user in enumerate(users):
            render.append({"template": template, "user": index, "out": signatures.render_signature(template, user)})
    for template in generated:
        index = rng.randrange(len(users))
        render.append({"template": template, "user": index, "out": signatures.render_signature(template, users[index])})

    warning = signatures.smart_quote_warning("<a \u201c>")
    templates = list(signatures._DEFAULT_TEMPLATES.values()) + curated + generated
    curly = [{"template": t, "warns": signatures.smart_quote_warning(t) == warning} for t in templates]
    if any(signatures.smart_quote_warning(t) not in ("", warning) for t in templates):
        raise SystemExit("smart_quote_warning has more than one message")

    # show signature: the mock's text for each directory user, then crafted shapes.
    shown = []
    with tempfile.TemporaryDirectory() as config:
        for name in ("oauth2service.json", "oauth2.txt"):
            Path(config, name).write_text('{"placeholder": true}')
        environment = {"PATH": "/usr/bin:/bin", "GAMCFGDIR": config, "GAM_MOCK_FIXTURES": str(mock.parent / "mock_gam")}
        for record in records[:4]:
            run = subprocess.run([str(mock), "user", record["primaryEmail"], "show", "signature"], capture_output=True,
                                 text=True, env=environment)
            if run.returncode != 0:
                raise SystemExit(f"the mock refused show signature for {record['primaryEmail']}")
            shown.append(strip_cfgdir_noise(run.stdout, Path(config)))
    shown += [
        "", "Signature:", "Signature:\n    None\n", "SendAs Address: <a@example.com>\n  Signature:\n    None\n",
        "SendAs Address: Al Ant <a@example.com>\n  IsPrimary: True\n  Default: True\n  Signature:\n"
        "    <div>\n      <b>Al</b>\n\n    </div>\n",
        "  Signature:\r\n    one\r\n    two\r\n", "  Signature: x\n    y\n", "  signature:\n    lower\n",
        "  Signature:::\n    colons\n", "Signature\n  no colon\n", "  Signature:\n\tTabbed\n    spaced\n",
        "  Signature:\n    None\n    more\n", "  Signature:\n    a\u2028b\n    c\n", "  Signature:\n    a\x85b\x0cc\n",
        "SendAs Address: <a@example.com>\n  Signature:\n    first\nSendAs Address: <b@example.com>\n  Signature:\n    second\n",
        "  Signature:\n    x\nUser: a@example.com\n    y\n", "  Signature:\n\n    after a blank\n", "  Signature:\n  \u00a0\n",
        "  Signature:\n     None  \n", "Signature:\n None\n", "\u00a0Signature:\u3000\n    wide\n",
    ]
    parse = [{"text": t, "body": _parse_signature(t)} for t in shown]

    # GAM's own handling of the signature argument.
    process = gam_function(code, "_processSignature")
    keywords = gam_constant(code, "SORF_FILE_ARGUMENTS")

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
        present = gam_function(code, "checkArgumentPresent", Cmd=command)
        # At run time the name holds a set (BUILD_SET, then SET_UPDATE from the frozenset constant), and
        # checkArgumentPresent treats anything but a list or a set as one choice. getStringOrFile passes no
        # `required`: False.
        return present(set(keywords), False) and command.taken

    bodies = [t["template"] for t in render[:400]] + [r["out"] for r in render[:400]]
    bodies += ["\\n", "a\\nb", "\\\\n", "\\\rn", "a\r\nb\rc\n", "\\N", "\\\n", "<br/>", ""]
    words = sorted(keywords) + ["File", " file ", "\tHTML_FILE\n", "g_doc", "G_C_S_HTML", "_ file", "file_ ", "html",
                                "sig", "files", "file.html", "\u00a0gdoc\u3000", "\u212aile", "f\u0130le", "\u017fig",
                                "GDOC", "gdoc\u200b", "fi le", "\u2028textfile\u2029", "file\x1c", "\x1ffile"]
    stored = [{"body": b, "stored": process({"tags": {}}, b, True)} for b in bodies]
    keyword = [{"body": w, "keyword": read_as_keyword(w)} for w in words + bodies[:50]]
    if not all(read_as_keyword(w) for w in keywords) or read_as_keyword("Best, Al"):
        raise SystemExit("the keyword oracle doesn't read GAM's own keywords as keywords: check checkArgumentPresent")
    # The template store's rules, from GamGUI's store pointed at a temporary file (never its default).
    with tempfile.TemporaryDirectory() as folder:
        store = signatures.SignatureStore(Path(folder, "signatures.json"))
        messages = {}
        for key, name, body in (("name_required", " \u3000", "x"), ("name_too_long", "x" * 61, "x"),
                                ("body_empty", "ok", " \u00a0\n")):
            try:
                store.save(name, body)
            except ValueError as error:
                messages[key] = str(error)
        if len(messages) != 3:
            raise SystemExit("GamGUI's store accepted a name or body it refuses")
        crafted = ["Zed", "alpha", "\u00c9t\u00e9", "E\u0301te", "e", "\U0001F600", "\uff5e", "a b", "A", "_x", "10", "9"]
        for name in crafted:
            store.save(name, "body")
        store_doc = {"seed_names": sorted(signatures._DEFAULT_TEMPLATES), "names": store.names(), "messages": messages,
                     "max_name_length": signatures._MAX_NAME_LEN}
    return {"variables": [[token, description] for token, description in signatures.VARIABLES.items()],
            "seeds": [[name, body] for name, body in signatures._DEFAULT_TEMPLATES.items()],
            "users": records, "render": render, "smart_quote_warning": warning, "smart_quote": curly,
            "parse_signature": parse, "store": store_doc,
            "gam": {"file_keywords": sorted(keywords), "stored": stored, "keyword": keyword}}


def offboarding_fixture(mock: Path) -> dict:
    """GamGUI's offboarding routine (core/lifecycle.py) and its preview's helpers (web/routes/lifecycle.py),
    over curated and seeded inputs: build_offboard_steps (each step's key, label, summary, requires and
    command lines), effective_requires over every left-out set, fill_autoreply, command_line,
    check_addresses, the preview's display names (_resolve_name, _manager_contact, _compose_autoreply) and
    its delegate warning (_delegate_warning). The helpers are handed a stand-in that holds only a directory
    or a delegate list: never GamGUI's AppState or a connector, which reach its app data and GAM."""
    import asyncio
    import itertools as it
    import random
    from datetime import date

    from gamgui.core import lifecycle
    from gamgui.core.gam.errors import GAMError
    from gamgui.core.gam.models import GAMUser
    from gamgui.web.routes import lifecycle as route

    keys = list(lifecycle.REQUIRES)
    optional = list(lifecycle.OPTIONAL_STEPS)

    def subsets(items):
        return [list(c) for n in range(len(items) + 1) for c in it.combinations(items, n)]

    def outcome(fn, *args, **kwargs):
        try:
            return {"out": fn(*args, **kwargs)}
        except Exception as exc:   # the Swift port must refuse the same inputs
            return {"error": type(exc).__name__, "message": str(exc)}

    # build_offboard_steps: GamGUI's test inputs, then seeded combinations.
    def steps_case(user, manager, subject, message, days, today, notify="", employee_name="", manager_contact="",
                   na=()):
        args = {"user": user, "manager": manager, "subject": subject, "message": message, "days": days, "today": today,
                "notify": notify, "employee_name": employee_name, "manager_contact": manager_contact,
                "not_applicable": sorted(na)}
        result = outcome(lifecycle.build_offboard_steps, user, manager, subject, message, days,
                         date.fromisoformat(today), notify=notify, employee_name=employee_name,
                         manager_contact=manager_contact, not_applicable=frozenset(na))
        if "out" in result:
            result = {"steps": [{"key": s.key, "label": s.label, "summary": s.summary, "requires": list(s.requires),
                                 "commands": s.commands, "command_lines": s.command_lines} for s in result["out"]]}
        return {"args": args} | result

    pinned = ("leaver@example.com", "mgr@example.com", "{employee} has left", "Line one.\nAsk {manager}", 30, "2026-06-23")
    pinned_kw = {"notify": "it@example.com", "employee_name": "Lee Ver", "manager_contact": "Mo Gr (mgr@example.com)"}
    steps = [steps_case("leaver@e.com", "mgr@e.com", "Subj", "Msg", 30, "2026-06-23"), steps_case(*pinned, **pinned_kw),
             steps_case("leaver@e.com", "mgr@e.com", "s", "m", 30, "2026-06-23", notify="it@e.com"),
             steps_case("jane@e.com", "bob@e.com", lifecycle.DEFAULT_SUBJECT, lifecycle.DEFAULT_MESSAGE, 30,
                        "2026-06-23", employee_name="Jane Doe"),
             steps_case("leaver@e.com", "mgr@e.com", "Subj", "Line one.\r\n\r\nAsk {manager} <IT> & co.\nC:\\new", 30,
                        "2026-06-23", manager_contact="Mo Gr (mgr@e.com)"),
             steps_case("a@example.com", "b@example.com", "Jane has left", "It's \"done\"\nbye", 30, "2026-06-23")]
    steps += [steps_case(*pinned, **pinned_kw, na=na) for na in subsets(optional)]
    steps += [steps_case(*pinned, **pinned_kw, na=[lock] + extra) for lock in ("password", "revoke", "forward")
              for extra in ([], ["delegate"])]
    # The calendar's edges, and the last due date before Python's date runs out (the end is the day after).
    last, first = date.max.toordinal() - date(2026, 6, 23).toordinal(), date.min.toordinal() - date(2026, 6, 23).toordinal()
    for today, days in (("2024-02-28", 1), ("2024-02-29", 365), ("2023-12-31", 1), ("2000-02-28", 1), ("1900-02-28", 1),
                        ("0001-01-01", 0), ("0001-01-01", -1), ("2026-06-23", -30), ("2026-06-23", 0),
                        ("2026-06-23", 3650), ("2026-06-23", 36500), ("9999-12-29", 1), ("9999-12-30", 1),
                        ("9999-12-31", 1), ("2026-06-23", last - 1), ("2026-06-23", last), ("2026-06-23", first),
                        ("2026-06-23", first - 1), ("2026-06-23", 10 ** 12)):
        steps.append(steps_case("l@example.com", "m@example.com", "s", "m", days, today))
    addresses = ["leaver@example.com", "carol@example.com", "o'neil@example.com", "zo\u00eb@example.com", "a b@example.com",
                 "$(x)@example.com", "-x@example.com", "", "line\nbreak@example.com", "tab\t@example.com", "\\@example.com",
                 "\"q\"@example.com", "\u212aim@example.com", "\U0001F600@example.com", "x" * 80 + "@example.com"]
    texts = ["", "s", "m", lifecycle.DEFAULT_SUBJECT, lifecycle.DEFAULT_MESSAGE, "{employee}{manager}{contact}",
             "{Employee} {MANAGER} {contact", "{{employee}}", "{employee}\u0301 left", "a & b < c > d", "C:\\new\\n",
             "Line one.\r\nLine two\rthree\n", "It's \"done\" `now` $HOME", "\u2028sep\u2029", "tab\there", "\n", " ",
             "<b>Bold</b> &amp;", "\U0001F600 caf\u00e9", "x" * 300]
    display = ["", "Lee Ver", "Mo Gr (mgr@example.com)", "{manager}", "{employee}", "O'Neil \"Bo\"", "\u00c9va \u212a",
               "a\\nb"]
    notifies = ["", "it@example.com", "it's@example.com", "a b", "\u00e9@example.com"]
    rng = random.Random(20261013)
    for _ in range(250):
        today = date.fromordinal(rng.randint(date(1990, 1, 1).toordinal(), date(2060, 12, 31).toordinal())).isoformat()
        na = [k for k in optional if rng.random() < 0.3] + (["revoke"] if rng.random() < 0.03 else [])
        steps.append(steps_case(rng.choice(addresses), rng.choice(addresses), rng.choice(texts), rng.choice(texts),
                                rng.choice([1, 2, 7, 14, 30, 31, 60, 90, 365, 400, 0, -5]), today,
                                notify=rng.choice(notifies), employee_name=rng.choice(display),
                                manager_contact=rng.choice(display), na=na))

    requires = [{"key": k, "not_applicable": na, "requires": list(lifecycle.effective_requires(k, frozenset(na)))}
                for k in keys for na in subsets(keys)]

    fill = [{"text": t, "employee": e, "manager": m, "out": lifecycle.fill_autoreply(t, e, m)}
            for t in texts for e, m in (("Lee Ver", "Mo Gr (mgr@example.com)"), ("{manager}", "{employee}"),
                                         ("", ""), ("{contact}", "x\u0301"))]

    # command_line: GamGUI's test argvs and every step's, then seeded argvs over sensitive keys, GAM's own
    # password keywords and the characters each quoting style turns on.
    tokens = ["password", "PASSWORD", "Password", "notifypassword", "signature", "recoveryemail", "recoveryphone",
              "alternateemail", "random", "RANDOM", "uniquerandom", "blocklogin", "prompt", "uniqueprompt", "Random",
              "random ", "S3cret pw!", "", " ", "'", "''", "\"", "\\", "$", "`", "!", "#", "*", "~", "a'b", "a\"b",
              "a$b`c\\d", "it's", "@%+=:,./-_", "abcXYZ019", "\u00e9", "\U0001F600", "\n", "\t", "a b", "{x}", ";", "&",
              "|", "<", ">", "(", ")", "[", "]", "?", "^", "\u00a0", "\u2028", "\u0661"]
    argvs = [["update", "user", "a@example.com", "password", "random", "changepassword", "off"],
             ["create", "user", "n@example.com", "firstname", "N", "lastname", "U", "password", "S3cret pw!",
              "changepassword", "on", "notify", "b@example.com", "notifypassword", "S3cret pw!"],
             ["user", "a@example.com", "vacation", "on", "subject", "Jane has left", "message", "It's \"done\"\nbye",
              "html", "contactsonly", "false", "domainonly", "false", "start", "Started", "end", "NotSpecified"],
             ["password", "random"], ["x", "password"], ["password", "password", "random"], []]
    argvs += [argv for case in steps for s in case.get("steps", []) for argv in s["commands"]][:200]
    argvs += [[rng.choice(tokens) for _ in range(rng.randint(1, 8))] for _ in range(600)]
    command = [{"argv": a, "line": lifecycle.command_line(a)} for a in argvs]

    # check_addresses: the mock's directory as GAM prints it, then crafted records the checks turn on.
    with gam_reader() as read:
        records = [r for out in mock_outputs(mock)["print_users"] for r in read(out)]
    records += [
        {"primaryEmail": "Dee@Example.com", "name": {"givenName": "Dee", "familyName": "Dell"}, "isDelegatedAdmin": True},
        {"primaryEmail": "eve@example.com", "isAdmin": True, "isDelegatedAdmin": True, "suspended": True,
         "aliases": ["E.Ve@Example.com", "dee@example.com"]},
        {"primaryEmail": "\u212aim@example.com", "name": {"givenName": "\u212aim", "familyName": ""},
         "aliases": ["kim@example.org"]},
        {"primaryEmail": "fay@example.com", "name": {"givenName": "", "familyName": ""}},
        {"primaryEmail": "gus@example.com", "name": {"givenName": " Gus ", "familyName": "O\u2019Neil\u3000"},
         "aliases": ["carol@example.com"], "suspended": True, "isDelegatedAdmin": True},
        {"primaryEmail": "gus@example.com", "name": {"givenName": "Gus", "familyName": "Two"}},
    ]
    directory = [GAMUser.from_json(r) for r in records]
    wanted = ["carol@example.com", " CAROL@example.com ", "Carol@Example.com", "alice@example.com", "a.anders@example.com",
              "A.Anders@EXAMPLE.com", "bob@example.com", "dana@example.com", "dee@example.com", "DEE@example.com",
              "e.ve@example.com", "eve@example.com", "kim@example.com", "\u212aim@example.com", "kim@example.org",
              "fay@example.com", "gus@example.com", "nobody@example.com", "alcie@example.com", "", "\u0130@example.com"]
    admins = ["", "alice@example.com", "CAROL@example.com", "eve@example.com", "kim@example.com", "nobody@example.com"]
    check = []
    for user, manager in it.product(wanted, wanted):
        for admin in (admins if rng.random() < 0.25 else [""]):
            c = lifecycle.check_addresses(directory, user, manager, connected_admin=admin)
            check.append({"user": user, "manager": manager, "connected_admin": admin, "errors": c.errors,
                          "warnings": c.warnings, "leaver": c.user.primary_email if c.user else None,
                          "manager_found": c.manager.primary_email if c.manager else None})

    # The preview's helpers, over a stand-in holding the directory (or a delegate list) and nothing else.
    class Directory:
        async def users(self, force=False, stale_ok=False):
            return directory

    class Delegates:
        def __init__(self, answer):
            self.answer = answer

        async def list_delegates(self, email):
            if isinstance(self.answer, GAMError):
                raise self.answer
            return self.answer

    st = Directory()
    lookups = wanted + ["  ", "\u00a0carol@example.com\u3000", "external@partner.com", "[manager]"]
    names = [{"email": e, "name": asyncio.run(route._resolve_name(st, e)),
              "contact": asyncio.run(route._manager_contact(st, e))} for e in lookups]
    compose = []
    for user, manager in it.product(lookups[::2], lookups[1::2]):
        for subject, message in (("", ""), ("{employee} has left", "Please contact {manager}."), ("s", "m")):
            s, m = asyncio.run(route._compose_autoreply(st, user, manager, subject, message))
            compose.append({"user": user, "manager": manager, "subject_in": subject, "message_in": message,
                            "subject": s, "message": m})
    answers = [[], ["Alice@example.com"], ["alice@example.com", "x@example.com"], ["\u212aim@example.com"], ["ALICE@EXAMPLE.COM"],
               {"exit": 73, "stderr": "Getting all Delegates for carol@example.com\n"
                                      "User: carol@example.com, Gmail Service/App not enabled\n"},
               {"exit": 1, "stderr": "ERROR: 400: failedPrecondition - Mail service not enabled\n"},
               {"exit": 50, "stderr": "User: carol@example.com, User:, Print Failed: invalid_grant: Invalid email or User ID\n"}]
    delegate = []
    with gam_progress():   # GAM's progress lines read as the Swift GamError reads them (gam_errors.json)
        for answer in answers:
            for manager in ("alice@example.com", "kim@example.com"):
                given = GAMError.from_run(answer["exit"], answer["stderr"]) if isinstance(answer, dict) else answer
                delegate.append({"user": "carol@example.com", "manager": manager, "delegates": answer,
                                 "warning": asyncio.run(route._delegate_warning(Delegates(given), "carol@example.com",
                                                                                 manager))})
    return {"constants": {"step_names": lifecycle.STEP_NAMES, "requires": {k: list(v) for k, v in lifecycle.REQUIRES.items()},
                          "optional_steps": optional, "not_applicable_cost": lifecycle.NOT_APPLICABLE_COST,
                          "default_subject": lifecycle.DEFAULT_SUBJECT, "default_message": lifecycle.DEFAULT_MESSAGE,
                          "transfer_services": lifecycle.TRANSFER_SERVICES, "transfer_privacy": lifecycle.TRANSFER_PRIVACY},
            "steps": steps, "effective_requires": requires, "fill_autoreply": fill, "command_line": command,
            "users": records, "check_addresses": check, "names": names, "compose_autoreply": compose,
            "delegate_warning": delegate}
def onboarding_fixture(gam_error_cases: list) -> dict:
    """GamGUI's onboarding core (core/onboarding.py): the temporary password's alphabet and defaults,
    split_name, what provision_hire does for one hire (the calls it makes, in order, through a recording
    connector that runs nothing: the checklist title, the gates), the new-account waits and their words,
    step_label and waiting_note, not_ready_yet over GAM's stderr corpus (gam_errors.json's cases, by
    index) and the live lines, _signature_html, and RunbookStore's load over crafted files. Never
    constructs a default RunbookStore() or SignatureStore(), which read the operator's GamGUI data
    (failure-log 2026-09-25): each store is given a file in a temporary folder."""
    import asyncio
    import tempfile
    from types import SimpleNamespace

    from gamgui.core import onboarding
    from gamgui.core.gam.commands import GAMCommands
    from gamgui.core.gam.errors import GAMError, GAMErrorKind
    from gamgui.core.signatures import _DEFAULT_TEMPLATES, SignatureStore

    out: dict = {}
    defaults = inspect.signature(onboarding.generate_temp_password).parameters
    out["password"] = {"alphabet": onboarding._PW_ALPHABET, "groups": defaults["groups"].default,
                       "size": defaults["size"].default}

    # split_name: curated, then every character str.isspace() holds as a separator, edge and inside.
    spaces = [chr(c) for c in range(0x110000) if chr(c).isspace()]
    triples = [("Ada", "", ""), ("Ada Byte", "", ""), ("Ada  Lovelace Byte", "", ""), ("", "Ada", "Byte"),
               ("Jordan Lee", "J", ""), ("Jordan Lee", "", "L"), (" Ada ", " ", " "), ("", "", ""), ("   ", "", ""),
               ("Zo\u00eb \u00c5ngstr\u00f6m", "", ""), ("Ada\u200bByte", "", ""), ("{name} [[x]]", "", ""),
               ("Ada", " Ada ", ""), ("O'Neil Mc Byte", "", "")]
    triples += [(f"{w}A{w}B{w}{w}C{w}", "", "") for w in spaces]
    triples += [("Ada Byte", f"{w}Ad{w}", f"{w}By{w}") for w in spaces]
    out["split_name"] = [{"name": n, "first": f, "last": l, "split": list(onboarding.split_name(n, f, l))}
                         for n, f, l in triples]

    out["waits"] = list(onboarding.NEW_ACCOUNT_WAITS)
    out["not_ready_reason"] = onboarding.NOT_READY_REASON
    out["stopped_reason"] = onboarding.STOPPED_REASON

    parked = [{"what": "signature", "email": "jordan@example.com", "name": "Classic"},
              {"what": "calendar", "email": "jordan@example.com", "calendar": "team@group.calendar.google.com"},
              {"what": "tasks", "email": "it@example.com", "title": "Onboard Jordan Lee \u2014 Sales", "steps": ["A"]},
              {"what": "signature", "email": "zo\u00eb@example.com", "name": "\u201cQuoted\u201d"},
              {"what": "calendar", "email": "x@example.com", "calendar": ""}]
    out["step_label"] = [{"step": step, "label": onboarding.step_label(step)} for step in parked]
    sig, cal, tasks = parked[0], parked[1], parked[2]
    lists = [[sig], [cal], [cal, cal], [sig, cal, tasks], [tasks], [cal, sig, cal, cal, tasks], [tasks, sig], [cal, tasks]]
    out["waiting_note"] = [{"steps": [s["what"] for s in steps], "note": onboarding.waiting_note(steps)} for steps in lists]

    # not_ready_yet over the classifier's own corpus (by index into gam_errors.json), then the live lines
    # and their case and fold variants.
    flags = [onboarding.not_ready_yet(GAMError.from_run(c["exit_code"], c["stderr"])) for c in gam_error_cases]
    extra = [(50, "User: new@example.com, User Set Failed: access_denied: Requested client not authorized\n"),
             (73, "User: new@example.com, Calendar Service/App not enabled\n"),
             (50, "User: new@example.com, Tasklist Create Failed: access_denied: REQUESTED CLIENT NOT AUTHORIZED\n"),
             (50, "User: new@example.com, Task Create Failed: reque\u017fted client not author\u0130zed\n"),
             (50, "User: new@example.com, User Set Failed: access_denied: Requested  client not authorized\n"),
             (1, "ERROR: Calendar not enabled. Please run\n"),
             (None, "User: new@example.com, User Set Failed: access_denied: Requested client not authorized\n"),
             (50, "User: new@example.com, Gmail Service/App not enabled\n"),
             (50, "User: a@example.com, Calendar: c, Add Failed: Not Found\n"),
             (57, "User: a@example.com, Create Failed: Duplicate, User: a@example.com\n")]
    out["not_ready"] = {"gam_error_cases": len(gam_error_cases),
                        "not_ready_indices": [i for i, flag in enumerate(flags) if flag],
                        "extra": [{"exit_code": code, "stderr": text,
                                   "not_ready": onboarding.not_ready_yet(GAMError.from_run(code, text))} for code, text in extra]}

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        templates = dict(_DEFAULT_TEMPLATES)
        templates.update({"Empty": "", "Optional": "[[{title}]]", "Tokens": "{first}|{last}|{name}|{email}|{ou}|{phone}"})
        (root / "signatures.json").write_text(json.dumps({"templates": templates}))
        signatures = SignatureStore(root / "signatures.json")
        assert signatures.names() == sorted(templates), "the temporary signature store didn't load"

        people = [("jordan@example.com", "Jordan", "Lee"), ("ada@example.com", "", ""), ("zo\u00eb@example.com", "Zo\u00eb", "e\u0301"),
                  ("x@example.com", "{phone}", "[[x]]"), ("y@example.com", "Ann", ""), ("z@example.com", "", "Byte")]
        out["signature_html"] = []
        for name in sorted(templates) + ["Missing", ""]:
            cfg = onboarding.RoleTemplate("Sales", ["A"], signature=name)
            for email, first, last in people:
                out["signature_html"].append({"template": name, "email": email, "first": first, "last": last,
                                              "html": onboarding._signature_html(signatures, cfg, email, first, last)})

        # What provision_hire does for one hire: each call in order, as the argv GamGUI's builder makes.
        class Recorder:
            def __init__(self, create_ok: bool = True):
                self.calls, self.create_ok = [], create_ok

            def _ok(self, ok: bool = True):
                kind = None if ok else GAMErrorKind.UNKNOWN
                return SimpleNamespace(ok=ok, kind=kind, detail="" if ok else "GAM failed", remediation="")

            async def create_user(self, email, first, last, password, change_password=True, org_unit=None, notify=None):
                self.calls.append(GAMCommands.create_user(email, first, last, password, change_password, org_unit, notify))
                return self._ok(self.create_ok)

            async def set_signature(self, email, signature, html=True):
                self.calls.append(GAMCommands.set_signature(email, signature, html=html))
                return self._ok()

            async def add_group_member(self, group, member, role="member"):
                self.calls.append(GAMCommands.add_group_member(group, member, role=role))
                return self._ok()

            async def subscribe_calendar_for(self, email, calendar_id):
                self.calls.append(GAMCommands.subscribe_calendar(email, calendar_id))
                return self._ok()

            async def create_onboarding_runbook(self, assignee, title, steps):
                self.calls.append(GAMCommands.create_tasklist(assignee, title))
                self.calls += [GAMCommands.create_task(assignee, "TASKLIST_ID", step) for step in steps]
                return {"tasklist_id": "TASKLIST_ID", "created": len(steps), "failed": [], "total": len(steps)}

        roles = {
            "Sales": {"steps": ["Set up the CRM login", "Order a laptop"], "signature": "Classic", "org_unit": "/Sales",
                      "groups": ["sales@example.com", "staff@example.com"], "calendars": ["team@group.calendar.google.com"]},
            "Warehouse": {"steps": ["Badge"], "signature": "", "org_unit": "", "groups": [], "calendars": []},
            "Gone": {"steps": ["A", "B", "C"], "signature": "Missing", "org_unit": "Warehouse/Night",
                     "groups": ["wh@example.com"], "calendars": ["c1@group.calendar.google.com", "c2@group.calendar.google.com"]},
            "Empty": {"steps": ["A"], "signature": "Empty", "org_unit": "root", "groups": [], "calendars": []},
            "Optional": {"steps": ["A"], "signature": "Optional", "org_unit": "/", "groups": ["g@example.com"], "calendars": []},
        }
        hires = [
            {"name": "Jordan Lee", "email": "jordan@example.com", "assignee": "", "create_account": True, "first": "", "last": ""},
            {"name": "Jordan Lee", "email": "jordan@example.com", "assignee": "it@example.com", "create_account": True,
             "first": "Jo", "last": "Lee-Smith"},
            {"name": "Sam Rivers", "email": "sam@example.com", "assignee": "", "create_account": False, "first": "", "last": ""},
            {"name": "", "email": "", "assignee": "it@example.com", "create_account": False, "first": "", "last": ""},
            {"name": "", "email": "x@example.com", "assignee": "", "create_account": False, "first": "", "last": ""},
            {"name": "  Zo\u00eb  \u00c5ngstr\u00f6m ", "email": "zoe@example.com", "assignee": "", "create_account": True,
             "first": "", "last": ""},
        ]
        store = onboarding.RunbookStore(root / "onboarding.json")
        real = onboarding.generate_temp_password
        onboarding.generate_temp_password = lambda groups=3, size=4: "PASSWORD"
        try:
            out["provision"] = []
            for role_name, role in roles.items():
                cfg = onboarding.RoleTemplate(role_name, role["steps"], role["signature"], role["org_unit"], role["groups"],
                                              role["calendars"])
                for hire in hires:
                    for create_ok in ([True, False] if hire["create_account"] else [True]):
                        conn = Recorder(create_ok)
                        row = {**hire, "role": role_name, "manager": "", "send_welcome": False, "notify": ""}
                        res = asyncio.run(onboarding.provision_hire(conn, signatures, store, cfg, row))
                        out["provision"].append({"role": {"name": role_name, **role}, "hire": hire, "create_ok": create_ok,
                                                 "calls": conn.calls,
                                                 "credential_org_unit": (res["credential"] or {}).get("org_unit")})
        finally:
            onboarding.generate_temp_password = real
        assert not (root / "onboarding.json").exists(), "provision_hire wrote the temporary role store"

        # RunbookStore's load over crafted files: what it migrates, and which it can't read (it falls back
        # to its seed then, which the native reader reports instead). The seed is swapped for a marked copy
        # while loading, so a fallback is told from a file that happens to equal it.
        files = [
            '{"roles": {"Sales": ["Set up POS", "Order a laptop"]}}',
            '{"roles": {"Sales": {"steps": ["a"], "signature": "Classic"}}, "welcomes": {"Default": {"subject": "S", "body": "B"}}}',
            '{"roles": {"Warehouse": {"steps": ["Badge"], "groups": "wh@example.com\\n\\n  staff@example.com \\n", "calendars": null}},'
            ' "welcome": {"subject": "Hi {name}", "body": "Welcome"}}',
            '{"roles": {}, "welcome": {"subject": "old"}, "welcomes": {"Default": {"subject": "new", "body": "b"}}}',
            '{"welcome": "text"}',
            '{"roles": {"A": 5, "B": null, "C": "steps", "D": {"steps": "abc", "signature": 0, "org_unit": true,'
            ' "groups": ["a@x.com", 7, null, " ", 2.5], "calendars": {"cal1": 1, "cal2": 2}, "welcome": 3.5}},'
            ' "welcomes": {"W": "x", "V": {"subject": null, "body": 12}}}',
            '{"roles": {"b": [], "B": [], "\u00e9": [], "e\u0301": [], "a": ["x"], "a ": ["y"]}}',
            '{"roles": {"A": ["x"], "A": ["y"], "B": ["z"]}}',
            '{"roles": {"A": [1, 2.50, 1E2, true, false, null, "s", -0, 1e400]}}',
            '{"roles": {"A": {"steps": ["x"]}}, "welcomes": []}',
            '{"roles": {"A": {"steps": ["x"], "groups": "a@x.com\\r\\nb@x.com\\u2028c@x.com"}}, "version": 7}',
            '{"roles": {"A": {"steps": {"k1": 1, "k2": 2}, "calendars": "", "signature": "", "welcome": ""}}}',
            '{"roles": {"A": {"steps": [], "org_unit": "  /Sales  ", "groups": [], "calendars": []}}}',
            # GamGUI can't read these: it falls back to its seed.
            '{"roles": ', '[]', '{"roles": []}', '{"roles": null}', '{"roles": {"A": {"steps": null}}}',
            '{"roles": {"A": {"steps": [], "groups": 5}}}', '{"roles": {"A": {"steps": 3}}}', '', 'null',
            '\ufeff{"roles": {}}', '{"roles": {"A": {"steps": [], "calendars": true}}}',
        ]
        out["load"] = []
        seed = onboarding._DEFAULT
        for text in files + [bytes([0x7B, 0xFF, 0x7D])]:
            path = root / "load.json"
            path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
            onboarding._DEFAULT = {**json.loads(json.dumps(seed)), "__seed__": True}
            try:
                loaded = onboarding.RunbookStore(path)
            finally:
                onboarding._DEFAULT = seed
            case = {"hex": text.hex()} if isinstance(text, bytes) else {"text": text}
            if "__seed__" in loaded._data:
                case["unreadable"] = True
            else:
                case["roles"] = [{"name": r.name, "steps": r.steps, "signature": r.signature, "org_unit": r.org_unit,
                                  "groups": r.groups, "calendars": r.calendars, "welcome": r.welcome} for r in loaded.roles()]
                case["welcomes"] = [[name, w["subject"], w["body"]] for name, w in loaded._data["welcomes"].items()]
            out["load"].append(case)
            path.unlink()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gamgui", default=str(ROOT.parent / "gamgui"), help="path to the GamGUI checkout")
    ap.add_argument("--gam-binary", default=str(ROOT / "Vendor" / "gam7" / "gam"))
    args = ap.parse_args()
    gamgui = Path(args.gamgui).resolve()
    sys.path.insert(0, str(gamgui))

    # Before anything is written: the build must still write GAM_DIALECT's CSV.
    from tests.test_gam_exit_codes import _gam_module_code

    blob = Path(args.gam_binary).read_bytes()
    code = _gam_module_code(blob)
    gam_dialect_in_build(blob, code)

    from gamgui.core.catalog import parser as catalog_parser
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
        | {"PY_WHITESPACE": [ord(c) for c in PY_WHITESPACE]}
        # The catalog's verb rule (invariant 3), which CommandKindTests holds every GamRead to.
        | {"CATALOG_READ_VERBS": sorted(catalog_parser._READ),
           "CATALOG_DESTRUCTIVE_VERBS": sorted(catalog_parser._DESTRUCTIVE),
           "CATALOG_LOW_VERBS": sorted(catalog_parser._LOW)},
        "cases": unique,
        "defaults": defaults,
    }
    # The vendored grammar's definitions the Swift tests check against (Vendor/gam7 isn't in the repo, and CI runs
    # the package tests before it fetches GAM).
    grammar = Path(args.gam_binary).with_name("GamCommands.txt").read_text(encoding="utf-8")
    argv_doc["constants"]["GRAMMAR_CALENDAR_ACL_ROLES"] = re.findall(r"<CalendarACLRole> ::=\s*(\S+)", grammar)
    if len(argv_doc["constants"]["GRAMMAR_CALENDAR_ACL_ROLES"]) < 3:
        raise SystemExit("the grammar's <CalendarACLRole> definitions weren't found")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "argv.json").write_text(json.dumps(argv_doc, indent=1, ensure_ascii=False) + "\n")
    covered = {c["builder"] for c in unique}
    print(f"argv.json: {len(unique)} cases over {len(covered)}/{len(builders)} builders")

    # Exit codes: the build's *_RC table, read like tests/test_gam_exit_codes.py's build_rc fixture.
    from gamgui.core.setup import CHECK_ANSWER_RCS, OAUTH2SERVICE_JSON_REQUIRED_RC, SCOPES_NOT_AUTHORIZED_RC
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

    # GAM's failures, classified and scrubbed as GamGUI does. ASCII-escaped: it holds the invisible
    # characters scripts/check_text.py refuses in a tracked file.
    errors_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | errors_fixture()
    (OUT / "gam_errors.json").write_text(json.dumps(errors_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_errors.json: {len(errors_doc['cases'])} cases")

    # GAM's output, read into records as GamGUI reads it (its CSV in GAM's dialect). ASCII-escaped, like
    # gam_errors.json.
    output_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | output_fixture(OUT / "mock_gam.sh")
    (OUT / "gam_output.json").write_text(json.dumps(output_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_output.json: {len(output_doc['cases'])} cases")

    # Records read into users, groups and members, as GamGUI's models read them.
    models_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | models_fixture(OUT / "mock_gam.sh")
    (OUT / "gam_models.json").write_text(json.dumps(models_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_models.json: {sum(len(models_doc[k]) for k in ('users', 'groups', 'members', 'calendar_acls', 'user_calendars', 'resources'))} records")

    # The destructive-operation guard: what a change set needs, and whether a confirmation is enough.
    guard_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | guard_fixture()
    (OUT / "guard.json").write_text(json.dumps(guard_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"guard.json: {len(guard_doc['cases'])} cases")

    # The audit log: the line each record writes, and the records a reader finds across generations.
    audit_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | audit_fixture()
    (OUT / "audit.json").write_text(json.dumps(audit_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"audit.json: {len(audit_doc['written'])} records, {len(audit_doc['records'])} read back")

    # The directory's reports over those users, as GamGUI's Home and Reports count them.
    reports_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | reports_fixture(OUT / "mock_gam.sh")
    (OUT / "reports.json").write_text(json.dumps(reports_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"reports.json: {len(reports_doc['records'])} users")

    # The Audit screen: its filter, pages and CSV export over a log of odd records.
    audit_screen_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | audit_screen_fixture()
    (OUT / "audit_screen.json").write_text(json.dumps(audit_screen_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"audit_screen.json: {audit_screen_doc['read']} records, {len(audit_screen_doc['pages'])} pages")

    # The usage report: GAM's CSV after its progress, the rows parsed, and the dates the walk back asks for.
    usage_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | usage_fixture(OUT / "mock_gam.sh")
    (OUT / "usage_report.json").write_text(json.dumps(usage_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"usage_report.json: {len(usage_doc['walks'])} walks")

    # The guided setup: the delegation step's facts and link, and the fresh-setup Terminal commands.
    setup_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | setup_fixture()
    (OUT / "setup.json").write_text(json.dumps(setup_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"setup.json: {len(setup_doc['facts'])} facts, {len(setup_doc['setup_commands'])} command sets")

    # The auto-reply: show vacation's text, and the HTML body to and from the operator's text.
    vacation_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | vacation_fixture(OUT / "mock_gam.sh")
    (OUT / "vacation.json").write_text(json.dumps(vacation_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"vacation.json: {len(vacation_doc['autoreply_text'])} bodies, {len(vacation_doc['unescape'])} references")

    # Signatures: GamGUI's render, curly-quote check and show-signature reader, and GAM's own handling of
    # the signature argument, run from the build.
    signature_doc = {"source": {"gamgui_commit": commit, "gam_version": EXPECTED_GAM_VERSION,
                                "generator": "scripts/gen_fixtures.py"}} | signature_fixture(OUT / "mock_gam.sh", code)
    (OUT / "signatures.json").write_text(json.dumps(signature_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"signatures.json: {len(signature_doc['render'])} renders, {len(signature_doc['parse_signature'])} shown texts")

    # Offboarding: GamGUI's routine and its preview's checks and words.
    offboarding_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | offboarding_fixture(OUT / "mock_gam.sh")
    (OUT / "offboarding.json").write_text(json.dumps(offboarding_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"offboarding.json: {len(offboarding_doc['steps'])} routines, {len(offboarding_doc['check_addresses'])} "
          f"address checks")
    # Onboarding: GamGUI's core for one hire, the new-account wait's words and test, and its role file's
    # load, never over the operator's own stores.
    onboarding_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | onboarding_fixture(errors_doc["cases"])
    (OUT / "onboarding.json").write_text(json.dumps(onboarding_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"onboarding.json: {len(onboarding_doc['provision'])} hires, {len(onboarding_doc['load'])} role files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
