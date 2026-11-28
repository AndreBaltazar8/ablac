#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
directory="$project_root/build/target-descriptors-test"
mkdir -p "$directory"

"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache -o "$directory/hosted"
set +e
"$project_root/tools/run-limited.sh" "$directory/hosted"
hosted_status=$?
set -e
[[ $hosted_status -eq 42 ]] || exit 1

set +e
"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache --target imaginary-none \
    -o "$directory/invalid" \
    >"$directory/invalid.out" 2>"$directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -eq 2 ]] || exit 1
grep -q "unsupported target 'imaginary-none'" "$directory/invalid.err"
[[ ! -e "$directory/invalid" ]] || exit 1

# The standard library on the freestanding x86_64-windows, which has no runtime: the runtime's names are missing, and
# the build says why once and names the hosted target, instead of only listing them.
set +e
"$compiler" build "$project_root/tests/cases/target-descriptors/freestanding-io.ab" \
    --fast --no-cache --target x86_64-windows -o "$directory/freestanding-io.obj" \
    >"$directory/freestanding-io.out" 2>"$directory/freestanding-io.err"
freestanding_status=$?
set -e
[[ $freestanding_status -ne 0 ]] || exit 1
[[ $(grep -c 'target x86_64-windows is freestanding' "$directory/freestanding-io.err") -eq 1 ]] ||
    { cat "$directory/freestanding-io.err" >&2; exit 1; }
grep 'help: .*--target x86_64-windows-hosted' "$directory/freestanding-io.err" > /dev/null ||
    { cat "$directory/freestanding-io.err" >&2; exit 1; }

# aarch64-linux links no C library (#811, G3: docs/design/aarch64-linux-c-boundary.md). A program that brings one stops with
# E_BUILD_TARGET_CAPABILITY naming the boundary: the manifest's nativeLibraries and LLVM before the link, C functions the
# libc-free link leaves undefined (dlsym) after it.
c_boundary() {
    local name=$1 expected=$2
    shift 2
    set +e
    env -u ABLA_STATIC_LLVM_LIB "$compiler" build "$@" --fast --no-cache --target aarch64-linux -o "$directory/$name" \
        >"$directory/$name.out" 2>"$directory/$name.err"
    local status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "target descriptors: $name built for aarch64-linux" >&2; exit 1; }
    grep -F "error[E_BUILD_TARGET_CAPABILITY]: target 'aarch64-linux' links no C library" "$directory/$name.err" |
        grep -F "$expected" > /dev/null || { cat "$directory/$name.err" >&2; exit 1; }
}
c_boundary a64-native-libraries 'the manifest names nativeLibraries (m)' --project "$project_root/tests/cases/floating-native"
c_boundary a64-llvm 'it links LLVM' "$project_root/tests/cases/target-descriptors/llvm-import.ab"
c_boundary a64-dlsym 'calls C functions nothing in it defines: dlsym' "$project_root/tests/cases/modules/unsafe-boundary.ab"

"$compiler" build \
    "$project_root/tests/cases/target-descriptors/generic-object-build.ab" \
    --fast --no-cache -o "$directory/generic-driver"
set +e
"$project_root/tools/run-limited.sh" "$directory/generic-driver"
generic_status=$?
set -e
[[ $generic_status -eq 43 ]] || exit 1
llvm-readelf -h "$directory/riscv64.o" > "$directory/riscv64.header"
grep -q 'RISC-V' "$directory/riscv64.header"
grep -q '"llvmTriple":"riscv64-unknown-elf"' \
    "$directory/riscv64.o.abi.json"

# A non-hosted target with a C library gets the runtime (the standard
# library's memory module type-checks), and a value-bound export is kept.
"$compiler" build \
    "$project_root/tests/cases/target-descriptors/libc-object-build.ab" \
    --fast --no-cache -o "$directory/libc-driver"
set +e
"$project_root/tools/run-limited.sh" "$directory/libc-driver"
libc_status=$?
set -e
[[ $libc_status -eq 44 ]] || exit 1
llvm-nm "$directory/riscv64-libc.o" > "$directory/riscv64-libc.symbols"
grep -q ' T libc_object_answer$' "$directory/riscv64-libc.symbols"
grep -q '"symbol":"libc_object_answer"' "$directory/riscv64-libc.o.abi.json"

"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache \
    --target-triple riscv64-unknown-elf --object-format elf \
    -o "$directory/raw-riscv64.o"
llvm-readelf -h "$directory/raw-riscv64.o" \
    > "$directory/raw-riscv64.header"
grep -q 'RISC-V' "$directory/raw-riscv64.header"
grep -q '"llvmTriple":"riscv64-unknown-elf"' \
    "$directory/raw-riscv64.o.abi.json"

"$compiler" build \
    "$project_root/tests/cases/target-descriptors/freestanding-object.ab" \
    --fast --no-cache \
    --target-triple riscv64-unknown-elf --object-format elf \
    -o "$directory/freestanding-riscv64.o"
llvm-nm "$directory/freestanding-riscv64.o" \
    > "$directory/freestanding-riscv64.symbols"
grep -q ' T firmware_entry$' "$directory/freestanding-riscv64.symbols"

"$compiler" build \
    "$project_root/tests/cases/native/manual-global-initialization.ab" \
    --fast --no-cache \
    --target-triple x86_64-unknown-linux-gnu --object-format elf \
    -o "$directory/manual-global-initialization.o"
llvm-nm "$directory/manual-global-initialization.o" \
    > "$directory/manual-global-initialization.symbols"
grep -q ' T freestanding_entry$' \
    "$directory/manual-global-initialization.symbols"
grep -q ' t abla_export_ensure_initialized$' \
    "$directory/manual-global-initialization.symbols"

set +e
"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache \
    --target-triple riscv64-unknown-elf --object-format elf \
    --emit executable -o "$directory/raw-executable" \
    >"$directory/raw-executable.out" \
    2>"$directory/raw-executable.err"
raw_executable_status=$?
set -e
[[ $raw_executable_status -eq 2 ]] || exit 1
grep -q 'emits only object or static-library artifacts' \
    "$directory/raw-executable.err"
[[ ! -e "$directory/raw-executable" ]] || exit 1

# A Mac has no Linux sysroot: a hosted Linux executable or shared library is
# refused before linking, while its object still builds.
if [[ $(uname -s) == Darwin ]]; then
    for emit in executable shared-library; do
        set +e
        "$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
            --fast --no-cache --target x86_64-linux --emit "$emit" \
            -o "$directory/linux-$emit" \
            >"$directory/linux-$emit.out" 2>"$directory/linux-$emit.err"
        linux_status=$?
        set -e
        [[ $linux_status -eq 160 ]] || exit 1
        grep -q "error\[E_TARGET_HOST_LINK\]: .* for target 'x86_64-linux' links against a Linux C library" \
            "$directory/linux-$emit.err"
        ! grep -q "E_NATIVE_TOOLCHAIN" "$directory/linux-$emit.err" || exit 1
        [[ ! -e "$directory/linux-$emit" ]] || exit 1
    done
    "$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
        --fast --no-cache --target x86_64-linux --emit object \
        -o "$directory/linux.o"
    linux_header=$(llvm-readelf -h "$directory/linux.o")
    grep -q 'X86-64' <<<"$linux_header"
fi

printf '%s\n' \
    'target descriptors: hosted, freestanding, extension-defined and raw LLVM objects, and deterministic unsupported-target and host-link diagnostics passed'
