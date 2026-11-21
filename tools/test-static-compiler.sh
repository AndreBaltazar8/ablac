#!/usr/bin/env bash
# #806 step C: the statically linked compiler (src/orc_main_static.ab on LLVM's static archives and Abla's own C library, no libc) is a static-pie executable
# with no needed library, and it builds programs byte for byte as the ordinary compiler does. Builds build/ablac-static, then builds each program of
# tests/cases/libc-imports with both and compares the executables. With several workers (the C library's pthread family is futex locks over the runtime's threads).
# Needs the static archives, which the pinned shell's LLVM does not carry (ABLA_STATIC_LLVM_LIB, and ABLA_STATIC_ZLIB when the C compiler finds no libz.a);
# without them it says so and passes (CI gets them once the LLVM release publishes them).
# Usage: tools/test-static-compiler.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'static compiler: Linux only'; exit 0; }
if [[ -z ${ABLA_STATIC_LLVM_LIB:-} || ! -f ${ABLA_STATIC_LLVM_LIB}/libLLVMSupport.a ]]; then
    echo 'static compiler: skipped (no static LLVM: set ABLA_STATIC_LLVM_LIB to a directory with libLLVM*.a)'
    exit 0
fi
out=build/static-compiler
rm -rf "$out"
mkdir -p "$out"
tools/build-static-compiler.sh "$compiler" "$out/ablac-static" > "$out/build.log" 2>&1 ||
    { echo 'static compiler: the build failed' >&2; tail -8 "$out/build.log" >&2; exit 1; }
needed=$(readelf -d "$out/ablac-static" | grep -c '(NEEDED)' || true)
[[ $needed == 0 ]] || { echo "static compiler: $needed needed libraries" >&2; readelf -d "$out/ablac-static" >&2; exit 1; }
file -b "$out/ablac-static" | grep 'static-pie linked' >/dev/null || { echo 'static compiler: not a static-pie image' >&2; exit 1; }
# Several workers: the compiler's own threads lock LLVM's shared structures through the library's futex mutexes (src/static_libc/pthread.ab).
export ABLA_NATIVE_JOBS=4 ABLA_CODEGEN_JOBS=4
count=0
for source in tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab \
    tests/cases/libc-imports/float-remainder.ab tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab \
    tests/cases/libc-imports/jwt-verify.ab; do
    name=$(basename -- "$source" .ab)
    "$out/ablac-static" build "$source" -o "$out/$name.static" --no-cache > "$out/$name.static.log" 2>&1 ||
        { echo "static compiler: it failed to build $name" >&2; tail -5 "$out/$name.static.log" >&2; exit 1; }
    "$compiler" build "$source" -o "$out/$name.dynamic" --no-cache > "$out/$name.dynamic.log" 2>&1 ||
        { echo "static compiler: the ordinary compiler failed to build $name" >&2; exit 1; }
    cmp -s "$out/$name.static" "$out/$name.dynamic" || { echo "static compiler: $name differs from the ordinary compiler's" >&2; exit 1; }
    count=$((count + 1))
done
# The JIT: `ablac run` and the compile-time jit tier find the process's symbols through the library's dlsym table (src/static_libc/dl.ab).
run=$("$out/ablac-static" run tests/cases/libc-imports/hello.ab 2>&1) || { echo "static compiler: ablac run failed: $run" >&2; exit 1; }
[[ $run == hello ]] || { echo "static compiler: ablac run printed [$run]" >&2; exit 1; }
cat > "$out/compile-time.ab" <<'AB'
import "abla/io"

fun fib(n: int): int = if (n < 2) n else fib(n - 1) + fib(n - 2)

val answer = #fib(20)

fun main: int {
    println("answer $answer")
    return 0
}
AB
for tier in interp jit auto; do
    ABLA_COMPILE_EVAL=$tier "$out/ablac-static" build "$out/compile-time.ab" -o "$out/compile-time-$tier" --no-cache > "$out/compile-time-$tier.log" 2>&1 ||
        { echo "static compiler: the $tier tier failed" >&2; tail -5 "$out/compile-time-$tier.log" >&2; exit 1; }
    [[ $("$out/compile-time-$tier") == 'answer 6765' ]] || { echo "static compiler: the $tier tier answered wrong" >&2; exit 1; }
    ! grep -q 'Symbols not found' "$out/compile-time-$tier.log" || { echo "static compiler: the $tier tier lacks symbols" >&2; cat "$out/compile-time-$tier.log" >&2; exit 1; }
