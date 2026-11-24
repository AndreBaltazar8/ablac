#!/usr/bin/env bash
# Postfix chains of receiver calls should reuse the types found while lowering
# the preceding links. Compare the compile-time JIT's lowering phase, before
# LLVM can obscure the cost, and check the result in the runtime program too.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$project_root/build/member-chain-scaling"
mkdir -p "$output"

lowering_time() {
    local links=$1 root="$output/$1" i
    mkdir -p "$root"
    {
        printf 'class Node(val number: int) { fun step(): Node = Node(this.number + 1) }\n'
        printf '@noinline\nfun measure(x: int): int = Node(x)'
        for ((i = 0; i < links; i++)); do printf '.step()'; done
        printf '.number\nval computed: int = #(measure(1))\n'
        printf 'fun main(): int = if (measure(1) == computed && computed == %d) 0 else 1\n' "$((links + 1))"
    } > "$root/main.ab"
    if ! (cd "$root" &&
        ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab --fast --no-cache -o program             > build.out 2> build.err); then
        cat "$root/build.err" >&2
        return 1
    fi
    "$project_root/tools/run-limited.sh" "$root/program"
    if ! grep '^note\[ct-jit\]: native at main.ab:' "$root/build.err" >/dev/null; then
        cat "$root/build.err" >&2
        echo "member-chain scaling: the site must use native JIT" >&2
        return 1
    fi
    sed -n 's/^note\[ct-jit\]: generation 1: .* lowering \([0-9][0-9]*\) ms,.*/\1/p' "$root/build.err"
}

small=$(lowering_time 1024)
large=$(lowering_time 2048)
if [[ ! $small =~ ^[0-9]+$ || ! $large =~ ^[0-9]+$ ]]; then
    echo "member-chain scaling: missing JIT lowering times" >&2
    exit 1
fi
if ((large > 3 * small + 100)); then
    printf 'member-chain scaling: 1024 links took %s ms, 2048 links took %s ms\n' "$small" "$large" >&2
    exit 1
fi
printf 'member-chain scaling: 1024 links %s ms, 2048 links %s ms\n' "$small" "$large"
