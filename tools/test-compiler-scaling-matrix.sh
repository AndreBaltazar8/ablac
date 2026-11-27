#!/usr/bin/env bash
# Bounded growth checks for generated compiler inputs. Each binary checks its
# result. Measure the affected JIT phase rather than unrelated startup cost.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
directory="$project_root/build/compiler-scaling-matrix"
mkdir -p "$directory"
output=$(mktemp -d "$directory/run.XXXXXXXX")
trap 'if (($? == 0)); then rm -rf "$output"; else echo "compiler scaling: logs in $output" >&2; fi' EXIT
export LC_ALL=C ABLA_CODEGEN_CACHE=0 ABLA_MAX_STACK_KB=8192
ulimit -Ss 8192
timer=${ABLA_TIME:-$(type -P time)}

generate() {
    local shape=$1 size=$2 duplicate=${3:-0}
    awk -v shape="$shape" -v n="$size" -v duplicate="$duplicate" '
        function main_result(expected) {
            printf "fun main(): int = if (answer == %d) 0 else 1\n", expected
        }
        BEGIN {
            if (shape == "chains") {
                print "class Node(val value: int) { fun step(): Node = Node(this.value + 1) }"
                print "@noinline"
                printf "fun measure(x: int): int = Node(x)"
                for (i = 0; i < n; i++) printf ".step()"
                print ".value"
                print "val answer: int = #(measure(1))"
                printf "fun main(): int = if (answer == %d && measure(1) == answer) 0 else 1\n", n + 1
            } else if (shape == "regions") {
                print "fun measure(x: int): int {"
                print "    var result = 0"
                for (i = 0; i < n; i++) printf "    result += region { (x + %d) * 2 }\n", i
                print "    result"
                print "}"
                printf "val answer: int = #(measure(%d))\n", n - 1
                main_result(3 * n * (n - 1))
            } else if (shape == "when") {
                print "@noinline"
                print "fun measure(x: int): int = when (x) {"
                for (i = 0; i < n; i++) printf "    %d -> %d\n", i, i * 3
                if (duplicate) print "    1 -> -2"
                print "    else -> -1"
                print "}"
                printf "val answer: int = #(measure(%d))\n", n - 1
                main_result(3 * (n - 1))
            } else if (shape == "wide-class") {
                print "class Wide("
                for (i = 0; i < n; i++) printf "    val f%d: int = %d%s\n", i, i, i + 1 < n ? "," : ""
                print ") {"
                for (i = 0; i < n; i++) printf "    fun m%d(x: int): int = this.f%d + x\n", i, i
                print "}"
                print "@noinline"
                print "fun measure(x: int): int {"
                print "    val wide = Wide()"
                print "    var result = 0"
                for (i = 0; i < n; i++) printf "    result += wide.m%d(x)\n", i
                print "    result"
                print "}"
                print "val answer: int = #(measure(1))"
                printf "fun main(): int = if (answer == %d && measure(1) == answer) 0 else 1\n", n * (n + 1) / 2
            } else if (shape == "locals") {
                print "fun measure(depth: int, table: array<int>): int {"
                print "    if (depth == 0) return 0"
                split("3 5 7 11 13 17 19 23", table)
                sum = 0
                for (i = 0; i < n; i++) {
                    printf "    val v%d = table[%d] * %d + depth\n", i, i % 8, i + 1
                    sum += table[i % 8 + 1] * (i + 1) + 1
                }
                print "    val child = measure(depth - 1, table)"
                printf "    depth - (child"
                for (i = 0; i < n; i++) printf " + v%d", i
                print ")"
                print "}"
                printf "fun main(): int = if (measure(1, [3,5,7,11,13,17,19,23]) == %d) 0 else 1\n", 1 - sum
            } else if (shape == "nested") {
                print "@noinline"
                print "fun measure(x: int): int {"
                for (i = 0; i < n; i++) printf "    if (x >= %d) {\n", i
                printf "        x + %d\n", n
                for (i = 0; i < n; i++) print "    } else -1"
                print "}"
                printf "fun main(): int = if (measure(%d) == %d) 0 else 1\n", n, 2 * n
            }
        }
    '
}

# Hybrid CPUs can record separate counters. Sum all the numeric instruction
# counts, and probe before choosing a metric so both sizes use the same unit.
instruction_count() {
    awk -F, '$1 ~ /^[0-9]+$/ && $3 ~ /instructions/ { total += $1 }
        END { if (total > 0) printf "%.0f\n", total; else exit 1 }' "$1"
}

perf_available=0
if command -v perf >/dev/null &&
    perf stat --no-big-num -x, -e instructions:u -o "$output/perf-probe" -- true 2>/dev/null &&
    instruction_count "$output/perf-probe" >/dev/null; then
    perf_available=1
fi

