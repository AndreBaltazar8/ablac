#!/usr/bin/env bash
# `orElse` alternatives that retry on WebAssembly, left by an exception (legacy
# try/catch_all): the module (development and release builds) under node, with
# direct and nested orElse, a retry from a call chain's depth, thousands of
# abandoned attempts and collections after them; no imports beyond what it had.
# A module without such an alternative has no tag, and built after one in the
# same compiler process it is byte-identical to one built alone.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/stm-unwinding"
cases="tests/cases/stm/unwinding"
rm -rf "$output_directory"
mkdir -p "$output_directory/after" "$output_directory/alone"
cd "$project_root"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
fail() {
    echo "stm wasm unwinding: $1" >&2
    exit 1
}

"$compiler" build "$cases/marked-then-plain.ab" -o "$output_directory/marked-driver" --no-cache
"$compiler" build "$cases/plain-alone.ab" -o "$output_directory/alone-driver" --no-cache
for module in marked-fast marked; do
    [ -f "$output_directory/$module.wasm" ] || fail "no $module module"
    result=$("$wasm_runner" tests/cases/stm/run.mjs "$output_directory/$module.wasm") ||
        fail "$module did not run"
    [[ $result == 0 ]] || fail "$module: $result checks failed"
    [[ $("$wasm_runner" "$cases/sections.mjs" "$output_directory/$module.wasm") == tags ]] ||
        fail "$module: expected a tag section and no imports"
done
# (Each pair has one file name: a development module's source map names its file.)
for module in after/plain-fast after/plain alone/plain-fast alone/plain; do
    [[ $("$wasm_runner" "$cases/sections.mjs" "$output_directory/$module.wasm") == "no tags" ]] ||
        fail "$module: a module without such an alternative has a tag or imports"
done
cmp -s "$output_directory/after/plain-fast.wasm" "$output_directory/alone/plain-fast.wasm" ||
    fail "a development module built after one with exception handling differs from one built alone"
cmp -s "$output_directory/after/plain.wasm" "$output_directory/alone/plain.wasm" ||
    fail "a release module built after one with exception handling differs from one built alone"

echo "stm wasm unwinding: retrying alternatives left by exceptions (development and release), no new imports; other modules unchanged in the same process"
