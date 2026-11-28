#!/usr/bin/env bash
# Values stay live across a call and are consumed by a left-associated sum.
# Build and run the program so this covers lowering and native optimization.
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    printf '%s\n' 'native locals scaling: timed on x86-64 Linux'
    exit 0
fi

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
out="$project_root/build/native-locals-scaling"
mkdir -p "$out"
cd "$project_root"
export LC_ALL=C ABLA_MAX_STACK_KB=8192
unset ABLA_TEST_FAST_BUILDS
ulimit -Ss 8192
timer=${ABLA_TIME:-$(type -P time)}

for count in 1000 2000 4000; do
    awk -v count="$count" -v expected="$out/$count.expected" 'BEGIN {
        print "import \"abla/io\""
        print "fun sumLocals(depth: int, table: array<int>): int {"
        print "    if (depth == 0) return 0"
        split("3 5 7 11 13 17 19 23", table)
        total = 0
        for (i = 0; i < count; i++) {
            printf "    val v%d = table[%d] * %d + depth\n", i, i % 8, i + 1
            total += table[i % 8 + 1] * (i + 1) + 1
        }
        print "    val child = sumLocals(depth - 1, table)"
        printf "    depth - (child"
        for (i = 0; i < count; i++) printf " + v%d", i
        print ")"
        print "}"
        print "fun main {"
        print "    val result = sumLocals(1, [3, 5, 7, 11, 13, 17, 19, 23])"
        print "    println(\"$result\")"
        print "}"
        printf "%.0f\n", 1 - total > expected
    }' >"$out/$count.ab"
done

# Measurements of a ratio over its bound, after the first.
retries=2

seconds() { printf '%d.%02d' "$(($1 / 100))" "$(($1 % 100))"; }

# measure <profile> <count>: builds and runs the program, sets cpu to the build's user + system CPU in hundredths of a second.
measure() {
    local target="$out/$1-$2"
    if ! "$timer" -p "$compiler" build "$out/$2.ab" -o "$target" "${flags[@]}" \
        >"$target.log" 2>"$target.time"; then
        cat "$target.log" "$target.time" >&2
        exit 1
    fi
    "$target" >"$target.stdout"
    cmp "$out/$2.expected" "$target.stdout"
    cpu=$(awk '/^(user|sys) / { total += $2 } END { printf "%.0f\n", total * 100 }' "$target.time")
    printf 'native locals scaling: %s %d locals %s CPU s\n' "$1" "$2" "$(seconds "$cpu")"
}

for profile in release fast; do
    flags=(--no-cache --no-debug)
    if [[ $profile == fast ]]; then flags+=(--fast); fi
    span=2
    max_ratio=3
    if [[ $profile == release ]]; then
        # Judge release over the whole fourfold increase. A single doubling can
        # be noisy, while quadratic work grows 16x
        # over this span. Keep the same overall allowance as two 3x bounds.
        span=4
        max_ratio=9
    fi
    cpu_by_count=()
    for count in 1000 2000 4000; do
        measure "$profile" "$count"
        cpu_by_count[$count]=$cpu
        reference_count=$((count / span))
        reference_cpu=${cpu_by_count[$reference_count]:-0}
        # CPU time swells under load (a JOBS=6 suite once gave 2.40/4.12/22.66 s where the same compiler alone gives
        # 1.67/3.20/9.27), and more for the longer build. A ratio over the bound is measured again, both sizes, and judged on
        # each size's least time: load only adds time, while a quadratic pass is over the bound in every run.
        retry=0
        while ((reference_cpu > 0 && cpu_by_count[$count] > max_ratio * reference_cpu && retry < retries)); do
            retry=$((retry + 1))
            printf 'native locals scaling: %s %d locals over %dx the CPU of %d, measuring both again (%d of %d)\n' \
                "$profile" "$count" "$max_ratio" "$reference_count" "$retry" "$retries"
            measure "$profile" "$reference_count"
            ((cpu >= reference_cpu)) || reference_cpu=$cpu
            cpu_by_count[$reference_count]=$reference_cpu
            measure "$profile" "$count"
            ((cpu >= cpu_by_count[$count])) || cpu_by_count[$count]=$cpu
        done
        if ((reference_cpu > 0 && cpu_by_count[$count] > max_ratio * reference_cpu)); then
            printf 'native locals scaling: %s %d locals took more than %dx the CPU of %d in each of %d runs (least %s s against %s s)\n' \
                "$profile" "$count" "$max_ratio" "$reference_count" "$((retries + 1))" \
                "$(seconds "${cpu_by_count[$count]}")" "$(seconds "$reference_cpu")" >&2
            exit 1
        fi
    done
done
