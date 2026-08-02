#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/artifact-slice"
module="$output_directory/client.wasm"
mkdir -p "$output_directory"

set +e
"$compiler" run \
    "$project_root/tests/cases/modules/compiler-service-transform.ab"
transform_status=$?
set -e
[[ $transform_status -eq 42 ]]

set +e
"$compiler" run \
    "$project_root/tests/cases/modules/invalid-compiler-transform-body-type.ab" \
    >"$output_directory/invalid-body.out" \
    2>"$output_directory/invalid-body.err"
invalid_body_status=$?
"$compiler" run \
    "$project_root/tests/cases/modules/invalid-runtime-compiler-service.ab" \
    >"$output_directory/invalid-runtime.out" \
    2>"$output_directory/invalid-runtime.err"
invalid_runtime_status=$?
set -e
[[ $invalid_body_status -ne 0 ]]
[[ $invalid_runtime_status -ne 0 ]]
grep -q 'function.result:answer:i64:string' \
    "$output_directory/invalid-body.err"
grep -q 'compile.value-runtime:compiler' \
    "$output_directory/invalid-runtime.err"

build_slice() {
    "$compiler" build \
        "$project_root/tests/cases/program-build/artifact-slice-root.ab" \
        -o "$output_directory/server" --fast --no-cache
}

build_slice
first_identity=$(sha256sum "$module" | cut -d' ' -f1)
build_slice
second_identity=$(sha256sum "$module" | cut -d' ' -f1)
[[ $first_identity == "$second_identity" ]]

"$output_directory/server"
llvm-readobj --file-headers "$module" | grep -q 'Format: WASM'
llvm-readobj --symbols "$module" | grep -q 'Name: abla_client_answer'
llvm-readobj --symbols "$module" | grep -q 'Name: abla_client_double'
if llvm-readobj --symbols "$module" | \
    grep -Eq 'Name: (unselectedClient|serverAnswer)'; then
    echo "unselected function escaped the artifact slice ABI" >&2
    exit 1
fi
grep -q '"symbol":"abla_client_answer"' "$module.abi.json"
grep -q '"symbol":"abla_client_double"' "$module.abi.json"
grep -q '"panic":"not-contained"' "$module.abi.json"

node --disable-wasm-trap-handler - "$module" <<'NODE'
const { readFileSync } = require("node:fs");
WebAssembly.instantiate(readFileSync(process.argv[2]), {}).then(({ instance }) => {
    if (instance.exports.abla_client_answer(40n) !== 42n) {
        throw new Error("unexpected selected client answer");
    }
    if (instance.exports.abla_client_double(21n) !== 42n) {
        throw new Error("unexpected aggregated client answer");
    }
});
NODE

echo "compiler service: annotations + validated self-transform + aggregated wasm artifact slices passed"
