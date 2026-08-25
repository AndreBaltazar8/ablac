#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/independent-module-test"
root_output="$output_directory/root"
child_output="$project_root/build/independent-module"
generated_entry="$project_root/build/.abla-independent/independent-module.abla-independent.ab"
wasm_output="$project_root/build/independent-module.wasm"
wasm_entry="$project_root/build/.abla-independent/independent-wasm.abla-independent.ab"
mkdir -p "$output_directory"

build_independent() {
    "$compiler" build \
        "$project_root/tests/cases/program-build/independent-module.ab" \
        -o "$root_output" --fast
}

build_independent
first_child_identity=$(sha256sum "$child_output" | cut -d' ' -f1)
first_wasm_identity=$(sha256sum "$wasm_output" | cut -d' ' -f1)
build_independent
second_child_identity=$(sha256sum "$child_output" | cut -d' ' -f1)
second_wasm_identity=$(sha256sum "$wasm_output" | cut -d' ' -f1)
[[ $first_child_identity == "$second_child_identity" ]]
[[ $first_wasm_identity == "$second_wasm_identity" ]]

set +e
"$root_output"
root_status=$?
"$child_output"
child_status=$?
set -e
[[ $root_status -eq 0 ]]
[[ $child_status -eq 8 ]]
grep -Fq 'compiler.addFunctionAnnotation' "$generated_entry"
grep -Fq 'fun main: int = lifted() + annotatedLift()' "$generated_entry"
grep -Fq 'compiler.exportFunction' "$wasm_entry"
grep -Fq 'fun __abla_generated_independent_wasm_adapter_' "$wasm_entry"
node --disable-wasm-trap-handler - "$wasm_output" <<'NODE'
const { readFileSync } = require("node:fs");
WebAssembly.instantiate(readFileSync(process.argv[2]), {}).then(({ instance }) => {
    if (instance.exports.abla_independent_lifted() !== 5n) {
        throw new Error("typed lifted Wasm export returned the wrong value");
    }
    if (instance.exports.abla_independent_generated() !== 42n) {
        throw new Error("generated Wasm adapter returned the wrong value");
    }
});
NODE

set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-independent-module-reference.ab" \
    -o "$output_directory/invalid-reference" --fast --no-cache \
    >"$output_directory/invalid-reference.out" \
    2>"$output_directory/invalid-reference.err"
invalid_reference_status=$?
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-runtime-declaration-block.ab" \
    -o "$output_directory/invalid-runtime-block" --fast --no-cache \
    >"$output_directory/invalid-runtime-block.out" \
    2>"$output_directory/invalid-runtime-block.err"
invalid_runtime_status=$?
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-independent-module-export.ab" \
    -o "$output_directory/invalid-export" --fast --no-cache \
    >"$output_directory/invalid-export.out" \
    2>"$output_directory/invalid-export.err"
invalid_export_status=$?
set -e

[[ $invalid_reference_status -ne 0 ]]
[[ $invalid_runtime_status -ne 0 ]]
[[ $invalid_export_status -ne 0 ]]
grep -Fq 'error[E_INDEPENDENT_MODULE_USE]' \
    "$output_directory/invalid-reference.err"
grep -Fq 'declaration.block.compile-only' \
    "$output_directory/invalid-runtime-block.err"
grep -Fq 'error[E_INDEPENDENT_MODULE_EXPORT]' \
    "$output_directory/invalid-export.err"

printf '%s\n' \
    'independent modules: typed references, generated declarations, exports, standalone native/Wasm children, and diagnostics passed'
