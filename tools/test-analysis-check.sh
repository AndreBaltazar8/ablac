#!/usr/bin/env bash
# The editor service's incremental analysis against a cold one (ABLA_ANALYSIS_CHECK=1: after each analysis the service runs the same
# analysis with nothing kept and compares the two answers document by document, and says so on standard error), over randomised edits
# of the compiler's own source (and abla-one in the full form). The seeds are fixed so a failure repeats; ANALYSIS_CHECK_SEED and
# ANALYSIS_CHECK_EDITS change them (a longer loop for a change to the analysis).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
seed=${ANALYSIS_CHECK_SEED:-7}
# The short form (the suite: the self-test and one seeded edit, about a minute) and the full one (six edits, and abla-one where it sits beside
# this checkout): `make test-full` (RUN_TESTS_FULL=1), or ANALYSIS_CHECK_FULL=1 for a batch gate or a change to the analysis.
full=0
[[ ${RUN_TESTS_FULL:-0} == 1 || ${ANALYSIS_CHECK_FULL:-0} == 1 ]] && full=1
if (( full )); then edits=${ANALYSIS_CHECK_EDITS:-6}; else edits=${ANALYSIS_CHECK_EDITS:-1}; fi
root=$(mktemp -d /tmp/analysis-check.XXXXXX)
trap 'rm -rf "$root"' EXIT
cp -R "$project_root/src" "$project_root/stdlib" "$project_root/runtime" "$root/"
# The check reports a difference when there is one: on a two-file program (an analysis of src/ costs seconds, and says no more).
tiny=$(mktemp -d /tmp/analysis-check-tiny.XXXXXX)
trap 'rm -rf "$root" "$tiny"' EXIT
printf 'import "dep.ab"\nfun main(): int = answer()\n' > "$tiny/main.ab"
printf 'fun answer(): int = 42\n' > "$tiny/dep.ab"
printf 'name = "tiny"\nentry = "main.ab"\n' > "$tiny/abla.toml"
ANALYSIS_CHECK_SELFTEST=1 ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
    node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$tiny" main.ab "$seed" 0
ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
    node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$root" src/orc_main.ab "$seed" "$edits"
# abla-one, where it sits beside this checkout (or ABLA_ONE_DIR): a program of another shape (packages, a UI, a different import graph).
one=${ABLA_ONE_DIR:-$project_root/../abla-one}
if (( full )) && [[ -f $one/abla.toml ]]; then
    ONE_ROOT=$(mktemp -d /tmp/analysis-check-one.XXXXXX)
    trap 'rm -rf "$root" "$tiny" "$ONE_ROOT"' EXIT
    (cd "$one" && tar --exclude=./build --exclude=./.git -cf - .) | tar -xf - -C "$ONE_ROOT"
    ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=12288 ABLA_MAX_SECONDS=3000 ABLA_MAX_CPU_SECONDS=2400 \
        node "$project_root/tests/analysis-check/run.mjs" "$project_root/tools/run-limited.sh" "$compiler" "$ONE_ROOT" src/one.ab "$seed" "$edits"
fi
