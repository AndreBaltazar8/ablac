#!/usr/bin/env bash
# Compare SSE2 and scalar output from the same deterministic byte corpus.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
cases=tests/cases/simd
out=build/simd-scanners
mkdir -p "$out"
"$compiler" build "$cases/scanners.ab" -o "$out/native" --no-cache
"$out/native" "${ABLA_SCAN_FUZZ_CASES:-1200}" > "$out/native.out"
if [[ $(uname -m) == x86_64 ]] && command -v qemu-aarch64 >/dev/null; then
    "$compiler" build "$cases/scanners.ab" --target aarch64-linux -o "$out/scalar" --no-cache
    qemu-aarch64 "$out/scalar" "${ABLA_SCAN_FUZZ_CASES:-1200}" > "$out/scalar.out"
    cmp "$out/native.out" "$out/scalar.out"
    echo "SIMD scanners: x86-64 and scalar AArch64 agree"
else
    echo "SIMD scanners: native assertions passed, x86-64 vs scalar comparison skipped on this host"
fi

"$compiler" build "$cases/scanner-wasm-build.ab" -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
wasm-dis "$out/scanner.wasm" > "$out/scanner.wat"
if grep -Eq '\bv128\b|\b(i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.' "$out/scanner.wat"; then
    echo "SIMD scanners: the Wasm fallback requires SIMD128" >&2
    exit 1
fi
node --input-type=module - "$out/scanner.wasm" <<'EOF'
import { readFileSync } from "node:fs";
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {
    abla_host: new Proxy({}, { get: () => () => 0 })
});
if (instance.exports.find_byte(80n) !== 160n) throw new Error("Wasm scalar byte search failed");
EOF
echo "SIMD scanners: the Wasm scalar fallback runs without SIMD128"
