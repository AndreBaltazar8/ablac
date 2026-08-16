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
object_seconds=${ABLA_RELEASE_SELFHOST_BUILD_SECONDS:-300}
emit_seconds=${ABLA_FINAL_SELFHOST_EMIT_SECONDS:-300}
release_cache=${ABLA_RELEASE_SELFHOST_CACHE:-1}
release_cache_root=${ABLA_RELEASE_SELFHOST_CACHE_DIR:-}
value_abi=${ABLA_RELEASE_VALUE_ABI:-24}
host_os=$(uname -s)
host_machine=$(uname -m)
host_triple=
host_sdk=

case "$value_abi" in
    24) runtime_abi_flag= ;;
    32) runtime_abi_flag=-DABLA_VALUE_ABI32=1 ;;
    40) runtime_abi_flag=-DABLA_VALUE_ABI40=1 ;;
    *)
        printf 'unsupported release value ABI: %s\n' "$value_abi" >&2
        exit 2
        ;;
esac

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

hash_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
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
if [[ -z $release_cache_root ]]; then
    release_cache_root="$project_root/build/cache/selfhost-release"
fi

# Keep the Abla frontend heap and LLVM's optimized-object heap in distinct
# processes. A complete compiler graph otherwise makes both peaks coexist and
# can exhaust the machine before the watchdog gets a useful diagnostic.
ABLA_MAX_MEMORY_MB=$emit_memory_mb ABLA_MAX_SECONDS=$emit_seconds \
    "$project_root/tools/run-limited.sh" \
    "$compiler" --emit-llvm "$entry" > "$module"

# The optimized whole-compiler backend is intentionally expensive. Reuse it
# only when every code-generation input is byte-identical: emitted compiler
# IR, linked runtime sources/headers, host, toolchain, and the exact release
# profile. The fixed-point gate still emits and compares compiler IR, so this
# warm path cannot conceal a frontend or deterministic-output regression.
if [[ $host_os == Darwin ]]; then
    toolchain_identity=$(printf '%s\n%s\n%s\n%s\n' \
        "$(clang --version)" "$(llvm-config --version)" \
        "$host_triple" "$host_sdk")
else
    toolchain_identity=$(run_toolchain_command \
        'printf "%s\n%s\n" "$(clang --version)" "$(llvm-config --version)"')
fi
build_key=$(
    {
        printf '%s\n' \
            'abla-selfhost-release-v1' \
            'clang-O2-full-lto-function-sections-data-sections' \
            "value-abi-$value_abi" \
            "$host_os" "$host_machine" "$toolchain_identity" \
            "module $(hash_file "$module")"
        find "$project_root/runtime" -maxdepth 1 -type f \
            \( -name '*.h' -o -name 'abla_runtime.c' \
                -o -name 'abla_runtime_host.c' \
                -o -name 'abla_llvm_host.c' \) -print |
            LC_ALL=C sort | while IFS= read -r runtime_input; do
                printf '%s %s\n' \
                    "${runtime_input#"$project_root/"}" \
                    "$(hash_file "$runtime_input")"
            done
    } | hash_stream
)
cache_entry="$release_cache_root/$build_key/compiler"
if [[ $release_cache != 0 && -x $cache_entry ]]; then
    cp -p -- "$cache_entry" "$output"
    mv -f -- "$module" "$output.ll"
    printf '[abla-release] reused optimized compiler %s\n' \
        "${build_key:0:12}" >&2
    exit 0
fi

if [[ $host_os == Darwin ]]; then
    printf -v compile_command \
        'clang -O2 -flto -target %q -isysroot %q -Wno-override-module -Wno-unused-command-line-argument -ffunction-sections -fdata-sections -c %q -o %q' \
        "$host_triple" "$host_sdk" "$module" "$object"
else
    printf -v compile_command \
        'clang -O2 -flto -Wno-unused-command-line-argument -ffunction-sections -fdata-sections -c %q -o %q' \
        "$module" "$object"
fi
ABLA_MAX_MEMORY_MB=$object_memory_mb ABLA_MAX_SECONDS=$object_seconds \
    run_toolchain_command "$compile_command"

runtime_self_host_text_flag=
if grep -Eq '^define .*@ablaTextIsValidUtf8\(' "$module"; then
    runtime_self_host_text_flag=-DABLA_SELF_HOSTED_RUNTIME_TEXT=1
fi

if [[ $host_os == Darwin ]]; then
    printf -v runtime_compile_command \
        'clang -std=c11 -O2 -flto %s %s -isysroot %q -ffunction-sections -fdata-sections -I%q -c %q -o %q && clang -std=c11 -O2 -flto -pthread %s -isysroot %q -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE -Wno-deprecated-declarations -ffunction-sections -fdata-sections -I%q -c %q -o %q' \
        "$runtime_self_host_text_flag" "$runtime_abi_flag" "$host_sdk" "$project_root/runtime" \
        "$project_root/runtime/abla_runtime.c" \
        "$value_runtime_object" "$runtime_abi_flag" "$host_sdk" \
        "$project_root/runtime" \
        "$project_root/runtime/abla_runtime_host.c" \
        "$host_runtime_object"
else
    printf -v runtime_compile_command \
        'clang -std=c11 -O2 -flto %s %s -ffunction-sections -fdata-sections -I%q -c %q -o %q && clang -std=c11 -O2 -flto %s -ffunction-sections -fdata-sections -I%q -c %q -o %q' \
        "$runtime_self_host_text_flag" "$runtime_abi_flag" "$project_root/runtime" "$project_root/runtime/abla_runtime.c" \
        "$value_runtime_object" "$runtime_abi_flag" "$project_root/runtime" \
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
ABLA_MAX_MEMORY_MB=$object_memory_mb ABLA_MAX_SECONDS=$object_seconds \
    run_toolchain_command "$link_command"

[[ -s $module && -s $object && -x $executable ]]
mv -f -- "$module" "$output.ll"
mv -f -- "$executable" "$output"
if [[ $release_cache != 0 ]]; then
    cache_directory=${cache_entry%/*}
    mkdir -p -- "$release_cache_root"
    if mkdir -- "$cache_directory" 2>/dev/null; then
        cp -p -- "$output" "$cache_directory/compiler.pending"
        mv -f -- "$cache_directory/compiler.pending" "$cache_entry"
    fi
fi
