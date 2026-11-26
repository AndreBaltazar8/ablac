#!/usr/bin/env bash
# Values an expression holds in temporaries while its thread is parked in a blocking call must be rooted when another thread collects
# (#1139 area 10, #1279 follow-up, tests/cases/gc-blocking-roots): `verify(buildStrings(), buildObject(), sleepNanoseconds(...))` and the same
# with `await` of a sleeping thread, in ordinary code, while the main thread allocates and collects. Plain, with ABLA_GC_POISON=1 and with
# ABLA_GC_STRESS=1 as well.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'gc blocking roots: Linux only'; exit 0; }
out="$root/build/gc-blocking-roots"
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/gc-blocking-roots/main.ab -o "$out/roots" --no-cache > "$out/build.log" 2>&1 \
    || { cat "$out/build.log" >&2; echo 'gc blocking roots: did not build' >&2; exit 1; }
for variant in "ABLA_GC_X=0" "ABLA_GC_POISON=1" "ABLA_GC_STRESS=1 ABLA_GC_POISON=1"; do
    status=0
    result=$(env $variant timeout 300 "$out/roots" 2>&1) || status=$?
    [[ $status -eq 0 && $result == "gc blocking roots ok"* ]] ||
        { echo "gc blocking roots ($variant): status $status: $(echo "$result" | head -3)" >&2; exit 1; }
done
echo "gc blocking roots: $result"
