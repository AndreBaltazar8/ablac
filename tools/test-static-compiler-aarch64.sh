#!/usr/bin/env bash
# #806 step C, the second target: the statically linked compiler for AArch64 Linux (src/orc_main_static.ab cross-built with --target aarch64-linux on the
# AArch64 LLVM archives and the target's libstdc++.a/libz.a/libgcc.a) is a static-pie image with no needed library, and run under qemu-aarch64 it builds
# each program of tests/cases/libc-imports for aarch64-linux, programs that behave as the ordinary (x86-64) compiler's cross builds of them do. Needs
# ABLA_STATIC_LLVM_LIB (a directory with the AArch64 libLLVM*.a), ABLA_STATIC_TARGET_LIBS (a directory with libstdc++.a, libz.a and libgcc.a of AArch64) and
# qemu-aarch64; without them it says so and passes (docs/toolchain.md: pkgsCross.aarch64-multiplatform's llvmPackages_23.libllvm.lib, zlib.static, the cross gcc).
# Usage: tools/test-static-compiler-aarch64.sh [compiler]
set -euo pipefail
export LC_ALL=C
ulimit -c 0
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'static compiler aarch64: x86-64 Linux only'; exit 0; }
if [[ -z ${ABLA_STATIC_LLVM_LIB:-} || ! -f ${ABLA_STATIC_LLVM_LIB}/libLLVMSupport.a || -z ${ABLA_STATIC_TARGET_LIBS:-} ||
    ! -f ${ABLA_STATIC_TARGET_LIBS}/libstdc++.a ]] || ! command -v qemu-aarch64 > /dev/null; then
    echo 'static compiler aarch64: skipped (needs ABLA_STATIC_LLVM_LIB and ABLA_STATIC_TARGET_LIBS for AArch64, and qemu-aarch64)'
    exit 0
fi
export ABLA_STATIC_LLVM_LIB ABLA_STATIC_TARGET_LIBS
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
# The launcher's default cap is 2048 MB; the frontend on the compiler's own source needs about 1.8 GB resident and the static link more (CI run 44878467709 died with
# "out of memory"; tools/build-static-compiler.sh has the same default). The compilers run under qemu below read it too.
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-8192}
out=build/static-compiler-aarch64
rm -rf "$out"
mkdir -p "$out"
"$compiler" build src/orc_main_static.ab --target aarch64-linux -o "$out/ablac-static" --no-cache > "$out/build.log" 2>&1 ||
    { echo 'static compiler aarch64: the build failed' >&2; grep -v 'warning' "$out/build.log" | tail -8 >&2; exit 1; }
file -b "$out/ablac-static" | grep 'ARM aarch64.*static-pie linked' > /dev/null || { echo 'static compiler aarch64: not an AArch64 static-pie image' >&2; exit 1; }
needed=$(readelf -d "$out/ablac-static" | grep -c '(NEEDED)' || true)
[[ $needed == 0 ]] || { echo "static compiler aarch64: $needed needed libraries" >&2; exit 1; }
export ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1
count=0
# Run natively (here under qemu) the compiler builds for the machine it runs on: no --target is the same as --target aarch64-linux (#806 step C). That
# is its in-process code generation, not the external opt/llc the x86-64 compiler's cross build uses, so the executables are not byte-identical to the
# cross build's; what must agree is what the programs do, run under qemu-aarch64 in a directory of their own: output and exit status.
run_program() { # executable directory output
    mkdir -p "$2"
    (cd "$2" && qemu-aarch64 "$OLDPWD/$1" > "$OLDPWD/$3" 2>&1 < /dev/null; echo "exit $?" >> "$OLDPWD/$3") || true
}
for source in tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab \
    tests/cases/libc-imports/float-remainder.ab tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab \
    tests/cases/libc-imports/jwt-verify.ab; do
    name=$(basename -- "$source" .ab)
    qemu-aarch64 "$out/ablac-static" build "$source" -o "$out/$name.static" --no-cache > "$out/$name.static.log" 2>&1 ||
        { echo "static compiler aarch64: it failed to build $name" >&2; grep -v 'warning' "$out/$name.static.log" | tail -5 >&2; exit 1; }
    qemu-aarch64 "$out/ablac-static" build "$source" --target aarch64-linux -o "$out/$name.explicit" --no-cache > "$out/$name.explicit.log" 2>&1 ||
        { echo "static compiler aarch64: it failed to build $name with --target aarch64-linux" >&2; exit 1; }
    cmp -s "$out/$name.static" "$out/$name.explicit" || { echo "static compiler aarch64: $name without --target is not the AArch64 build" >&2; exit 1; }
    "$compiler" build "$source" --target aarch64-linux -o "$out/$name.cross" --no-cache > "$out/$name.cross.log" 2>&1 ||
        { echo "static compiler aarch64: the ordinary compiler failed to build $name" >&2; exit 1; }
    run_program "$out/$name.static" "$out/run-static-$name" "$out/$name.static.out"
    run_program "$out/$name.cross" "$out/run-cross-$name" "$out/$name.cross.out"
    cmp -s "$out/$name.static.out" "$out/$name.cross.out" || {
        echo "static compiler aarch64: $name built by it behaves differently from the ordinary compiler's cross build" >&2
        diff "$out/$name.static.out" "$out/$name.cross.out" | head -5 >&2; exit 1; }
    count=$((count + 1))
