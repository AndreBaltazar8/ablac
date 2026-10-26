#!/usr/bin/env bash
# A bare wasm32 module's standard library reaches the browser host ABI
# (stdlib/abla/runtime/platform/wasm.ab): release and development modules that
# print, read both clocks, take random bytes and exit import abla_host's write,
# exit, clock_ns and random and nothing else (no env.syscall or
# env.__errno_location), and run against a host that provides only those.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/wasm-host"
output_directory="$project_root/build/wasm-host"
rm -rf "$output_directory"
mkdir -p "$output_directory"

(cd "$project_root" && "$compiler" build "$cases/build.ab" \
    -o "$output_directory/build-driver" --no-cache)
(cd "$project_root" && "$output_directory/build-driver")
for module in host host-dev; do
    node "$cases/run.mjs" "$output_directory/$module.wasm"
done
echo "wasm host: release and development modules print, read the clocks, draw random bytes, get ENOSYS and exit through abla_host alone"
