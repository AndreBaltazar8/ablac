#!/usr/bin/env bash
# abla/uint256, int256, uint128 and int128 against Python's integers (tools/wide-integers/gen-cases.py), on each target
# ablac has. test-wide-integers.sh COMPILER [TYPE]: TYPE is one of them, uint256 by default:
#   run:      x86-64 (release and --fast, on a fresh random seed each run), Wasm under Node, AArch64,
#             RISC-V 64 and 32 (no M extension) and Xtensa under qemu, with a start of their own and no
#             C library (tests/cases/wide-integers/start.c).
#   Xtensa is run only where the ESP toolchain is, as lld can't link it; elsewhere it's compiled.
# Then what the compiler refuses, what a division by zero does, and that a program not using it has
# none of it in it.
#
# By default a quick run, for `make test`: every edge and corner case, a small random sample, x86-64 --fast,
# the compile-time check, decimal text and the Wasm imports for each type, and for uint256 also the rest of the host checks (the
# nominal type, the refusals, the analysis, hello). WIDE_FULL=1, `make test-wide-integers-full` and `make test-full`
# run it all.
set -euo pipefail

type=${2:-uint256}
case $type in
    uint256 | int256) bits=256; words="x, x, x, x, x, x, x, x" ;;
    uint128 | int128) bits=128; words="x, x, x, x" ;;
    *) echo "test-wide-integers.sh: unknown type $type" >&2; exit 2 ;;
esac
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=build/$type
cd "$project_root"
rm -rf "$out"
mkdir -p "$out/src"
python3 tools/wide-integers/stage.py "$type" tests/cases/wide-integers "$out/cases"
cases=$out/cases
cp "$cases"/checks.ab "$cases"/object.ab "$cases"/wasm.ab "$out/src/"
python3 tools/wide-integers/gen-cases.py 1 3000 --type "$type" --abla > "$out/src/cases.ab"

full=${WIDE_FULL:-${RUN_TESTS_FULL:-}}
count=16000
if [[ -n $full ]]; then count=60000; fi
seed=${WIDE_SEED:-$(python3 -c 'import random; print(random.getrandbits(48))')}
python3 tools/wide-integers/gen-cases.py "$seed" "$count" --type "$type" > "$out/random.txt"
modes=(--fast)
[[ -z $full ]] || modes=("--fast -g" --fast "")
for mode in "${modes[@]}"; do
    "$compiler" build "$cases/file.ab" -o "$out/file" --no-cache $mode
    "$out/file" "$out/random.txt" || { echo "$type ${mode:-release}: seed $seed: see that line of $out/random.txt" >&2; exit 1; }
done
if [[ -n $full ]]; then
    "$compiler" run "$cases/file.ab" -- "$out/random.txt" || { echo "$type ablac run: seed $seed: see that line of $out/random.txt" >&2; exit 1; }
    echo "ok   x86-64: release, --fast, -g and ablac run, $(wc -l < "$out/random.txt") cases, seed $seed"
else
    echo "ok   x86-64: --fast, $(wc -l < "$out/random.txt") cases, seed $seed"
fi

if [[ -n $full ]]; then
# The boxed values (a field, an array element, a capture, the checks' language section) must survive a collection at
# every allocation: a prefix of the cases, since each allocation collects.
head -n 6000 "$out/random.txt" > "$out/stress.txt"
for mode in "--fast" ""; do
    "$compiler" build "$cases/file.ab" -o "$out/file-stress" --no-cache $mode
    ABLA_GC_STRESS=1 "$out/file-stress" "$out/stress.txt" || { echo "$type ${mode:-release} under GC stress: seed $seed" >&2; exit 1; }
done
echo "ok   GC stress: fast and release, 6000 cases and the language checks"
fi

