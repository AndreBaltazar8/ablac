#!/usr/bin/env bash
# Prove the backport in the standalone optimizer, clang, and lld's Wasm LTO.
set -euo pipefail
[[ $# == 1 || ( $# == 2 && $2 == --opt-and-lld ) ]] ||
    { echo "usage: $0 <llvm-bin-dir> [--opt-and-lld]" >&2; exit 2; }
bin=$(realpath -- "$1")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture="$root/tests/cases/llvm-miscompiles/fdiv-zero-by-zero-times-value.ll"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

OPT="$bin/opt" "$root/tools/test-llvm-miscompiles.sh"
if [[ $# == 1 ]]; then
    "$bin/clang" -Qunused-arguments -Wno-override-module -O2 -S -emit-llvm -x ir "$fixture" -o "$work/clang.ll"
    sed -n '/^define .*@f(/,/^}/p' "$work/clang.ll" > "$work/f.ll"
    grep -Eq '^[[:space:]]+ret double (\+qnan|0x7FF8[0-9A-Fa-f]+)' "$work/f.ll" ||
        { echo 'clang -O2 did not fold f to NaN' >&2; cat "$work/f.ll" >&2; exit 1; }
fi

# Assemble the unoptimized IR directly, so wasm-ld runs its own optimizer.
{
    cat <<'IR'
target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-i128:128-n32:64-S128-ni:1:10:20"
target triple = "wasm32-unknown-unknown"
IR
    cat "$fixture"
    cat <<'IR'

define double @run(i32 %n) {
  %wide = sext i32 %n to i64
  %result = call double @f(i64 %wide)
  ret double %result
}
IR
} > "$work/input.ll"
"$bin/llvm-as" "$work/input.ll" -o "$work/input.bc"
"$bin/wasm-ld" --no-entry --export=run -O2 --lto-O2 "$work/input.bc" -o "$work/output.wasm"
node - "$work/output.wasm" <<'JS'
const fs = require('fs');
const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[2])));
if (!Number.isNaN(instance.exports.run(5))) throw new Error('wasm-ld LTO did not return NaN');
JS
if [[ $# == 1 ]]; then
    echo 'external LLVM: opt, clang -O2 and wasm-ld LTO return NaN'
else
    echo 'external LLVM: opt and wasm-ld LTO return NaN'
fi