done
# The JIT: `ablac run` and the compile-time jit tier find the process's symbols through the library's dlsym table (src/static_libc/dl.ab), here with
# LLVM's AArch64 JIT running under qemu-aarch64; and the three compile-time evaluation tiers agree.
run=$(qemu-aarch64 "$out/ablac-static" run tests/cases/libc-imports/hello.ab 2>&1) || { echo "static compiler aarch64: ablac run failed: $run" >&2; exit 1; }
[[ $run == hello ]] || { echo "static compiler aarch64: ablac run printed [$run]" >&2; exit 1; }
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
    ABLA_COMPILE_EVAL_TIMES=1 ABLA_COMPILE_EVAL=$tier qemu-aarch64 "$out/ablac-static" build "$out/compile-time.ab" -o "$out/compile-time-$tier" --no-cache > "$out/compile-time-$tier.log" 2>&1 ||
        { echo "static compiler aarch64: the $tier tier failed" >&2; grep -v 'warning' "$out/compile-time-$tier.log" | tail -5 >&2; exit 1; }
    [[ $(qemu-aarch64 "$out/compile-time-$tier") == 'answer 6765' ]] || { echo "static compiler aarch64: the $tier tier answered wrong" >&2; exit 1; }
    # Which tier ran the `#` site is in the times the compiler reports (ABLA_COMPILE_EVAL_TIMES=1): jit must have run it as native AArch64 code (the
    # JIT generated and ran it in the process, not the evaluator), interp must have used the evaluator.
    case $tier in
        jit) grep -qE '^ +[0-9.]+ s  native  .*#fib\(20\)' "$out/compile-time-$tier.log" ||
            { echo 'static compiler aarch64: the jit tier did not run the site natively' >&2; grep 'compile-time evaluation' -A3 "$out/compile-time-$tier.log" >&2; exit 1; } ;;
        interp) grep -qE '^ +[0-9.]+ s  evaluator  .*#fib\(20\)' "$out/compile-time-$tier.log" ||
            { echo 'static compiler aarch64: the interp tier did not use the evaluator' >&2; exit 1; } ;;
    esac
done
[[ $(head -n 1 "$out/hello.static.out") == hello ]] || { echo 'static compiler aarch64: the hello it built did not print hello' >&2; exit 1; }
echo "static compiler aarch64: static-pie, no needed library, the default target is AArch64, $count programs it builds behave as the ordinary compiler's cross builds under qemu, ablac run and the three compile-time tiers work (jit runs the site as native code), hello runs"
# End to end: with STATIC_AARCH64_MODULES=1 the AArch64 half of the module-program check (tests/cases/modules built --fast for aarch64-linux link no
# C library, tools/test-libc-free-programs.sh) has this compiler, under qemu, as its builder; no x86-64 compiler builds a program. About nine minutes on
# eight cores. ABLA_STATIC_LLVM_LIB is left out of that run so the programs that import LLVM stay the exceptions the allowlist names.
if [[ ${STATIC_AARCH64_MODULES:-0} == 1 ]]; then
    env -u ABLA_STATIC_LLVM_LIB LIBC_FREE_TARGETS=a64 LIBC_FREE_RUNNER=qemu-aarch64 ABLA_TEST_JOBS=${ABLA_TEST_JOBS:-4} \
        tools/test-libc-free-programs.sh "$PWD/$out/ablac-static"
fi
