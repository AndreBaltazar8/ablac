#!/usr/bin/env bash
# abla/uint256 against Python's integers (tools/uint256/gen-cases.py), on each target ablac has:
#   run:      x86-64 (release and --fast, on a fresh random seed each run), Wasm under Node, AArch64,
#             RISC-V 64 and 32 (no M extension) and Xtensa under qemu, with a start of their own and no
#             C library (tests/cases/uint256/start.c).
#   Xtensa is run only where the ESP toolchain is, as lld can't link it; elsewhere it's compiled.
# Then what the compiler refuses, what a division by zero does, and that a program not using it has
# none of it in it.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=tests/cases/uint256
out=build/uint256
cd "$project_root"
rm -rf "$out"
mkdir -p "$out/src"
cp "$cases"/checks.ab "$cases"/object.ab "$cases"/wasm.ab "$out/src/"
python3 tools/uint256/gen-cases.py 1 3000 --abla > "$out/src/cases.ab"

seed=${UINT256_SEED:-$(python3 -c 'import random; print(random.getrandbits(48))')}
python3 tools/uint256/gen-cases.py "$seed" 60000 > "$out/random.txt"
for mode in "--fast -g" --fast ""; do
    "$compiler" build "$cases/file.ab" -o "$out/file" --no-cache $mode
    "$out/file" "$out/random.txt" || { echo "uint256 ${mode:-release}: seed $seed: see that line of $out/random.txt" >&2; exit 1; }
done
"$compiler" run "$cases/file.ab" -- "$out/random.txt" || { echo "uint256 ablac run: seed $seed: see that line of $out/random.txt" >&2; exit 1; }
echo "ok   x86-64: release, --fast, -g and ablac run, $(wc -l < "$out/random.txt") cases, seed $seed"

# The checks can fail: one wrong answer in those cases is found.
sed '20000s/[^ ]*$/bad/' "$out/random.txt" > "$out/wrong.txt"
[[ $("$out/file" "$out/wrong.txt") == "line 20000" ]] || { echo "a wrong answer wasn't noticed" >&2; exit 1; }

# Wasm has nothing to import for it: a wide `mul` calls the module's own __multi3.
"$compiler" build "$cases/build-wasm.ab" -o "$out/wasm-driver" --no-cache 2> "$out/wasm.log" || { cat "$out/wasm.log" >&2; exit 1; }
"$out/wasm-driver"
node "$cases/run.mjs" "$out/uint256.wasm"
echo "ok   wasm under node $(node --version): imports nothing of C's"

"$compiler" build "$cases/build-objects.ab" -o "$out/objects-driver" --no-cache
start() { # triple, flags, name
    NIX_HARDENING_ENABLE= clang --target="$1" $2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -O1 \
        -c "$cases/start.c" -o "$out/start-$3.o" 2>/dev/null
    ld.lld -static --no-pie -z notext "$out/$3.o" "$out/start-$3.o" -o "$out/$3"
}
if command -v qemu-aarch64 > /dev/null; then
    start aarch64-linux-gnu "" aarch64
    qemu-aarch64 "$out/aarch64" || { echo "uint256 aarch64: failed with $?" >&2; exit 1; }
    echo "ok   aarch64 under qemu"
else
    echo "skip aarch64: no qemu-aarch64"
fi
if command -v qemu-riscv64 > /dev/null; then
    start riscv64-linux-gnu "-march=rv64i -mabi=lp64" riscv64
    qemu-riscv64 "$out/riscv64" || { echo "uint256 riscv64: failed with $?" >&2; exit 1; }
    echo "ok   riscv64 under qemu"
else
    echo "skip riscv64: no qemu-riscv64"
fi
"$compiler" build "$out/src/object.ab" -o "$out/riscv32.o" --no-cache \
    --target-triple riscv32-unknown-elf --object-format elf --emit object
if command -v qemu-riscv32 > /dev/null; then
    start riscv32-unknown-elf "-march=rv32i -mabi=ilp32" riscv32
    qemu-riscv32 "$out/riscv32" || { echo "uint256 riscv32: failed with $?" >&2; exit 1; }
    echo "ok   riscv32 under qemu"
else
    echo "skip riscv32: no qemu-riscv32"
fi

# Xtensa: the companion owns CPU/static selection. QEMU's CPU lacks mul32high,
# so request that feature mask explicitly rather than hiding it in a PATH shim.
ABLA_ESP_CPU=esp32 ABLA_XTENSA_FEATURES='' "$compiler" build "$out/src/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
grep -q 'Machine: EM_XTENSA' <<<"$(llvm-readobj --file-headers "$out/xtensa.o")"
esp_bin=$(ls -d "$HOME"/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin 2>/dev/null | tail -1 || true)
runner=()
command -v steam-run > /dev/null && runner=(steam-run)
if [[ -n $esp_bin ]] && command -v qemu-xtensa > /dev/null &&
    "${runner[@]}" "$esp_bin/xtensa-esp32-elf-gcc" -ffreestanding -fno-builtin -fno-stack-protector -O0 \
        -mtext-section-literals -mlongcalls -c "$cases/start.c" -o "$out/start-xtensa.o"; then
    ABLA_ESP_CPU=esp32 ABLA_XTENSA_FEATURES=-mul32high "$compiler" build "$out/src/object.ab" -o "$out/xtensa-run.o" --no-cache \
        --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
    "${runner[@]}" "$esp_bin/xtensa-esp32-elf-ld" -z noexecstack -static "$out/xtensa-run.o" "$out/start-xtensa.o" -o "$out/xtensa"
    qemu-xtensa -cpu dc232b "$out/xtensa" || { echo "uint256 xtensa: failed with $?" >&2; exit 1; }
    echo "ok   xtensa under qemu, without mul32high; with it, compiled"