# The checks can fail: one wrong answer in those cases is found.
middle=$(( $(wc -l < "$out/random.txt") / 2 ))
sed "${middle}s/[^ ]*$/bad/" "$out/random.txt" > "$out/wrong.txt"
[[ $("$out/file" "$out/wrong.txt") == "line $middle" ]] || { echo "a wrong answer wasn't noticed" >&2; exit 1; }

# Wasm has nothing to import for it: a wide `mul` calls the module's own __multi3.
"$compiler" build "$cases/build-wasm.ab" -o "$out/wasm-driver" --no-cache 2> "$out/wasm.log" || { cat "$out/wasm.log" >&2; exit 1; }
"$out/wasm-driver"
node "$cases/run.mjs" "$out/$type.wasm"
echo "ok   wasm under node $(node --version): imports nothing of C's"

if [[ -n $full ]]; then
"$compiler" build "$cases/build-objects.ab" -o "$out/objects-driver" --no-cache
start() { # triple, flags, name
    NIX_HARDENING_ENABLE= clang --target="$1" $2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -O1 \
        -c "$cases/start.c" -o "$out/start-$3.o" 2>/dev/null
    ld.lld -static --no-pie -z notext "$out/$3.o" "$out/start-$3.o" -o "$out/$3"
}
if command -v qemu-aarch64 > /dev/null; then
    start aarch64-linux-gnu "" aarch64
    qemu-aarch64 "$out/aarch64" || { echo "$type aarch64: failed with $?" >&2; exit 1; }
    echo "ok   aarch64 under qemu"
else
    echo "skip aarch64: no qemu-aarch64"
fi
if command -v qemu-riscv64 > /dev/null; then
    start riscv64-linux-gnu "-march=rv64i -mabi=lp64" riscv64
    qemu-riscv64 "$out/riscv64" || { echo "$type riscv64: failed with $?" >&2; exit 1; }
    echo "ok   riscv64 under qemu"
else
    echo "skip riscv64: no qemu-riscv64"
fi
"$compiler" build "$out/src/object.ab" -o "$out/riscv32.o" --no-cache \
    --target-triple riscv32-unknown-elf --object-format elf --emit object
if command -v qemu-riscv32 > /dev/null; then
    start riscv32-unknown-elf "-march=rv32i -mabi=ilp32" riscv32
    qemu-riscv32 "$out/riscv32" || { echo "$type riscv32: failed with $?" >&2; exit 1; }
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
    qemu-xtensa -cpu dc232b "$out/xtensa" || { echo "$type xtensa: failed with $?" >&2; exit 1; }
    echo "ok   xtensa under qemu, without mul32high; with it, compiled"
else
    echo "ok   xtensa: compiled only, no ESP toolchain to link it here"
fi

# What it needs on each target besides what's in the object, arithmetic alone: nothing where the
# target multiplies, and on RISC-V without M only the helpers `*` calls anyway.
cat > "$out/src/arithmetic.ab" <<EOF
import "abla/$type"
@export("arithmetic")
fun arithmetic(x: u32): int {
    val a = ${type}Words($words)
    val b = a * a + (a << 3) - ${type}(x)
    if ((b / a) * a + b % a != b) return 1
    if (a < b) 2 else 0
}
EOF
ABLA_ESP_CPU=esp32 ABLA_XTENSA_FEATURES='' "$compiler" build "$out/src/arithmetic.ab" -o "$out/arithmetic-xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
[[ -z $(llvm-nm -u "$out/arithmetic-xtensa.o") ]] || { echo "Xtensa arithmetic needs: $(llvm-nm -u "$out/arithmetic-xtensa.o")" >&2; exit 1; }
"$compiler" build "$out/src/arithmetic.ab" -o "$out/arithmetic-riscv32.o" --no-cache \
    --target-triple riscv32-unknown-elf --object-format elf --emit object
