#!/usr/bin/env bash
# The root plan's soundness, one minimal program per kind of instruction that can lead to a collection (#1139 area 7, round 4,
# tests/cases/gc-root-plan): the values a caller holds (strings, an array, an object) are live across only that instruction, once as
# expression temporaries and once as locals, under ABLA_GC_STRESS=1 (a collection at every safe point) and ABLA_GC_POISON=1 (what a
# collection frees is overwritten). Every case must print its name three times with 0 wrong values, and the program must end normally
# (an awaited task freed under its own body once ended in SIGILL).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'gc root plan: Linux only'; exit 0; }
out="$root/build/gc-root-plan"
rm -rf "$out"
mkdir -p "$out"
cases=(call callop indirect generator task thread drop loop explicit)
"$compiler" build tests/cases/gc-root-plan/main.ab -o "$out/plan" --no-cache > "$out/build.log" 2>&1 \
    || { cat "$out/build.log" >&2; echo 'gc root plan: did not build' >&2; exit 1; }
for variant in "ABLA_GC_X=0" "ABLA_GC_POISON=1" "ABLA_GC_STRESS=1 ABLA_GC_POISON=1"; do
    status=0
    env $variant timeout 300 "$out/plan" > "$out/run.out" 2>&1 || status=$?
    [[ $status -eq 0 ]] || { echo "gc root plan ($variant): status $status after: $(tail -2 "$out/run.out" | tr '\n' ' ')" >&2; exit 1; }
    for name in "${cases[@]}"; do
        for holder in temp local; do
            [[ $(grep -c "^$name-$holder=0$" "$out/run.out") -eq 3 ]] ||
                { echo "gc root plan ($variant): $name-$holder: $(grep "^$name-$holder=" "$out/run.out" | tr '\n' ' ')" >&2; exit 1; }
        done
    done
done
echo "gc root plan: ${#cases[@]} kinds, temporaries and locals, plain, poison and stress all hold"
