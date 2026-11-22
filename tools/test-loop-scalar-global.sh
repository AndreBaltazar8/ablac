#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -s)-$(uname -m) != Linux-x86_64 ]]; then
    echo 'loop scalar global: x86-64 Linux only'
    exit 0
fi
compiler=${1:-build/ablac}
out=build/loop-scalar-global
mkdir -p "$out"
ABLA_KEEP_LLVM_TEXT=1 "$compiler" build tests/cases/loop-optimization/scalar-global.ab \
    -o "$out/program" --no-cache
expected=$'15 15\n63 63\n63 63\n36 13\n2 3\n1'
[[ $("$out/program") == "$expected" ]]

body_of() {
    local attribute
    attribute=$(sed -n "s/^attributes \(#[0-9]*\) = .*\"abla.source\"=\"$1\".*/\1/p" "$out/program.ll")
    [[ -n $attribute ]]
    awk -v attribute="$attribute" '
        /^define / && index($0, " " attribute " {") { inside = 1 }
        inside { print }
        inside && /^}/ { exit }' "$out/program.ll"
}

body_of advance > "$out/isolated.ll"
body_of advanceObserved > "$out/observed.ll"
body_of advancePacked > "$out/packed.ll"
body_of advanceGeneral > "$out/general.ll"
grep -q 'dense.array.in.bounds' "$out/packed.ll"
grep -q "%loop.global.slot" "$out/general.ll"
if grep -q 'dense.array.in.bounds' "$out/general.ll"; then exit 1; fi
grep -q '%loop.global.slot = alloca i64' "$out/isolated.ll"
[[ $(grep -c 'load i64, ptr @abla_global_' "$out/isolated.ll") == 1 ]]
[[ $(grep -c 'store i64 %loop.global.final.*ptr @abla_global_' "$out/isolated.ll") == 2 ]]
if grep -q '%loop.global.slot' "$out/observed.ll"; then exit 1; fi
grep -q 'load i64, ptr @abla_global_' "$out/observed.ll"
ABLA_KEEP_LLVM_TEXT=1 "$compiler" build tests/cases/loop-optimization/threaded-global.ab \
    -o "$out/threaded" --no-cache
status=0
"$out/threaded" || status=$?
[[ $status == 42 ]]
if grep -q '%loop.global.slot' "$out/threaded.ll"; then exit 1; fi
echo 'loop scalar global: isolated state stays local, with checks for exits, observational calls and threads'
