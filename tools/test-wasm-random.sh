#!/usr/bin/env bash
# cryptoRandomBytes and secureRandomBytes on WebAssembly with no cryptoSetRandom use the host's source: abla_host.random on the abla_host ABI, random_get on WASI.
# A host that fails (an error, or no progress) fails the call, and keygen: never zeros. Runs under node (both ABIs, the failing hosts) and wasmtime (WASI).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$root/tests/cases/wasm-random"
out="$root/build/wasm-random"
rm -rf "${out:?}"; mkdir -p "$out"
command -v node >/dev/null || { echo "wasm-random: skipped (no node)"; exit 0; }
(cd "$root" && "$compiler" build "$cases/build.ab" -o "$out/driver" --no-cache && "$out/driver")
"$compiler" build "$cases/wasi.ab" --target wasm32-wasi -o "$out/wasi.wasm" --no-cache
node --no-warnings "$cases/run.mjs" "$out/probe.wasm" "$out/wasi.wasm"
if command -v wasmtime >/dev/null; then wasmtime run "$out/wasi.wasm" && echo "wasm-random: wasmtime ok"; else echo "wasm-random: wasmtime skipped"; fi
