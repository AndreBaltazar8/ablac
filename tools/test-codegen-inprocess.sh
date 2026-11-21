#!/usr/bin/env bash
# The release path's code generation in the compiler's own process (#101, runtime/abla_lld_shim.cpp, abla_emit_object): what `llc` does with --function-sections --data-sections
# --align-loops=32, which the C API cannot set, built from the C++ API's TargetMachine. Held to llc's bytes: every program built in release mode (no --fast) by a statically
# linked compiler that carries the shim (the default) and with ABLA_CODEGEN_INPROCESS=0 (the external llc) is the same executable; and with a PATH that has no llc a release
# build still works. Programs are the 8 of tools/test-static-lld.sh and a big one that is cut into release parts; ABLA_CODEGEN_BIG names more files to hold the same way (the
# compiler's own source: src/orc_main.ab, which takes a few minutes).
# Usage: tools/test-codegen-inprocess.sh <static compiler>
set -euo pipefail
export LC_ALL=C
compiler=${1:?usage: tools/test-codegen-inprocess.sh <static compiler>}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'codegen in process: Linux only'; exit 0; }
# (the static archives are for building the static compiler: a program that links LLVM must not be linked on them here)
unset ABLA_STATIC_LLVM_LIB ABLA_STATIC_ZLIB ABLA_STATIC_LLD_LIB ABLA_STATIC_LLD_INCLUDE ABLA_STATIC_LLVM_INCLUDE ABLA_STATIC_LLD_OBJECT
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS ABLA_LINK_DIRECT ABLA_LINK_BUILTIN ABLA_LINK_INPROCESS ABLA_CODEGEN_INPROCESS ABLA_COMPILER_RT_BUILTINS
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
out=build/codegen-inprocess
rm -rf "$out"
mkdir -p "$out"
fail() { echo "codegen in process: $*" >&2; exit 1; }
programs=(tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab tests/cases/libc-imports/tasks.ab
    tests/cases/libc-imports/threads.ab tests/cases/libc-imports/float-remainder.ab tests/cases/modules/http-event.ab tests/cases/modules/udp-ephemeral.ab)
# shellcheck disable=SC2206
programs+=(${ABLA_CODEGEN_BIG:-})
count=0
for program in "${programs[@]}"; do
    name=$(basename -- "$program" .ab)
    ABLA_CACHE_DIR=$PWD/$out/$name.in.cache "$compiler" build "$program" -o "$out/$name.in" --no-cache > "$out/$name.in.log" 2>&1 ||
        { tail -5 "$out/$name.in.log" >&2; fail "$name: the in-process build failed"; }
    ABLA_CODEGEN_INPROCESS=0 ABLA_CACHE_DIR=$PWD/$out/$name.ex.cache "$compiler" build "$program" -o "$out/$name.ex" --no-cache > "$out/$name.ex.log" 2>&1 ||
        { tail -5 "$out/$name.ex.log" >&2; fail "$name: the build with llc failed"; }
    cmp -s "$out/$name.in" "$out/$name.ex" || fail "$name: the in-process code generation differs from llc's"
    count=$((count + 1))
done
# An EMPTY PATH and no ABLA_LLVM_TOOLS (the nix shell sets it): no llc, no ld.lld (it links in process), not even cp or env.
bin=$out/bin
mkdir -p "$bin"
builtins=$(clang --rtlib=compiler-rt -print-libgcc-file-name)
[[ -f $builtins ]] || fail "no compiler-rt builtins archive to name"
PATH=$PWD/$bin ABLA_LLVM_TOOLS= ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/nollc.cache "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/nollc" --no-cache > "$out/nollc.log" 2>&1 ||
    { tail -5 "$out/nollc.log" >&2; fail "a release build of hello failed with no llc on the PATH"; }
cmp -s "$out/nollc" "$out/hello.ex" || fail "hello built with no llc differs from the one built with it"
[[ $("$out/nollc") == hello ]] || fail "the release hello did not print hello"
# An object artifact is published without `cp` too (an Xtensa build ends the same way): built on the empty PATH, the same bytes as with the whole one.
PATH=$PWD/$bin ABLA_LLVM_TOOLS= ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/obj-empty.cache "$compiler" build tests/cases/libc-imports/hello.ab --emit object -o "$out/obj-empty.o" \
    --no-cache > "$out/obj-empty.log" 2>&1 || { tail -5 "$out/obj-empty.log" >&2; fail "an object build of hello failed on an empty PATH"; }
ABLA_CACHE_DIR=$PWD/$out/obj-full.cache "$compiler" build tests/cases/libc-imports/hello.ab --emit object -o "$out/obj-full.o" --no-cache > "$out/obj-full.log" 2>&1 ||
    { tail -5 "$out/obj-full.log" >&2; fail "an object build of hello failed"; }
cmp -s "$out/obj-empty.o" "$out/obj-full.o" || fail "the object built on an empty PATH differs"
if PATH=$PWD/$bin ABLA_LLVM_TOOLS= ABLA_CODEGEN_INPROCESS=0 ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/nollc-off.cache "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/nollc-off" \
    --no-cache > "$out/nollc-off.log" 2>&1; then
    fail "hello built with ABLA_CODEGEN_INPROCESS=0 and no llc: the test does not tell the in-process code generation from llc"
fi
echo "codegen in process: $count release builds identical to the ones that run llc; a release hello builds with no llc on the PATH"
