#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/export-reflection-test
mkdir -p "$out"
for tier in interp auto jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build tests/cases/export-reflection/main.ab -o "$out/$tier" --no-cache
    "$out/$tier"
done
# The experimental journal cannot reconstruct array arguments. This query
# must remain explicitly unreplayable there; the ordinary build cache below
# still tracks imported annotation edits.
ABLA_ACTION_JOURNAL=1 ABLA_COMPILE_EVAL=interp "$compiler" --emit-llvm tests/cases/export-reflection/main.ab \
    > /dev/null 2> "$out/journal.log"
grep -q 'compilerExportedNames|a' "$out/journal.log"
grep -q 'calls=.*replayable=false.*extern compilerExportedNames' "$out/journal.log"
# Cached builds must re-reflect when an imported annotation changes, even when
# the function name and signature stay the same.
cp tests/cases/export-reflection/{main,helper,through}.ab "$out/"
"$compiler" build "$out/main.ab" -o "$out/cached"
"$out/cached"
sed -i 's/reflection_helper_z/reflection_helper_y/g' "$out/helper.ab"
"$compiler" build "$out/main.ab" -o "$out/cached"
if "$out/cached"; then
    echo 'export reflection: a cached query ignored an imported annotation edit' >&2
    exit 1
fi
cat > "$out/runtime.ab" <<'AB'
import "abla/compiler"
fun main: int = compilerExportedNames([]).size
AB
if "$compiler" build "$out/runtime.ab" -o "$out/runtime" > "$out/runtime.log" 2>&1; then
    echo 'export reflection: a compile-only query was accepted at runtime' >&2
    exit 1
fi
grep -q 'compile.call-runtime' "$out/runtime.log"
cat > "$out/invalid.ab" <<'AB'
import "abla/compiler"
val names = #compiler.exportedNames([42])
fun main: int = 0
AB
if "$compiler" build "$out/invalid.ab" -o "$out/invalid" > "$out/invalid.log" 2>&1; then
    echo 'export reflection: a non-string module identity was accepted' >&2
    exit 1
fi
tools/gen-static-libc-symbols.sh "$compiler" --check
echo 'export reflection: annotation arrays, module sets, aliases, reachability, tiers, cache invalidation and snapshot passed'
