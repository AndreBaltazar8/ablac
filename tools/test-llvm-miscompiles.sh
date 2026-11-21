#!/usr/bin/env bash
# Known upstream LLVM miscompiles (tests/cases/llvm-miscompiles/*.ll) that our LLVM carries a backport for must stay fixed in the opt
# of this shell. fdiv-zero-by-zero-times-value.ll: InstCombine folded 0.0 / (0.0 * %v) to copysign(0.0, %v), but that is NaN
# (llvm-project #202482; nix/llvm-instcombine-fdiv-zero.patch). The body of @f after instcombine must not be a copysign, and the whole -O2
# pipeline must turn a call with a constant argument into the NaN constant. The unpatched 23.1.3 opt fails both (the mutation check).
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
opt=${OPT:-opt}
case=$project_root/tests/cases/llvm-miscompiles/fdiv-zero-by-zero-times-value.ll
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

"$opt" -passes=instcombine -S "$case" > "$work/instcombine.ll"
sed -n "/^define double @f/,/^}/p" "$work/instcombine.ll" > "$work/f.ll"
if grep -q "copysign" "$work/f.ll"; then
    echo "llvm-miscompiles: instcombine folds 0.0 / (0.0 * v) to a signed zero (it is NaN):" >&2
    cat "$work/instcombine.ll" >&2
    exit 1
fi

{
    cat "$case"
    printf '\ndefine double @g() {\n  %%r = call double @f(i64 5)\n  ret double %%r\n}\n'
} > "$work/call.ll"
"$opt" -passes='default<O2>' -S "$work/call.ll" > "$work/o2.ll"
sed -n "/^define .*@g()/,/^}/p" "$work/o2.ll" > "$work/g.ll"
grep -q 'ret double 0x7FF8000000000000\|ret double +qnan\|ret double 0x7FF8' "$work/g.ll" ||
    { echo "llvm-miscompiles: -O2 does not turn 0.0 / (0.0 * 5.0) * 0.16 into NaN:" >&2; cat "$work/g.ll" >&2; exit 1; }
echo "llvm-miscompiles: 0.0 / (0.0 * v) stays a NaN at instcombine and at -O2"
