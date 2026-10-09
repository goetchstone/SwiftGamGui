#!/usr/bin/env bash
# Builds and runs the libFuzzer target Fuzz/GamFuzz.swift. Linux only: Apple's toolchain ships no
# libFuzzer runtime. CI's `fuzz` job runs it in the pinned Swift image; on a Mac, the same through Docker:
#
#   docker run --rm -v "$PWD":/src -w /src swift:6.4@<digest in .github/workflows/ci.yml> \
#     scripts/fuzz.sh -seed=1 -runs=200000 -max_len=4096
#
# Arguments go to libFuzzer; pass a crash file to reproduce it. Only GamEngine's platform-free sources are
# compiled in (the rest need Darwin), as one module with the fuzz entry point.
set -euo pipefail
cd "$(dirname "$0")/.."

engine=Packages/GamKit/Sources/GamEngine
out="${FUZZ_OUT:-${TMPDIR:-/tmp}/gamfuzz}"
mkdir -p "$out"
swiftc -sanitize=fuzzer,address -parse-as-library -package-name gamfuzz -module-name GamFuzz \
  Fuzz/GamFuzz.swift \
  "$engine"/GamChoices.swift "$engine"/GamCommand.swift "$engine"/GamCommands.swift \
  "$engine"/GamError.swift "$engine"/GamOutput.swift "$engine"/JSONValue.swift "$engine"/PythonText.swift \
  -o "$out/gamfuzz"
exec "$out/gamfuzz" -dict=Fuzz/gam.dict "$@"
