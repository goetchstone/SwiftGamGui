#!/usr/bin/env python3
"""Generate the parity fixtures SwiftGamGui's tests hold the Swift code to.

GamGUI (the Python app) is frozen and its argv builders are live-proven, so they are the reference:

  Tests/Fixtures/argv.json        every GAMCommands builder, called over GamGUI's own test inputs
                                  (the grammar contract's enumeration, the mock tests' concrete calls)
                                  plus deterministic edge cases from its property-test specs. Each case
                                  records the full keyword arguments and either the argv or the error.
  Tests/Fixtures/gam_errors.json  GamGUI's classification, message and scrubbing of failed GAM runs
                                  (core/gam/errors.py) over its own and generated stderr, with the
                                  Unicode tables its regexes use.
  Tests/Fixtures/gam_output.json  GamGUI's parse_records over the mock's output for every read, its
                                  property tests' JSON/CSV shapes and noise, and the inputs its
                                  failure log names.
  Tests/Fixtures/gam_models.json  GamGUI's user, group and member models over the mock's records and
                                  seeded variants.
  Tests/Fixtures/guard.json       GamGUI's guard (evaluate, enforce, alias_deletes) over seeded change
                                  sets and confirmations.
  Tests/Fixtures/audit.json       GamGUI's audit log: the line each record writes, and what its reader
                                  finds across generations.
  Tests/Fixtures/reports.json     GamGUI's directory reports over the mock's users and seeded variants.
  Tests/Fixtures/setup.json       GamGUI's guided setup: the delegation step's client ID, Admin-console
                                  link and sign-out-scope note, and the fresh-setup Terminal commands.
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
    """GamGUI's GAMError.from_run over GAM's known stderr lines and their case, indent and counter
    variants, mixed stderrs, progress chatter and instructions, timeouts, missing-scope lines, echoed
    passwords, Unicode and boundary edges, and seeded random text: what the Swift GamError must say."""
    import random
    import re
    import unicodedata

    from gamgui.core.audit import _SENSITIVE_KEYS
    from gamgui.core.gam.errors import _REMEDIATION, _SEVERITY, ACCOUNT_WIDE_KINDS, GAMError
    from tests.test_props_errors import _KNOWN, _gam_usage_error

    def run(exit_code, stderr, argv=None, stdout=""):
        err = GAMError.from_run(exit_code, stderr, argv, stdout=stdout)
        return {"exit_code": exit_code, "stderr": stderr, "argv": argv, "stdout": stdout,
                "kind": err.kind.value, "kinds": sorted(k.value for k in err.kinds), "message": err.message,
                "scrubbed_stderr": err.stderr, "scrubbed_stdout": err.stdout, "redacted_argv": err.argv,
                "remediation_suffix": err.remediation[len(_REMEDIATION[err.kind]):]}

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
    """GamGUI's parse_records over GAM's output shapes: what the strict mock prints for every read the
    app makes; the JSON, CSV and formatjson shapes and the noise GamGUI's property tests generate
    (drawn deterministically); and the inputs its failure log names (a long cell, a bare CR, deep
    nesting, raw line separators in NDJSON, an empty header) with JSON's and CSV's own edges. The
    records are stored as Python's json.dumps text, NaN and Infinity included."""
    from hypothesis import HealthCheck, Phase, given, seed, settings
    from hypothesis import strategies as st

    from gamgui.core.gam.parser import parse_records
    from tests import test_props_parsing as props

    cases = []

    def add(stdout: str) -> None:
        cases.append({"stdout": stdout, "records": json.dumps(parse_records(stdout), ensure_ascii=True)})

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
    for text, _ in drawn(props._plain_csv(), 120):
        add(text)
    for text, _ in drawn(props._formatjson_csv(), 120):
        add(text)
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
    for text in edges:
        add(text)

    seen, unique = set(), []
    for case in cases:
        key = json.dumps(case, sort_keys=True)
        if key not in seen:
            seen.add(key)
            unique.append(case)
    return {"cases": unique}


