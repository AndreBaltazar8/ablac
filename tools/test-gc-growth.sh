#!/usr/bin/env bash
# ABLA_GC_GROWTH=<bytes> sets the growth between collections without a rebuild. A
# program keeping a small live heap amid much garbage stays below 8 MiB with a 2 MiB
# step and not with the default one, keeping what it keeps either way (and under
# ABLA_GC_STRESS=1); a value that is not decimal bytes of at least 1 MiB is ignored.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/gc-growth"
program="$output_directory/garbage"
mkdir -p "$output_directory"
fail() {
    echo "gc growth: $1" >&2
    exit 1
}
"$compiler" build "$project_root/tests/cases/gc-growth/garbage.ab" \
    -o "$program" --fast --no-cache

expected='total 48778890 kept 7890'
default=$("$program")
[[ $default == "$expected small true" ]] || fail "default growth: '$default'"
stepped=$(ABLA_GC_GROWTH=2097152 "$program")
[[ $stepped == "$expected small true" ]] || fail "ABLA_GC_GROWTH=2097152: '$stepped'"
large=$(ABLA_GC_GROWTH=67108864 "$program")
[[ $large == "$expected small false" ]] || fail "explicit large growth: '$large'"
ignored=$(ABLA_GC_GROWTH=2mb "$program")
[[ $ignored == "$default" ]] || fail "ABLA_GC_GROWTH=2mb is not bytes, yet: '$ignored'"
tiny=$(ABLA_GC_GROWTH=4096 "$program")
[[ $tiny == "$default" ]] || fail "ABLA_GC_GROWTH=4096 is under 1 MiB, yet: '$tiny'"
native="$output_directory/native-pressure"
"$compiler" build "$project_root/tests/cases/gc-growth/native-pressure.ab" \
    -o "$native" --fast --no-cache
[[ $("$native") == "native pressure true small payload true" ]] ||
    fail "discarded native buffers did not trigger automatic collection"
[[ $(ABLA_GC_GROWTH=67108864 "$native") == "native pressure false small payload true" ]] ||
    fail "explicit payload pacing counted discarded native buffers"

trim="$output_directory/trim-pressure"
"$compiler" build "$project_root/tests/cases/gc-growth/trim-pressure.ab" \
    -o "$trim" --fast --no-cache
trimmed=$("$trim")
[[ $trimmed == "trim true" || $trimmed == "trim unavailable" ]] ||
    fail "automatic collection retained the allocation burst"

# Every round collects under stress, about two minutes in one process: the same
# rounds, shared out among processes. Their totals add up to the whole run's.
shards=10
pids=()
for ((shard = 0; shard < shards; shard++)); do
    ABLA_GC_STRESS=1 ABLA_GC_GROWTH=2097152 "$program" \
        $((shard * 100000)) $(((shard + 1) * 100000)) > "$output_directory/stress-$shard.out" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail "under ABLA_GC_STRESS=1: a process failed"; done
stressed_total=0
for ((shard = 0; shard < shards; shard++)); do
    read -r _ total _ kept _ small < "$output_directory/stress-$shard.out"
    [[ $kept == 7890 && $small == true ]] ||
        fail "under ABLA_GC_STRESS=1, shard $shard: $(<"$output_directory/stress-$shard.out")"
    stressed_total=$((stressed_total + total))
done
[[ $stressed_total == 48778890 ]] || fail "under ABLA_GC_STRESS=1: total $stressed_total"
echo 'gc growth: adaptive pacing, native buffer pressure, explicit growth and stress'
