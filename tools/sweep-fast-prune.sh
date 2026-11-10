#!/usr/bin/env bash
# Builds each program --fast twice, pruned and with ABLA_FAST_PRUNE=0, runs both and lists
# the programs whose build status, exit status or output differ (a run that times out in
# both counts as equal). Usage: sweep-fast-prune.sh [compiler] [program.ab...]; with no
# programs, the benchmarks, examples and the single-file test programs. Known benign
# differences: a program that prints its own binary path (tests/cases/modules/proc-self-exe.ab)
# or stack frames (tests/cases/any-text-panic) differs between the two binaries by name only.
set -u
compiler=${1:-build/ablac.bin}
shift || true
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root" || exit 1
work=$project_root/build/sweep-fast-prune
mkdir -p "$work"
if (($# > 0)); then programs=("$@"); else
    mapfile -t programs < <(ls tests/benchmarks/perf/*.ab tests/benchmarks/*.ab \
        tests/cases/modules/*.ab examples/*.ab tests/cases/*/main.ab 2>/dev/null | sort -u)
fi
export ABLA_CACHE_DIR=$work/cache
differences=0
for program in "${programs[@]}"; do
    rm -rf "$ABLA_CACHE_DIR"
    ABLA_FAST_PRUNE=0 timeout 120 "$compiler" build "$program" -o "$work/full" --fast --no-cache >"$work/full.build" 2>&1
    full_build=$?
    rm -rf "$ABLA_CACHE_DIR"
    ABLA_FAST_PRUNE=1 timeout 120 "$compiler" build "$program" -o "$work/pruned" --fast --no-cache >"$work/pruned.build" 2>&1
    pruned_build=$?
    if ((full_build != pruned_build)); then
        echo "DIFF build $program full=$full_build pruned=$pruned_build $(grep -m1 -E 'undefined|error' "$work/pruned.build" | cut -c1-120)"
        differences=$((differences + 1))
        continue
    fi
    ((full_build == 0)) || continue
    (cd "$work" && timeout 20 ./full </dev/null >full.out 2>&1)
    full_run=$?
    (cd "$work" && timeout 20 ./pruned </dev/null >pruned.out 2>&1)
    pruned_run=$?
    # Addresses and the binary's name differ between the two binaries; a benchmark prints
    # timings, so only its exit status is compared.
    sed -E -i 's/0x[0-9a-f]+/0x/g; s#\./(full|pruned)#./bin#g' "$work/full.out" "$work/pruned.out"
    same_output=true
    # A run cut off by the timeout (124) has only whatever it printed by then.
    if [[ $program != tests/benchmarks/* && $full_run -ne 124 ]] && ! cmp -s "$work/full.out" "$work/pruned.out"; then same_output=false; fi
    if ((full_run != pruned_run)) || ! $same_output; then
        echo "DIFF run $program full=$full_run pruned=$pruned_run"
        differences=$((differences + 1))
    fi
done
echo "sweep-fast-prune: ${#programs[@]} programs, $differences differences"
((differences == 0))
