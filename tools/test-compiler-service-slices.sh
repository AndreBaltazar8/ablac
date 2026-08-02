#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/artifact-slice"
module="$output_directory/client.wasm"
stateful_output_directory="$project_root/build/artifact-slice-stateful"
stateful_module="$stateful_output_directory/client.wasm"
stateful_fail_output="$stateful_output_directory/fail"
stateful_conflict_output="$project_root/build/artifact-slice-stateful-conflict"
mkdir -p "$output_directory"
mkdir -p "$stateful_output_directory"
mkdir -p "$stateful_fail_output"
mkdir -p "$stateful_conflict_output"

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

build_stateful_slice() {
    "$compiler" build \
        "$project_root/tests/cases/program-build/artifact-slice-stateful-root.ab" \
        -o "$stateful_output_directory/server" --fast --no-cache
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

build_stateful_slice
stateful_first_identity=$(sha256sum "$stateful_module" | cut -d' ' -f1)
build_stateful_slice
stateful_second_identity=$(sha256sum "$stateful_module" | cut -d' ' -f1)
[[ $stateful_first_identity == "$stateful_second_identity" ]]

llvm-readobj --symbols "$stateful_module" | grep -q 'Name: client_increment'
llvm-readobj --symbols "$stateful_module" | grep -q 'Name: client_double'
if llvm-readobj --symbols "$stateful_module" | \
    grep -Eq 'Name: (unselectedStatefulClient|invalidStatefulClient|serverAction|serverSessions|serverAction)'; then
    echo "unselected/unrelated declaration escaped the stateful artifact slice ABI" >&2
    exit 1
fi
if [[ $(grep -o '"symbol":"client_increment"' "$stateful_module.abi.json" | wc -l | awk '{ print $1 }') -ne 1 ]]; then
    echo "stateful export was duplicated in ABI manifest" >&2
    exit 1
fi
if [[ $(grep -o '"symbol":"client_double"' "$stateful_module.abi.json" | wc -l | awk '{ print $1 }') -ne 1 ]]; then
    echo "stateful export was duplicated in ABI manifest" >&2
    exit 1
fi
if grep -q '"symbol":"unselectedStatefulClient"' "$stateful_module.abi.json"; then
    echo "unselected stateful client escaped the artifact slice ABI" >&2
    exit 1
fi

node --disable-wasm-trap-handler - "$stateful_module" <<'NODE'
const { readFileSync } = require("node:fs");
WebAssembly.instantiate(readFileSync(process.argv[2]), {}).then(({ instance }) => {
    if (instance.exports.client_increment(40n) !== 41n) {
        throw new Error("unexpected selected client increment");
    }
    if (instance.exports.client_double(21n) !== 44n) {
        throw new Error("unexpected aggregated client double");
    }
});
NODE

set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/artifact-slice-stateful-root-invalid.ab" \
    -o "$stateful_fail_output/server" --fast --no-cache \
    >"$stateful_output_directory/stateful-invalid.out" \
    2>"$stateful_output_directory/stateful-invalid.err"
invalid_stateful_status=$?
set -e
[[ $invalid_stateful_status -ne 0 ]]
grep -Fq 'error[E_ARTIFACT_SLICE_REACHABILITY]' \
    "$stateful_output_directory/stateful-invalid.err"
if grep -Fq 'error[E_EXPORT_SIGNATURE_UNSUPPORTED]' \
    "$stateful_output_directory/stateful-invalid.err"; then
    echo "stateful reachability failure regressed to generic export signature error" >&2
    exit 1
fi

rm -f "$stateful_conflict_output/server" \
    "$stateful_conflict_output/client.wasm" \
    "$stateful_conflict_output/client.wasm.abi.json"
set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/artifact-slice-stateful-root-conflict.ab" \
    -o "$stateful_conflict_output/server" --fast --no-cache \
    >"$stateful_conflict_output/conflict.out" \
    2>"$stateful_conflict_output/conflict.err"
conflict_status=$?
set -e
[[ $conflict_status -ne 0 ]]
grep -Fq 'error[E_ARTIFACT_ROOT_CONFLICT]' \
    "$stateful_conflict_output/conflict.err"
[[ ! -e "$stateful_conflict_output/server" ]]
[[ ! -e "$stateful_conflict_output/client.wasm" ]]
[[ ! -e "$stateful_conflict_output/client.wasm.abi.json" ]]

echo "compiler service: annotations + validated self-transform + aggregated wasm artifact slices passed"
