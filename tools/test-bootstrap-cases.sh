#!/usr/bin/env bash
# The tests/cases/modules/bootstrap-*.ab programs import the compiler's own sources (src/ir.ab, src/subparser.ab,
# src/eval.ab, ...) and check one of its pieces at run time, exiting 42 (bootstrap-llvm 0). Nothing else built them,
# so four went stale against src/ unnoticed (their parity rows read runtime-skipped until 2026-11-16). Each must build
# (--fast) and run as expected.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
cd "$project_root"
out=build/bootstrap-cases
rm -rf "$out"; mkdir -p "$out"
cases=(tests/cases/modules/bootstrap-*.ab)
[[ ${#cases[@]} -ge 8 ]] || { echo "bootstrap cases: expected at least 8, found ${#cases[@]}" >&2; exit 1; }
check() { # case
    local name
    name=$(basename "$1" .ab)
    "$compiler" build "$1" -o "$out/$name" --fast --no-cache > "$out/$name.log" 2>&1 ||
        { echo "bootstrap cases: $name doesn't build (stale against src/?):" >&2; grep -m5 '^error' "$out/$name.log" >&2; return 1; }
    local status=0
    "$out/$name" > "$out/$name.out" 2>&1 || status=$?
    # bootstrap-llvm's main returns the IR it emits as a string (nothing printed): it must run and exit 0. The others
    # exit 42.
    local want=42
    [[ $name != bootstrap-llvm ]] || want=0
    [[ $status -eq $want ]] || { echo "bootstrap cases: $name exited $status, expected $want" >&2; return 1; }
}
export -f check
export compiler out
printf '%s\0' "${cases[@]}" | xargs -0 -n1 -P4 bash -c 'check "$1"' check
echo "bootstrap cases: ${#cases[@]} programs built from the compiler's own sources each run as expected"
