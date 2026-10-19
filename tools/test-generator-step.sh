#!/usr/bin/env bash
# A `for` over a generator calls the generator's own step entry rather than
# the closure dispatcher, and a step that allocates nothing neither roots
# values nor polls memory pressure; one that allocates or runs another
# generator still does.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/generator-step"
output_directory="$project_root/build/generator-step"
mkdir -p "$output_directory"

for name in counter words; do
    "$compiler" build "$cases/$name.ab" -o "$output_directory/$name" --no-cache
    "$compiler" --emit-llvm "$cases/$name.ab" > "$output_directory/$name.ll"
done
[[ $("$output_directory/counter") == 5000411500 ]] || {
    echo "generator step: counter printed $("$output_directory/counter")"; exit 1
}
[[ $("$output_directory/words") == 2177800 ]] || {
    echo "generator step: words printed $("$output_directory/words")"; exit 1
}

# The body of the direct function behind each step entry of `$1`.
step_bodies() {
    local ll=$1
    grep -o '^define internal void @[A-Za-z0-9_]*_generator_step(' "$ll" |
        sed -E 's/^define internal void @(.*)_generator_step\($/\1/' |
        while read -r symbol; do
            awk -v name="@${symbol}_direct(" 'index($0, "define") == 1 && index($0, name) {on = 1} on {print} on && /^}/ {exit}' "$ll"
        done
}

for name in counter words; do
    ll="$output_directory/$name.ll"
    grep -q 'call void @abla_generator_create(.*_generator_step' "$ll" || {
        echo "generator step: $name does not pass its step entry"; exit 1
    }
    grep -q 'call void @abla_llvm_call_dispatch(' "$ll" || {
        echo "generator step: $name's runtime does not call the step entry"; exit 1
    }
done
# count's step allocates nothing; squares' creates and steps a generator.
counter_steps=$(step_bodies "$output_directory/counter.ll" |
    awk '/^define/ {roots = 0} /abla_runtime_roots_push|abla_runtime_memory_pressure/ {roots = 1} /^}/ {print roots}')
[[ $(echo "$counter_steps" | sort | tr -d '\n') == 01 ]] || {
    echo "generator step: counter's steps root as $counter_steps (want one without, one with)"; exit 1
}
grep -q 'abla_runtime_roots_push' <<<"$(step_bodies "$output_directory/words.ll")" || {
    echo "generator step: an allocating step does not root"; exit 1
}
echo "generator step: steps are called directly; only an allocating one roots"
