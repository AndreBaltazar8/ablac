#!/usr/bin/env bash
# lld in the compiler's own process (#92, runtime/abla_lld_shim.cpp, src/static_lld.ab): a statically linked compiler built with ABLA_STATIC_LLD_LIB links its programs
# without starting ld.lld. Held to the external linker's output and to its absence: every program built in process (the default) and with ABLA_LINK_INPROCESS=0 (the
# external ld.lld) is byte for byte the same executable, for x86-64 and AArch64; and with a PATH that has no ld.lld, wasm-ld or clang, the in-process build of hello
# works while ABLA_LINK_INPROCESS=0 fails (so the first really ran no linker). Needs the static compiler built with lld (tools/build-static-compiler.sh after
# eval "$(tools/static-llvm-env.sh)"); a compiler built without says so and the test is skipped.
# Usage: tools/test-static-lld.sh <static compiler>
set -euo pipefail
export LC_ALL=C
compiler=${1:?usage: tools/test-static-lld.sh <static compiler>}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'static lld: Linux only'; exit 0; }
# (the static archives are for building the static compiler: a program that links LLVM must not be linked on them here)
unset ABLA_STATIC_LLVM_LIB ABLA_STATIC_ZLIB ABLA_STATIC_LLD_LIB ABLA_STATIC_LLD_INCLUDE ABLA_STATIC_LLVM_INCLUDE ABLA_STATIC_LLD_OBJECT
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS ABLA_LINK_DIRECT ABLA_LINK_BUILTIN ABLA_LINK_INPROCESS ABLA_COMPILER_RT_BUILTINS
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
out=build/static-lld
rm -rf "$out"
mkdir -p "$out"
fail() { echo "static lld: $*" >&2; exit 1; }
builtins=$(clang --rtlib=compiler-rt -print-libgcc-file-name)
[[ -f $builtins ]] || fail "no compiler-rt builtins archive to name"
bin=$out/bin
mkdir -p "$bin"
# What the compiler still runs: the coreutils, and for the AArch64 build opt, llc and llvm-extract (the cross code generation is external). No ld.lld, wasm-ld, llvm-ar or clang.
for tool in env cp nproc rm mktemp cat uname dirname readlink opt llc llvm-extract; do
    path=$(command -v "$tool" 2> /dev/null || true)
    [[ -z $path ]] || ln -sf "$path" "$bin/$tool"
done
for tool in ld.lld wasm-ld clang llvm-ar; do [[ ! -e $bin/$tool ]] || fail "$tool is in the test's PATH"; done
run() { # tag, then the environment words and the build arguments after --
    local tag=$1; shift
    env "$@" > "$out/$tag.log" 2>&1
}
programs=(tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab tests/cases/libc-imports/tasks.ab
    tests/cases/libc-imports/threads.ab tests/cases/libc-imports/float-remainder.ab tests/cases/modules/http-event.ab tests/cases/modules/udp-ephemeral.ab)
count=0
for program in "${programs[@]}"; do
    name=$(basename -- "$program" .ab)
    for variant in "x86:" "x86-release:" "aarch64:--target aarch64-linux"; do
        tag=${variant%%:*}
        read -r -a flags <<< "${variant#*:}"
        fast=(--fast)
        [[ $tag == x86-release ]] && fast=()
        base=$name.$tag
        run "$base.inprocess" ABLA_CACHE_DIR=$PWD/$out/$base.in.cache "$compiler" build "$program" -o "$out/$base.in" "${fast[@]}" "${flags[@]}" ||
            { tail -5 "$out/$base.inprocess.log" >&2; fail "$name ($tag): the in-process build failed"; }
        run "$base.external" ABLA_LINK_INPROCESS=0 ABLA_CACHE_DIR=$PWD/$out/$base.ex.cache "$compiler" build "$program" -o "$out/$base.ex" "${fast[@]}" "${flags[@]}" ||
            { tail -5 "$out/$base.external.log" >&2; fail "$name ($tag): the external build failed"; }
        cmp -s "$out/$base.in" "$out/$base.ex" || fail "$name ($tag): the in-process link differs from the external one"
        count=$((count + 1))
    done
