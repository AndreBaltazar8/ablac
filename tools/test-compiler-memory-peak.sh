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
# that range. The resident peak is only a loose ceiling (more than 20% over the record fails: add a line to the record in
# the commit that moves it, saying why); what holds a commit to its memory is the live bytes per source byte, below.
if ! /usr/bin/env time --version >/dev/null 2>&1; then
    echo "compiler-memory-peak: needs GNU time (shell.nix has it)" >&2
    exit 1
fi
# The budget is CPU time (about 9 s of it), which load does not change; the wall-clock limit only ends a hang.
#
# Keep the default-GC RSS ceiling for both entry spellings. A path change can cross a
# collection threshold and change the high-water mark without retaining more data.
# Use the forced-collection checkpoints below to check the actual path retention (#814).
measure() { # KIND ROUND: the peak resident kB of one compile, in the file named by the arguments
    local kind=$1 round=$2 input directory=$project_root
    input="$project_root/src/orc_main.ab"
    [[ $kind == absolute ]] || input=src/orc_main.ab
    (
        cd "$directory"
        ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=120 /usr/bin/env time -f '%M' -o "$output_directory/$kind.$round" \
            "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm "$input" >"$output_directory/self.ll" 2>"$output_directory/self.err"
    ) || {
        echo "compiler-memory-peak: --emit-llvm src/orc_main.ab ($kind path) failed" >&2
        sed -n '1,20p' "$output_directory/self.err" >&2
        exit 1
    }
    tail -n 1 "$output_directory/$kind.$round"
}
peak=""
relative_peak=""
recorded=$(grep -v '^#' "$record" | tail -n 1 | cut -d' ' -f1)
# Two pairs suffice if both minima are comfortably within the RSS ceiling.
# RUN_TESTS_FULL=1 or MEMORY_PEAK_ROUNDS=5 still takes five interleaved pairs.
all_rounds=${MEMORY_PEAK_ROUNDS:-${RUN_TESTS_FULL:+5}}
rounds=0
for round in 1 2 3 4 5; do
    if (( round % 2 == 1 )); then first=absolute second=relative; else first=relative second=absolute; fi
    for kind in $first $second; do
        measured=$(measure "$kind" "$round")
        if [[ $kind == absolute ]]; then
            if [[ -z $peak || $measured -lt $peak ]]; then peak=$measured; fi
        else
            if [[ -z $relative_peak || $measured -lt $relative_peak ]]; then relative_peak=$measured; fi
        fi
    done
    rounds=$round
    if [[ $all_rounds != 5 ]] && (( round >= 2 && peak * 100 <= recorded * 115 && relative_peak * 100 <= recorded * 115 )); then
        break
    fi
done
# In retained mode the compiler collects at major phase boundaries so changes in
# collection cadence cannot turn pending garbage into a memory regression.
# With native LLVM text streamed to stdout, the peak moved from render.end
# (49.41–49.44 B/B) to frontend.lowering.end (43.22–43.25 B/B) across three inputs.
# A limit of 47 leaves about 9% margin. The RSS runs keep default GC.
retained_per_source_byte_hundredths=4700
for kind in absolute relative; do
    input=src/orc_main.ab
    if [[ $kind == absolute ]]; then input="$project_root/$input"; fi
    traced="$output_directory/traced-$kind.err"
    (
        cd "$project_root"
        ABLA_COMPILER_MEMORY_TRACE=retained \
            ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=120 \
            "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm "$input" >"$output_directory/self.ll" 2>"$traced"
    ) || {
        echo "compiler-memory-peak: the traced --emit-llvm ($kind path) failed" >&2
        tr -d '\0' <"$traced" | sed -n '1,20p' >&2
        exit 1
    }
    tr -d '\0' < "$traced" | awk '
        /^abla-retained-memory / {
            phase = $2
            sub(/:.*/, "", phase)
            if ($NF + 0 > high[phase]) high[phase] = $NF + 0
        }
        END { for (phase in high) printf "%s %d\n", phase, high[phase] }
    ' > "$output_directory/retained-$kind.txt"
done
# Compare corresponding phases. An earlier regression could retain long names during
# semantic analysis and free them before the overall lowering peak.
path_sample=$(awk '
    NR == FNR { absolute[$1] = $2; phases++; next }
    $1 in absolute && $2 > 0 {
        matched++
        growth = absolute[$1] / $2
        if (growth > worst) { worst = growth; phase = $1; a = absolute[$1]; r = $2 }
    }
    END {
        if (matched == 0 || matched != phases || matched != FNR) exit 1
        printf "%s %d %d\n", phase, a, r
    }
' "$output_directory/retained-absolute.txt" "$output_directory/retained-relative.txt") || {
    echo "compiler-memory-peak: no matching retained-heap samples for both entry paths" >&2
    exit 1
}
read -r path_phase path_absolute path_relative <<< "$path_sample"
if (( path_absolute * 100 > path_relative * 101 )); then
    echo "compiler-memory-peak: $path_absolute retained bytes for the absolute path at $path_phase vs $path_relative for the relative path, over the 1% path-retention limit (#814)." >&2
    exit 1
fi
peak_sample=$(awk '$2 + 0 > m { m = $2; phase = $1 } END { printf "%s %d\n", phase, m }' \
    "$output_directory/retained-absolute.txt" "$output_directory/retained-relative.txt")
read -r peak_phase retained <<< "$peak_sample"
traced="$output_directory/traced-relative.err"
source_bytes=$(tr -d '\0' <"$traced" | sed -n 's/^abla-frontend-memory graph\.acquire:\(.*\) [0-9]*$/\1/p' | sort -u |
    (cd "$project_root" && xargs -d '\n' cat) | wc -c)
if (( retained <= 0 || source_bytes <= 0 )); then
    echo "compiler-memory-peak: no retained-heap samples in the trace (retained $retained, source $source_bytes)" >&2
    exit 1
fi
if (( retained * 100 > source_bytes * retained_per_source_byte_hundredths )); then
    echo "compiler-memory-peak: $retained retained bytes at $peak_phase for $source_bytes bytes of source: $((retained / source_bytes)) per byte, over the limit of $((retained_per_source_byte_hundredths / 100)). Inspect the retained trace with ABLA_COMPILER_MEMORY_TRACE=retained." >&2
    exit 1
fi
if (( peak * 100 > recorded * 120 || relative_peak * 100 > recorded * 120 )); then
    echo "compiler-memory-peak: $peak kB absolute and $relative_peak kB relative, over the recorded $recorded kB by more than 20% (a loose ceiling: the live-bytes check is the tight one, and it passed). Add a line to $record saying why, or find what grew." >&2
    exit 1
fi
echo "compiler-memory-peak: absolute/relative retained comparison passes (largest ratio at $path_phase, $path_absolute versus $path_relative bytes)"
echo "compiler-memory-peak: --emit-llvm of the compiler peaks at $peak kB resident (recorded $recorded kB; $relative_peak kB given a relative path; $rounds rounds), $retained retained bytes at $peak_phase for $source_bytes source bytes ($((retained * 100 / source_bytes)) hundredths per byte)"