done
# Math the compiler folds or simplifies at compile time comes from the library's own routines (src/static_libc/math.ab): same program bytes as
# the ordinary compiler's, with constants LLVM folds through the host's functions.
cat > "$out/math-fold.ab" <<'AB'
import "abla/io"
import "abla/math"
import "abla/float/text"

fun main: int {
    val x = 0.5 + 1.0
    println("${sqrt(2.0)} ${floor(x)} ${ceil(x)} ${fabs(0.0 - x)} ${exp(1.0)} ${log(10.0)} ${pow(2.0, 0.5)} ${sin(1.0)} ${cos(1.0)} ${tan(1.0)} ${atan(1.0)} ${atan2(1.0, 2.0)}")
    return 0
}
AB
"$out/ablac-static" build "$out/math-fold.ab" -o "$out/math-fold.static" --no-cache > "$out/math-fold.static.log" 2>&1 ||
    { echo 'static compiler: it failed to build the math program' >&2; tail -5 "$out/math-fold.static.log" >&2; exit 1; }
"$compiler" build "$out/math-fold.ab" -o "$out/math-fold.dynamic" --no-cache > "$out/math-fold.dynamic.log" 2>&1 ||
    { echo 'static compiler: the ordinary compiler failed to build the math program' >&2; exit 1; }
cmp -s "$out/math-fold.static" "$out/math-fold.dynamic" || { echo 'static compiler: the math program differs from the ordinary compiler'"'"'s' >&2; exit 1; }
# JIT'd code reaches C through the library's symbol table only: the libm functions the optimiser rewrites into (pow(2, x) becomes exp2), compile-time
# `extern:"c"` calls (strtol, fmod, cbrt, toupper, strstr ...) and `ablac run` must work in the static compiler as in the dynamic one, whose
# glibc has them all. The same program is run through `ablac run`, built with the jit tier and built with the interpreter-free default, and each
# must print what the dynamic compiler's builds print.
mkdir -p "$out/jit-libcalls"
printf 'compileCapabilities = ["trusted.native"]\n' > "$out/jit-libcalls/abla.toml"
cat > "$out/jit-libcalls/main.ab" <<'AB'
import "abla/io"
import "abla/math"
import "abla/float/text"
import "abla/compiler"
#compilerGrant("trusted.native")
import "abla/unsafe/native"
import "abla/unsafe/memory/raw"
trusted noescape extern:"c" fun exp2(x: f64): f64
trusted noescape extern:"c" fun cbrt(x: f64): f64
trusted noescape extern:"c" fun fmod(x: f64, y: f64): f64
trusted noescape extern:"c" fun trunc(x: f64): f64
trusted noescape extern:"c" fun rint(x: f64): f64
trusted noescape extern:"c" fun fmaxf(x: f32, y: f32): f32
trusted noescape extern:"c" fun expm1(x: f64): f64
trusted noescape extern:"c" fun strtol(text: cstring, end: i64*, base: i32): i64
trusted noescape extern:"c" fun toupper(c: i32): i32
trusted noescape extern:"c" fun atof(text: cstring): f64

trusted fun viaC(x: f64): string =
    "${f64Text(exp2(x))} ${f64Text(cbrt(x))} ${f64Text(fmod(x, 3.0))} ${f64Text(trunc(x))} ${f64Text(rint(x))} " +
    "${f64Text(expm1(x / 1000.0))} ${strtol("-0x2a", nativeNullPointer(), 0)} ${toupper(97)} ${f64Text(atof("2.5e3"))}"

// Abla's own pow with a power-of-two base: LLVM turns it into exp2 once the exponent is not constant.
fun powers(n: int): string = "${f64Text(pow(2.0, f64FromInt(n)))} ${f64Text(pow(10.0, f64FromInt(n)))} ${f64Text(pow(f64FromInt(n), 0.5))}"

val folded = #viaC(10.0)

