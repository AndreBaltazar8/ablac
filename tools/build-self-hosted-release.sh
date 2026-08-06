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
host_os=$(uname -s)
host_machine=$(uname -m)
host_triple=
host_sdk=

if [[ $host_os == Darwin ]]; then
    case "$host_machine" in
        x86_64|arm64) ;;
        *)
            printf 'unsupported macOS host architecture: %s\n' \
                "$host_machine" >&2
            exit 2
            ;;
    esac
    if [[ -x /opt/homebrew/bin/brew ]]; then
        brew_command=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
        brew_command=/usr/local/bin/brew
    else
        printf '%s\n' 'Homebrew LLVM is required on macOS' >&2
        exit 2
    fi
    llvm_prefix=$($brew_command --prefix llvm@21 2>/dev/null ||
        $brew_command --prefix llvm)
    lld_prefix=$($brew_command --prefix lld@21 2>/dev/null ||
        $brew_command --prefix lld)
    export PATH="$llvm_prefix/bin:$lld_prefix/bin:$PATH"
    llvm_version=$(llvm-config --version)
    if [[ $llvm_version != 21.* ]]; then
        printf 'LLVM 21 is required, found %s\n' "$llvm_version" >&2
        exit 2
    fi
    host_triple=$(llvm-config --host-target)
    host_sdk=$(xcrun --sdk macosx --show-sdk-path)
fi

run_toolchain_command() {
    local command=$1
    if [[ $host_os == Darwin ]]; then
        "$project_root/tools/run-limited.sh" /bin/bash -c "$command"
    else
        "$project_root/tools/run-limited.sh" nix-shell --run "$command"
    fi
}

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
llvm_host_object="$temporary_directory/llvm-host.o"
executable="$temporary_directory/compiler"

# Keep the Abla frontend heap and LLVM's optimized-object heap in distinct
# processes. A complete compiler graph otherwise makes both peaks coexist and
# can exhaust the machine before the watchdog gets a useful diagnostic.
ABLA_MAX_MEMORY_MB=$emit_memory_mb ABLA_MAX_SECONDS=$emit_seconds \
    "$project_root/tools/run-limited.sh" \
    "$compiler" --emit-llvm "$entry" > "$module"

if [[ $host_os == Darwin ]]; then
    printf -v compile_command \
        'clang -O2 -flto -target %q -isysroot %q -Wno-override-module -Wno-unused-command-line-argument -ffunction-sections -fdata-sections -c %q -o %q' \
        "$host_triple" "$host_sdk" "$module" "$object"
else
    printf -v compile_command \
        'clang -O2 -flto -Wno-unused-command-line-argument -ffunction-sections -fdata-sections -c %q -o %q' \
        "$module" "$object"
fi
ABLA_MAX_MEMORY_MB=$object_memory_mb ABLA_MAX_SECONDS=180 \
    run_toolchain_command "$compile_command"

if [[ $host_os == Darwin ]]; then
    printf -v runtime_compile_command \
        'clang -std=c11 -O2 -flto -isysroot %q -ffunction-sections -fdata-sections -I%q -c %q -o %q && clang -std=c11 -O2 -flto -pthread -isysroot %q -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE -Wno-deprecated-declarations -ffunction-sections -fdata-sections -I%q -c %q -o %q' \
        "$host_sdk" "$project_root/runtime" \
        "$project_root/runtime/abla_runtime.c" \
        "$value_runtime_object" "$host_sdk" \
        "$project_root/runtime" \
        "$project_root/runtime/abla_runtime_host.c" \
        "$host_runtime_object"
else
    printf -v runtime_compile_command \
        'clang -std=c11 -O2 -flto -ffunction-sections -fdata-sections -I%q -c %q -o %q && clang -std=c11 -O2 -flto -ffunction-sections -fdata-sections -I%q -c %q -o %q' \
        "$project_root/runtime" "$project_root/runtime/abla_runtime.c" \
        "$value_runtime_object" "$project_root/runtime" \
        "$project_root/runtime/abla_runtime_host.c" "$host_runtime_object"
fi
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    run_toolchain_command "$runtime_compile_command"

if [[ $host_os == Darwin ]]; then
    printf -v llvm_host_compile_command \
        'clang -std=c11 -O2 -isysroot %q -I"$(llvm-config --includedir)" -c %q -o %q' \
        "$host_sdk" "$project_root/runtime/abla_llvm_host.c" \
        "$llvm_host_object"
else
    printf -v llvm_host_compile_command \
        'clang -std=c11 -O2 -I"$(llvm-config --includedir)" -c %q -o %q' \
        "$project_root/runtime/abla_llvm_host.c" "$llvm_host_object"
fi
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    run_toolchain_command "$llvm_host_compile_command"

if [[ $host_os == Darwin ]]; then
    printf -v link_command \
        'llvm_dir=$(llvm-config --libdir); clang -O2 -flto -isysroot %q -Wl,-dead_strip -Wl,-export_dynamic %q %q %q %q -L"$llvm_dir" -Wl,-rpath,"$llvm_dir" -lLLVM -o %q' \
        "$host_sdk" "$object" "$value_runtime_object" "$host_runtime_object" \
        "$llvm_host_object" "$executable"
else
    printf -v link_command \
        'llvm_dir=$(llvm-config --libdir); clang -O2 -flto -fuse-ld=lld -Wl,--threads=1 -Wl,--gc-sections -Wl,--export-dynamic %q %q %q %q -L"$llvm_dir" -Wl,-rpath,"$llvm_dir" -lLLVM -o %q' \
        "$object" "$value_runtime_object" "$host_runtime_object" \
        "$llvm_host_object" "$executable"
fi
ABLA_MAX_MEMORY_MB=$object_memory_mb ABLA_MAX_SECONDS=180 \
    run_toolchain_command "$link_command"

[[ -s $module && -s $object && -x $executable ]]
mv -f -- "$module" "$output.ll"
mv -f -- "$executable" "$output"
