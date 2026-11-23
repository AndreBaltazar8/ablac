#!/usr/bin/env bash
# Rebuild the RV64 compiler under QEMU. CI runs each stage on its own runner.
# Usage: tools/test-rv64-static-convergence.sh <sdk-dir> <compiler> <shim-object> [stage2|stage3]
set -euo pipefail
if [[ $# != 3 && $# != 4 ]]; then
    echo "usage: $0 <sdk-dir> <compiler> <shim-object> [stage2|stage3]" >&2
    exit 2
fi
mode=${4:-both}
deps=$(realpath -e -- "$1")
seed=$(realpath -e -- "$2")
shim=$(realpath -e -- "$3")
qemu=$(command -v qemu-riscv64)
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
ulimit -S -s 8192
ulimit -c 0
export LC_ALL=C

out="$root/build/rv64-static-convergence"
mkdir -p "$out"
case $mode in
    both)
        stages=(stage2 stage3)
        out=$(mktemp -d "$out/run-XXXXXX")
        ;;
    stage2|stage3)
        stages=("$mode")
        out="$out/run-ci"
        ;;
    *)
        echo "RV64 convergence: expected stage2 or stage3, got $mode" >&2
        exit 2
        ;;
esac
mkdir -p "$out/empty-path"
if [[ $mode == stage2 ]]; then
    # Give the shim the same path in both jobs as well as the same bytes.
    if [[ $shim != "$out/abla_lld_shim.o" ]]; then
        install -m 644 "$shim" "$out/abla_lld_shim.o"
        shim="$out/abla_lld_shim.o"
    fi
elif [[ $mode == stage3 ]]; then
    [[ $seed == "$out/stage2" && $shim == "$out/abla_lld_shim.o" ]] ||
        { echo 'RV64 convergence: stage 3 expects the downloaded compiler and shim in run-ci' >&2; exit 1; }
    [[ $(cat "$out/source.sha") == "$(git rev-parse HEAD)" ]] ||
        { echo 'RV64 convergence: stage 2 was built from a different source commit' >&2; exit 1; }
    (cd "$out" && sha256sum -c stage2.sha256 shim.sha256)
    chmod +x "$seed"
fi
echo "RV64 convergence evidence in $out"
sha256sum "$seed" "$shim" > "$out/inputs.sha256"

# The same source, link inputs and output path keep the comparison independent
# of stage names. A single codegen unit avoids guest child re-exec in qemu-user.
guest=(env -i PATH="$out/empty-path" HOME="$out" ABLA_SYSROOT="$root"
    ABLA_CODEGEN_UNITS=1 ABLA_NATIVE_JOBS=1 ABLA_MAX_MEMORY_MB=8192
    ABLA_STATIC_LLVM_LIB="$deps/lib" ABLA_STATIC_LLD_LIB="$deps/lib"
    ABLA_STATIC_TARGET_LIBS="$deps/sysroot/lib" ABLA_STATIC_LLD_OBJECT="$shim" "$qemu")
candidate="$out/compiler"
input="$seed"
for stage in "${stages[@]}"; do
    echo "Building $stage with $input"
    /usr/bin/env time -f 'wall=%e cpu=%U+%S rss_kb=%M exit=%x' -o "$out/$stage.time" \
        "${guest[@]}" "$input" build src/orc_main_static.ab --no-cache -o "$candidate" \
        2>&1 | tee "$out/$stage.log"
    mv -- "$candidate" "$out/$stage"
    "${guest[@]}" "$out/$stage" --version 2>&1 | tee -a "$out/$stage.log"
    readelf -hldW "$out/$stage" > "$out/$stage.elf"
    (cd "$out" && sha256sum "$stage") | tee "$out/$stage.sha256"
    input="$out/$stage"
done

if [[ $mode == stage2 ]]; then
    (cd "$out" && sha256sum abla_lld_shim.o > shim.sha256)
    git rev-parse HEAD > "$out/source.sha"
    exit 0
fi
if cmp -- "$out/stage2" "$out/stage3" 2>&1 | tee "$out/comparison.log"; then
    echo 'RV64 release stage 2 and stage 3 are byte-identical' | tee -a "$out/comparison.log"
else
    echo 'RV64 release stage 2 and stage 3 differ' | tee -a "$out/comparison.log" >&2
    exit 1
fi
