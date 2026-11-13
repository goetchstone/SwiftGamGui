#!/usr/bin/env python3
"""Generate the parity fixtures SwiftGamGui's tests hold the Swift code to.

GamGUI (the Python app) is the parity reference (invariant 11), read at a pinned commit:

  Tests/Fixtures/argv.json        every GAMCommands builder, called over GamGUI's own test inputs
                                  (the grammar contract's enumeration, the mock tests' concrete calls)
                                  plus deterministic edge cases from its property-test specs. Each case
                                  records the full keyword arguments and either the argv or the error.
  Tests/Fixtures/gam_errors.json  GamGUI's classification, message and scrubbing of failed GAM runs
                                  (core/gam/errors.py) over its own and generated stderr, with the
                                  Unicode tables its regexes use.
  Tests/Fixtures/gam_output.json  GamGUI's parse_records over the mock's output for every read, its
                                  property tests' JSON/CSV shapes and noise, and the inputs its
                                  failure log names, CSV read in GAM's dialect.
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
  Tests/Fixtures/roster.json      GamGUI's roster reader (read_upload) over the packages its tests build and more:
                                  every refusal in its words, or the snapshot and its issues. The inputs are kept as
                                  base64, with any cap a case lowers; a case marked `swift` is a listed deviation.
  Tests/Fixtures/roster_plan.json GamGUI's change list (roster_plan.plan) over every call its planner tests make and the
                                  web tests' compare: each call's inputs and its ChangeList (changes, counts, flags, notes,
                                  summary), with what roster_handover hands over for it; alias_for and managed_from too.
  Tests/Fixtures/roster_handover.json and handover/  GamGUI's hand-over files for its byte test's list (handover/ equals
                                  GamGUI's own tests/fixtures/handover byte for byte), each step's gam csv line, and the
                                  files for a list of values Python's csv writer treats specially.
  Tests/Fixtures/exit_codes.json  the vendored GAM build's *_RC exit-code table, read from the binary,
                                  plus GamGUI's own constants that branch on it.

Run it with GamGUI's virtualenv Python (it imports GamGUI's package and test modules, read-only;
nothing is written into GamGUI):

    ../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py [--gamgui ../gamgui] [--gam-python python3.X]

What GAM itself does (its exit codes, its CSV, its signature functions) is asked of scripts/gam_oracle.py,
run under the build's own Python, the only one its bytecode loads in: `python3.X` on the PATH for the build's
3.X, or --gam-python. Nothing is written until the build's Python has written every CSV here the same.

Re-run on every GAM bump (scripts/bump_gam.py does).
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import dataclasses
import functools
import importlib.util
import inspect
import io
import itertools
import json
import re
import shutil
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

def _load_oracle():
    """scripts/gam_oracle.py as a module, for what runs under any Python: GAM_DIALECT, build_python, gam_csv."""
    spec = importlib.util.spec_from_file_location("gam_oracle", ROOT / "scripts" / "gam_oracle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ORACLE = _load_oracle()
# How GAM writes every CSV (one home: scripts/gam_oracle.py, which refuses a build where it moved). CPython's
# writer in this dialect doubles each backslash in a value and quotes a value holding a comma, quote, CR or LF.
GAM_DIALECT = ORACLE.GAM_DIALECT
# Every CSV gam_csv wrote, as (rows, text): before any fixture is written, the build's own Python writes the same
# rows and must give the same bytes (`csv_as_the_build_writes`).
CSV_WRITTEN: list = []


def gam_csv(rows) -> str:
    """Rows as GAM prints them: this Python's writer in GAM's dialect, checked against the build's at the end."""
    rows = [list(row) for row in rows]
    text = ORACLE.gam_csv(rows)
    CSV_WRITTEN.append((rows, text))
    return text


class GamOracle:
    """scripts/gam_oracle.py under the build's own Python: what the vendored GAM itself does."""

    def __init__(self, gam: Path, python: str | None):
        self.gam = gam
        self.version = ORACLE.build_python(gam.read_bytes())
        self.python = python or shutil.which(f"python{self.version}")
        if not self.python:
            raise SystemExit(f"GAM's build is Python {self.version}'s, and no python{self.version} is on the PATH: "
                             f"install it, or pass --gam-python")

    def ask(self, request: dict) -> dict:
        run = subprocess.run([self.python, "-I", "-B", str(ROOT / "scripts" / "gam_oracle.py"), str(self.gam)],
                             input=json.dumps(request), capture_output=True, text=True)
        if run.returncode != 0:
            raise SystemExit(run.stderr.strip() or f"gam_oracle.py exited {run.returncode}")
        return json.loads(run.stdout)


def csv_as_the_build_writes(oracle: GamOracle) -> None:
    """Refuse fixtures whose CSV the build's own Python writes otherwise: GamGUI's Python wrote them."""
    written = oracle.ask({"csv": [rows for rows, _ in CSV_WRITTEN]})["csv"]
    for (rows, text), theirs in zip(CSV_WRITTEN, written, strict=True):
        if text != theirs:
            raise SystemExit(f"CPython {oracle.version}'s csv writes {theirs[:80]!r} where this Python's writes "
                             f"{text[:80]!r}: read the new writer, then update the Swift reader and the mock's gam_cell")


# GAM 7.48.22's progress lines (show_gettings, on by default): every one its printers write starts with
# Msg.GETTING or Msg.GOT and a count (gam/__init__.py:2681-2722, the page counts :2736-2763), and no error it
# writes starts with "Getting " (those start "ERROR:", "WARNING:" or an entity's name).
GAM_PROGRESS = r"(Getting |Got \d+ )"


def parse_records(text: str) -> list:
    """GamGUI's reader of GAM's output (core/gam/parser.py), as the pinned commit has it."""
    from gamgui.core.gam.parser import parse_records as read

    return read(text)


def require_gamgui_reads_gam() -> None:
    """Refuse a GamGUI pin that misreads GAM where the Swift app reads it right. Until 487be35 the generator patched
    three GamGUI readings in memory and kept GamGUI's own beside each case it read differently: CSV without GAM's
    backslash escape (failure-log 2026-10-10), only "Getting all " as progress, and GAM's command echo as the
    failure (both 2026-10-13). GamGUI fixed all three (its #67 and the 2026-10-30/31 failure-log entries), so the
    fixtures are GamGUI's own reading, and a pin from before the fixes is refused rather than patched."""
    from gamgui.core.gam import errors, parser

    # The record {"a": 'x\"'} as GAM prints it: its JSON's three backslashes doubled, each quote doubled.
    escaped = "primaryEmail,JSON\n" + r'a@example.com,"{""a"": ""x\\\\\\""""}"' + "\n"
    if parser.parse_records(escaped) != [{"primaryEmail": "a@example.com", "a": 'x\\"'}]:
        raise SystemExit("this GamGUI reads GAM's CSV without its escape character: pin a commit from #67 on")
    if errors._PROGRESS_LINE.pattern != GAM_PROGRESS:
        raise SystemExit(f"this GamGUI's progress rule is {errors._PROGRESS_LINE.pattern!r}, not GAM's {GAM_PROGRESS!r}")
    if not getattr(errors, "_FRAMING_LINE", None) or not errors._FRAMING_LINE.match("Command: gam info user >>>x<<<"):
        raise SystemExit("this GamGUI reads GAM's command echo as the failure: pin a commit from 2026-10-31 on")


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
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        # GamGUI's typed values (MessageId, Phone): their fields by name, as the Swift adapter reads them.
        return {f.name: jsonable(getattr(value, f.name)) for f in dataclasses.fields(value)}
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
    if kind == "OneOfStrategy":
        # Each branch's values, in order, once (print_courses' teacher: none, or one address).
        out = []
        for branch in inner.original_strategies:
            out += [v for v in strategy_values(branch) if v not in out]
        return out
    if kind == "IntegersStrategy":
        # A bounded count (trash_message's copies, 1 to 9): both ends, so the Swift builder is held at each.
        if inner.start is None or inner.end is None:
            raise SystemExit("unbounded st.integers in a Spec: give it bounds, or name the values here")
        return sorted({inner.start, inner.end})
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
    """GamGUI's GAMError.from_run over GAM's
    known stderr lines and their case, indent and counter variants, mixed stderrs, progress chatter in each
    shape GAM prints it and instructions, timeouts, missing-scope lines, echoed passwords, Unicode and
    boundary edges, and seeded random text: what the Swift GamError must say."""
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
        err = GAMError.from_run(exit_code, stderr, argv, stdout=stdout)
        ours = read(err)
        return {"exit_code": exit_code, "stderr": stderr, "argv": argv, "stdout": stdout,
                "kind": ours["kind"], "kinds": ours["kinds"], "message": ours["message"],
                "scrubbed_stderr": err.stderr, "scrubbed_stdout": err.stdout, "redacted_argv": err.argv,
                "remediation_suffix": ours["remediation_suffix"]}

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
    # GAM's entityDoesNotExistExit (gam/__init__.py:800-805 at 7.48.22): the command echoed with the address that
    # isn't one marked, then ERROR and the entity, ENTITY_DOES_NOT_EXIST_RC. A transfer to or from a non-user ends
    # this way (convertEmailAddressToUID, :5997-6013).
    from tests.test_props_errors import _quoted
    for argv, at, entity in (
            (["gam", "create", "datatransfer", "nobody@example.com", "drive,calendar", "alice@example.com", "all"], 3, "User"),
            (["gam", "create", "datatransfer", "carol@example.com", "drive,calendar", "sales@example.com", "all"], 5, "User"),
            (["gam", "user", "x@example.com", "add", "delegate", "Not Found 404"], 5, "User")):
        echo = f"Command: {_quoted(argv[:at])} >>>{_quoted([argv[at]])}<<< {_quoted(argv[at + 1:])}"
        cases.append(run(56, f"{echo}\n\nERROR: {entity}: {argv[at]}, Does not exist\n\n", argv))

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

    # Whether a `print courses … owneremail` exit 56 is only unknown owners (only_unknown_owners, #113): GamGUI's own
    # cases and their neighbours.
    from gamgui.core.gam.errors import only_unknown_owners
    warn = "Course: 500000000004, Owner ID: 100000000000000000009, Does not exist"
    owner_stderrs = [
        warn, f"Getting all Courses that match query ()\n{warn} (1/2)\n", "", "   \n", f"{warn}\nTeacher: nobody@example.com, Does not exist",
        "Course: 999, Does not exist", f"{warn} (1/2) extra", f"  {warn} (3/40)  ", f"{warn} (1/)", f"{warn} (/2)", f"{warn}(1/2)",
        f"{warn} (" + chr(0x661) + "/" + chr(0x662) + ")", "Course: x1, Owner ID: 9, Does not exist",
        "Course: 1,2, Owner ID: 9, Does not exist", "Course: , Owner ID: 9, Does not exist", "Course: 1, Owner ID: , Does not exist",
        "course: 1, Owner ID: 9, Does not exist", "Course: 1, Owner ID: 9, does not exist", f"{warn}\r\n{warn} (2/2)",
        f"Command: gam print courses\n{warn}", f"ERROR: x\n{warn}", f"{warn}\nPlease run",
        "Course: 1, Owner ID: 9, Owner ID: 8, Does not exist", "Course: \u00e9t\u00e9, Owner ID: 9\u200b, Does not exist"]
    owners = [{"stderr": e, "only_unknown_owners": only_unknown_owners(e)} for e in owner_stderrs]

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
        "only_unknown_owners": owners,
    }


