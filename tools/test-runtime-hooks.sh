#!/usr/bin/env bash
# The compiler takes a few declarations from the runtime BY NAME: a body it swaps in (background freeing replaces the platform's collection, a WebAssembly
# module whose `orElse` retries takes the unwinding versions of attempt, abandon and save/restore) and a root it marks (the float formatting a program asked
# for). A name that is gone, renamed in the standard library, used to turn the feature off without a word. Each is an error now, E_RUNTIME_DECLARATION_MISSING,
# when the program asked for the feature. This renames each declaration in a copy of the standard library and expects the error from a program that asks for it,
# and expects the same program to build with the library as it is (so the test sees the feature, not a broken program).
# Usage: tools/test-runtime-hooks.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'runtime hooks: Linux only'; exit 0; }
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
out=build/runtime-hooks
rm -rf "$out"
mkdir -p "$out"
fail() { echo "runtime hooks: $*" >&2; exit 1; }
# A tree whose stdlib is a copy in which `old` is `new` in the given files; every other entry is a link to the real one.
renamed_root() { # name old new file...
    local name=$1 old=$2 new=$3
    shift 3
    local dir=$out/$name entry file
    mkdir -p "$dir"
    for entry in "$root"/*; do
        [[ $(basename -- "$entry") == stdlib || $(basename -- "$entry") == build ]] || ln -s "$entry" "$dir/$(basename -- "$entry")"
    done
    cp -r "$root/stdlib" "$dir/stdlib"
    for file in "$@"; do
        grep -q "$old" "$dir/stdlib/$file" || fail "$old is not in stdlib/$file"
        sed -i "s/$old/$new/g" "$dir/stdlib/$file"
    done
    echo "$dir"
}
# build <label> <sysroot> <expected: ok|missing:<name>> <program> [flags...]
check() {
    local label=$1 sysroot=$2 expected=$3 program=$4
    shift 4
    local log=$out/$label.log status=0
    ABLA_SYSROOT=$sysroot "$compiler" build "$program" -o "$out/$label.bin" --no-cache "$@" > "$log" 2>&1 || status=$?
    case $expected in
        ok) ((status == 0)) || { tail -5 "$log" >&2; fail "$label: the build failed with the standard library as it is"; } ;;
        missing:*)
            ((status != 0)) || fail "$label: the build succeeded without the runtime declaration"
            grep -q 'E_RUNTIME_DECLARATION_MISSING' "$log" || { tail -5 "$log" >&2; fail "$label: no E_RUNTIME_DECLARATION_MISSING"; }
            grep -q "${expected#missing:}" "$log" || { tail -5 "$log" >&2; fail "$label: the error does not name ${expected#missing:}"; } ;;
    esac
}
# 1. background freeing: a program that turns it on, with the library as it is and each of the pair renamed
background=tests/cases/gc-background-free/background.ab
check background-control "$root" ok "$background"
host=abla/runtime/platform/host.ab
check background-body "$(renamed_root background-body __ablaRuntimeHostBackgroundMemoryCollect __ablaRuntimeHostBackgroundMemoryCollectRenamed $host)" \
    missing:__ablaRuntimeHostBackgroundMemoryCollect "$background"
collect_files=$(grep -rl '__ablaRuntimePlatformMemoryCollect' stdlib | sed 's|^stdlib/||' | tr '\n' ' ')
# shellcheck disable=SC2086
check background-target "$(renamed_root background-target __ablaRuntimePlatformMemoryCollect __ablaRuntimePlatformMemoryCollectRenamed $collect_files)" \
    missing:__ablaRuntimePlatformMemoryCollect "$background"
# 2. a float erased to `any` and formatted: the formatter the program asked for is a root by name
printf 'import "abla/io"\nimport "abla/float/text"\n@noinline fun anyFloat(value: f64): any = value\nfun main: int {\n    println("${anyFloat(1.5)}")\n    return 0\n}\n' > "$out/erased-float.ab"
check float-control "$root" ok "$out/erased-float.ab"
formatter_files=$(grep -rl '__ablaRuntimeFormatErasedFloat' stdlib | sed 's|^stdlib/||' | tr '\n' ' ')
# shellcheck disable=SC2086
check float-formatter "$(renamed_root float-formatter __ablaRuntimeFormatErasedFloat __ablaRuntimeFormatErasedFloatRenamed $formatter_files)" \
    missing:__ablaRuntimeFormatErasedFloat "$out/erased-float.ab"
# 3. WebAssembly unwinding: a module with an `orElse` that retries, with one half of a pair gone
wasm=tests/cases/stm/unwinding/module.ab
check unwinding-control "$root" ok "$wasm" --target-triple wasm32-unknown-unknown --object-format wasm
check unwinding-attempt "$(renamed_root unwinding-attempt __ablaRuntimePlatformUnwindingAttempt __ablaRuntimePlatformUnwindingAttemptRenamed abla/runtime/platform/wasm.ab)" \
    missing:__ablaRuntimePlatformUnwindingAttempt "$wasm" --target-triple wasm32-unknown-unknown --object-format wasm
echo "runtime hooks: the library as it is builds, and each declaration the compiler takes by name, renamed, is an E_RUNTIME_DECLARATION_MISSING error (7 builds)"
