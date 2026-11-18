#!/usr/bin/env bash
# A `#` site whose native result is 2000 objects (tests/cases/ct-lift-large) is typed back with a few searches of the
# program's declarations, not several per value: the retyper scanned every declaration for each value's type and
# searched every aggregate typed before it, so the lift grew with the square of the value and kept the game client's
# compile-time screenshot build going for minutes after its sites had finished (#1022). The trace counts the searches
# (`typed back N aggregates ... with M declaration searches`). It agrees with run time.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-lift-large"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-lift-large"
fail() { echo "ct lift large: $*" >&2; exit 1; }
ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/p" --fast --no-cache \
    > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; fail "the build failed"; }
grep -q 'note\[ct-jit\]: native at main.ab' "$out/build.log" ||
    { cat "$out/build.log" >&2; fail "the site didn't run natively"; }
line=$(grep -o 'typed back [0-9]* aggregates at main.ab[^ ]* with [0-9]* declaration searches' "$out/build.log") ||
    { grep 'ct-jit' "$out/build.log" >&2; fail "no typed-back note"; }
read -r aggregates searches < <(sed -E 's/typed back ([0-9]+) aggregates .* with ([0-9]+) declaration searches/\1 \2/' <<< "$line")
(( aggregates > 2000 )) || fail "only $aggregates aggregates typed back: $line"
(( searches <= 8 )) || fail "$searches declaration searches for $aggregates aggregates (one per type expected): $line"
read -r runtime compiled < <("$out/p")
[[ $runtime == "2000:259952" && $compiled == "2000:259952" ]] || fail "run time '$runtime', under # '$compiled'"
echo "ct lift large: a native result of 2000 objects is typed back with $searches declaration searches and agrees with run time"
