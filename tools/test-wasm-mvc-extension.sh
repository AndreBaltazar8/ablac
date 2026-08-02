#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-mvc-extension"
module="$output_directory/abla-mvc.wasm"
adapter="$output_directory/abla-mvc.js"
mkdir -p "$output_directory"

build_once() {
    "$compiler" build \
        "$project_root/tests/cases/wasm-mvc-extension/build.ab" \
        -o "$output_directory/build-driver" --fast --no-cache
}

build_once
first_identity=$(sha256sum "$module" | cut -d' ' -f1)
build_once
second_identity=$(sha256sum "$module" | cut -d' ' -f1)
[[ $first_identity == "$second_identity" ]]

set +e
"$output_directory/build-driver"
driver_status=$?
set -e
[[ $driver_status -eq 36 ]]

llvm-readobj --file-headers "$module" | grep -q 'Format: WASM'
llvm-readobj --file-headers "$module" | grep -q 'Arch: wasm32'
llvm-readobj --symbols "$module" | grep -q 'Name: abla_mvc_revision'
if llvm-readobj --sections "$module" | grep -q 'Type: IMPORT'; then
    echo "WASM proof unexpectedly requires runtime imports" >&2
    exit 1
fi
node - "$module" <<'NODE'
const { readFileSync } = require("node:fs");
WebAssembly.instantiate(readFileSync(process.argv[2]), {}).then(({ instance }) => {
    if (instance.exports.abla_mvc_revision() !== 42n) {
        throw new Error("unexpected Abla MVC revision");
    }
});
NODE
[[ -s $adapter ]]
grep -q 'WebAssembly.instantiate' "$adapter"
grep -q 'instance.exports.abla_mvc_revision' "$adapter"

if rg -n 'abla-mvc-browser|abla_mvc_revision|WebAssembly.instantiate' \
    "$project_root/bootstrap/compiler" >/dev/null; then
    echo "MVC or browser host policy leaked into the compiler" >&2
    exit 1
fi

echo "WASM/MVC extension: deterministic wasm32 module + generated host adapter passed"