def output_fixture(mock: Path, oracle: GamOracle) -> dict:
    """GamGUI's parse_records, reading CSV in GAM's dialect, over GAM's output shapes: what
    the strict mock prints for every read the app makes; the JSON, CSV and formatjson shapes and the noise
    GamGUI's property tests generate (drawn deterministically, the CSV ones as GAM prints them); the
    inputs its failure log names (a long cell, a bare CR, deep nesting, raw line separators in NDJSON, an
    empty header) with JSON's and CSV's own edges; and GAM's escaping. The records are stored as Python's
    json.dumps text, NaN and Infinity included."""
    from hypothesis import HealthCheck, Phase, given, seed, settings
    from hypothesis import strategies as st

    from gamgui.core.gam.parser import parse_records
    from tests import test_props_parsing as props

    cases = []

    def add(stdout: str) -> None:
        cases.append({"stdout": stdout, "records": json.dumps(parse_records(stdout), ensure_ascii=True)})

    def as_gam_prints(draw) -> str:
        """A drawn CSV, which GamGUI's strategies write as GAM prints it (its _gam_csv, GAM's escape character
        included). Read back it must give the draw's own records, an oracle the reader didn't make."""
        text, expected = draw
        if parse_records(text) != expected:
            raise SystemExit(f"a draw printed as GAM prints it reads back wrong: {text[:80]!r}")
        return text

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
                             "source": "GAM's setDialect with csv_output_no_escape_char off (gam_oracle.py checks the "
                                       f"build), written by CPython {sys.version_info[0]}.{sys.version_info[1]}'s csv "
                                       f"module and byte for byte by the build's CPython {oracle.version}'s"}
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

    reads = dict(READS)

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
        for builder, argvs in reads.items():
            for argv in argvs:
                run = subprocess.run([str(mock), *argv], capture_output=True, text=True, env=environment)
                if builder in NOT_MODELLED:
                    if run.returncode != 2 or "isn't modelled" not in run.stderr:
                        raise SystemExit(f"the mock answered a read it doesn't model: {argv}")
                    continue
                if run.returncode != 0:
                    raise SystemExit(f"the mock refused a read (exit {run.returncode}): {argv}\n{run.stderr[-600:]}")
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
    records = {name: [r for out in found for r in parse_records(out)] for name, found in outputs.items()}
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
    records = [r for out in mock_outputs(mock)["print_users"] for r in parse_records(out)]
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
    mocked = parse_records(gam_connector._csv_from(report))
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
            with patching.patch.object(gam_connector, "datetime", clock):
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
    # Whether the admin token reads Classroom (classroom_readable, C1.4): False only on a token known to lack its scopes.
    from gamgui.core.classroom import CLASSROOM_SCOPES
    from gamgui.core.secrets.vault import InMemoryBackend, SecretsVault
    every = [scope for scope, _, _ in CLASSROOM_SCOPES]
    readable_jsons = oauth_jsons + [
        _json.dumps({"scopes": every}), _json.dumps({"scopes": [s + ".readonly" for s in every]}),
        _json.dumps({"scopes": every[:2]}), _json.dumps({"scopes": [every[0], every[1] + ".readonly", every[2], 7, None]}),
        _json.dumps({"scopes": [every[0] + ".READONLY", every[1], every[2]]}), _json.dumps({"scopes": {"a": every}}),
        _json.dumps({"scopes": None}), "[]", _json.dumps([{"scopes": every}])]
    classroom = []
    for oauth in readable_jsons:
        vault = SecretsVault(InMemoryBackend())
        if oauth:
            vault.set("example.com", "oauth2", oauth)
        classroom.append({"oauth2": oauth, "readable": setup.classroom_readable(vault, "example.com")})
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
            "facts": facts, "user_security": security, "classroom_readable": classroom, "setup_commands": commands}


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


