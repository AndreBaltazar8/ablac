#!/usr/bin/env bash
# abla/simd: every operation on every vector type against values worked out without the
# compiler (tests/cases/simd/checks.ab), and the target-specific operations against FIPS-197.
#   run:      x86-64 (release and --fast, on this CPU and under qemu with no AES, CLMUL or
#             AVX2), AArch64 under qemu, Wasm under Node.
#   compiled: Xtensa, whose object is checked for the scalar code it should be.
# Then the misuses the compiler refuses, each with the error on its first line.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=tests/cases/simd
out=build/simd
cd "$project_root"
rm -rf "$out"
mkdir -p "$out"

for mode in "" --fast; do
    "$compiler" build "$cases/native.ab" -o "$out/native" --no-cache $mode
    "$out/native" || { echo "simd native ${mode:-release}: check $? failed" >&2; exit 1; }
done
echo "ok   x86-64: release and --fast, cpu has aes/clmul/avx2 where /proc/cpuinfo says"
llvm-objdump -d "$out/native" > "$out/native.s"
grep -q aesenc "$out/native.s" || { echo "no aesenc in the program" >&2; exit 1; }
if command -v qemu-x86_64 >/dev/null; then
    qemu-x86_64 -cpu qemu64 "$out/native" || { echo "simd under qemu64 (no AES): check $? failed" >&2; exit 1; }
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
echo "ok   wasm under node $(node --version): SIMD128 instructions, no AES"

# AArch64: no executable target exists, so an object, a start of its own, and qemu.
if command -v qemu-aarch64 >/dev/null; then
    "$compiler" build "$cases/aarch64-build.ab" -o "$out/aarch64-driver" --no-cache
    llvm-mc -triple aarch64-linux-gnu -filetype=obj "$cases/aarch64-start.s" -o "$out/aarch64-start.o"
    ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
    llvm-objdump -d "$out/aarch64" > "$out/aarch64.s"
    grep -q 'aese' "$out/aarch64.s" || { echo "no AESE in the AArch64 program" >&2; exit 1; }
    grep -q 'pmull' "$out/aarch64.s" || { echo "no PMULL in the AArch64 program" >&2; exit 1; }
    for cpu in max cortex-a57; do
        qemu-aarch64 -cpu "$cpu" "$out/aarch64" || { echo "simd aarch64 $cpu: check $? failed" >&2; exit 1; }
    done
    echo "ok   aarch64 under qemu (max, cortex-a57), with AES and PMULL taken"
else
    echo "skip aarch64: no qemu-aarch64"
fi

# Xtensa is compiled only: nothing here runs it, as in tools/test-f32.sh.
tools_directory="$out/xtensa-tools"
mkdir -p "$tools_directory"
real_llc=$(command -v llc)
cat > "$tools_directory/llc" <<EOF
#!/usr/bin/env bash
arguments=()
for argument in "\$@"; do
    [[ \$argument == -relocation-model=pic ]] && argument=-relocation-model=static
    arguments+=("\$argument")
done
exec "$real_llc" -mcpu=esp32 "\${arguments[@]}"
EOF
chmod +x "$tools_directory/llc"
PATH="$tools_directory:$PATH" "$compiler" build "$cases/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
grep -q 'Machine: EM_XTENSA' <<<"$(llvm-readobj --file-headers "$out/xtensa.o")"
echo "ok   xtensa: compiled only, not run; every vector operation is scalar code there"

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
