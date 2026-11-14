#!/usr/bin/env bash
# The Abla port of the differential fuzzer (tools/fuzz), kept short for the suite: the PRNG's reference vectors and
# the comparison self-test, a planted disagreement that the minimiser must find and reduce, a check's own oracle
# failure and a shared non-zero exit through the real six-way runner, two fixed seeds, and the recorded cases. Long
# campaigns run outside the suite (tools/fuzz/run --seeds ...).
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
fuzz() { tools/fuzz/run --compiler "$compiler" "$@"; }

fuzz --selftest
fuzz --control-minimise

controls=build/fuzz-abla/controls
mkdir -p "$controls"
printf 'import "abla/io"\n\n@export("run")\nfun run(): int {\n    println("c0=FUZZ_ORACLE_FAILURE:control")\n    0\n}\n\nfun main: int = run()\n' \
    > "$controls/oracle.ab"
printf 'import "abla/io"\n\n@export("run")\nfun run(): int {\n    println("c0=1")\n    3\n}\n\nfun main: int = run()\n' \
    > "$controls/status.ab"
if output=$(fuzz --program "$controls/oracle.ab"); then
    echo "fuzz: a failed oracle line was not reported: $output" >&2
    exit 1
fi
[[ $output == *"result oracle failed"* ]] || { echo "fuzz: oracle control: $output" >&2; exit 1; }
if output=$(fuzz --program "$controls/status.ab"); then
    echo "fuzz: a shared non-zero exit was not reported: $output" >&2
    exit 1
fi
[[ $output == *"exited with status 3"* ]] || { echo "fuzz: status control: $output" >&2; exit 1; }
echo "fuzz: an oracle failure and a non-zero exit are reported through every mode"

fuzz --seeds 100000-100001 --checks 12
fuzz --replay