def signature_fixture(mock: Path, oracle: GamOracle) -> dict:
    """GamGUI's signature helpers (core/signatures.py) and its reader of `show signature`
    (gam_connector._parse_signature), and what the vendored GAM does with a signature argument, from its
    own functions (scripts/gam_oracle.py): _processSignature, the stored form, and checkArgumentPresent over
    SORF_FILE_ARGUMENTS, the bodies it reads as a file or document keyword. Never constructs a SignatureStore, which reads the
    operator's GamGUI data by default (failure-log 2026-09-25)."""
    import random
    import subprocess
    import tempfile

    from gamgui.core import signatures
    from gamgui.core.connectors.gam_connector import _parse_signature
    from gamgui.core.gam.models import GAMUser
    from gamgui.core.gam.runner import strip_cfgdir_noise

    # The people a template renders for: the mock's directory as GAM prints it, then crafted records.
    records = [r for out in mock_outputs(mock)["print_users"] for r in parse_records(out)]
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

    # GAM's own handling of the signature argument, from the build.
    bodies = [t["template"] for t in render[:400]] + [r["out"] for r in render[:400]]
    bodies += ["\\n", "a\\nb", "\\\\n", "\\\rn", "a\r\nb\rc\n", "\\N", "\\\n", "<br/>", ""]
    words = ["File", " file ", "\tHTML_FILE\n", "g_doc", "G_C_S_HTML", "_ file", "file_ ", "html",
             "sig", "files", "file.html", "\u00a0gdoc\u3000", "\u212aile", "f\u0130le", "\u017fig",
             "GDOC", "gdoc\u200b", "fi le", "\u2028textfile\u2029", "file\x1c", "\x1ffile"]
    gam = oracle.ask({"signature": {"bodies": bodies, "words": words + bodies[:50]}})["signature"]
    keywords = gam["file_arguments"]
    stored = [{"body": b, "stored": out} for b, out in zip(bodies, gam["stored"], strict=True)]
    keyword = [{"body": w, "keyword": k} for w, k in zip(keywords + words + bodies[:50], gam["keyword"], strict=True)]
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
    command lines), effective_requires over every left-out set that can change it, fill_autoreply, command_line,
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

    # effective_requires reads a left-out set only for steps another step requires (`req in not_applicable`), so
    # leaving any other out can't change it: every key over every set of the required ones covers every left-out
    # set (14 steps x 2**14 was 52 MB). A step that comes to be required joins `required` by itself.
    required = [k for k in keys if any(k in reqs for reqs in lifecycle.REQUIRES.values())]
    requires = [{"key": k, "not_applicable": na, "requires": list(lifecycle.effective_requires(k, frozenset(na)))}
                for k in keys for na in subsets(required)]

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
    records = [r for out in mock_outputs(mock)["print_users"] for r in parse_records(out)]
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
    # and their case and fold variants, read with GAM's progress lines as progress, as gam_errors.json is
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

            async def send_welcome_email(self, to, subject, body):
                self.calls.append(GAMCommands.send_email(to, subject, body))
                return self._ok()

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
            # The welcome email (W): the hire's held welcome, rendered for them, sent last, only with an address.
            welcomes = {"Default": onboarding._DEFAULT["welcomes"]["Default"],
                        "Contractor": {"subject": "Hi {name} \u2014 {role}",
                                       "body": "Line one {email}\n\nAsk {manager} or {nobody} {{name}}\r\nBye <b>&"}}
            out["welcome_provision"] = []
            for role_name in ("Sales", "Warehouse"):
                role = roles[role_name]
                for welcome_name in ("", "Contractor"):
                    cfg = onboarding.RoleTemplate(role_name, role["steps"], role["signature"], role["org_unit"],
                                                  role["groups"], role["calendars"], welcome_name)
                    for hire in hires[:4]:
                        conn = Recorder(True)
                        held = welcomes[welcome_name or "Default"]
                        row = {**hire, "role": role_name, "manager": "boss@example.com", "send_welcome": True, "notify": "",
                               "welcome": held}
                        asyncio.run(onboarding.provision_hire(conn, signatures, store, cfg, row))
                        out["welcome_provision"].append({"role": {"name": role_name, **role, "welcome": welcome_name},
                                                         "hire": hire, "manager": "boss@example.com", "welcome": held,
                                                         "calls": conn.calls})
        finally:
            onboarding.generate_temp_password = real
        assert not (root / "onboarding.json").exists(), "provision_hire wrote the temporary role store"

        # render: GamGUI's {token} substitution (one pass, WELCOME_VARS only, Unicode \\w), over curated and seeded
        # templates, with values that hold tokens themselves.
        import random as _random
        ctx = onboarding.welcome_context("Zo\u00eb {role}", "zoe@example.com", "Sales {name}", "")
        pieces = ["{name}", "{role}", "{email}", "{manager}", "{nobody}", "{", "}", "{{", "}}", "{na", "me}", "{n\u00e0me}",
                  "{name\u0301}", "{\u00e9}", "{_}", "{1}", "text ", "\n", "\u00e9", "{NAME}", "{ name}", "{name }", "\u212a"]
        rng = _random.Random(20261013)
        templates = ["", "Hi {name}!", "{{name}}", "{na{name}me}", "{name}{role}{email}{manager}", "{unknown} {name",
                     "Welcome aboard as our new {role}.", "{n\u00e0me} {\u00e9t\u00e9}"]
        templates += ["".join(rng.choice(pieces) for _ in range(rng.randint(1, 10))) for _ in range(300)]
        out["render"] = {"context": ctx, "vars": onboarding.WELCOME_VARS,
                         "cases": [{"template": t, "out": onboarding.render(t, ctx)} for t in templates]}

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

        # The store's rules (RunbookStore over a temporary file, never GamGUI's own: failure-log 2026-09-25): its
        # seed, what set_role keeps and refuses, and the welcome emails' names and refusals. The native role store
        # keeps these, and adds its own bounds on top.
        def role_doc(r):
            return {"name": r.name, "steps": r.steps, "signature": r.signature, "org_unit": r.org_unit,
                    "groups": r.groups, "calendars": r.calendars, "welcome": r.welcome}

        store = onboarding.RunbookStore(root / "store.json")
        doc = {"seed_roles": [role_doc(r) for r in store.roles()],
               "seed_welcomes": [[n, w["subject"], w["body"]] for n, w in store._data["welcomes"].items()],
               "set_role": [], "set_welcome": [], "delete_welcome": []}
        store.set_welcome("Contract subject", "Contract body", "Contractor")
        for name, steps, signature, org_unit, groups, calendars, welcome in [
                ("  Sales  ", ["  a  ", "", " ", "b"], " Classic ", "  /Sales ", [" x@e.com ", "", "y@e.com"],
                 ["c@e.com\n"], ""),
                ("Ops", [], "", "", None, None, "Default"),
                ("Ops", ["replaced"], "", "", [], [], " Contractor "),
                ("Floor", ["a"], "", "", "x@e.com\ny@e.com", " ", "contractor"),
                ("", ["a"], "", "", [], [], ""), ("  \u3000", ["a"], "", "", [], [], ""),
                ("Lab", ["a"], "", "", [], [], "Nobody")]:
            case = {"name": name, "steps": steps, "signature": signature, "org_unit": org_unit, "groups": groups,
                    "calendars": calendars, "welcome": welcome}
            try:
                store.set_role(name, steps, signature, org_unit, groups, calendars, welcome)
                case["saved"] = role_doc(store.role(name.strip()))
            except ValueError as error:
                case["error"] = str(error)
            doc["set_role"].append(case)
        for name in ["contractor", "CONTRACTOR", "New one", " Trimmed "]:
            doc["set_welcome"].append({"name": name, "saved_as": store.set_welcome("s", "b", name)})
        for name in ["", " "]:
            try:
                store.set_welcome("s", "b", name)
            except ValueError as error:
                doc["set_welcome"].append({"name": name, "error": str(error)})
        store.set_role("Ops", ["x"], welcome="Contractor")
        for name in ["Default", "Contractor", "New one"]:
            case = {"name": name}
            try:
                store.delete_welcome(name)
                case["deleted"] = True
            except ValueError as error:
                case["error"] = str(error)
            doc["delete_welcome"].append(case)
        doc["role_names"] = store.role_names()
        doc["welcome_names"] = store.welcome_names()
        out["store"] = doc
    return out



