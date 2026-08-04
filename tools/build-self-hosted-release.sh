#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'usage: %s <compiler> <output> [entry]\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output=$2
entry=${3:-src/orc_main.ab}
emit_memory_mb=${ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB:-4096}
object_memory_mb=${ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB:-4096}
emit_seconds=${ABLA_FINAL_SELFHOST_EMIT_SECONDS:-300}

cd "$project_root"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
mkdir -p -- "$(dirname -- "$output")" "$project_root/build"
temporary_directory=$(mktemp -d "$project_root/build/.selfhost-release.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

module="$temporary_directory/compiler.ll"
object="$temporary_directory/compiler.o"
value_runtime_object="$temporary_directory/value-runtime.o"
host_runtime_object="$temporary_directory/host-runtime.o"
executable="$temporary_directory/compiler"

# Keep the Abla frontend heap and LLVM's optimized-object heap in distinct
# processes. A complete compiler graph otherwise makes both peaks coexist and
# can exhaust the machine before the watchdog gets a useful diagnostic.
ABLA_MAX_MEMORY_MB=$emit_memory_mb ABLA_MAX_SECONDS=$emit_seconds \
    "$project_root/tools/run-limited.sh" \
    "$compiler" --emit-llvm "$entry" > "$module"

printf -v compile_command \
    'clang -O2 -flto -Wno-unused-command-line-argument -ffunction-sections -fdata-sections -c %q -o %q' \
    "$module" "$object"
ABLA_MAX_MEMORY_MB=$object_memory_mb ABLA_MAX_SECONDS=180 \
    "$project_root/tools/run-limited.sh" \
    nix-shell --run "$compile_command"

printf -v runtime_compile_command \
    'clang -std=c11 -O2 -flto -ffunction-sections -fdata-sections -I%q -c %q -o %q && clang -std=c11 -O2 -flto -ffunction-sections -fdata-sections -I%q -c %q -o %q' \
    "$project_root/runtime" "$project_root/runtime/abla_runtime.c" \
    "$value_runtime_object" "$project_root/runtime" \
    "$project_root/runtime/abla_runtime_host.c" "$host_runtime_object"
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    nix-shell --run "$runtime_compile_command"

printf -v link_command \
    'llvm_dir=$(llvm-config --libdir); clang -O2 -flto -fuse-ld=lld -Wl,--threads=1 -Wl,--gc-sections -Wl,--export-dynamic %q %q %q -L"$llvm_dir" -Wl,-rpath,"$llvm_dir" -lLLVM -o %q' \
    "$object" "$value_runtime_object" "$host_runtime_object" "$executable"
ABLA_MAX_MEMORY_MB=$object_memory_mb ABLA_MAX_SECONDS=180 \
    "$project_root/tools/run-limited.sh" \
    nix-shell --run "$link_command"

[[ -s $module && -s $object && -x $executable ]]
mv -f -- "$module" "$output.ll"
mv -f -- "$executable" "$output"
