#!/usr/bin/env bash
# JIT analysis, LLVM emission and machine code generation should scale
# with the number of literal arms. Check the selected value and a late duplicate.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$project_root/build/ct-wide-when-scaling"
mkdir -p "$output"

generate() {
    local arms=$1 target=$2 duplicate=$3
    awk -v n="$arms" -v duplicate="$duplicate" 'BEGIN {
        print "@noinline"
        print "fun select(x: int): int = when (x) {"
        for (i = 0; i < n; i++)
            printf "    %d -> %d\n", i, i * 3
        if (duplicate) print "    1 -> -2"
        print "    else -> -1"
        print "}"
        printf "val answer: int = #(select(%d))\n", n - 1
        printf "fun main(): int = if (answer == %d) 0 else 1\n", (n - 1) * 3
    }' > "$target"
}

phase_times() {
    local arms=$1 root="$output/$1"
    mkdir -p "$root"
    generate "$arms" "$root/main.ab" 0
    if ! (cd "$root" &&
        ABLA_CODEGEN_CACHE=0 ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 \
            "$compiler" build main.ab --fast --no-cache -o program > build.out 2> build.err); then
        cat "$root/build.err" >&2
        return 1
    fi
    "$project_root/tools/run-limited.sh" "$root/program"
    if ! grep '^note\[ct-jit\]: native at main.ab:' "$root/build.err" >/dev/null; then
        cat "$root/build.err" >&2
        echo "CT wide when scaling: the site must use native JIT" >&2
        return 1
    fi
    sed -n 's/^note\[ct-jit\]: generation 1: .* analysis \([0-9][0-9]*\) ms, lowering [0-9][0-9]* ms, emission \([0-9][0-9]*\) ms, code \([0-9][0-9]*\) ms$/\1 \2 \3/p' \
        "$root/build.err" | awk 'NF == 3 {print $1 + $2, $3}'
}

small=$(phase_times 4096)
large=$(phase_times 12288)
if [[ ! $small =~ ^[0-9]+\ [0-9]+$ || ! $large =~ ^[0-9]+\ [0-9]+$ ]]; then
    echo "CT wide when scaling: missing JIT phase times" >&2
    exit 1
fi
read -r small_frontend small_codegen <<< "$small"
read -r large_frontend large_codegen <<< "$large"
if ((large_frontend > 5 * small_frontend + 100 || large_codegen > 5 * small_codegen + 150)); then
    printf 'CT wide when scaling: 4096 arms took %s ms, 12288 took %s ms (frontend, codegen)\n' "$small" "$large" >&2
    exit 1
fi
printf 'CT wide when scaling: 4096 arms %s ms, 12288 arms %s ms (frontend, codegen)\n' "$small" "$large"

generate 256 "$output/duplicate.ab" 1
if "$compiler" build "$output/duplicate.ab" --fast --no-cache -o "$output/duplicate"     > "$output/duplicate.out" 2> "$output/duplicate.err"; then
    echo "CT wide when scaling: duplicate arm compiled" >&2
    exit 1
fi
[[ $(grep -cxF 'error[E_SEMANTIC]: when.duplicate:integer:1' "$output/duplicate.err" || true) == 1 ]] ||
    { cat "$output/duplicate.err" >&2; exit 1; }
