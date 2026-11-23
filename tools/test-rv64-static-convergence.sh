#!/usr/bin/env bash
# Rebuild the static RV64 compiler twice under QEMU with the same pinned SDK.
# Usage: tools/test-rv64-static-convergence.sh <sdk-dir> <seed> <shim-object>
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 <sdk-dir> <seed> <shim-object>" >&2; exit 2; }
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
out=$(mktemp -d "$out/run-XXXXXX")
mkdir "$out/empty-path"
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
for stage in stage2 stage3; do
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

if cmp -- "$out/stage2" "$out/stage3" 2>&1 | tee "$out/comparison.log"; then
    echo 'RV64 release stage 2 and stage 3 are byte-identical' | tee -a "$out/comparison.log"
else
    echo 'RV64 release stage 2 and stage 3 differ' | tee -a "$out/comparison.log" >&2
    exit 1
fi
