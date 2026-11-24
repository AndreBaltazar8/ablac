#!/usr/bin/env bash
# Many sequential regions can expose an integer sum deep enough to make the
# native JIT's object generation repeatedly walk the accumulated prefix.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$project_root/build/ct-region-scaling"
mkdir -p "$output"

codegen_time() {
    local regions=$1 root="$output/$1"
    mkdir -p "$root"
    awk -v n="$regions" 'BEGIN {
        print "fun sum(x: int): int {"
        print "    var result = 0"
        for (i = 0; i < n; i++)
            printf "    result += region { (x + %d) * 2 }\n", i
        print "    result"
        print "}"
        printf "val answer: int = #(sum(%d))\n", n - 1
        printf "fun main(): int = if (answer == %d) 0 else 1\n", 3 * n * (n - 1)
    }' > "$root/main.ab"
    if ! (cd "$root" &&
        ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab --fast --no-cache -o program             > build.out 2> build.err); then
        cat "$root/build.err" >&2
        return 1
    fi
    "$project_root/tools/run-limited.sh" "$root/program"
    if ! grep '^note\[ct-jit\]: native at main.ab:' "$root/build.err" >/dev/null; then
        cat "$root/build.err" >&2
        echo "CT region scaling: the site must use native JIT" >&2
        return 1
    fi
    sed -n 's/^note\[ct-jit\]: generation 1: .* code \([0-9][0-9]*\) ms$/\1/p' "$root/build.err"
}

small=$(codegen_time 2048)
large=$(codegen_time 4096)
if [[ ! $small =~ ^[0-9]+$ || ! $large =~ ^[0-9]+$ ]]; then
    echo "CT region scaling: missing JIT code generation times" >&2
    exit 1
fi
if ((large > 3 * small + 100)); then
    printf 'CT region scaling: 2048 regions took %s ms, 4096 took %s ms\n' "$small" "$large" >&2
    exit 1
fi
printf 'CT region scaling: 2048 regions %s ms, 4096 regions %s ms\n' "$small" "$large"
