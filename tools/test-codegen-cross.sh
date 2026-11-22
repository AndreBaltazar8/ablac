#!/usr/bin/env bash
# The cross targets' code generation in the compiler's own process (#101, runtime/abla_lld_shim.cpp, abla_tool_main): opt is LLVM's own driver (optMain) and llc is its
# compileModule for the options the compiler passes, each run as a child of the compiler itself (`ablac --llvm-tool opt|llc`), so a statically linked compiler needs no LLVM
# tools for them. Held to the tools' bytes: every AArch64 Linux program (fast, release and debug-free) and every WebAssembly module built with the compiler's own opt and llc
# (the default) and with ABLA_CODEGEN_INPROCESS=0 (the external ones) is the same file; and on an empty PATH an AArch64 Linux build works while the external one cannot.
# Needs a static compiler built with the shim (tools/build-static-compiler.sh after eval "$(tools/static-llvm-env.sh)"). Usage: tools/test-codegen-cross.sh <static compiler>
set -euo pipefail
export LC_ALL=C
compiler=${1:?usage: tools/test-codegen-cross.sh <static compiler>}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'codegen cross: Linux only'; exit 0; }
unset ABLA_STATIC_LLVM_LIB ABLA_STATIC_ZLIB ABLA_STATIC_LLD_LIB ABLA_STATIC_LLD_INCLUDE ABLA_STATIC_LLVM_INCLUDE ABLA_STATIC_LLD_OBJECT
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS ABLA_LINK_DIRECT ABLA_LINK_BUILTIN ABLA_LINK_INPROCESS ABLA_CODEGEN_INPROCESS ABLA_COMPILER_RT_BUILTINS
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
out=build/codegen-cross
rm -rf "$out"
mkdir -p "$out"
fail() { echo "codegen cross: $*" >&2; exit 1; }
programs=(tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab tests/cases/libc-imports/tasks.ab
    tests/cases/libc-imports/threads.ab tests/cases/libc-imports/float-remainder.ab tests/cases/modules/http-event.ab tests/cases/modules/udp-ephemeral.ab)
count=0
for program in "${programs[@]}"; do
    name=$(basename -- "$program" .ab)
    for mode in fast release; do
        flags=(--target aarch64-linux)
        [[ $mode == fast ]] && flags+=(--fast)
        ABLA_CACHE_DIR=$PWD/$out/$name.$mode.in.cache "$compiler" build "$program" -o "$out/$name.$mode.in" --no-cache "${flags[@]}" > "$out/$name.$mode.in.log" 2>&1 ||
            { tail -5 "$out/$name.$mode.in.log" >&2; fail "$name ($mode, AArch64): the build with the compiler's own tools failed"; }
        ABLA_CODEGEN_INPROCESS=0 ABLA_CACHE_DIR=$PWD/$out/$name.$mode.ex.cache "$compiler" build "$program" -o "$out/$name.$mode.ex" --no-cache "${flags[@]}" > "$out/$name.$mode.ex.log" 2>&1 ||
            { tail -5 "$out/$name.$mode.ex.log" >&2; fail "$name ($mode, AArch64): the build with the external tools failed"; }
        cmp -s "$out/$name.$mode.in" "$out/$name.$mode.ex" || fail "$name ($mode, AArch64): the in-process code generation differs from opt and llc's"
        count=$((count + 1))
    done
done
# WebAssembly modules: the compile-time module builders of tests/cases (a build.ab that makes its module while it compiles).
wasm=0
for case in wasm-export-extern wasm-alloc-limit wasm-debug-reproducible; do
    [[ -f tests/cases/$case/build.ab ]] || continue
    module=$(sed -n 's/^.*"\(\.\.\/\.\.\/\.\.\/build\/[^"]*\.wasm\)".*$/\1/p' tests/cases/$case/build.ab | head -1)
    [[ -n $module ]] || continue
    target=$root/tests/cases/$case/$module
    for variant in in ex; do
        extra=()
        [[ $variant == ex ]] && extra=(ABLA_CODEGEN_INPROCESS=0)
        rm -f "$target"
        env "${extra[@]}" ABLA_CACHE_DIR=$PWD/$out/$case.$variant.cache "$compiler" build "tests/cases/$case/build.ab" -o "$out/$case.$variant.driver" --no-cache \
            > "$out/$case.$variant.log" 2>&1 || { tail -5 "$out/$case.$variant.log" >&2; fail "$case ($variant): the module did not build"; }
        [[ -f $target ]] || fail "$case ($variant): no module at $target"
        cp "$target" "$out/$case.$variant.wasm"
    done
    cmp -s "$out/$case.in.wasm" "$out/$case.ex.wasm" || fail "$case: the in-process WebAssembly module differs from opt and llc's"
    wasm=$((wasm + 1))
done
[[ $wasm -gt 0 ]] || fail "no WebAssembly module case ran"
# An empty PATH: AArch64 builds with the compiler's own opt and llc (the external ones are not there).
mkdir -p "$out/empty"
builtins=$(clang --rtlib=compiler-rt -print-libgcc-file-name)
env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_SYSROOT="$ABLA_SYSROOT" ABLA_COMPILER_RT_BUILTINS="$builtins" ABLA_CACHE_DIR="$PWD/$out/empty.cache" \
    "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/empty.aarch64" --no-cache --target aarch64-linux > "$out/empty.log" 2>&1 ||
    { tail -5 "$out/empty.log" >&2; fail "hello for AArch64 did not build on an empty PATH"; }
cmp -s "$out/empty.aarch64" "$out/hello.release.ex" || fail "hello for AArch64 built on an empty PATH differs from the external tools' (release)"
if env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_SYSROOT="$ABLA_SYSROOT" ABLA_CODEGEN_INPROCESS=0 ABLA_COMPILER_RT_BUILTINS="$builtins" ABLA_CACHE_DIR="$PWD/$out/empty-off.cache" \
    "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/empty-off.aarch64" --no-cache --target aarch64-linux > "$out/empty-off.log" 2>&1; then
    fail "hello for AArch64 built with ABLA_CODEGEN_INPROCESS=0 and an empty PATH: the test does not tell the compiler's tools from the external ones"
fi
echo "codegen cross: $count AArch64 builds (fast and release) and $wasm WebAssembly modules identical to the ones built with opt and llc; AArch64 builds on an empty PATH"
