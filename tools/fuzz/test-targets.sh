#!/usr/bin/env bash
# Exercise the real target arms and the WASI-specific panic verdict.
set -euo pipefail
compiler=$1
runtime=${ABLA_WASMTIME:-wasmtime}
out=build/fuzz-abla/controls
mkdir -p "$out"
if command -v "$runtime" >/dev/null; then
    ABLA_FUZZ_WASI=1 ABLA_FUZZ_RISCV64=0 tools/fuzz/run \
        --compiler "$compiler" --seeds 100008,100016 --checks 2 --panics > "$out/wasi.log" || { cat "$out/wasi.log" >&2; exit 1; }
    cat "$out/wasi.log"
    grep -Fxq 'seed 100008: 2 checks agree in all six modes + wasm32-wasi' "$out/wasi.log"
    grep -Fxq 'seed 100016: 2 checks agree in all six modes + wasm32-wasi' "$out/wasi.log"

    cat > "$out/wrong-panic-host" <<'WRAPPER'
#!/usr/bin/env bash
status=0
"$FUZZ_REAL_WASMTIME" "$@" || status=$?
if [[ $status == 134 ]]; then exit 101; fi
exit "$status"
WRAPPER
    chmod +x "$out/wrong-panic-host"
    if output=$(FUZZ_REAL_WASMTIME="$(command -v "$runtime")" ABLA_WASMTIME="$PWD/$out/wrong-panic-host" \
        ABLA_FUZZ_WASI=1 ABLA_FUZZ_RISCV64=0 tools/fuzz/run \
        --compiler "$compiler" --seed 100008 --checks 2 --panics); then
        echo 'fuzz: Wasmtime exit 101 was mistaken for a validated trap' >&2
        exit 1
    fi
    [[ $output == *"wasm32-wasi: stdout"*"status 101"* ]]
    # Raw addresses belong to the ABI, so keep them out of the portable
    # corpus. Verify the exact width difference and prove that the ordinary
    # comparator still reports it instead of discarding unequal output.
    cat > "$out/pointer-width.ab" <<'AB'
import "abla/io"
import "abla/unsafe/memory/raw"

@export("run")
trusted fun run(): int {
    // Round-trip only, without accessing the address.
    val address = nativePointerAddress(nativePointerFromAddress(4294967297))
    println("c0=$address")
    0
}

fun main: int = run()
AB
    if output=$(ABLA_FUZZ_WASI=1 ABLA_FUZZ_RISCV64=1 tools/fuzz/run --compiler "$compiler" \
        --program "$out/pointer-width.ab"); then
        echo 'fuzz: an ABI-dependent pointer value was treated as portable' >&2
        exit 1
    fi
    [[ $output == *"wasm32-wasi"* ]]
    probe=build/fuzz-abla/program
    grep -Fxq 'c0=4294967297' "$probe/fast.stdout"
    grep -Fxq 'c0=4294967297' "$probe/release.stdout"
    grep -Fxq 'c0=1' "$probe/wasm32-wasi.stdout"
    if [[ $output != *"fuzz: riscv64-linux skipped ("* ]]; then
        grep -Fxq 'c0=4294967297' "$probe/riscv64-linux.stdout"
    fi
else
    printf 'fuzz: wasm32-wasi skipped (%s unavailable)\n' "$runtime"
fi

ABLA_FUZZ_WASI=0 ABLA_FUZZ_RISCV64=1 tools/fuzz/run \
    --compiler "$compiler" --seed 100008 --checks 2 --panics > "$out/riscv64.log"
cat "$out/riscv64.log"
if ! grep -Fq 'fuzz: riscv64-linux skipped (' "$out/riscv64.log"; then
    grep -Fxq 'seed 100008: 2 checks agree in all six modes + riscv64-linux' "$out/riscv64.log"
fi
