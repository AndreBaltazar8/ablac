#!/usr/bin/env bash
# abla/simd: every operation on every vector type against values worked out without the
# compiler (tests/cases/simd/checks.ab), and the target-specific operations against FIPS-197.
#   run:      x86-64 (release and --fast, on this CPU and under qemu with no AES, CLMUL or
#             AVX2), AArch64, Wasm under Node.
#   compiled: Xtensa, whose vectors are scalar code; nothing here runs it.
# Then the misuses the compiler refuses, each with the error on its first line.
# With --avx512-only after the compiler argument, run the native AVX-512 checks
# when both CPU features are usable and record the result for GitHub Actions.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=tests/cases/simd
cd "$project_root"

if [[ ${2:-} == --avx512-only ]]; then
    mkdir -p build
    out=$(mktemp -d build/simd-avx512.XXXXXX)
    trap 'rm -rf -- "$out"' EXIT
    ABLA_TEST_FAST_BUILDS=0 "$compiler" build "$cases/native.ab" -o "$out/native" --no-cache
    status=0
    "$out/native" --require-avx512 || status=$?
    case $status in
        0) summary='AVX-512: passed the native AVX-512F and AVX-512BW checks.' ;;
        216) summary='AVX-512: skipped because the runner lacks usable AVX-512F or AVX-512BW.' ;;
        *) summary="AVX-512: native validation failed with status $status." ;;
    esac
    printf '%s\n' "$summary"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"; fi
    if [[ $status == 216 ]]; then exit 0; fi
    exit "$status"
fi

out=build/simd
rm -rf "$out"
mkdir -p "$out"

for mode in "" --fast; do
    ABLA_TEST_FAST_BUILDS=0 "$compiler" build "$cases/native.ab" -o "$out/native" --no-cache $mode
    "$out/native" || { echo "simd native ${mode:-release}: check $? failed" >&2; exit 1; }
    if [[ -z $mode ]]; then cp "$out/native" "$out/native-release"; fi
done
echo "ok   x86-64: release and --fast, cpu has aes/clmul/avx2 where /proc/cpuinfo says"
llvm-objdump -d "$out/native" > "$out/native.s"
llvm-objdump -d "$out/native-release" > "$out/native-release.s"
grep -q aesenc "$out/native.s" || { echo "no aesenc in the program" >&2; exit 1; }
grep -q 'pshufb' "$out/native.s" || { echo "no SSSE3 byte shuffle in the program" >&2; exit 1; }
grep -qE 'roundps|roundpd' "$out/native.s" || { echo "no SSE4.1 lane rounding in the program" >&2; exit 1; }
grep -q 'vpgatherqq' "$out/native.s" || { echo "no AVX2 array gather in the program" >&2; exit 1; }
grep -qE 'vpaddd.*%zmm' "$out/native-release.s" || { echo "no AVX-512F word addition" >&2; exit 1; }
grep -qE 'vpaddb.*%zmm' "$out/native-release.s" || { echo "no AVX-512BW byte addition" >&2; exit 1; }
if [[ -n ${ABLA_SIMD_SDE:-} ]]; then
    "$ABLA_SIMD_SDE" -skx -- "$out/native-release" --require-avx512
    echo "ok   AVX-512F/BW under Intel SDE"
fi
"$compiler" build "$cases/gather-bounds.ab" -o "$out/gather-bounds" --no-cache
check_gather_bounds() {
    for index in 2 -1; do
        local args=("$@") status=0
        [[ $index == 2 ]] || args+=(negative)
        "${args[@]}" > "$out/gather-bounds.out" 2> "$out/gather-bounds.err" || status=$?
        if [[ $status != 101 ]] ||
            ! grep -qFx "panic: index $index out of bounds for array of size 2" "$out/gather-bounds.err"; then
            cat "$out/gather-bounds.err" >&2
            printf 'SIMD gather: wrong out-of-bounds result for %s (status %s)\n' "$index" "$status" >&2
            return 1
        fi
    done
}
check_gather_bounds "$out/gather-bounds"
if command -v qemu-x86_64 >/dev/null; then
    qemu-x86_64 -cpu qemu64 "$out/native" || { echo "simd under qemu64 (no AES): check $? failed" >&2; exit 1; }
    check_gather_bounds qemu-x86_64 -cpu qemu64 "$out/gather-bounds"
    echo "ok   x86-64 under qemu64: no AES, CLMUL or AVX2, the paths behind cpuHas not taken"
fi
"$compiler" build "$cases/positive-language.ab" -o "$out/language" --no-cache
"$out/language" || { echo "simd language: check $? failed" >&2; exit 1; }
"$compiler" build "$cases/positive-language.ab" -o "$out/language-debug" --no-cache --fast -g
"$out/language-debug" || { echo "simd language -g: check $? failed" >&2; exit 1; }
echo "ok   language: fields, arrays, maps, nullable, defaults, globals, closures, -g"

