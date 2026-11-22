#!/usr/bin/env bash
# The static compiler builds WebAssembly modules (#806): the compile-time module builders of tests/cases (a build.ab whose #wasmBuildModule makes the module while it compiles) run with the
# statically linked compiler, which links the module with lld in its own process (the LTO there starts threads: v0.2.65's static compiler aborted with "stack smashing detected" in a
# thread attribute its libc initialised too far) and with the ordinary compiler when one is given, and the two modules are the same bytes. The suite and the gates run the wasm tests with the
# ordinary compiler; this is what runs them with the static one.
# Needs the static compiler (tools/build-static-compiler.sh); without it the test says so. Usage: tools/test-static-wasm-modules.sh <static compiler> [ordinary compiler]
set -euo pipefail
export LC_ALL=C
static=${1:?usage: tools/test-static-wasm-modules.sh <static compiler> [ordinary compiler]}
ordinary=${2:-}
[[ $static == /* || $static != */* ]] || static="$PWD/$static"
[[ -z $ordinary || $ordinary == /* || $ordinary != */* ]] || ordinary="$PWD/$ordinary"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'static wasm modules: Linux only'; exit 0; }
unset ABLA_STATIC_LLVM_LIB ABLA_STATIC_ZLIB ABLA_STATIC_LLD_LIB ABLA_STATIC_LLD_INCLUDE ABLA_STATIC_LLVM_INCLUDE ABLA_STATIC_LLD_OBJECT ABLA_DEBUG ABLA_CODEGEN_INPROCESS ABLA_LINK_INPROCESS
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
out=build/static-wasm-modules
rm -rf "$out"
mkdir -p "$out"
fail() { echo "static wasm modules: $*" >&2; exit 1; }
count=0
for case in wasm-export-extern wasm-alloc-limit wasm-debug-reproducible; do
    [[ -f tests/cases/$case/build.ab ]] || fail "no tests/cases/$case/build.ab"
    module=$(sed -n 's/^.*"\(\.\.\/\.\.\/\.\.\/build\/[^"]*\.wasm\)".*$/\1/p' tests/cases/$case/build.ab | head -1)
    [[ -n $module ]] || fail "$case: no module path in its build.ab"
    target=$root/tests/cases/$case/$module
    for which in static ordinary; do
        if [[ $which == static ]]; then builder=$static; else builder=$ordinary; fi
        [[ -n $builder ]] || continue
        rm -f "$target"
        ABLA_CACHE_DIR=$PWD/$out/$case.$which.cache "$builder" build "tests/cases/$case/build.ab" -o "$out/$case.$which.driver" --no-cache > "$out/$case.$which.log" 2>&1 ||
            { tail -5 "$out/$case.$which.log" >&2; fail "$case: the $which compiler did not build the module"; }
        [[ -s $target ]] || fail "$case: the $which compiler left no module at $target"
        cp "$target" "$out/$case.$which.wasm"
    done
    if [[ -n $ordinary ]]; then
        cmp -s "$out/$case.static.wasm" "$out/$case.ordinary.wasm" || fail "$case: the static compiler's module differs from the ordinary compiler's"
    fi
    count=$((count + 1))
done
echo "static wasm modules: $count modules built by the static compiler$([[ -n $ordinary ]] && echo ', byte for byte the ordinary compiler'"'"'s')"
