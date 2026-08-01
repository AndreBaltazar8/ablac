#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output="$project_root/build/repl-test.out"
errors="$project_root/build/repl-test.err"

printf 'missingName\n20 + 21\n20 + 22\n:quit\n' | \
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" repl \
    > "$output" 2> "$errors"

[[ $(< "$output") == $'abla> abla> 41\nabla> 42\nabla> ' ]]
grep -q 'identifier:missingName' "$errors"

printf 'fun add(value: int): int = value + 1\nadd(41)\nval base: int = 40\nbase + 2\n:reset\nbase\n:quit\n' | \
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" repl \
    > "$output" 2> "$errors"
[[ $(< "$output") == $'abla> defined\nabla> 42\nabla> defined\nabla> 42\nabla> reset\nabla> abla> ' ]]
grep -q 'identifier:base' "$errors"

{
    for _ in $(seq 1 128); do
        printf '20 + 22\n'
    done
    printf ':quit\n'
} | ABLA_MAX_MEMORY_MB=512 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" repl \
    > "$output" 2> "$errors"
[[ $(grep -o '42' "$output" | wc -l) -eq 128 ]]

printf '%s\n' 'persistent REPL: retained definitions + recovery + reclaimed JIT generations'