def mock_outputs(mock: Path) -> dict:
    """What the strict mock prints for every read the app makes, by builder."""
    import subprocess
    import tempfile

    from gamgui.core.gam.runner import strip_cfgdir_noise
    from tests.test_mock_gam import READS

    outputs = {}
    with tempfile.TemporaryDirectory() as config:
        for name in ("oauth2service.json", "oauth2.txt"):
            Path(config, name).write_text('{"placeholder": true}')
        environment = {"PATH": "/usr/bin:/bin", "GAMCFGDIR": config,
                       "GAM_MOCK_FIXTURES": str(mock.parent / "mock_gam")}
        for builder, argvs in READS.items():
            for argv in argvs:
                run = subprocess.run([str(mock), *argv], capture_output=True, text=True, env=environment)
                if run.returncode != 0:
                    raise SystemExit(f"the mock refused a read: {argv}")
                # As GamGUI's runner hands it on: without the first-run banner naming the config dir.
                outputs.setdefault(builder, []).append(strip_cfgdir_noise(run.stdout, Path(config)))
    return outputs


def models_fixture(mock: Path) -> dict:
    """GamGUI's GAMUser, GAMGroup and GroupMember.from_json over the mock's records and seeded variants
    of them: the alternate keys GAM uses across commands, flags as booleans, words or numbers, counts
    as numbers or text, primary entries in Directory lists. String fields hold strings (or nothing):
    that is how GAM sends them."""
    import dataclasses
    import random

    from gamgui.core.gam.models import GAMGroup, GAMUser, GroupMember
    from gamgui.core.gam.parser import parse_records

    outputs = mock_outputs(mock)
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

    users = [r for name in ("print_users", "info_user") for out in outputs[name] for r in parse_records(out)]
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

    groups = [r for out in outputs["print_groups"] for r in parse_records(out)]
    members = [r for name in ("print_group_members",) for out in outputs[name] for r in parse_records(out)]
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
    from gamgui.core.gam.parser import parse_records
    from gamgui.core.reports import build_reports

    now = datetime(2026, 10, 8, 12, 0, tzinfo=timezone.utc)
    records = [r for out in mock_outputs(mock)["print_users"] for r in parse_records(out)][:]
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
    return {"dwd_scopes": [list(pair) for pair in setup.DWD_SCOPES],
            "user_security_scope": setup.USER_SECURITY_SCOPE,
            "admin_console_dwd_url": setup.ADMIN_CONSOLE_DWD_URL,
            "facts": facts, "user_security": security, "setup_commands": commands}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gamgui", default=str(ROOT.parent / "gamgui"), help="path to the GamGUI checkout")
    ap.add_argument("--gam-binary", default=str(ROOT / "Vendor" / "gam7" / "gam"))
    args = ap.parse_args()
    gamgui = Path(args.gamgui).resolve()
    sys.path.insert(0, str(gamgui))

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

    # GAM's failures, classified and scrubbed as GamGUI does. ASCII-escaped: it holds the invisible
    # characters scripts/check_text.py refuses in a tracked file.
    errors_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | errors_fixture()
    (OUT / "gam_errors.json").write_text(json.dumps(errors_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_errors.json: {len(errors_doc['cases'])} cases")

    # GAM's output, read into records as GamGUI reads it. ASCII-escaped, like gam_errors.json.
    output_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | output_fixture(OUT / "mock_gam.sh")
    (OUT / "gam_output.json").write_text(json.dumps(output_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_output.json: {len(output_doc['cases'])} cases")

    # Records read into users, groups and members, as GamGUI's models read them.
    models_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} \
        | models_fixture(OUT / "mock_gam.sh")
    (OUT / "gam_models.json").write_text(json.dumps(models_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"gam_models.json: {sum(len(models_doc[k]) for k in ('users', 'groups', 'members'))} records")

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

    # The guided setup: the delegation step's facts and link, and the fresh-setup Terminal commands.
    setup_doc = {"source": {"gamgui_commit": commit, "generator": "scripts/gen_fixtures.py"}} | setup_fixture()
    (OUT / "setup.json").write_text(json.dumps(setup_doc, indent=1, ensure_ascii=True) + "\n")
    print(f"setup.json: {len(setup_doc['facts'])} facts, {len(setup_doc['setup_commands'])} command sets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
