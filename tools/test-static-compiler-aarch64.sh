#!/usr/bin/env bash
# #806 step C, the second target: the statically linked compiler for AArch64 Linux (src/orc_main_static.ab cross-built with --target aarch64-linux on the
# AArch64 LLVM archives and the target's libstdc++.a/libz.a/libgcc.a) is a static-pie image with no needed library, and run under qemu-aarch64 it builds
# each program of tests/cases/libc-imports for aarch64-linux, programs that behave as the ordinary (x86-64) compiler's cross builds of them do. Needs
# ABLA_STATIC_LLVM_LIB (a directory with the AArch64 libLLVM*.a), ABLA_STATIC_TARGET_LIBS (a directory with libstdc++.a, libz.a and libgcc.a of AArch64) and
# qemu-aarch64; without them it says so and passes (nix/aarch64-static-native-deps.nix: nixpkgs' native aarch64-linux llvmPackages_23.libllvm.lib, zlib.static, the native gcc).
# Usage: tools/test-static-compiler-aarch64.sh [compiler]
set -euo pipefail
export LC_ALL=C
ulimit -c 0
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
source "$root/tools/aarch64-test-runner.sh"
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
# (with ABLA_STATIC_LLD_LIB, ABLA_STATIC_LLD_INCLUDE, ABLA_STATIC_LLVM_INCLUDE, ABLA_STATIC_CXX and ABLA_STATIC_CXXFLAGS the build script carries the real shim: #1124)
ABLA_STATIC_TARGET=aarch64-linux tools/build-static-compiler.sh "$compiler" "$out/ablac-static" > "$out/build.log" 2>&1 ||
    { echo 'static compiler aarch64: the build failed' >&2; grep -v 'warning' "$out/build.log" | tail -8 >&2; exit 1; }
file -b "$out/ablac-static" | grep 'ARM aarch64.*static-pie linked' > /dev/null || { echo 'static compiler aarch64: not an AArch64 static-pie image' >&2; exit 1; }
needed=$(readelf -d "$out/ablac-static" | grep -c '(NEEDED)' || true)
[[ $needed == 0 ]] || { echo "static compiler aarch64: $needed needed libraries" >&2; exit 1; }
# End to end: with STATIC_AARCH64_MODULES=1 the AArch64 half of the module-program check (tests/cases/modules built --fast for aarch64-linux link no
# C library, tools/test-libc-free-programs.sh) has this compiler, under qemu, as its builder; no x86-64 compiler builds a program. About nine minutes on
# eight cores, 24 on a four-CPU CI runner: STATIC_AARCH64_PART=1, 2 or 3 builds one third of the programs (CI runs the parts on three runners), and
# parts 2 and 3 skip the checks below, which part 1 (and a run without a part) makes. ABLA_STATIC_LLVM_LIB is left out of that run so the programs
# that import LLVM stay the exceptions the allowlist names.
part=${STATIC_AARCH64_PART:-0}
[[ $part == [0-3] ]] || { echo "static compiler aarch64: STATIC_AARCH64_PART must be 1, 2 or 3, got $part" >&2; exit 2; }
check_modules() {
    [[ ${STATIC_AARCH64_MODULES:-0} == 1 ]] || return 0
    local part_options=()
    ((part == 0)) || part_options=(--part "$part/3")
    env -u ABLA_STATIC_LLVM_LIB LIBC_FREE_TARGETS=a64 LIBC_FREE_RUNNER=qemu-aarch64 ABLA_TEST_JOBS=${ABLA_TEST_JOBS:-4} \
        tools/test-libc-free-programs.sh "$PWD/$out/ablac-static" "${part_options[@]}"
}
if ((part > 1)); then
    echo "static compiler aarch64: static-pie, no needed library (part $part/3: the other checks are part 1's)"
    check_modules
    exit
