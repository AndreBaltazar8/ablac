#!/usr/bin/env bash
# `@unroll(n)` and `@unroll` on loops (#1296, docs/language.md#loops):
#   - on the CPU, the IR's loops carry llvm.loop.unroll.count (with the count) and llvm.loop.unroll.full, and the program
#     prints what the same loops print without the hints;
#   - in a kernel, a 4-trip loop under `@unroll` has no back edge in the PTX, and the same loop under `@unroll(1)` has one;
#   - a count that is not a whole number from 1 (a name, 0), `@unroll` on a loop without a constant trip count and
#     `@unroll` before something that is not a loop are refused.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/unroll
rm -rf "$out"
mkdir -p "$out"
fail() { echo "unroll: $1" >&2; exit 1; }
cases=tests/cases/unroll

"$compiler" --emit-llvm "$cases/cpu.ab" > "$out/cpu.ll" 2> "$out/cpu-ir.err" || fail "cpu.ab gave no IR: $(head -4 "$out/cpu-ir.err")"
grep -q '!{!"llvm.loop.unroll.count", i32 4}' "$out/cpu.ll" || fail "no unroll.count 4 in the IR"
grep -q '!{!"llvm.loop.unroll.count", i32 2}' "$out/cpu.ll" || fail "no unroll.count 2 (the while loop) in the IR"
grep -q '!{!"llvm.loop.unroll.count", i32 3}' "$out/cpu.ll" || fail "no unroll.count 3 (the labeled do-while) in the IR"
grep -q '!{!"llvm.loop.unroll.full"}' "$out/cpu.ll" || fail "no unroll.full in the IR"
grep -q '^ *br .*!llvm.loop !' "$out/cpu.ll" || fail "no branch carries llvm.loop"
"$compiler" build "$cases/cpu.ab" -o "$out/cpu" --no-cache > "$out/cpu.log" 2>&1 || fail "cpu.ab did not build: $(head -4 "$out/cpu.log")"
sed -E 's/@unroll(\([0-9]+\))? ?//' "$cases/cpu.ab" > "$out/plain.ab"
"$compiler" build "$out/plain.ab" -o "$out/plain" --no-cache > "$out/plain.log" 2>&1 || fail "the plain copy did not build: $(head -4 "$out/plain.log")"
[[ $("$out/cpu") == "$("$out/plain")" ]] || fail "the hints changed the result: $("$out/cpu") against $("$out/plain")"

# The kernels' PTX: a branch to a label already seen in the same function is a back edge.
"$compiler" build "$cases/kernel.ab" -o "$out/kernel" --fast --no-cache > "$out/kernel.log" 2>&1 ||
    fail "kernel.ab did not build: $(head -4 "$out/kernel.log")"
"$out/kernel" > "$out/kernel.ptx"
back_edges() { # $1 = the kernel's entry name
    awk -v entry="$1" '
        $0 ~ "\\.entry " entry "\\(" { inside = 1; delete seen; next }
        inside && /^\.(visible|entry)/ { inside = 0 }
        inside && /^\$L__[A-Za-z0-9_]+:/ { label = $1; sub(":", "", label); seen[label] = 1 }
        inside && /bra(\.uni)? / { target = $NF; sub(";", "", target); if (target in seen) count++ }
        END { print count + 0 }' "$out/kernel.ptx"
}
grep -q '\.entry unrolledQuad(' "$out/kernel.ptx" && grep -q '\.entry rolledQuad(' "$out/kernel.ptx" ||
    fail "the PTX lacks a kernel: $(grep '\.entry' "$out/kernel.ptx")"
[[ $(back_edges rolledQuad) -ge 1 ]] || fail "the @unroll(1) loop has no back edge (the control proves nothing)"
[[ $(back_edges unrolledQuad) == 0 ]] || fail "the @unroll loop kept a back edge"

refused() { # $1 = case, $2 = the text its diagnostics must contain
    local status=0
    "$compiler" build "$cases/refused-$1.ab" -o "$out/refused-$1" --no-cache > "$out/refused-$1.log" 2>&1 || status=$?
    [[ $status != 0 ]] || fail "refused-$1 built"
    grep -qF -- "$2" "$out/refused-$1.log" || fail "refused-$1 lacks '$2': $(head -4 "$out/refused-$1.log")"
}
refused count 'error[E_PARSE_UNROLL_COUNT]: @unroll(n) takes a whole number from 1 to 9999'
refused zero 'error[E_PARSE_UNROLL_COUNT]'
refused dynamic 'error[E_SEMANTIC]: unroll.trip-count'
refused while 'error[E_SEMANTIC]: unroll.trip-count'
refused target 'error[E_PARSE_UNROLL_TARGET]: @unroll must precede a loop'

echo "unroll: CPU loops carry the unroll metadata and keep their results; a kernel's @unroll loop has no back edge in the PTX (its @unroll(1) twin has); a bad count, a loop without a constant trip count and a non-loop are refused"