def roster_fixture(gamgui: Path) -> dict:
    """GamGUI's `read_upload` (core/roster.py) over packages built here: every case tests/test_roster.py and the reader's
    parts of tests/test_roster_web.py make, and the ZIP and CSV shapes behind them (stored, a comment, prepended data, cp437
    and UTF-8 names, a bad CRC, a chunk boundary inside a character, Python's strict csv errors). Each case keeps its input
    bytes and the caps it lowers, and the error's words, the column map's name, or the snapshot with its issues.

    A case marked `swift` is a deviation docs/domains/classroom.md lists: GamGUI reads it, and the Swift reader refuses it
    (`refused`, in its own words)."""
    import base64
    import bz2  # noqa: F401  (zipfile's BZIP2 needs it)
    import io
    import stat
    import struct
    import zipfile

    from gamgui.core import roster
    from tests import test_roster as t

    caps_names = {"UPLOAD_CAP": "upload", "MEMBER_CAP": "member", "TOTAL_CAP": "total", "RATIO_CAP": "ratio",
                  "MEMBERS_CAP": "members", "CENTRAL_DIRECTORY_CAP": "centralDirectory", "MANIFEST_CAP": "manifest",
                  "COLUMNS_CAP": "columns", "LINE_CAP": "line", "ROWS_CAP": "rows", "FIELD_CAP": "field",
                  "ISSUE_SAMPLE": "issueSample"}
    cases: list = []

    def snapshot(snap) -> dict:
        return {"source": snap.source,
                "schools": [[s.id, s.name] for s in snap.schools.values()],
                "terms": [[x.id, x.title, x.kind, x.start, x.end] for x in snap.terms.values()],
                "courses": [[c.id, c.title, c.code, c.school_id] for c in snap.courses.values()],
                "classes": [[c.id, c.title, c.course_id, c.school_id, list(c.term_ids), c.code, c.location]
                            for c in snap.classes.values()],
                "people": [[p.id, p.role, p.email, p.given, p.family] for p in snap.people.values()],
                "enrollments": [[e.class_id, e.person_id, e.role, e.primary] for e in snap.enrollments],
                "issue_counts": [[k, v] for k, v in snap.issue_counts.items()],
                "issue_sample": [[i.code, i.file, i.row, i.source_id, i.detail] for i in snap.issue_sample],
                "others": snap.others, "counts": snap.counts}

    def case(name: str, uploads, caps=None, swift: str = "") -> None:
        caps = caps or {}
        saved = {k: getattr(roster, k) for k in caps}
        try:
            for k, v in caps.items():
                setattr(roster, k, v)
            try:
                expect = {"snapshot": snapshot(roster.read_upload(uploads))}
            except roster.PackageError as exc:
                expect = {"error": str(exc)}
            except roster.NeedsMap as needs:
                expect = {"needs_map": needs.name}
        finally:
            for k, v in saved.items():
                setattr(roster, k, v)
        entry = {"name": name, "uploads": [[n, base64.b64encode(b).decode()] for n, b in uploads],
                 "caps": {caps_names[k]: v for k, v in caps.items()}, "expect": expect}
        if swift:
            entry["swift"] = swift
        cases.append(entry)

    files, zipped, csv_, with_ = t._files, t._zip, t._csv, t._with
    USERS, ENROLLMENTS, CLASSES, ORGS, MANIFEST = t.USERS, t.ENROLLMENTS, t.CLASSES, t.ORGS, t.MANIFEST

    def listed(**override) -> list:
        return list(files(**override).items())

    def patched(data: bytes, find: bytes, replace: bytes) -> bytes:
        assert data.count(find) >= 1, find
        return data.replace(find, replace)

    # --- a good package, and the shapes it comes in (test_roster.py) -------------------------------------------------
    case("a OneRoster ZIP reads into one snapshot", [("export.zip", zipped(files()))])
    case("Finder's one enclosing folder and its litter are fine",
         [("Export.zip", zipped(files(), prefix="Export/", extra=[("__MACOSX/Export/._users.csv", b"x"),
                                                                    ("Export/.DS_Store", b"x")]))])
    case("a folder's CSV files read like its ZIP", listed())
    case("a byte-order mark is dropped", listed(**{"users.csv": b"\xef\xbb\xbf" + csv_(USERS)}))

    # --- the wrong kind of file ----------------------------------------------------------------------------------------
    for name, uploads in (("nothing picked", []), ("not a ZIP at all", [("roster.zip", b"not a zip at all")]),
                          ("a ZIP and a CSV", [("a.zip", zipped(files())), ("users.csv", b"x")]),
                          ("a text file", [("notes.txt", b"x")]), ("two unknown CSVs", [("a.csv", b"x"), ("b.csv", b"y")]),
                          ("OneRoster mixed with Clever", [("users.csv", b"x"), ("sections.csv", b"y")])):
        case(name, uploads)

    # --- OneRoster 1.2 ---------------------------------------------------------------------------------------------------
    for version in ("1.2", "1.2.1"):
        manifest = [r if r[0] != "oneroster.version" else ("oneroster.version", version) for r in t.MANIFEST_12]
        enrol = ENROLLMENTS + [("E3", "", "C1", "S1", "U4", "teacher", "false")]
        case(f"OneRoster {version} reads each role from roles.csv",
             [("export.zip", zipped(t._files_12(**{"manifest.csv": manifest, "enrollments.csv": enrol})))])
    case("OneRoster 1.2 needs roles.csv", list(t._files_12(**{"roles.csv": None}).items()))
    case("OneRoster 1.2 holds an enrolment to its roles",
         list(t._files_12(**{"enrollments.csv": ENROLLMENTS + [("E3", "", "C1", "S1", "U2", "teacher", "false")]}).items()))
    case("OneRoster 1.2's userProfiles.csv is named, never unpacked",
         [("export.zip", zipped(t._files_12(**{"userProfiles.csv": b"sourcedId,password\r\nP1,hunter2\r\n"})))])
    profiles = zipped(t._files_12(**{"userProfiles.csv": b"sourcedId,password\r\nP1,hunter2\r\n"}))
    central = [i for i in range(len(profiles)) if profiles.startswith(b"PK\x01\x02", i)]
    for i in central:
        if profiles[i + 46:i + 46 + 16] == b"userProfiles.csv":
            profiles = profiles[:i + 16] + b"\x00\x00\x00\x00" + profiles[i + 20:]      # its CRC: wrong if it were read
    case("an unused file is never unpacked, so its broken CRC never matters", [("export.zip", profiles)])
    case("a 1.1 users.csv in a 1.2 package is read by name", [("export.zip", zipped(t._files_12(**{"users.csv": USERS})))])
    case("a 1.2 manifest that says roles.csv is absent",
         list(t._files_12(**{"manifest.csv": [r if r[0] != "file.roles" else ("file.roles", "absent")
                                               for r in t.MANIFEST_12]}).items()))

    # --- the package-level refusals --------------------------------------------------------------------------------------
    case("a delta export", listed(**{"manifest.csv": [r if r[0] != "file.users" else ("file.users", "delta")
                                                       for r in MANIFEST]}))
    for missing in ("manifest.csv", "users.csv", "enrollments.csv"):
        case(f"no {missing}", listed(**{missing: None}))
    case("wrong columns", listed(**{"users.csv": [("id", "mail"), ("U1", "a@b.com")]}))
    case("one column missing", listed(**{"users.csv": [tuple(c for c in USERS[0] if c != "email")] + [r[:6] for r in USERS[1:]]}))
    case("text that isn't UTF-8", listed(**{"orgs.csv": "sourcedId,status,name,type\nS1,,Zürich,school\n".encode("latin-1")}))
    case("another OneRoster version", listed(**{"manifest.csv": [r if r[0] != "oneroster.version" else ("oneroster.version", "2.0")
                                                                  for r in MANIFEST]}))
    case("no version", listed(**{"manifest.csv": [r for r in MANIFEST if r[0] != "oneroster.version"]}))
    case("a manifest that isn't one", listed(**{"manifest.csv": [("name", "value"), ("oneroster.version", "1.1")]}))
    case("a manifest with a byte-order mark, quotes and spaces",
         listed(**{"manifest.csv": b"\xef\xbb\xbf propertyName , value \r\n" + csv_(MANIFEST[1:]).replace(b'"1.1"', b'" 1.1 "')}))
    case("an empty file", listed(**{"orgs.csv": b""}))
    case("a blank first line", listed(**{"orgs.csv": b"\r\n" + csv_(ORGS)}))

    # --- what the ZIP may hold -------------------------------------------------------------------------------------------
    for name in ("../users.csv", "/users.csv", "a\\users.csv", "a/b/users.csv", "./users.csv", "C:/users.csv",
                 "users.csv\x00.txt", "a/", "a/b/", "../", "x/./y.csv"):
        case(f"a member named {name!r}", [("x.zip", with_(name))])
    info = zipfile.ZipInfo("Export/users.csv")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    case("a symlink member", [("x.zip", zipped({k: v for k, v in files().items() if k != "users.csv"},
                                                extra=[(info, b"/etc/passwd")]))])
    fifo = zipfile.ZipInfo("users.csv")
    fifo.create_system = 3
    fifo.external_attr = (stat.S_IFIFO | 0o644) << 16
    case("a FIFO member", [("x.zip", zipped({k: v for k, v in files().items() if k != "users.csv"}, extra=[(fifo, csv_(USERS))]))])
    windows = zipfile.ZipInfo("users.csv")
    windows.create_system = 0
    windows.external_attr = 0o120777 << 16
    case("link bits from a system that isn't Unix are ignored",
         [("x.zip", zipped({k: v for k, v in files().items() if k != "users.csv"}, extra=[(windows, csv_(USERS))]))])
    data = bytearray(zipped(files()))
    data[6] |= 1
    data[data.find(b"PK\x01\x02") + 8] |= 1
    case("an encrypted member", [("x.zip", bytes(data))])
    case("two members with one name in any case", [("x.zip", with_("USERS.csv", csv_(USERS)))])
    case("an unknown member", [("x.zip", with_("payload.sh", b"#!/bin/sh"))])
    case("two folders", [("x.zip", zipped(files(), prefix="A/", extra=[("B/resources.csv", b"x")]))])
    case("a root file beside one folder", [("x.zip", zipped({k: v for k, v in files().items() if k != "users.csv"},
                                                             prefix="A/", extra=[("users.csv", csv_(USERS))]))])
    case("folder entries for the one folder", [("x.zip", zipped(files(), prefix="Export/", extra=[("Export/", b"")]))])
    case("too many entries", [("x.zip", zipped(files()))], {"MEMBERS_CAP": 5})
    understated = bytearray(zipped(files()))
    end = understated.rfind(b"PK\x05\x06")
    understated[end + 8:end + 12] = struct.pack("<HH", 1, 1)
    case("more entries than the end record says", [("x.zip", bytes(understated))], {"MEMBERS_CAP": 5})
    case("a decompression bomb by its ratio", [("x.zip", zipped(files(**{"users.csv": csv_(USERS) + b"0" * (8 * 1024 * 1024)})))])
    case("an optional file is named but never unpacked", [("x.zip", zipped(files(**{"demographics.csv": b"x" * (1024 * 1024)})))],
         {"MEMBER_CAP": 64 * 1024})
    case("two of one optional file", [("x.zip", zipped(files(**{"demographics.csv": b"x"}), extra=[("Demographics.csv", b"y")]))])

    # --- ZIP shapes ---------------------------------------------------------------------------------------------------------
    stored = io.BytesIO()
    with zipfile.ZipFile(stored, "w", zipfile.ZIP_STORED) as z:
        for name, body in files().items():
            z.writestr(name, body)
    case("stored, not deflated", [("export.zip", stored.getvalue())])
    commented = io.BytesIO()
    with zipfile.ZipFile(commented, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body in files().items():
            z.writestr(name, body)
        z.comment = b"exported by a SIS"
    case("an archive comment", [("export.zip", commented.getvalue())])
    planted = io.BytesIO()
    with zipfile.ZipFile(planted, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body in files().items():
            z.writestr(name, body)
        z.comment = b"exported by a SIS PK\x05\x06 with a signature in its comment"
    case("an end-record signature planted in the comment", [("export.zip", planted.getvalue())])
    case("data before the ZIP (a self-extractor's stub)", [("export.zip", b"MZ" + b"\x00" * 1000 + zipped(files()))])
    case("an empty ZIP", [("empty.zip", zipped({}))])
    case("a ZIP named .txt is still read by its bytes", [("export.txt", zipped(files()))])
    case("a .ZIP that isn't one", [("export.ZIP", b"PK but not really")])
    bad = bytearray(zipped(files(**{"users.csv": csv_(USERS)})))
    for i in [i for i in range(len(bad)) if bad.startswith(b"PK\x01\x02", i)]:
        if bad[i + 46:i + 46 + 9] == b"users.csv":
            bad[i + 16] ^= 0xFF
    case("a bad CRC", [("x.zip", bytes(bad))])

    def deflated_by_hand(target: str, raw: bytes, crc: int, size: int) -> bytes:
        """The package's ZIP, written by hand so `target`'s deflated bytes, CRC and size are exactly these."""
        import zlib
        body, directory = bytearray(), bytearray()
        for name, data in files().items():
            if name == target:
                packed, check, length = raw, crc, size
            else:
                squeeze = zlib.compressobj(9, zlib.DEFLATED, -15)
                packed, check, length = squeeze.compress(data) + squeeze.flush(), zlib.crc32(data), len(data)
            encoded = name.encode()
            fields = struct.pack("<HHHHHIIIHH", 20, 0, 8, 0, 0x21, check, len(packed), length, len(encoded), 0)
            directory += b"PK\x01\x02" + struct.pack("<H", 20) + fields + struct.pack("<HHHII", 0, 0, 0, 0, len(body)) + encoded
            body += b"PK\x03\x04" + fields + encoded + packed
        count = len(files())
        return bytes(body + directory + b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, count, count, len(directory), len(body), 0))

    def inflated(raw: bytes) -> bytes:
        import zlib
        loose = zlib.decompressobj(-15)
        return loose.decompress(raw) + loose.flush()

    def deflate_case(name: str, raw: bytes, out: bytes | None = None) -> None:
        import zlib
        out = inflated(raw) if out is None else out
        case(name, [("x.zip", deflated_by_hand("users.csv", raw, zlib.crc32(out), len(out)))])

    import zlib
    users = csv_(USERS)
    sync = zlib.compressobj(9, zlib.DEFLATED, -15)
    unended = sync.compress(users) + sync.flush(zlib.Z_SYNC_FLUSH)
    # zlib.error in GamGUI: invalid block type, invalid stored block lengths, a good start then garbage, a distance back
    # past the start (a stream made against a dictionary the reader doesn't have). The CRC of what came out matches.
    deflate_case("a deflated member of an invalid block type", b"\xff" * 5000, b"")
    deflate_case("a deflated member whose stored block's lengths disagree", b"\x00" * 5000, b"")
    deflate_case("a deflated member that starts well and turns to garbage", unended + b"\xff" * 50, users)
    against = zlib.compressobj(9, zlib.DEFLATED, -15, zdict=users)
    deflate_case("a deflated member reaching back past its start", against.compress(users) + against.flush(), users)
    # No zlib.error: the input runs out before the stream's end, and zipfile ends there; the CRC decides.
    deflate_case("a deflated member whose stream never ends", unended)
    # Bytes after the stream's end: zipfile stops at Z_STREAM_END and never reads them.
    tidy = zlib.compressobj(9, zlib.DEFLATED, -15)
    deflate_case("a deflated member with bytes after its stream's end", tidy.compress(users) + tidy.flush() + b"\xff" * 50,
                 users)
    # Garbage just past a header size on a 256 KiB boundary inside a 1 MiB read: ZipExtFile's read(1 MiB) lets zlib write
    # up to the rest of the read (decompress(data, n)), so it inflates past the size into the garbage and raises
    # zlib.error. A reader that inflated 256 KiB at a time would stop at the size and accept it. Random hex keeps the
    # ratio under RATIO_CAP.
    import random
    noise = random.Random(0)
    for size in (262144, 524288):
        body = users + b"".join(f"x{noise.getrandbits(128):032x},a,b\r\n".encode() for _ in range(size // 30 + 400))
        assert len(body) > size + 5000
        cut = zlib.compressobj(9, zlib.DEFLATED, -15)
        deflate_case(f"a deflated member turning to garbage just past its {size >> 10} KiB size",
                     cut.compress(body) + cut.flush(zlib.Z_SYNC_FLUSH) + b"\xff" * 50, body[:size])
    renamed = bytearray(zipped(files()))
    local = renamed.find(b"PK\x03\x04" )
    while local >= 0:
        if renamed[local + 30:local + 30 + 9] == b"users.csv":
            renamed[local + 30] = ord("U")
        local = renamed.find(b"PK\x03\x04", local + 4)
    case("a local header naming another file", [("x.zip", bytes(renamed))])
    wrong_offset = bytearray(zipped(files()))
    end = wrong_offset.rfind(b"PK\x05\x06")
    wrong_offset[end + 16:end + 20] = struct.pack("<I", 7)
    case("an end record pointing at the wrong place", [("x.zip", bytes(wrong_offset))])
    data = bytearray(zipped(files()))
    central = data.find(b"PK\x01\x02")
    data[central + 6:central + 8] = (64).to_bytes(2, "little")
    case("an unknown ZIP version", [("x.zip", bytes(data))])
    method = bytearray(zipped(files()))
    for i in [i for i in range(len(method)) if method.startswith(b"PK\x01\x02", i)]:
        if method[i + 46:i + 46 + 9] == b"users.csv":
            method[i + 10:i + 12] = (99).to_bytes(2, "little")
    case("a compression method zipfile doesn't know", [("x.zip", bytes(method))])
    truncated = zipped(files())
    case("a ZIP cut short", [("x.zip", truncated[: len(truncated) // 2])])
    high = bytes(range(0x80, 0x100))
    for half in (high[:64], high[64:]):
        cases_zip = zipped(files(), extra=[(zipfile.ZipInfo("placeholder" + "_" * 53), b"x")])
        cases_zip = patched(cases_zip, b"placeholder" + b"_" * 53, half)
        case(f"a cp437 name {half[:2].hex()}…", [("x.zip", cases_zip)])
    case("a UTF-8 name", [("x.zip", with_("Schüler.csv"))])
    nul = zipped({k: v for k, v in files().items() if k != "users.csv"}, extra=[(zipfile.ZipInfo("users.csv\x01../x"), csv_(USERS))])
    case("a NUL in a member's name", [("x.zip", patched(nul, b"users.csv\x01../x", b"users.csv\x00../x"))], swift="refused")
    shared = io.BytesIO()
    with zipfile.ZipFile(shared, "w", zipfile.ZIP_BZIP2) as z:
        for name, body in files().items():
            z.writestr(name, body)
    case("BZIP2 members", [("export.zip", shared.getvalue())], swift="refused")

    # --- found by GamGUI's adversarial run (2026-11-11) ---------------------------------------------------------------------
    case("a huge central directory", [("x.zip", zipped(files()))], {"CENTRAL_DIRECTORY_CAP": 200})
    case("a ZIP64 directory whose 32-bit size lies", [("r.zip", t._directory_only(2000, "zip64"))])
    case("an end-record signature planted in its size field", [("r.zip", t._directory_only(2000, "fieldsig"))])
    spread = b'U9,,student,"' + b"x" * 900 + (b"\n" + b"x" * 900) * 10 + b'",A,B\n'
    case("a field spanning many lines", listed(**{"users.csv": csv_(USERS) + spread}), {"LINE_CAP": 4000})
    case("a wide header", listed(**{"users.csv": [USERS[0] + tuple(f"x{i}" for i in range(300))] + list(USERS[1:])}))
    case("a header of a hundred more columns", listed(**{"users.csv": [USERS[0] + tuple(f"x{i}" for i in range(100))] + list(USERS[1:])}))
    case("a column named twice", listed(**{"users.csv": [USERS[0] + ("email",),
                                                         ("U1", "", "teacher", "ann", "Ann", "Lee", "ann@example.com", "evil@x.com")]}))
    case("two columns named twice", listed(**{"users.csv": [("status",) + USERS[0] + ("email",)] + [("",) + r + ("",) for r in USERS[1:]]}))
    case("a manifest past its cap", listed(**{"manifest.csv": csv_(MANIFEST) + b"\n" * (128 * 1024)}))
    case("a line of thousands of fields", listed(**{"users.csv": csv_(USERS) + b"U9" + b"," * 5000 + b"\n"}), {"LINE_CAP": 1000})
    case("a row wider than its header", listed(**{"users.csv": csv_(USERS) + b"U9,,student,x,A,B,c@example.com,1,2,3\n"}))
    case("a row one wider than its header", listed(**{"users.csv": csv_(USERS) + b"U9,,student,x,A,B,c@example.com,\n"}))
    for email in ("b\x1b[31m@example.com", "a\u200b@example.com", "a\x07@example.com", "é@example.com",
                  "a b@example.com", "a@b", "@example.com", "a@@example.com", "a@example.com,b@example.com",
                  "  Padded@Example.COM  ", "<a@example.com>", "\ufeffa@example.com"):
        case(f"the address {email!r}", listed(**{"users.csv": USERS[:3] + [("U9", "", "student", "", "X", "Y", email)]}))
    case("a source ID and a name starting with U+FEFF",
         listed(**{"users.csv": USERS[:3] + [("\ufeffU9", "", "student", "", "\ufeffX", "Y", "not an address")]}))
    case("control characters are dropped from names",
         listed(**{"users.csv": USERS[:3] + [("U9", "", "student", "", "Al\x07ex\u200b\x7f", "Ki\x1bm\x1f\u2028", "u9@example.com"),
                                             ("U10", "", "student", "", "\u00a0Zo\u00eb\u2060", "\ufeffOh\u00ad", "u10@example.com")]}))
    for where, row in (("email", ("U9", "", "student", "", "X", "Y", "a\x00@example.com")),
                       ("name", ("U9", "", "student", "", "Al\x00ex", "Y", "u9@example.com"))):
        case(f"a NUL in an {where}", listed(**{"users.csv": USERS[:3] + [row]}))
    case("an issue names the line its record starts on",
         listed(**{"users.csv": USERS[:3] + [("U9", "", "student", "", "Multi\nLine\nName", "Y", ""),
                                             ("U8", "", "student", "", "A", "B", "")]}))
    case("a member capped by what it unpacks to", [("x.zip", zipped(files(**{"users.csv": csv_(USERS) + b"x" * 4096})))],
         {"MEMBER_CAP": 1024, "RATIO_CAP": 10 ** 9})
    case("the roster's total capped", [("x.zip", zipped(files()))], {"TOTAL_CAP": 600})
    case("loose files' total capped", listed(), {"TOTAL_CAP": 600})
    case("a loose file past the member cap", listed(), {"MEMBER_CAP": 100})
    case("a field past its cap", listed(**{"orgs.csv": [ORGS[0], ("S1", "", "", "x" * 200, "school")]}), {"FIELD_CAP": 100})
    case("rows past the cap", listed(), {"ROWS_CAP": 1})
    case("the upload cap, before anything is read", [("x.zip", zipped(files()))], {"UPLOAD_CAP": 10})
    seed, letters = 7, []
    for _ in range(140_000):
        seed = (seed * 1103515245 + 12345) % 2 ** 31
        letters.append("abcdefghijklmnopqrstuvwxyz"[seed % 26])
    noise = "".join(letters)
    case("a field past the csv module's own limit", listed(**{"orgs.csv": [ORGS[0], ("S1", "", "", noise, "school")]}))
    case("a field past FIELD_CAP within the csv module's limit",
         listed(**{"orgs.csv": [ORGS[0], ("S1", "", "", noise[:70_000], "school")]}))

    # --- the csv module's strict reading ---------------------------------------------------------------------------------
    case("quotes, commas, doubled quotes and line endings",
         listed(**{"orgs.csv": b'sourcedId,status,name,type\r\nS1,,"North, ""High""",school\nS2,,"Two\r\nLines",school\r'
                               b'S3,,Plain "quote,school\n'}))
    case("text after a closing quote", listed(**{"orgs.csv": b'sourcedId,status,name,type\r\nS1,,"North"x,school\r\n'}))
    case("a quote left open at the end", listed(**{"orgs.csv": b'sourcedId,status,name,type\r\nS1,,"North,school\r\n'}))
    case("no line ending at the end", listed(**{"orgs.csv": b"sourcedId,status,name,type\r\nS1,,North,school"}))
    case("blank and whitespace rows are skipped",
         listed(**{"orgs.csv": b"sourcedId,status,name,type\r\n\r\n , ,\xc2\xa0,\r\nS1,,North,school\r\n"}))
    case("a row narrower than its header", listed(**{"orgs.csv": b"sourcedId,status,name,type\r\nS1,,North\r\n"}))
    case("header cells are stripped", listed(**{"orgs.csv": b" sourcedId , status ,\tname, type \r\nS1,,North,school\r\n"}))
    head = csv_(ORGS[:1]) + b"S1,,"
    rows = head + b"a" * (8191 - len(head)) + b"\xc3\xb6,school\r\n" + b"S2,,Two,school\r\n"
    assert rows[8191:8193] == b"\xc3\xb6"
    case("a character across the decoder's chunk boundary", listed(**{"orgs.csv": rows}))
    late = csv_([("id", "name")]) + b"x" * 9000 + b"\xff\r\n"
    case("a bad byte past the first chunk, after a missing column", listed(**{"orgs.csv": late}))
    early_nul = csv_(ORGS) + b"S2,,No\x00rth,school\r\n" + b"x" * 9000 + b"\xff\r\n"
    case("a NUL before a bad byte in a later chunk", listed(**{"orgs.csv": early_nul}))
    case("a bad byte in the first chunk, after a NUL", listed(**{"orgs.csv": csv_(ORGS) + b"S2,,No\x00rth,school\r\n\xff"}))
    # CPython holds a surrogate's first two bytes at a chunk's end (unicodeobject.c), so a refusal earlier in that chunk
    # comes first.
    wide = csv_(ORGS[:1]) + b"S1,,North,school,a,b,c\r\n"
    narrow = csv_([("id", "name")]) + b"S1,North\r\n"
    for why, start in (("a wide row", wide), ("a missing column", narrow)):
        surrogate = start + b"x" * (8190 - len(start)) + b"\xed\xa0\x80\r\n"
        assert surrogate[8190:8192] == b"\xed\xa0"
        case(f"a surrogate's first two bytes ending the first chunk, after {why}", listed(**{"orgs.csv": surrogate}))
        case(f"a surrogate's first two bytes ending the file, after {why}", listed(**{"orgs.csv": start + b"S2,\xed\xbf"}))
    unheld = narrow + b"x" * (8190 - len(narrow)) + b"\xed\x9f"
    case("a character's first two bytes ending the first chunk, after a missing column", listed(**{"orgs.csv": unheld + b"\xbf\r\n"}))
    case("an E0 sequence no byte can finish, ending the first chunk", listed(**{"orgs.csv": narrow + b"x" * (8190 - len(narrow)) + b"\xe0\x80\r\n"}))
    case("a character cut off by the end of the file",listed(**{"orgs.csv": csv_(ORGS) + b"S2,,North,schoo\xc3"}))

    # --- row-level issues ----------------------------------------------------------------------------------------------------
    users = USERS + [("U4", "", "student", "", "No", "Mail", ""), ("U5", "", "student", "", "Bad", "Mail", "a b@x.com"),
                     ("U6", "", "student", "", "Dup", "Mail", "BO@example.com"), ("U7", "tobedeleted", "student", "", "", "", "z@x.com")]
    enrolls = ENROLLMENTS + [("E3", "", "C9", "S1", "U2", "student", ""), ("E4", "", "C1", "S1", "U9", "student", ""),
                             ("E5", "", "C1", "S1", "U2", "teacher", "")]
    classes = CLASSES + [("C2", "", "", "CO9", "", "S9", "T9", "")]
    case("row problems counted by kind", listed(**{"users.csv": users, "enrollments.csv": enrolls, "classes.csv": classes}))
    case("the sample capped, the count whole",
         listed(**{"users.csv": [USERS[0]] + [(f"U{i}", "", "student", "", "", "", "") for i in range(10)],
                   "enrollments.csv": [ENROLLMENTS[0]]}), {"ISSUE_SAMPLE": 2})
    case("duplicates, no IDs and statuses",
         listed(**{"orgs.csv": ORGS + [("S1", "", "", "Again", "school"), ("", "", "", "Nameless", "school"),
                                       ("S2", "TOBEDELETED", "", "Gone", "school")],
                   "academicSessions.csv": t.TERMS + [("T1", "", "Again", "term", "", ""), ("T2", "active", "Spring", "SEMESTER", "a", "b")],
                   "courses.csv": t.COURSES + [("CO1", "", "Again", "", "S1"), ("CO2", "", "", "", "S1")],
                   "classes.csv": CLASSES + [("C1", "", "Again", "CO1", "", "S1", "T1", ""),
                                             ("C3", "", "Three", "CO2", "", "S1", " T1 , T2 ,,T9", "")],
                   "users.csv": USERS + [("U1", "", "teacher", "", "Ann", "Again", "other@example.com"),
                                         ("U8", "", "TEACHER", "", "Eve", "Up", "EVE@Example.com")],
                   "enrollments.csv": ENROLLMENTS + [("E9", "", "C3", "S1", "U8", "Teacher", "TRUE"),
                                                     ("E9", "", "C3", "S1", "U3", "student", ""),
                                                     ("E10", "", "C3", "S1", "U2", "aide", ""),
                                                     ("", "", "C3", "S1", "U2", "student", "")]}))
    case("a long detail is cut at 200 characters",
         listed(**{"enrollments.csv": ENROLLMENTS + [("E9", "", "C" * 300, "S1", "U2", "student", "")]}))

    # --- found by GamGUI's adversarial run of C5 (2026-11-12), and the web tests' readers ------------------------------------
    for name in ("students.csv", "users.csv", "sections.csv", "schedule.csv"):
        case(f"one CSV named {name} is a spreadsheet to map", [(name, b"a,b\r\n1,2\r\n")])
    case("one CSV beside Mac litter is still one spreadsheet", [("Folder/._x.csv", b"x"), ("schedule.CSV", b"a,b\r\n")])
    case("a Kelvin sign address", listed(**{"users.csv": USERS[:1] + [("U1", "", "teacher", "ann", "Ann", "Lee", "\u212aim@example.com")] + USERS[2:]}))
    case("a 1.2 enrolment of someone without a roster role", list(t._files_12(**{"roles.csv": [r for r in t.ROLES_12 if r[3] != "U2"]}).items()))
    case("the issues the import screen groups",
         listed(**{"users.csv": USERS + [("U4", "", "student", "", "No", "Mail", ""), ("U5", "", "student", "", "Also", "None", "")],
                   "enrollments.csv": ENROLLMENTS + [("E9", "", "C9", "S1", "U2", "student", "")]}))
    case("more files than a ZIP may hold", [(f"x{i}.csv", b"x") for i in range(roster.MEMBERS_CAP + 5)])
    case("a picked file is matched by its base name", [(f"C:\\Export\\{n}", b) for n, b in files().items()])
    case("a file picked twice", listed() + [("Users.csv", csv_(USERS))])
    case("an optional file picked loose is skipped", listed(**{"demographics.csv": b"\xff not even text"}))
    case("an unknown file picked loose", listed() + [("notes.txt", b"x")])
    case("Mac litter picked loose is ignored", listed() + [(".DS_Store", b"\x00\x01"), ("._users.csv", b"\x00")])

    # --- Clever is read by the next slice: detected here, its snapshot recorded for then ---------------------------------
    clever = gamgui / "tests" / "fixtures" / "roster" / "clever"
    clever_files = [(p.name, p.read_bytes()) for p in sorted(clever.iterdir()) if p.suffix == ".csv"]
    case("Clever's CSV files", clever_files)
    case("Clever's ZIP", [("clever.zip", zipped(dict(clever_files)))])
    return {"cases": cases}


def roster_plan_fixture(gamgui: Path) -> dict:
    """GamGUI's change list (core/roster_plan.py, plan C3) and its hand-over (core/roster_handover.py, C4), recorded by
    running GamGUI's own tests: `plan` is wrapped while every synchronous test in tests/test_roster_plan.py runs, so each
    call's inputs (the snapshot, the Classroom classes as read, the directory, the unread count, the risk limits) and its
    ChangeList are kept as plain JSON. The compare test_roster_web.py makes end to end is recorded too: the SIS files it
    uploads read by `read_upload`, and Classroom read by `managed_from` from GamGUI's own mock (never GAM), plain and with
    the limits its flagged test lowers. Each case also keeps what `roster_handover.build` hands over for it (every file's
    text, or the refusal's words), with the flagged kinds left out and then ticked, and `kept_changes`' indexes.

    Also `alias_for` over IDs plain and not, and `managed_from` over the alias and roster cells its tests read and more."""
    import tempfile

    from gamgui.core import roster as roster_mod
    from gamgui.core import roster_handover as handover
    from gamgui.core import roster_plan
    from gamgui.core.gam.commands import GAMCommands
    from gamgui.core.gam.runner import strip_cfgdir_noise
    from tests import test_roster as tr
    from tests import test_roster_plan as tp
    from tests import test_roster_web as tw

    def snapshot(snap) -> dict:
        return {"terms": [[t.id, t.title] for t in snap.terms.values()],
                "classes": [[c.id, c.title, list(c.term_ids)] for c in snap.classes.values()],
                "people": [[p.id, p.role, p.email] for p in snap.people.values()],
                "enrollments": [[e.class_id, e.person_id, e.role, e.primary] for e in snap.enrollments]}

    def managed(m) -> dict:
        c = m.course
        return {"course": {"id": c.id, "name": c.name, "section": c.section, "state": c.state,
                           "owner_email": c.owner_email},
                "aliases": list(m.aliases), "teachers": list(m.teachers), "students": list(m.students)}

    def handed(out, include) -> dict:
        try:
            files = handover.build(out, "example.com", "2026-11-11 18:00 UTC", include)
        except handover.HandoverError as exc:
            return {"error": type(exc).MESSAGE}
        return {"files": {name: body.decode("utf-8") for name, body in sorted(files.items())}}

    def result(out) -> dict:
        kept = handover.kept_changes(out)
        everything = handover.kept_changes(out, list(out.flags))
        return {"changes": [change_row(c) for c in out.changes], "counts": dict(out.counts), "flags": dict(out.flags),
                "notes": list(out.notes), "summary": out.summary(), "managed": out.managed, "enrolled": out.enrolled,
                "unmanaged_ignored": out.unmanaged_ignored, "incomplete": out.incomplete,
                "kept": [out.changes.index(c) for c in kept],
                "kept_with_flagged": [out.changes.index(c) for c in everything],
                "handover": handed(out, ()), "handover_with_flagged": handed(out, list(out.flags))}

    cases: list = []
    real_plan = roster_plan.plan

    def record(name: str, snap, classroom, directory=None, unread=0):
        entry = {"name": name, "snapshot": snapshot(snap), "classroom": [managed(m) for m in classroom],
                 "directory": None if directory is None else sorted(directory), "unread": unread,
                 "limits": {k: list(v) for k, v in roster_plan.LIMITS.items()}}
        out = real_plan(snap, classroom, directory, unread)
        entry["expect"] = result(out)
        cases.append(entry)
        return out

    # 1. Every synchronous test of the planner, its `plan` calls recorded.
    for test_name, fn in sorted(vars(tp).items()):
        if not test_name.startswith("test_") or inspect.iscoroutinefunction(fn) or inspect.signature(fn).parameters:
            continue
        calls = [0]

        def wrapped(snap, classroom, directory=None, unread=0, _name=test_name, _calls=calls):
            _calls[0] += 1
            return record(f"{_name} #{_calls[0]}", snap, classroom, directory, unread)
        tp.plan = wrapped
        try:
            fn()
        finally:
            tp.plan = real_plan
    if len(cases) < 20:
        raise SystemExit(f"only {len(cases)} plan() calls recorded from tests/test_roster_plan.py")

    # 2. The web tests' compare: their SIS files read, and Classroom read from GamGUI's mock as classroom_state reads it.
    fixtures = gamgui / "tests" / "fixtures"

    def mock(argv) -> str:
        with tempfile.TemporaryDirectory() as cfg:
            for name, body in (("oauth2service.json", '{"client_id": "x"}'), ("oauth2.txt", '{"refresh_token": "x"}'),
                               ("client_secrets.json", "{}")):
                Path(cfg, name).write_text(body)
            env = {"PATH": "/usr/bin:/bin", "GAMCFGDIR": cfg, "GAM_MOCK_FIXTURES": str(fixtures)}
            run = subprocess.run(["/bin/sh", str(fixtures / "mock_gam.sh"), *argv], capture_output=True, text=True,
                                 env=env, check=False)
            if run.returncode != 0:
                raise SystemExit(f"GamGUI's mock refused {argv}: {run.stderr}")
            return strip_cfgdir_noise(run.stdout, Path(cfg))   # as GamGUI's runner reads it

    states = ("active", "provisioned", "archived")
    courses = parse_records(mock(GAMCommands.print_courses(states=states, aliases=True)))
    people = parse_records(mock(GAMCommands.print_all_course_participants(states)))
    classroom, unread = roster_plan.managed_from(courses, people)
    if unread:
        raise SystemExit(f"GamGUI's mock left classes unread: {unread}")
    directory = {str(r.get("primaryEmail") or "").lower() for r in parse_records(mock(GAMCommands.print_users()))}
    web = tr._files(**{"classes.csv": tw.SIS_CLASSES, "users.csv": tw.SIS_USERS, "enrollments.csv": tw.SIS_ENROLL})
    snap = roster_mod.read_upload(list(web.items()))
    flagged = {"remove_student": (0, 0.0), "remove_teacher": (99, 1.0), "archive": (99, 1.0)}
    for name, limits in (("test_roster_web compare", None), ("test_roster_web flagged", flagged)):
        saved = roster_plan.LIMITS
        try:
            if limits is not None:
                roster_plan.LIMITS = limits
            out = record(name, snap, classroom, directory, len(unread))
        finally:
            roster_plan.LIMITS = saved
        if limits is None and out.summary() != "Would remove 1 person; would create 1 class, add 1 person and rename 2 classes.":
            raise SystemExit(f"the web compare planned {out.summary()!r}, not what test_roster_web asserts")

    # 3. The pieces: alias_for, and managed_from over the cells its tests read (and more GAM could print).
    alias_ids = ["C-101.a_b", "class #1 / ünï", "C1", "x" * 80, "x" * 81, "a b", "é", "OLD", "C/1",
                 "d:gg-x", "\U0001F600", "x.y-z_0", "é", "C1\n", "ı"]
    aliases = [[i, roster_plan.alias_for(i)] for i in alias_ids]
    row = {"courseId": "9", "courseName": "X", "JSON-teachers": "[]", "JSON-students": "[]"}
    cells = ['[{"alias": "d:gg-C9"}, {"alias": "d:other"}]', '[{"etag": "x"}]', '["d:gg-C9"]', "{oops", "[]",
             '{"alias": "d:gg-C9"}', '[{"alias": ""}]', '[{"alias": 7}]', "[null]", '[["d:gg-C9"]]', '"d:gg-C9"',
             '[{"alias": "gg-C9"}]', None]
    managed_cases = []
    for cell in cells:
        rec = {"id": "9", "name": "X"} | ({} if cell is None else {"JSON-aliases": cell})
        for participants in ([row], [], [{**row, "JSON-students": "{bad"}],
                             [{**row, "JSON-students": '[{"profile": {"name": {"fullName": "No Address"}}}]'}]):
            got, unread_ids = roster_plan.managed_from([rec], participants)
            managed_cases.append({"courses": [rec], "participants": participants,
                                  "managed": [managed(m) for m in got], "unread": unread_ids})
    return {"cases": cases, "web_reads": {"courses": courses, "participants": people, "directory": sorted(directory)},
            "alias_for": aliases, "managed_from": managed_cases}


def change_row(c) -> list:
    """A planner `Change` as the fixtures keep it: its fields in their order."""
    return [c.kind, c.alias, c.title, c.person, c.before, c.after, c.course_id, c.swap, c.late, c.name, c.section]


def handover_fixture(gamgui: Path) -> dict:
    """GamGUI's hand-over (core/roster_handover.py) over the list its byte test uses (tests/test_roster_handover.py's
    `_plan`, every kind with a district's awkward values), dated as that test dates it. The files go to
    Tests/Fixtures/handover/ only when they equal GamGUI's own tests/fixtures/handover/ byte for byte. Also each step's
    `gam csv` line, and the files for a list of values Python's csv writer and csv_safe treat specially."""
    from gamgui.core import roster_handover as handover
    from gamgui.core.roster_plan import Change, ChangeList
    from tests import test_roster_handover as th

    files = handover.build(th._plan(), "example.com", "2026-11-11 18:00 UTC")
    theirs = {p.name: p.read_bytes() for p in (gamgui / "tests" / "fixtures" / "handover").iterdir()}
    if theirs != files:
        raise SystemExit("GamGUI's roster_handover no longer writes its own tests/fixtures/handover byte for byte")
    odd = ["", " lead", "trail ", "a\nb", "a\rb", "a\r\nb", 'q"uote', "comma,", "\tTab", "=SUM(A1)", "+1", "-1", "@x",
           "\rCR", "'already", "café", "é", "\U0001F600", "back\\slash", "semi;colon", "\u2028"]
    changes = [Change("create", f"d:gg-V{i}", v or "Untitled", person="ann@x.com", after=v, name=v, section=v)
               for i, v in enumerate(odd)]
    changes += [Change("rename", f"d:gg-R{i}", v, before=v, after=v, name=v, section="", course_id="1")
                for i, v in enumerate(odd)]
    changes += [Change("archive", v, v or "Unnamed") for v in ("", "a,b")]
    odd_list = ChangeList(changes=changes)
    for c in changes:
        odd_list.counts[c.kind] = odd_list.counts.get(c.kind, 0) + 1
    odd_files = handover.build(odd_list, "exämple.com", "2026-11-11 18:00 UTC")
    return {"files": files,
            "lines": {s.file: handover.gam_line(s) for s in handover.STEPS},
            "odd": {"changes": [change_row(c) for c in changes],
                    "files": {name: body.decode("utf-8") for name, body in sorted(odd_files.items())}}}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gamgui", default=str(ROOT.parent / "gamgui"), help="path to the GamGUI checkout")
    ap.add_argument("--gam-binary", default=str(ROOT / "Vendor" / "gam7" / "gam"))
    ap.add_argument("--gam-python", help="the Python the GAM build was frozen with (default: python3.X on the PATH)")
    args = ap.parse_args()
    pending: list = []

    def emit(name: str, text: str) -> None:
        """A fixture, written once every one is made and the build has written their CSV the same."""
        pending.append((name, text))
    gamgui = Path(args.gamgui).resolve()
    sys.path.insert(0, str(gamgui))
    require_gamgui_reads_gam()

    # Before anything is read: the build must answer, under its own Python, and still write GAM_DIALECT's CSV.
    oracle = GamOracle(Path(args.gam_binary), args.gam_python)
    build = oracle.ask({})
    # The fixtures are stamped with the build the oracle ran (its VERSION, as build_command_catalog.py stamps the
    # catalog), never GamGUI's own GAM pin: GamGUI doesn't hold back this repo's GAM (operator, 2026-10-17). GamGUI
    # is still the source of the builders, named by its commit.
    gam_version = Path(args.gam_binary).with_name("VERSION").read_text(encoding="utf-8").strip().lstrip("v")

    from gamgui.core.catalog import parser as catalog_parser
    from gamgui.core.gam import commands as commands_mod
    from gamgui.core.gam.commands import GAMCommands

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
            # A placeholder, or the first value GamGUI's own contract test passes where the builder checks it.
            required = {p.name: (ENUM_ARGS[name, p.name][0] if (name, p.name) in ENUM_ARGS
                                 else ["<" + p.name + ">"] if "Sequence" in str(p.annotation) else "<" + p.name + ">")
                        for p in params if p.default is p.empty}
            defaults[name] = {"kwargs": {k: jsonable(v) for k, v in required.items()},
                              "argv": list(originals[name](**required))}

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
        "source": {"gamgui_commit": commit, "gam_version": gam_version,
                   "generator": "scripts/gen_fixtures.py"},
        "builders": builders,
        "signatures": signatures,
        "constants": {k: jsonable(getattr(GAMCommands, k)) for k in ("TRANSFER_PRIVACY", "FORWARD_ACTIONS",
                                                                      "MESSAGE_DETAIL", "REPORT_APPLICATIONS")}
        | {k: jsonable(getattr(commands_mod, k)) for k in ("GROUP_ROLES", "CALENDAR_ACL_ROLES", "USER_LIST_FIELDS",
                                                           "USER_DETAIL_FIELDS", "GROUP_LIST_FIELDS", "COURSE_STATES",
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
    emit("argv.json", json.dumps(argv_doc, indent=1, ensure_ascii=False) + "\n")
    covered = {c["builder"] for c in unique}
    print(f"argv.json: {len(unique)} cases over {len(covered)}/{len(builders)} builders")

    # Exit codes: the build's *_RC table, as the build's own Python reads it (scripts/gam_oracle.py).
    from gamgui.core.setup import CHECK_ANSWER_RCS, OAUTH2SERVICE_JSON_REQUIRED_RC, SCOPES_NOT_AUTHORIZED_RC
    table = build["rc"]
    rc_doc = {
        "source": {"gam_version": gam_version, "gamgui_commit": commit,
                   "generator": "scripts/gen_fixtures.py"},
        "build_rc": dict(sorted(table.items())),
        "gamgui": {"SCOPES_NOT_AUTHORIZED_RC": SCOPES_NOT_AUTHORIZED_RC,
                   "OAUTH2SERVICE_JSON_REQUIRED_RC": OAUTH2SERVICE_JSON_REQUIRED_RC,
                   "CHECK_ANSWER_RCS": list(CHECK_ANSWER_RCS)},
    }
    emit("exit_codes.json", json.dumps(rc_doc, indent=1) + "\n")
    print(f"exit_codes.json: {len(table)} *_RC constants")

    # GAM's failures, classified and scrubbed as GamGUI does. ASCII-escaped: it holds the invisible
    # characters scripts/check_text.py refuses in a tracked file.
    errors_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | errors_fixture()
    emit("gam_errors.json", json.dumps(errors_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_errors.json: {len(errors_doc['cases'])} cases")

    # GAM's output, read into records as GamGUI reads it (its CSV in GAM's dialect). ASCII-escaped, like
    # gam_errors.json.
    output_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | output_fixture(OUT / "mock_gam.sh", oracle)
    emit("gam_output.json", json.dumps(output_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_output.json: {len(output_doc['cases'])} cases")

    # Records read into users, groups and members, as GamGUI's models read them.
    models_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | models_fixture(OUT / "mock_gam.sh")
    emit("gam_models.json", json.dumps(models_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_models.json: {sum(len(models_doc[k]) for k in ('users', 'groups', 'members', 'calendar_acls', 'user_calendars', 'resources'))} records")

    # The destructive-operation guard: what a change set needs, and whether a confirmation is enough.
    guard_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | guard_fixture()
    emit("guard.json", json.dumps(guard_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"guard.json: {len(guard_doc['cases'])} cases")

    # The audit log: the line each record writes, and the records a reader finds across generations.
    audit_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | audit_fixture()
    emit("audit.json", json.dumps(audit_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"audit.json: {len(audit_doc['written'])} records, {len(audit_doc['records'])} read back")

    # The directory's reports over those users, as GamGUI's Home and Reports count them.
    reports_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | reports_fixture(OUT / "mock_gam.sh")
    emit("reports.json", json.dumps(reports_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"reports.json: {len(reports_doc['records'])} users")

    # The Audit screen: its filter, pages and CSV export over a log of odd records.
    audit_screen_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | audit_screen_fixture()
    emit("audit_screen.json", json.dumps(audit_screen_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"audit_screen.json: {audit_screen_doc['read']} records, {len(audit_screen_doc['pages'])} pages")

    # The usage report: GAM's CSV after its progress, the rows parsed, and the dates the walk back asks for.
    usage_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | usage_fixture(OUT / "mock_gam.sh")
    emit("usage_report.json", json.dumps(usage_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"usage_report.json: {len(usage_doc['walks'])} walks")

    # The guided setup: the delegation step's facts and link, and the fresh-setup Terminal commands.
    setup_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | setup_fixture()
    emit("setup.json", json.dumps(setup_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"setup.json: {len(setup_doc['facts'])} facts, {len(setup_doc['setup_commands'])} command sets")

    # The auto-reply: show vacation's text, and the HTML body to and from the operator's text.
    vacation_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | vacation_fixture(OUT / "mock_gam.sh")
    emit("vacation.json", json.dumps(vacation_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"vacation.json: {len(vacation_doc['autoreply_text'])} bodies, {len(vacation_doc['unescape'])} references")

    # Signatures: GamGUI's render, curly-quote check and show-signature reader, and GAM's own handling of
    # the signature argument, run from the build.
    signature_doc = {"source": {"gamgui_commit": commit, "gam_version": gam_version,
                                "generator": "scripts/gen_fixtures.py"}} | signature_fixture(OUT / "mock_gam.sh", oracle)
    emit("signatures.json", json.dumps(signature_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"signatures.json: {len(signature_doc['render'])} renders, {len(signature_doc['parse_signature'])} shown texts")

    # Offboarding: GamGUI's routine and its preview's checks and words.
    offboarding_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | offboarding_fixture(OUT / "mock_gam.sh")
    emit("offboarding.json", json.dumps(offboarding_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"offboarding.json: {len(offboarding_doc['steps'])} routines, {len(offboarding_doc['check_addresses'])} "
          f"address checks")
    # Onboarding: GamGUI's core for one hire, the new-account wait's words and test, and its role file's
    # load, never over the operator's own stores.
    onboarding_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | onboarding_fixture(errors_doc["cases"])
    emit("onboarding.json", json.dumps(onboarding_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"onboarding.json: {len(onboarding_doc['provision'])} hires, {len(onboarding_doc['load'])} role files")
    # The roster reader: GamGUI's read_upload over every package its tests build, and more. ASCII-escaped: the inputs
    # hold control and invisible characters on purpose.
    roster_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | roster_fixture(gamgui)
    emit("roster.json", json.dumps(roster_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"roster.json: {len(roster_doc['cases'])} packages")
    # The change list (C3) and its hand-over (C4): GamGUI's plan over every call its tests make, and the hand-over's bytes.
    plan_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | roster_plan_fixture(gamgui)
    emit("roster_plan.json", json.dumps(plan_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"roster_plan.json: {len(plan_doc['cases'])} change lists")
    handover_doc = handover_fixture(gamgui)
    handover_files = handover_doc.pop("files")
    emit("roster_handover.json", json.dumps({"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}}
                                            | handover_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"handover/: {len(handover_files)} files, GamGUI's own byte for byte")
    csv_as_the_build_writes(oracle)
    for name, text in pending:
        (OUT / name).write_text(text)
    # The hand-over's bytes, written as they are (CRLF kept): the folder holds exactly GamGUI's files.
    (OUT / "handover").mkdir(exist_ok=True)
    for old in (OUT / "handover").iterdir():
        old.unlink()
    for name, body in handover_files.items():
        (OUT / "handover" / name).write_bytes(body)
    print(f"CSV: {len(CSV_WRITTEN)} writes, byte for byte as the build's CPython {oracle.version} writes them")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