fi
export ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1
# Under qemu-user a compiler cannot start itself as a child (/proc/self/exe is the emulator's, status 127), which the in-process code generation does for its parts of a
# big program (src/codegen_units.ab, the --emit-object child): these builds make their objects with the external llc as before, and the empty-PATH check below, a program
# small enough to be built in the compiler's own process, is the shim's. (Natively, on a Raspberry Pi, the children work: ab-rpi1.)
[[ -z ${ABLA_STATIC_LLD_LIB:-} ]] || export ABLA_CODEGEN_INPROCESS=0
count=0
# Run natively (here under qemu) the compiler builds for the machine it runs on: no --target is the same as --target aarch64-linux (#806 step C). That
# is its in-process code generation, not the external opt/llc the x86-64 compiler's cross build uses, so the executables are not byte-identical to the
# cross build's; what must agree is what the programs do, run in a directory of their own: output and exit status.
run_program() { # executable directory output
    mkdir -p "$2"
    (cd "$2" && aarch64_run -- "$OLDPWD/$1" > "$OLDPWD/$3" 2>&1 < /dev/null; echo "exit $?" >> "$OLDPWD/$3") || true
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
# With the shim (#1124): the compiler needs no tools of its own PATH for an AArch64 build, the way a Raspberry Pi without LLVM installed uses it: an empty PATH,
# release and --fast, programs that print what the ordinary compiler's builds do.
if [[ -n ${ABLA_STATIC_LLD_LIB:-} ]]; then
    mkdir -p "$out/empty"
    for mode in release fast; do
        flags=()
        [[ $mode == fast ]] && flags=(--fast)
        env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_SYSROOT="$ABLA_SYSROOT" ABLA_MAX_MEMORY_MB="$ABLA_MAX_MEMORY_MB" ABLA_CACHE_DIR="$PWD/$out/empty-$mode.cache" \
            "$(command -v qemu-aarch64)" "$out/ablac-static" build tests/cases/libc-imports/hello.ab -o "$out/empty-$mode" --no-cache "${flags[@]}" > "$out/empty-$mode.log" 2>&1 ||
            { echo "static compiler aarch64: hello ($mode) did not build on an empty PATH" >&2; grep -v 'warning' "$out/empty-$mode.log" | tail -5 >&2; exit 1; }
        [[ $(qemu-aarch64 "$out/empty-$mode") == hello ]] || { echo "static compiler aarch64: the $mode hello built on an empty PATH did not print hello" >&2; exit 1; }
    done
    echo 'static compiler aarch64: hello builds (release and --fast) on an empty PATH'
    # The compiler's own link generates an assembly file (the libc data and trampolines, src/toolchain.ab) and assembles it with LLVM MC in the shim, so a
    # self-build needs no clang or `as` (a whole self-build is too long under qemu; ab-rpi1 builds it natively). Here: `--llvm-tool llvm-mc` on an empty PATH makes
    # an AArch64 relocatable object whose defined symbols are the file's, and a bad file fails with a message.
    cat > "$out/mc.s" <<'ASM'
.data
.p2align 3
.globl environ
.type environ,%object
.size environ,8
environ:
.quad 0
.text
.p2align 2
.globl abla_mc_probe
.type abla_mc_probe,%function
abla_mc_probe:
	b environ_jump
environ_jump:
	ret
ASM
    env -i PATH="$PWD/$out/empty" "$(command -v qemu-aarch64)" "$out/ablac-static" --llvm-tool llvm-mc -triple=aarch64-unknown-linux-gnu -filetype=obj "$out/mc.s" -o "$out/mc.o" ||
        { echo "static compiler aarch64: llvm-mc failed on an empty PATH" >&2; exit 1; }
    symbols=$(readelf -sW "$out/mc.o") || { echo "static compiler aarch64: llvm-mc's object does not read" >&2; exit 1; }
    [[ $(readelf -hW "$out/mc.o") == *"Machine:"*"AArch64"* && $symbols == *" environ"* && $symbols == *" abla_mc_probe"* ]] ||
        { echo "static compiler aarch64: llvm-mc's object is not the AArch64 object of the file: $symbols" >&2; exit 1; }
    printf '.text\n\tnot_an_instruction x0\n' > "$out/mc-bad.s"
    if env -i PATH="$PWD/$out/empty" "$(command -v qemu-aarch64)" "$out/ablac-static" --llvm-tool llvm-mc -triple=aarch64-unknown-linux-gnu -filetype=obj "$out/mc-bad.s" -o "$out/mc-bad.o" > "$out/mc-bad.log" 2>&1; then
        echo "static compiler aarch64: llvm-mc accepted a file with a bad instruction" >&2; exit 1
    fi
    grep -q 'instruction' "$out/mc-bad.log" || { echo "static compiler aarch64: llvm-mc's error names no instruction: $(cat "$out/mc-bad.log")" >&2; exit 1; }
    echo 'static compiler aarch64: llvm-mc assembles the generated data file on an empty PATH'
fi
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
    [[ $(aarch64_run -- "$out/compile-time-$tier") == 'answer 6765' ]] || { echo "static compiler aarch64: the $tier tier answered wrong" >&2; exit 1; }
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
echo "static compiler aarch64: static-pie, no needed library, the default target is AArch64, $count program outputs match the ordinary compiler's cross builds, ablac run and the three compile-time tiers work (jit runs the site as native code), hello runs"
check_modules