measure() {
    local shape=$1 size=$2 metric=$3
    local root="$output/$shape-$size"
    mkdir -p "$root"
    generate "$shape" "$size" > "$root/main.ab"
    local flags=(--fast)
    if [[ $shape == locals ]]; then flags=(); fi
    local prefix=("$timer" -p -o "$root/time")
    if [[ $metric == instr ]]; then
        prefix=(perf stat --no-big-num -x, -e instructions:u -o "$root/instructions" --)
    fi
    if ! (
        cd "$root"
        ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "${prefix[@]}" "$compiler" \
            build main.ab "${flags[@]}" --no-debug --no-cache -o program >build.out 2>build.err
    ); then
        cat "$root/build.err" >&2
        return 1
    fi
    "$project_root/tools/run-limited.sh" "$root/program" || return
    case $shape in
        chains|regions|when|wide-class)
            if ! grep '^note\[ct-jit\]: native at main.ab:' "$root/build.err" >/dev/null; then
                cat "$root/build.err" >&2
                echo "compiler scaling: $shape must use native compile-time evaluation" >&2
                return 1
            fi
            ;;
    esac
    case $metric in
        jit)
            sed -n 's/^note\[ct-jit\]: generation 1: .* analysis \([0-9][0-9]*\) ms, lowering \([0-9][0-9]*\) ms, emission \([0-9][0-9]*\) ms, code \([0-9][0-9]*\) ms$/\1 \2 \3 \4/p' "$root/build.err" |
                awk -v shape="$shape" 'NF == 4 {
                    if (shape=="chains") print $2
                    if (shape=="regions") print $4
                    if (shape=="when") print $1 + $3, $4
                }'
            ;;
        instr) instruction_count "$root/instructions" ;;
        cpu) awk '/^(user|sys) / {total += $2} END {printf "%.0f\n", total * 100}' "$root/time" ;;
    esac
}

# The jit rows are phase times the compiler reports in wall-clock milliseconds, which a busy shared runner inflates at
# random (release run 45898824396: regions codegen 727 -> 4063 ms, 727 again on a rerun). Each size is measured three times
# and each phase keeps its minimum: interference only ever adds time, so the minimum is the phase's own cost, and a phase
# that really grows faster than linearly does so in every repeat.
measure_min() {
    local shape=$1 size=$2 repeat value values=()
    for repeat in 1 2 3; do
        value=$(measure "$shape" "$size" jit) || return
        values+=("$value")
    done
    printf '%s\n' "${values[@]}" | awk '{
            for (i = 1; i <= NF; i++) if (NR == 1 || $i < low[i]) low[i] = $i
            if (NF > fields) fields = NF
        }
        END { for (i = 1; i <= fields; i++) printf "%s%s", low[i], i < fields ? " " : "\n" }'
}

failed=0
check_growth() {
    local label=$1 small=$2 large=$3 limit=$4 slack=$5
    if [[ ! $small =~ ^[0-9]+$ || ! $large =~ ^[0-9]+$ ]]; then
        echo "compiler scaling: missing measurements for $label" >&2
        failed=1
        return
    fi
    printf 'compiler scaling: %-31s %s -> %s (bound %sx + %s)\n' "$label" "$small" "$large" "$limit" "$slack"
    if ((large > limit * small + slack)); then
        echo "compiler scaling: $label exceeded its growth bound" >&2
        failed=1
    fi
}

small=$(measure_min chains 1024)
large=$(measure_min chains 2048)
check_growth 'chains 1024/2048 lowering ms' "$small" "$large" 3 100

small=$(measure_min regions 2048)
large=$(measure_min regions 4096)
check_growth 'regions 2048/4096 codegen ms' "$small" "$large" 3 100

small=$(measure_min when 4096)
large=$(measure_min when 12288)
read -r small_front small_code <<< "$small"
read -r large_front large_code <<< "$large"
check_growth 'when 4096/12288 frontend ms' "$small_front" "$large_front" 5 100
check_growth 'when 4096/12288 codegen ms' "$small_code" "$large_code" 5 150

metric=cpu
unit='CPU cs'
slack=8
if ((perf_available)); then
    metric=instr
    unit=instructions
    slack=0
fi
small=$(measure wide-class 512 "$metric")
large=$(measure wide-class 1024 "$metric")
check_growth "wide class 512/1024 $unit" "$small" "$large" 3 "$slack"

# CPU time includes the release code generation that regressed in #1197.
small=$(measure locals 1000 cpu)
large=$(measure locals 2000 cpu)
check_growth 'locals 1000/2000 release CPU cs' "$small" "$large" 3 8

small=$(measure nested 96 "$metric")
large=$(measure nested 288 "$metric")
check_growth "nested blocks 96/288 $unit" "$small" "$large" 5 "$slack"

generate when 256 1 > "$output/duplicate.ab"
if "$compiler" build "$output/duplicate.ab" --fast --no-cache -o "$output/duplicate" \
    >"$output/duplicate.out" 2>"$output/duplicate.err"; then
    echo "compiler scaling: duplicate arm compiled" >&2
    failed=1
elif [[ $(grep -cxF 'error[E_SEMANTIC]: when.duplicate:integer:1' "$output/duplicate.err" || true) != 1 ]]; then
    cat "$output/duplicate.err" >&2
    failed=1
fi

if ((failed)); then
    echo "compiler scaling: a growth bound or correctness check failed" >&2
    exit 1
fi
