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
# llvm-extract and llvm-ar in process too: a FAST cross build is cut into partitions by llvm-extract, and a static library is written by llvm-ar. Held to the tools' bytes, and run on an
# empty PATH (no llvm-extract, no llvm-ar, no opt, no llc). One output name for the three builds of each variant: a static library records the name it was built as.
extra=0
for variant in "aarch64-fast:--target aarch64-linux --fast" "aarch64-lib:--target aarch64-linux --emit static-library --fast"; do
    tag=${variant%%:*}
    read -r -a flags <<< "${variant#*:}"
    mkdir -p "$out/ex-$tag.in.d" "$out/ex-$tag.ex.d" "$out/ex-$tag.nl.d"
    ABLA_CACHE_DIR=$PWD/$out/ex-$tag.in.cache "$compiler" build tests/cases/modules/http-event.ab -o "$out/ex-$tag.in.d/product" --no-cache "${flags[@]}" > "$out/ex-$tag.in.log" 2>&1 ||
        { tail -5 "$out/ex-$tag.in.log" >&2; fail "http-event ($tag): the build with the compiler's own tools failed"; }
    ABLA_CODEGEN_INPROCESS=0 ABLA_CACHE_DIR=$PWD/$out/ex-$tag.ex.cache "$compiler" build tests/cases/modules/http-event.ab -o "$out/ex-$tag.ex.d/product" --no-cache "${flags[@]}" > "$out/ex-$tag.ex.log" 2>&1 ||
        { tail -5 "$out/ex-$tag.ex.log" >&2; fail "http-event ($tag): the build with the external tools failed"; }
    cmp -s "$out/ex-$tag.in.d/product" "$out/ex-$tag.ex.d/product" || fail "http-event ($tag): the in-process llvm-extract/llvm-ar/opt/llc differ from the tools'"
    env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_SYSROOT="$ABLA_SYSROOT" ABLA_COMPILER_RT_BUILTINS="$builtins" ABLA_CACHE_DIR="$PWD/$out/ex-$tag.nl.cache" \
        "$compiler" build tests/cases/modules/http-event.ab -o "$out/ex-$tag.nl.d/product" --no-cache "${flags[@]}" > "$out/ex-$tag.nl.log" 2>&1 ||
        { tail -5 "$out/ex-$tag.nl.log" >&2; fail "http-event ($tag) did not build on an empty PATH"; }
    cmp -s "$out/ex-$tag.nl.d/product" "$out/ex-$tag.ex.d/product" || fail "http-event ($tag) built on an empty PATH differs from the external tools'"
    extra=$((extra + 1))
done
# Objects of three targets (ELF AArch64, Mach-O x86-64 and arm64: no SDK needed for an object) from a module of two functions, by the compiler's own llc and by llc: the same bytes.
objects=()
for triple in aarch64-unknown-linux-gnu x86_64-apple-macosx arm64-apple-macosx; do
    printf 'target triple = "%s"\ndefine i64 @add(i64 %%a, i64 %%b) {\n  %%c = add i64 %%a, %%b\n  ret i64 %%c\n}\ndefine i64 @twice(i64 %%a) {\n  %%c = call i64 @add(i64 %%a, i64 %%a)\n  ret i64 %%c\n}\n' "$triple" > "$out/mini.$triple.ll"
    "$compiler" --llvm-tool llc -filetype=obj -relocation-model=pic -O2 -mtriple="$triple" "$out/mini.$triple.ll" -o "$out/mini.$triple.in.o" 2> "$out/mini.log" || { cat "$out/mini.log" >&2; fail "llc for $triple: the compiler's own failed"; }
    llc -filetype=obj -relocation-model=pic -O2 -mtriple="$triple" "$out/mini.$triple.ll" -o "$out/mini.$triple.ex.o"
    cmp -s "$out/mini.$triple.in.o" "$out/mini.$triple.ex.o" || fail "llc for $triple: the compiler's object differs from llc's"
    objects+=("$out/mini.$triple.in.o")
done
# The two tools themselves, as the compiler runs them (`ablac --llvm-tool llvm-ar|llvm-extract`), against the LLVM tools' bytes: archives of ELF and of Mach-O members in each format
# (the base name of each member, the symbol table, the format inferred from the first member), and the functions of a module cut out and cut away, as text.
tools=0
for format in gnu darwin bsd default; do
    for set in "0 0" "1 2" "0 1 2"; do
        members=()
        for index in $set; do members+=("${objects[$index]}"); done
        "$compiler" --llvm-tool llvm-ar rcsD "--format=$format" "$out/ar.$format.in.a" "${members[@]}" 2> "$out/ar.log" || { cat "$out/ar.log" >&2; fail "llvm-ar --format=$format of ${set// /,}: the compiler's own failed"; }
        llvm-ar rcsD "--format=$format" "$out/ar.$format.ex.a" "${members[@]}"
        cmp -s "$out/ar.$format.in.a" "$out/ar.$format.ex.a" || fail "llvm-ar --format=$format of members ${set// /,}: the compiler's archive differs from llvm-ar's"
        rm -f "$out/ar.$format.in.a" "$out/ar.$format.ex.a"
        tools=$((tools + 1))
    done
done
"$compiler" --emit-llvm tests/cases/modules/http-event.ab > "$out/extract.ll" 2> /dev/null || fail "no LLVM text of http-event"
symbols=$(sed -n 's/^define [^@]*@\(abla_fn_[A-Za-z0-9_]*\)(.*/\1/p' "$out/extract.ll" | sed -n '3p;9p;27p')
[[ -n $symbols ]] || fail "no function to extract"
for mode in keep delete; do
    args=()
    for symbol in $symbols; do args+=("--func=$symbol"); done
    [[ $mode == delete ]] && args=(--delete "${args[@]}")
    "$compiler" --llvm-tool llvm-extract "${args[@]}" "$out/extract.ll" -S -o "$out/extract.$mode.in.ll" 2> "$out/extract.log" || { cat "$out/extract.log" >&2; fail "llvm-extract ($mode): the compiler's own failed"; }
    llvm-extract "${args[@]}" "$out/extract.ll" -S -o "$out/extract.$mode.ex.ll"
    cmp -s "$out/extract.$mode.in.ll" "$out/extract.$mode.ex.ll" || fail "llvm-extract ($mode): the compiler's module differs from llvm-extract's"
    tools=$((tools + 1))
done
echo "codegen cross: $count AArch64 builds (fast and release) and $wasm WebAssembly modules identical to the ones built with opt and llc; AArch64 builds on an empty PATH; $extra more (fast AArch64 partitions and static library) identical and on an empty PATH; $tools direct llvm-ar, llvm-extract and llc runs on Mach-O and ELF inputs identical to the tools"
