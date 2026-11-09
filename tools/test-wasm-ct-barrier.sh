#!/usr/bin/env bash
# A --fast WebAssembly module with the constant-time barrier (abla/ct, inline assembly) builds on the
# default in-process object route and selects correctly: it used to abort with "LLVM ERROR: Inline asm
# not supported by this streamer because we don't have an asm parser for this target" unless
# ABLA_KEEP_LLVM_TEXT=1 chose the text route.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
out=build/wasm-ct-barrier
rm -rf "$out"
mkdir -p "$out"
cp tests/cases/wasm-ct-barrier/mod.ab "$out/mod.ab"
env -u ABLA_KEEP_LLVM_TEXT "$compiler" build tests/cases/wasm-ct-barrier/build.ab -o "$out/driver" --fast --no-cache
[[ -s $out/ct-barrier.wasm ]] || { echo "wasm ct barrier: no module built" >&2; exit 1; }
node -e '
const bytes = require("fs").readFileSync(process.argv[1]);
const { exports } = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
    abla_host: new Proxy({}, { get: () => () => 0 }),
});
const pick = exports.pick;
const cases = [[0xffffffff, 5, 9, 5], [0, 5, 9, 9], [0xffffffff, 0, 0xdeadbeef, 0], [0, 7, 0xdeadbeef, 0xdeadbeef | 0]];
for (const [mask, a, b, want] of cases) {
    const got = pick(mask | 0, a | 0, b | 0) >>> 0;
    if (got !== (want >>> 0)) { console.error("pick", mask, a, b, "=", got, "expected", want >>> 0); process.exit(1); }
}
' "$out/ct-barrier.wasm"
echo "wasm ct barrier: a --fast module with the barrier builds in process and selects"
