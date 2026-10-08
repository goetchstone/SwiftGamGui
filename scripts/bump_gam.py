#!/usr/bin/env python3
"""Bump the vendored GAM to a target version: GamGUI's scripts/bump_gam.py, repointed at this repo.

In order:

  1. download the release asset and verify GitHub's build attestation for it (`gh attestation
     verify`, signed by GAM-team/GAM's release workflow on its main branch). That is the trust anchor
     that lets the pin be written automatically without becoming trust-on-first-use;
  2. write that asset's SHA-256 into scripts/gam_checksums.txt;
  3. re-vendor through scripts/fetch_gam.sh, which verifies the download against that pin;
  4. bump GamVersion.expected (Swift) and fetch_gam.sh's TAG;
  5. point the test mock's `gam version` at the new number (the mock must match the real GAM);
  6. regenerate the browse catalog and the parity fixtures (argv, exit codes).

Not here, because it needs judgment or a real tenant: reading GamUpdate.txt for breaking changes, and
the live acceptance pass. GamGUI is frozen but still takes GAM updates: bump it with its own script.

Run with GamGUI's virtualenv Python (steps 6 borrow its frozen parser and builders, read-only):

    ../gamgui/.venv/bin/python -I -B scripts/bump_gam.py vX.Y.Z [--gamgui ../gamgui] [--allow-unattested]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "GAM-team/GAM"
# The one workflow, ref and runner kind that sign GAM's release assets. `--repo` alone accepts an
# attestation from any workflow in the repo, so pin all three; if GAM-team moves its build, the bump
# fails closed and a human looks.
SIGNER_WORKFLOW = f"{REPO}/.github/workflows/build.yml"
SOURCE_REF = "refs/heads/main"
CHECKSUMS = ROOT / "scripts" / "gam_checksums.txt"
FETCH = ROOT / "scripts" / "fetch_gam.sh"
VERSION_SWIFT = ROOT / "Packages" / "GamKit" / "Sources" / "GamEngine" / "GamVersion.swift"
MOCK = ROOT / "Tests" / "Fixtures" / "mock_gam.sh"


def select_asset(release: dict, arch: str) -> "tuple[str, str]":
    """`(asset_name, download_url)` for the macOS asset, mirroring fetch_gam.sh: highest ``macosNN``."""
    cands = []
    for a in release.get("assets", []):
        name = a["name"]
        if "macos" in name and arch in name and name.endswith(".tar.xz"):
            m = re.search(r"macos(\d+)", name)
            cands.append((int(m.group(1)) if m else 0, name, a["browser_download_url"]))
    if not cands:
        raise SystemExit(f"no macOS/{arch} .tar.xz asset in the release")
    cands.sort()
    _, name, url = cands[-1]
    return name, url


def attest_argv(blob: "Path | str") -> list:
    """The `gh attestation verify` call that gates the pin."""
    return ["gh", "attestation", "verify", str(blob), "--repo", REPO,
            "--signer-workflow", SIGNER_WORKFLOW, "--source-ref", SOURCE_REF, "--deny-self-hosted-runners"]


def bump_version_strings(version: str) -> None:
    v = version.lstrip("v")
    _sub(VERSION_SWIFT, r'public static let expected = "[0-9.]+"', f'public static let expected = "{v}"')
    _sub(FETCH, r'^TAG="v[0-9.]+"', f'TAG="v{v}"', flags=re.MULTILINE)


def bump_mock_version(version: str) -> None:
    v = version.lstrip("v")
    _sub(MOCK, r'echo "GAM [0-9.]+ - mock"', f'echo "GAM {v} - mock"')


def _sub(path: Path, pattern: str, repl: str, flags: int = 0) -> None:
    text = path.read_text()
    new, n = re.subn(pattern, repl, text, flags=flags)
    if n == 0:
        raise SystemExit(f"{path.name}: pattern not found, refusing to guess: {pattern!r}")
    path.write_text(new)


def _arch() -> str:
    m = platform.machine().lower()
    return "arm64" if m in ("arm64", "aarch64") else "x86_64"


def main() -> int:
    ap = argparse.ArgumentParser(description="Bump the vendored GAM to a target version.")
    ap.add_argument("version", help="e.g. v7.48.23")
    ap.add_argument("--gamgui", default=str(ROOT.parent / "gamgui"), help="path to the GamGUI checkout")
    ap.add_argument("--allow-unattested", action="store_true",
                    help="skip the GitHub build-attestation check (NOT for a real build)")
    args = ap.parse_args()
    version = args.version if args.version.startswith("v") else f"v{args.version}"

    rel = json.loads(_run(["gh", "api", f"repos/{REPO}/releases/tags/{version}"]))
    asset, url = select_asset(rel, _arch())
    print(f"==> {asset}")

    with tempfile.TemporaryDirectory() as td:
        blob = Path(td) / asset
        print("==> downloading…")
        urllib.request.urlretrieve(url, blob)  # noqa: S310 — GitHub release URL from the API above
        if args.allow_unattested:
            print("!! WARNING: skipping attestation — the pin will be trust-on-first-use.")
        else:
            print("==> verifying GitHub build attestation…")
            _run(attest_argv(blob))   # fail closed: no verified provenance -> no pin
            print("    attestation OK.")
        sha = _sha256(blob)

    _write_pin(asset, sha)
    print(f"==> pinned {sha}  {asset}")

    _run(["bash", str(FETCH), "--tag", version], cwd=ROOT, stream=True)
    bump_version_strings(version)
    bump_mock_version(version)
    py = [sys.executable, "-I", "-B"]
    _run([*py, str(ROOT / "scripts" / "build_command_catalog.py"), "--gamgui", args.gamgui], cwd=ROOT, stream=True)
    _run([*py, str(ROOT / "scripts" / "gen_fixtures.py"), "--gamgui", args.gamgui], cwd=ROOT, stream=True)

    print(f"\n==> bumped to {version}. Now run:  swift test --package-path Packages/GamKit")
    print("    then skim Vendor/gam7/GamUpdate.txt and run the live acceptance pass with the operator.")
    return 0


def _write_pin(asset: str, sha: str) -> None:
    lines = [ln for ln in CHECKSUMS.read_text().splitlines()
             if ln.startswith("#") or (ln.strip() and not ln.split()[1].startswith("gam-"))]
    lines.append(f"{sha}  {asset}")
    CHECKSUMS.write_text("\n".join(lines) + "\n")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _run(cmd: list, cwd: "Path | None" = None, stream: bool = False) -> str:
    if stream:
        subprocess.run(cmd, cwd=cwd, check=True)
        return ""
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout


if __name__ == "__main__":
    raise SystemExit(main())
