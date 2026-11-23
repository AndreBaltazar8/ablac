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
# The compile is measured with the absolute path to src/orc_main.ab (the record's method) and with the path relative to the
# project root: the semantic identities once carried the source path of every name and local, and an absolute path peaked
# ~100 MB (6-7%) over a relative one (#814). The two are measured alternately, five rounds, so load that comes and goes
# is on both; each takes the lowest of its runs. The absolute path may not peak more than 5% over the relative one: the
# old compiler's gap is 6-7%, the fixed one's is -2%..+2%, and the lowest of five interleaved runs moves by about 1%
# under suite load (the first version, the lower of two runs measured one kind after the other, saw +4.9% at load).
# A source with the same text measured 1,689,700-1,730,964 kB on one machine across five runs of a commit (a 1.5-2% spread), and
# 1,640,000-1,657,000 on another: the limits are 10% over and 20% under the last record line, so the lowest of five rounds (not three)
# keeps a commit that did not move the peak from failing by luck of the load or of the checkout (see the record).
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
# Five rounds keep a commit that did not move the peak from failing by luck, which matters near a limit. Clear of every
# limit by a margin after two rounds (the gap within 3%, the peak within 7% over and 17% under the record), the rest
# would only lower the minima (2026-11-19: 100 of the suite's CPU-seconds for the ten runs): the suite stops there.
# More rounds can only bring a peak down, so a peak over a limit still fails, after all five. RUN_TESTS_FULL=1 or
# MEMORY_PEAK_ROUNDS=5 always runs five.
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
    if [[ $all_rounds != 5 ]] && (( round >= 2 && peak * 100 <= relative_peak * 103 && peak * 100 <= recorded * 115 )); then
        break
    fi
done
# The ordinary trace can count the rendered LLVM text and garbage awaiting collection in one sample.
# A cadence shift made the optimized compiler measure 71.11 B/B against the earlier compiler's 64.54.
# In retained mode the compiler collects at major phase boundaries. The optimized compiler measured
# 49.42–49.45 B/B across three inputs. A limit of 54 leaves about 9% margin. The RSS runs keep default GC.
retained_per_source_byte_hundredths=5400
traced="$output_directory/traced.err"
(
    cd "$project_root"
    ABLA_COMPILER_MEMORY_TRACE=retained \
        ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=120 \
        "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm src/orc_main.ab >"$output_directory/self.ll" 2>"$traced"
) || {
    echo "compiler-memory-peak: the traced --emit-llvm failed" >&2
    tr -d '\0' <"$traced" | sed -n '1,20p' >&2
    exit 1
}
peak_sample=$(tr -d '\0' <"$traced" | awk '
    /^abla-retained-memory / && $NF + 0 > m { m = $NF + 0; phase = $2 }
    END { printf "%s %d\n", (phase != "" ? phase : "unknown"), m }
')
read -r peak_phase retained <<< "$peak_sample"
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
if (( peak * 100 > relative_peak * 105 )); then
    echo "compiler-memory-peak: $peak kB with the absolute path to src/orc_main.ab, $relative_peak kB with the relative one: a build's peak must not follow the length of the path (what keeps the path per name or local?)." >&2
    exit 1
fi
if (( peak * 100 > recorded * 120 )); then
    echo "compiler-memory-peak: $peak kB, over the recorded $recorded kB by more than 20% (a loose ceiling: the live-bytes check is the tight one, and it passed). Add a line to $record saying why, or find what grew." >&2
    exit 1
fi
echo "compiler-memory-peak: --emit-llvm of the compiler peaks at $peak kB resident (recorded $recorded kB; $relative_peak kB given a relative path; $rounds rounds), $retained retained bytes at $peak_phase for $source_bytes source bytes ($((retained * 100 / source_bytes)) hundredths per byte)"
