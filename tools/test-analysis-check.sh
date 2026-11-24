#!/usr/bin/env bash
# The editor service's incremental analysis against a cold one (ABLA_ANALYSIS_CHECK=1: after each analysis the service runs the same
# analysis with nothing kept and compares the two answers document by document, and says so on standard error), over randomised edits
# of the compiler's own source (and abla-one in the full form). The seeds are fixed so a failure repeats; ANALYSIS_CHECK_SEED and
# ANALYSIS_CHECK_EDITS change them (a longer loop for a change to the analysis).
set -euo pipefail
# The editor service answers a request that outruns ABLA_ANALYSIS_BUDGET_MS (60 s by default) with an incomplete result. These analyse the compiler's own source and run
# beside other tests, so they give it the longest budget: a loaded run would otherwise compare an incomplete answer with a complete one (#1206).
export ABLA_ANALYSIS_BUDGET_MS=${ABLA_ANALYSIS_BUDGET_MS:-600000}
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
seed=${ANALYSIS_CHECK_SEED:-7}
# The short form (the suite: the self-test and one seeded edit, about a minute) and the full one (six edits, and abla-one where it sits beside
# this checkout): `make test-full` (RUN_TESTS_FULL=1), or ANALYSIS_CHECK_FULL=1 for a batch gate or a change to the analysis.
full=0
[[ ${RUN_TESTS_FULL:-0} == 1 || ${ANALYSIS_CHECK_FULL:-0} == 1 ]] && full=1
if (( full )); then edits=${ANALYSIS_CHECK_EDITS:-6}; else edits=${ANALYSIS_CHECK_EDITS:-1}; fi
# The since comparison on the compiler's own source (and abla-one) only in the full form: it parses the whole answer twice per analysis.
since=""
(( full )) && since=1
root=$(mktemp -d /tmp/analysis-check.XXXXXX)
trap 'rm -rf "$root"' EXIT
cp -R "$project_root/src" "$project_root/stdlib" "$project_root/runtime" "$root/"
# The check reports a difference when there is one: on a two-file program (an analysis of src/ costs seconds, and says no more).
tiny=$(mktemp -d /tmp/analysis-check-tiny.XXXXXX)
trap 'rm -rf "$root" "$tiny"' EXIT
printf 'import "dep.ab"\nfun main(): int = answer()\n' > "$tiny/main.ab"
printf 'fun answer(): int = 42\n' > "$tiny/dep.ab"
printf 'name = "tiny"\nentry = "main.ab"\n' > "$tiny/abla.toml"
# The since answers against the full ones, on the same program with a few edits (the compiler's own source in the full form: below).
ANALYSIS_CHECK_SINCE=1 ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
    node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$tiny" main.ab "$seed" 3
ANALYSIS_CHECK_SELFTEST=1 ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
    node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$tiny" main.ab "$seed" 0
ANALYSIS_CHECK_SINCE=$since ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
    node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$root" src/orc_main.ab "$seed" "$edits"
# abla-one, where it sits beside this checkout (or ABLA_ONE_DIR): a program of another shape (packages, a UI, a different import graph).
one=${ABLA_ONE_DIR:-$project_root/../abla-one}
if (( full )) && [[ -f $one/abla.toml ]]; then
    ONE_ROOT=$(mktemp -d /tmp/analysis-check-one.XXXXXX)
    trap 'rm -rf "$root" "$tiny" "$ONE_ROOT"' EXIT
    (cd "$one" && tar --exclude=./build --exclude=./.git -cf - .) | tar -xf - -C "$ONE_ROOT"
    ANALYSIS_CHECK_SINCE=$since ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
        node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$ONE_ROOT" src/one.ab "$seed" "$edits"
fi