shifts='ashldi3|lshrdi3'
[[ $type == int* ]] && shifts="$shifts|ashrdi3"
helpers=$(llvm-nm -u "$out/arithmetic-riscv32.o" | awk '{print $2}' | grep -vE "^__(mulsi3|muldi3|$shifts)\$" || true)
[[ -z $helpers ]] || { echo "RISC-V arithmetic needs: $helpers" >&2; exit 1; }
echo "ok   arithmetic: nothing on Xtensa, on RISC-V only the helpers of \`*\` and a shift"

# By zero: the language's own panic.
for operator in / %; do
    cat > "$out/src/zero.ab" <<EOF
import "abla/$type"
fun main: int = (${type}(1) $operator ${type}(processArguments())).toInt()
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
fi

modes=(--fast)
[[ -z $full ]] || modes=("" --fast)

for mode in "${modes[@]}"; do
    "$compiler" build "$cases/compile-time.ab" -o "$out/compile-time" --no-cache $mode
    "$out/compile-time" > "$out/compile-time.out" || { echo "$type under #, ${mode:-release}: check $? failed" >&2; tail -n 4 "$out/compile-time.out" >&2; exit 1; }
    if [[ -n $full || $type == uint256 ]]; then
        "$compiler" build "$cases/nominal.ab" -o "$out/nominal" --no-cache $mode
        "$out/nominal" || { echo "$type nominal, ${mode:-release}: check $? failed" >&2; exit 1; }
    fi
done
echo "ok   under #, as at run time; a type of its own name"

# Decimal formatting has an independent oracle, including each power of ten through 10^77,
# its neighbors, the integer edges and random widths. Exercise both # and native formatting.
python3 tools/wide-integers/gen-cases.py "$seed" 64 --type "$type" --decimal-abla > "$out/src/decimal.ab"
"$compiler" build "$out/src/decimal.ab" -o "$out/decimal" --no-cache --fast
"$out/decimal" || { echo "$type decimal text: seed $seed" >&2; exit 1; }
echo "ok   decimal text: compile-time and native agree with Python"

if [[ -n $full || $type == uint256 ]]; then
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
    '{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":[],"clientName":"wide-test","clientVersion":"1"}}' \
    '{"schema":1,"id":2,"method":"document/open","params":{"uri":"file:///tmp/abla-wide-analysis.ab","version":1,"text":"import \"abla/'"$type"'\"\nfun twice(value: '"$type"'): '"$type"' = value + value\nfun wrong(value: '"$type"'): bool = value == 1\n"}}' \
    '{"schema":1,"id":3,"method":"analyze","params":{}}' \
    '{"schema":1,"id":4,"method":"shutdown","params":{}}' | "$compiler" analyze --stdio)
grep -q '"name":"twice"' <<<"$analysis" || { echo "analysis has no \`twice\`: $analysis" >&2; exit 1; }
grep -q 'comparison.type' <<<"$analysis" || { echo "analysis missed a mixed comparison: $analysis" >&2; exit 1; }
[[ $(grep -o 'E_SEMANTIC\|"severity":"error"' <<<"$analysis" | wc -l) -ge 1 ]]
! grep -q 'wideint.import\|type.unknown' <<<"$analysis" || { echo "analysis refused the type: $analysis" >&2; exit 1; }
echo "ok   analysis: symbols, and only the mistake reported"

# A program not using it has none of it.
cat > "$out/src/hello.ab" <<'EOF'
import "abla/io"
fun main { println("hello") }
EOF
"$compiler" build "$out/src/hello.ab" -o "$out/hello" --no-cache
! llvm-nm "$out/hello" 2>/dev/null | grep -qE '__multi3' || { echo "hello has __multi3" >&2; exit 1; }
"$compiler" --emit-llvm "$out/src/hello.ab" > "$out/hello.ll" 2>/dev/null
! grep -qE "i256|i128|$type" "$out/hello.ll" || { echo "hello has a $type in it" >&2; exit 1; }
echo "ok   hello: no trace of it"
fi
echo "$type: all targets above agree with Python"