fun main: int {
    println(folded)
    println(viaC(10.0))
    println(powers(7))
    return 0
}
AB
expected=$("$compiler" run "$out/jit-libcalls/main.ab" 2>&1) || { echo "static compiler: the ordinary compiler could not run the libcalls program: $expected" >&2; exit 1; }
actual=$("$out/ablac-static" run "$out/jit-libcalls/main.ab" 2>&1) || { echo "static compiler: ablac run of the libcalls program failed: $actual" >&2; exit 1; }
[[ $actual == "$expected" ]] || { echo "static compiler: ablac run of the libcalls program printed [$actual], the ordinary compiler [$expected]" >&2; exit 1; }
for tier in jit auto; do
    ABLA_COMPILE_EVAL=$tier "$out/ablac-static" build "$out/jit-libcalls/main.ab" -o "$out/jit-libcalls/static-$tier" --no-cache > "$out/jit-libcalls/static-$tier.log" 2>&1 ||
        { echo "static compiler: the $tier tier failed on the libcalls program" >&2; tail -5 "$out/jit-libcalls/static-$tier.log" >&2; exit 1; }
    [[ $("$out/jit-libcalls/static-$tier") == "$expected" ]] || { echo "static compiler: the $tier tier's libcalls program printed other than the ordinary compiler's" >&2; exit 1; }
done
# LLVM prints floating-point constants through snprintf (%e and friends): the IR text of a float-heavy module is the same from both compilers.
cat > "$out/float-text.ab" <<'AB'
import "abla/io"
import "abla/float/text"

fun main: int {
    val a = 0.1 + 0.2
    val b = 1.0e-7 * 3.0
    val c = 123456789.125
    val d = 5.0e-324 + 1.7976931348623157e308
    val e = 2.0 / 3.0
    val f = 1.0e22 + 1.0e23
    val g = 0.000123456789
    println("${f64Text(a)} ${f64Text(b)} ${f64Text(c)} ${f64Text(d)} ${f64Text(e)} ${f64Text(f)} ${f64Text(g)}")
    return 0
}
AB
for program in "$out/float-text.ab" "$out/math-fold.ab" tests/cases/libc-imports/float-remainder.ab; do
    name=$(basename -- "$program" .ab)
    ABLA_SYSROOT="$root" "$out/ablac-static" --emit-llvm "$program" > "$out/$name.static.ll" 2> "$out/$name.static.ll.err" ||
        { echo "static compiler: --emit-llvm failed on $name" >&2; tail -3 "$out/$name.static.ll.err" >&2; exit 1; }
    "$compiler" --emit-llvm "$program" > "$out/$name.dynamic.ll" 2> "$out/$name.dynamic.ll.err" ||
        { echo "static compiler: the ordinary compiler's --emit-llvm failed on $name" >&2; exit 1; }
    cmp -s "$out/$name.static.ll" "$out/$name.dynamic.ll" || { echo "static compiler: the LLVM text of $name differs from the ordinary compiler's" >&2; exit 1; }
done
# The table covers every symbol the guard lists.
for symbol in $(cat tools/compiler-libc-needs.txt); do
    grep -q "\"$symbol\"" src/static_libc_symbols.ab || { echo "static compiler: $symbol is not in src/static_libc_symbols.ab" >&2; exit 1; }
done
# Every other symbol the image exports for JIT'd code is in it too: the library's own exports and the compiler's bridge (the dynamic compiler
# exposes all of them through --export-dynamic; a JIT'd program that needs one the table lacks fails with "Symbols not found").
for symbol in $(grep -ho '@export("[^"]*")' src/static_libc/*.ab src/ct_*.ab | sed 's/@export("//; s/")//' | grep -Ev '^(abla_libc_|_Unwind_|a$)' | LC_ALL=C sort -u); do
    grep -q "\"$symbol\"" src/static_libc_symbols.ab || { echo "static compiler: exported $symbol is not in src/static_libc_symbols.ab" >&2; exit 1; }
done
# The aliased exports (abla_libc_NAME of src/static_libc/hosted.ab) are bound to NAME by the link and listed in the table.
for symbol in $(grep -ho '@export("abla_libc_[^"]*")' src/static_libc/hosted.ab | sed 's/@export("abla_libc_//; s/")//' | LC_ALL=C sort -u); do
    [[ $(grep -c "\"$symbol\"" src/static_libc_symbols.ab) -ge 2 ]] ||
        { echo "static compiler: $symbol must be in the table and in bootstrapStaticLibcAliases (src/static_libc_symbols.ab)" >&2; exit 1; }
done
echo "static compiler: static-pie, no needed library, $count programs byte-identical to the ordinary compiler's, ablac run and the three compile-time tiers work"
