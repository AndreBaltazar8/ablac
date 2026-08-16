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

unsafe_module="$output_directory/unsafe-memory.wasm"
"$compiler" build \
    "$project_root/tests/cases/wasm-mvc-extension/unsafe-memory-build.ab" \
    -o "$output_directory/unsafe-memory-driver" --fast --no-cache
# Primitive scalar operations belong to LLVM lowering, not to an Abla runtime
# wrapper. The portable text algorithms below remain ordinary Abla functions.
grep -q 'scalar.add' "$unsafe_module.ll"
grep -q 'scalar.bit.and' "$unsafe_module.ll"
grep -q 'scalar.shift.left' "$unsafe_module.ll"
if grep -Eq '^define .*@(abla_add|abla_less|ablaBitAnd|ablaBitShiftLeft)\(' \
    "$unsafe_module.ll"; then
    echo "WASM proof unexpectedly defines primitive runtime wrappers" >&2
    exit 1
fi
grep -Eq '^define .*@ablaTextIsValidUtf8\(' "$unsafe_module.ll"
if llvm-readobj --sections "$unsafe_module" | grep -q 'Type: IMPORT'; then
    echo "WASM unsafe-memory proof unexpectedly requires runtime imports" >&2
    exit 1
fi
node --disable-wasm-trap-handler - "$unsafe_module" <<'NODE'
const { readFileSync } = require("node:fs");
WebAssembly.instantiate(readFileSync(process.argv[2]), {}).then(({ instance }) => {
    const pointer = instance.exports.abla_wasm_allocate(8n);
    const value = 0x1122334455667788n;
    if (instance.exports.abla_wasm_store_and_load(pointer, value) !== value) {
        throw new Error("unexpected unsafe-memory round trip");
    }
    const request = new TextEncoder().encode("hello");
    const requestPointer = instance.exports.abla_wasm_allocate(
        BigInt(request.byteLength + 1)
    );
    new Uint8Array(instance.exports.memory.buffer).set(
        request,
        Number(requestPointer)
    );
    if (
        instance.exports.abla_wasm_adopt_string_length(
            requestPointer,
            BigInt(request.byteLength)
        ) !== BigInt(request.byteLength)
    ) {
        throw new Error("unexpected adopted string length");
    }
    if (instance.exports.abla_wasm_json_length() !== 29n) {
        throw new Error("unexpected runtime $jsons result");
    }
    const packed = BigInt.asUintN(
        64,
        instance.exports.abla_wasm_json_packed()
    );
    const responsePointer = Number(packed >> 32n);
    const responseLength = Number(packed & 0xffffffffn);
    const response = new TextDecoder().decode(
        new Uint8Array(
            instance.exports.memory.buffer,
            responsePointer,
            responseLength
        )
    );
    if (response !== '{"status":200,"body":"hello"}') {
        throw new Error("unexpected borrowed string response");
    }
    if (instance.exports.abla_wasm_nested_array_value() !== 1n) {
        throw new Error("unexpected nested array result");
    }
    if (instance.exports.abla_wasm_nested_json_value() !== 1n) {
        throw new Error("unexpected nested JSON parse result");
    }
    if (instance.exports.abla_wasm_bit_runtime_score() !== 42n) {
        throw new Error("unexpected self-hosted bit runtime result");
    }
    if (instance.exports.abla_wasm_text_runtime_score() !== 42n) {
        throw new Error("unexpected self-hosted text runtime result");
    }
    if (instance.exports.abla_wasm_i8_identity(-100) !== -100) {
        throw new Error("unexpected i8 export round trip");
    }
    if (instance.exports.abla_wasm_u8_identity(250) !== 250) {
        throw new Error("unexpected u8 export round trip");
    }
    if (instance.exports.abla_wasm_i16_identity(-30000) !== -30000) {
        throw new Error("unexpected i16 export round trip");
    }
    if (instance.exports.abla_wasm_u16_identity(60000) !== 60000) {
        throw new Error("unexpected u16 export round trip");
    }
    if (instance.exports.abla_wasm_i32_identity(-2000000000) !== -2000000000) {
        throw new Error("unexpected i32 export round trip");
    }
    if (instance.exports.abla_wasm_u32_identity(4000000000) !== -294967296) {
        throw new Error("unexpected u32 export bit-pattern round trip");
    }
    if (
        BigInt.asUintN(64, instance.exports.abla_wasm_u64_identity(
            18000000000000000000n
        )) !== 18000000000000000000n
    ) {
        throw new Error("unexpected u64 export bit-pattern round trip");
    }
    if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
        throw new Error("linear memory was not exported");
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
