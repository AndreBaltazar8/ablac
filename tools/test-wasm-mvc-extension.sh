#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-mvc-extension"
module="$output_directory/abla-mvc.wasm"
abi_manifest="$module.abi.json"
adapter="$output_directory/abla-mvc.js"
mkdir -p "$output_directory"

build_once() {
    "$compiler" build \
        "$project_root/tests/cases/wasm-mvc-extension/build.ab" \
        -o "$output_directory/build-driver" --fast --no-cache
}

build_once
first_identity=$(sha256sum "$module" | cut -d' ' -f1)
first_abi_identity=$(sha256sum "$abi_manifest" | cut -d' ' -f1)
rm -f "$abi_manifest"
build_once
second_identity=$(sha256sum "$module" | cut -d' ' -f1)
second_abi_identity=$(sha256sum "$abi_manifest" | cut -d' ' -f1)
[[ $first_identity == "$second_identity" ]]
[[ $first_abi_identity == "$second_abi_identity" ]]

set +e
"$output_directory/build-driver"
driver_status=$?
set -e
[[ $driver_status -eq 36 ]]

llvm-readobj --file-headers "$module" | grep -q 'Format: WASM'
llvm-readobj --file-headers "$module" | grep -q 'Arch: wasm32'
llvm-readobj --symbols "$module" | grep -q 'Name: abla_mvc_revision'
[[ ! -e $module.value-runtime.o ]]
[[ ! -e $module.wasm-platform.o ]]
grep -q '"schema":"abla.abi.v1"' "$abi_manifest"
grep -q '"name":"wasm32-module"' "$abi_manifest"
grep -q '"symbol":"abla_mvc_revision"' "$abi_manifest"
grep -q '"ownership":"value"' "$abi_manifest"
grep -q '"panic":"not-contained"' "$abi_manifest"
node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' \
    "$abi_manifest"
if llvm-readobj --sections "$module" | grep -q 'Type: IMPORT'; then
    echo "WASM proof unexpectedly requires runtime imports" >&2
    exit 1
fi
node --disable-wasm-trap-handler - "$module" <<'NODE'
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

set +e
"$compiler" build \
    "$project_root/tests/cases/wasm-mvc-extension/owned-result-build.ab" \
    -o "$output_directory/owned-result-driver" --fast --no-cache \
    >"$output_directory/owned-result.out" \
    2>"$output_directory/owned-result.err"
owned_result_status=$?
"$compiler" build \
    "$project_root/tests/cases/wasm-mvc-extension/checked-export-build.ab" \
    -o "$output_directory/checked-export-driver" --fast --no-cache \
    >"$output_directory/checked-export.out" \
    2>"$output_directory/checked-export.err"
checked_export_status=$?
set -e
[[ $owned_result_status -ne 0 ]]
grep -q 'error\[E_EXPORT_TARGET_CAPABILITY\]' \
    "$output_directory/owned-result.err"
[[ $checked_export_status -ne 0 ]]
grep -q 'error\[E_EXPORT_TARGET_CAPABILITY\]' \
    "$output_directory/checked-export.err"

if rg -n 'abla-mvc-browser|abla_mvc_revision|WebAssembly.instantiate' \
    "$project_root/src" >/dev/null; then
    echo "MVC or browser host policy leaked into the compiler" >&2
    exit 1
fi

echo "WASM/MVC extension: deterministic wasm32 module + generated host adapter passed"
