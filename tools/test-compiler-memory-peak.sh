#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compiler-memory-peak"
record="$project_root/tests/cases/memory-peak/emit-llvm-self"
mkdir -p "$output_directory"

# The compiler's peak resident memory on its own source's IR (`--emit-llvm src/orc_main.ab`, about
# 9 s), the lower of two runs, under the launcher's limits (the collector paces itself by the
# address-space limit), against the last line of the record. The allocator's free lists once held
# each size's high-water mark for good: that took this build from 1.26-1.40 GB to 1.67 GB, and an
# Xtensa build of abla-embedded's package-import past the 4 GB limit. Runs land near either end of
# that range. More than 10% over the record fails, and so does more than 20% under it, so later
# growth can't hide in a gain: add a line to the record in the commit that moves it, saying why.
if ! /usr/bin/env time --version >/dev/null 2>&1; then
    echo "compiler-memory-peak: needs GNU time (shell.nix has it)" >&2
    exit 1
fi
# The budget is CPU time (about 9 s of it), which load does not change; the wall-clock limit only ends a hang.
peak=""
for run in 1 2; do
    ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=120 /usr/bin/env time -f '%M' -o "$output_directory/peak.$run" \
        "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm "$project_root/src/orc_main.ab" >"$output_directory/self.ll" 2>"$output_directory/self.err" || {
        echo "compiler-memory-peak: --emit-llvm src/orc_main.ab failed" >&2
        sed -n '1,20p' "$output_directory/self.err" >&2
        exit 1
    }
    measured=$(tail -n 1 "$output_directory/peak.$run")
    if [[ -z $peak || $measured -lt $peak ]]; then peak=$measured; fi
done
recorded=$(grep -v '^#' "$record" | tail -n 1 | cut -d' ' -f1)
if (( peak * 100 > recorded * 110 )); then
    echo "compiler-memory-peak: $peak kB, over the recorded $recorded kB by more than 10%. Find what grew (ABLA_COMPILER_MEMORY_TRACE=1 prints live bytes by phase), or add a line to $record saying why." >&2
    exit 1
fi
if (( peak * 100 < recorded * 80 )); then
    echo "compiler-memory-peak: $peak kB, more than 20% under the recorded $recorded kB: add a line to $record." >&2
    exit 1
fi
echo "compiler-memory-peak: --emit-llvm of the compiler peaks at $peak kB (recorded $recorded kB)"