else
    echo "ok   xtensa: compiled only, no ESP toolchain to link it here"
fi

# What it needs on each target besides what's in the object, arithmetic alone: nothing where the
# target multiplies, and on RISC-V without M only the helpers `*` calls anyway.
cat > "$out/src/arithmetic.ab" <<'EOF'
import "abla/uint256"
@export("arithmetic")
fun arithmetic(x: u32): int {
    val a = uint256Words(x, x, x, x, x, x, x, x)
    val b = a * a + (a << 3) - uint256(x)
    if ((b / a) * a + b % a != b) return 1
    if (a < b) 2 else 0
}
EOF
ABLA_ESP_CPU=esp32 ABLA_XTENSA_FEATURES='' "$compiler" build "$out/src/arithmetic.ab" -o "$out/arithmetic-xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
[[ -z $(llvm-nm -u "$out/arithmetic-xtensa.o") ]] || { echo "Xtensa arithmetic needs: $(llvm-nm -u "$out/arithmetic-xtensa.o")" >&2; exit 1; }
"$compiler" build "$out/src/arithmetic.ab" -o "$out/arithmetic-riscv32.o" --no-cache \
    --target-triple riscv32-unknown-elf --object-format elf --emit object
helpers=$(llvm-nm -u "$out/arithmetic-riscv32.o" | awk '{print $2}' | grep -vE '^__(mulsi3|muldi3|ashldi3|lshrdi3)$' || true)
[[ -z $helpers ]] || { echo "RISC-V arithmetic needs: $helpers" >&2; exit 1; }
echo "ok   arithmetic: nothing on Xtensa, on RISC-V only the helpers of \`*\` and a shift"

# By zero: the language's own panic.
for operator in / %; do
    cat > "$out/src/zero.ab" <<EOF
import "abla/uint256"
fun main: int = (uint256(1) $operator uint256(processArguments())).toInt()
fun processArguments(): int = 0
EOF
    "$compiler" build "$out/src/zero.ab" -o "$out/zero" --no-cache
    set +e
    "$out/zero" > "$out/zero.out" 2>&1
    status=$?
    set -e
    [[ $status -eq 101 ]] && grep -q 'division by zero' "$out/zero.out" || { echo "$operator by zero: status $status" >&2; cat "$out/zero.out" >&2; exit 1; }
done
echo "ok   by zero: panic, status 101"

for mode in "" --fast; do
    "$compiler" build "$cases/compile-time.ab" -o "$out/compile-time" --no-cache $mode
    "$out/compile-time" > "$out/compile-time.out" || { echo "uint256 under #, ${mode:-release}: check $? failed" >&2; tail -n 4 "$out/compile-time.out" >&2; exit 1; }
    "$compiler" build "$cases/nominal.ab" -o "$out/nominal" --no-cache $mode
    "$out/nominal" || { echo "uint256 nominal, ${mode:-release}: check $? failed" >&2; exit 1; }
done
echo "ok   under #, as at run time; a type of its own name"

# Decimal formatting has an independent oracle, including each power of ten through 10^77,
# its neighbors, the integer edges and random widths. Exercise both # and native formatting.
python3 tools/uint256/gen-cases.py "$seed" 64 --decimal-abla > "$out/src/decimal.ab"
"$compiler" build "$out/src/decimal.ab" -o "$out/decimal" --no-cache --fast
"$out/decimal" || { echo "uint256 decimal text: seed $seed" >&2; exit 1; }
echo "ok   decimal text: compile-time and native agree with Python"

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

# The analysis service takes it as it takes the other widths.
analysis=$(printf '%s\n' \
    '{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":[],"clientName":"uint256-test","clientVersion":"1"}}' \
    '{"schema":1,"id":2,"method":"document/open","params":{"uri":"file:///tmp/abla-uint256-analysis.ab","version":1,"text":"import \"abla/uint256\"\nfun twice(value: uint256): uint256 = value + value\nfun wrong(value: uint256): bool = value == 1\n"}}' \
    '{"schema":1,"id":3,"method":"analyze","params":{}}' \
    '{"schema":1,"id":4,"method":"shutdown","params":{}}' | "$compiler" analyze --stdio)
grep -q '"name":"twice"' <<<"$analysis" || { echo "analysis has no \`twice\`: $analysis" >&2; exit 1; }
grep -q 'comparison.type' <<<"$analysis" || { echo "analysis missed a mixed comparison: $analysis" >&2; exit 1; }
[[ $(grep -o 'E_SEMANTIC\|"severity":"error"' <<<"$analysis" | wc -l) -ge 1 ]]
! grep -q 'uint256.import\|type.unknown' <<<"$analysis" || { echo "analysis refused the type: $analysis" >&2; exit 1; }
echo "ok   analysis: symbols, and only the mistake reported"

# A program not using it has none of it.
cat > "$out/src/hello.ab" <<'EOF'
import "abla/io"
fun main { println("hello") }
EOF
"$compiler" build "$out/src/hello.ab" -o "$out/hello" --no-cache
! llvm-nm "$out/hello" 2>/dev/null | grep -qE '__multi3' || { echo "hello has __multi3" >&2; exit 1; }
"$compiler" --emit-llvm "$out/src/hello.ab" > "$out/hello.ll" 2>/dev/null
! grep -qE 'i256|uint256' "$out/hello.ll" || { echo "hello has a uint256 in it" >&2; exit 1; }
echo "ok   hello: no trace of it"
echo "uint256: all targets above agree with Python"