done
# Code generation units (a big program is cut into units, whose objects are combined by an archive): forced on a small one, the archive is written in process (no llvm-ar on the PATH below)
# and the executable is the external tools' byte for byte.
units=(ABLA_CODEGEN_UNITS=4 ABLA_CODEGEN_UNITS_MINIMUM=1 ABLA_CODEGEN_JOBS=1)
for name in hello strings-arrays; do
    program=tests/cases/libc-imports/$name.ab
    run "units.$name.inprocess" "${units[@]}" ABLA_CACHE_DIR=$PWD/$out/units.$name.in.cache "$compiler" build "$program" -o "$out/units.$name.in" --fast ||
        { tail -5 "$out/units.$name.inprocess.log" >&2; fail "$name with units: the in-process build failed"; }
    run "units.$name.external" "${units[@]}" ABLA_LINK_INPROCESS=0 ABLA_CACHE_DIR=$PWD/$out/units.$name.ex.cache "$compiler" build "$program" -o "$out/units.$name.ex" --fast ||
        { tail -5 "$out/units.$name.external.log" >&2; fail "$name with units: the external build failed"; }
    cmp -s "$out/units.$name.in" "$out/units.$name.ex" || fail "$name with units: the in-process executable differs from the external one"
    count=$((count + 1))
done
run "units.nolinker" PATH=$PWD/$bin "${units[@]}" ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/units.nolinker.cache "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/units.nolinker" --fast ||
    { tail -5 "$out/units.nolinker.log" >&2; fail "hello with units did not build with no linker or llvm-ar on the PATH"; }
cmp -s "$out/units.nolinker" "$out/units.hello.ex" || fail "hello with units, built with no llvm-ar, differs from the external one"
# The Windows target (W1a): --target x86_64-windows-freestanding links a freestanding program with lld-link, in process too (lld's COFF driver in the shim, #1092): byte for byte what the external
# lld-link makes (/brepro), and built with no lld-link on the PATH.
if [[ -f tests/cases/windows/exit7.ab ]]; then
    run "windows.inprocess" ABLA_CACHE_DIR=$PWD/$out/windows.in.cache "$compiler" build tests/cases/windows/exit7.ab --target x86_64-windows-freestanding -o "$out/exit7.in.exe" --no-cache ||
        { tail -5 "$out/windows.inprocess.log" >&2; fail "exit7 for Windows: the in-process link failed"; }
    run "windows.external" ABLA_LINK_INPROCESS=0 ABLA_CACHE_DIR=$PWD/$out/windows.ex.cache "$compiler" build tests/cases/windows/exit7.ab --target x86_64-windows-freestanding -o "$out/exit7.ex.exe" --no-cache ||
        { tail -5 "$out/windows.external.log" >&2; fail "exit7 for Windows: the external link failed"; }
    cmp -s "$out/exit7.in.exe" "$out/exit7.ex.exe" || fail "exit7 for Windows: the in-process lld-link differs from the external one"
    run "windows.nolinker" PATH=$PWD/$bin ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/windows.nl.cache "$compiler" build tests/cases/windows/exit7.ab --target x86_64-windows-freestanding \
        -o "$out/exit7.nl.exe" --no-cache || { tail -5 "$out/windows.nolinker.log" >&2; fail "exit7 for Windows did not build with no lld-link on the PATH"; }
    cmp -s "$out/exit7.nl.exe" "$out/exit7.ex.exe" || fail "exit7 for Windows built with no linker differs from the external link's"
    count=$((count + 1))
fi
# No linker on the PATH.
for variant in "x86:" "aarch64:--target aarch64-linux"; do
    tag=${variant%%:*}
    read -r -a flags <<< "${variant#*:}"
    run "nolinker.$tag" PATH=$PWD/$bin ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/nolinker.$tag.cache "$compiler" build tests/cases/libc-imports/hello.ab \
        -o "$out/nolinker.$tag" --fast "${flags[@]}" || { tail -5 "$out/nolinker.$tag.log" >&2; fail "hello ($tag) did not build with no linker on the PATH"; }
    cmp -s "$out/nolinker.$tag" "$out/hello.$tag.ex" || fail "hello ($tag) built with no linker differs from the external link's"
    if run "nolinker-off.$tag" PATH=$PWD/$bin ABLA_LINK_INPROCESS=0 ABLA_COMPILER_RT_BUILTINS=$builtins ABLA_CACHE_DIR=$PWD/$out/nolinker-off.$tag.cache "$compiler" build \
        tests/cases/libc-imports/hello.ab -o "$out/nolinker-off.$tag" --fast "${flags[@]}"; then
        fail "hello ($tag) built with ABLA_LINK_INPROCESS=0 and no linker: the test does not tell the in-process link from the external"
    fi
done
[[ $("$out/nolinker.x86") == hello ]] || fail "the linker-free x86-64 hello did not print hello"
echo "static lld: $count builds (${#programs[@]} programs x 3 ways) linked in process, byte for byte the external ld.lld's; hello builds with no ld.lld, wasm-ld or clang on the PATH (x86-64 and AArch64)"