# Wasm: SIMD128 runs, and its instructions are in the module.
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" --no-cache 2> "$out/wasm.log" || { cat "$out/wasm.log" >&2; exit 1; }
"$out/wasm-driver"
node "$cases/run.mjs" "$out/simd.wasm"
wasm-dis "$out/simd.wasm" > "$out/simd.wat" 2>/dev/null
grep -q 'i32x4\.add' "$out/simd.wat" || { echo "no SIMD128 instructions in the module" >&2; exit 1; }
grep -q 'i8x16\.swizzle' "$out/simd.wat" || { echo "no Wasm SIMD swizzle in the module" >&2; exit 1; }
grep -q 'f32x4\.nearest' "$out/simd.wat" || { echo "no Wasm SIMD rounding in the module" >&2; exit 1; }
echo "ok   wasm under node $(node --version): SIMD128 instructions, no AES"

# AArch64: build the same program as an ordinary static Linux executable.
source "$project_root/tools/aarch64-test-runner.sh"
if aarch64_runner_available; then
    "$compiler" build "$cases/native.ab" --target aarch64-linux -o "$out/aarch64" --no-cache
    "$compiler" build "$cases/gather-bounds.ab" --target aarch64-linux -o "$out/aarch64-gather-bounds" --no-cache
    llvm-objdump -d "$out/aarch64" > "$out/aarch64.s"
    grep -q 'aese' "$out/aarch64.s" || { echo "no AESE in the AArch64 program" >&2; exit 1; }
    grep -q 'pmull' "$out/aarch64.s" || { echo "no PMULL in the AArch64 program" >&2; exit 1; }
    grep -qE '[[:space:]]tbl[[:space:]]' "$out/aarch64.s" || { echo "no NEON table lookup in the program" >&2; exit 1; }
    grep -q 'frintn' "$out/aarch64.s" || { echo "no NEON ties-to-even rounding in the program" >&2; exit 1; }
    cpus=(max)
    # With the default emulator, keep the second QEMU CPU profile too.
    if [[ -z ${ABLA_AARCH64_RUN:-} ]]; then cpus+=(cortex-a57); fi
    for cpu in "${cpus[@]}"; do
        aarch64_run --cpu "$cpu" -- "$out/aarch64" || { echo "simd aarch64: check $? failed" >&2; exit 1; }
        check_gather_bounds aarch64_run --cpu "$cpu" -- "$out/aarch64-gather-bounds"
    done
    echo "ok   aarch64-linux: NEON, with AES and PMULL where available"
else
    echo "skip aarch64: no AArch64 runner"
fi

# Xtensa is compiled only: nothing here runs it, as in tools/test-f32.sh.
tools_directory="$out/xtensa-tools"
. "$project_root/tools/xtensa-test-tools.sh"
abla_xtensa_test_prepare "$tools_directory"
abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
grep -q 'Machine: EM_XTENSA' <<<"$(llvm-readobj --file-headers "$out/xtensa.o")"
echo "ok   xtensa: compiled only, not run; every vector operation is scalar code there"

for mode in "" --fast; do
    "$compiler" build "$cases/if-join.ab" -o "$out/if-join" --no-cache $mode
    "$out/if-join" || { echo "simd if join ${mode:-release}: check $? failed" >&2; exit 1; }
done
# Only the boxed entry of a function, for a call through a value, boxes its result.
if "$compiler" --emit-llvm "$cases/if-join.ab" |
    awk '/^define/ { direct = /_direct\(/ } direct && /call.*@abla_vector_box/ { found = 1 } END { exit !found }'; then
    echo "a vector's if join boxes its branches" >&2
    exit 1
fi

for tier in interp jit auto; do
    ABLA_COMPILE_EVAL="$tier" ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$cases/compile-time.ab" \
        -o "$out/compile-time-$tier" --no-cache --fast > "$out/compile-time-$tier.log" 2>&1 || {
        cat "$out/compile-time-$tier.log" >&2
        exit 1
    }
    "$out/compile-time-$tier" || { echo "simd compile-time $tier: check $? failed" >&2; exit 1; }
done
native_sites=$(awk '/^note\[ct-jit\]: native at .*compile-time\.ab:/ { count++ } END { print count+0 }' \
    "$out/compile-time-jit.log")
[[ $native_sites == 4 ]] || { cat "$out/compile-time-jit.log" >&2; exit 1; }
echo "ok   compile-time vectors: interp, jit and auto"

for invalid in "$cases"/invalid-*.ab; do
    expected=$(sed -n '1s|^// *||p' "$invalid")
    set +e
    "$compiler" build "$invalid" -o "$out/invalid" --no-cache --fast > "$out/invalid.out" 2>&1
    status=$?
    set -e
    if [[ $status -eq 0 ]] || ! grep -qF "$expected" "$out/invalid.out"; then
        echo "$(basename "$invalid"): expected an error with: $expected" >&2
        cat "$out/invalid.out" >&2
        exit 1
    fi
done
echo "ok   refusals: $(ls "$cases"/invalid-*.ab | wc -l)"
echo "simd: all targets above agree with the reference values"
