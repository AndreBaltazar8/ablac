#!/usr/bin/env bash
set -euo pipefail

# Hosted programs collect under allocation pressure by default; a program that
# calls memorySetManualCollection is compiled without pressure safe points and
# collects only at memoryCollect(), until it asks for pressure collection again.
if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
directory="$project_root/build/collection-modes-test"
cases="$project_root/tests/cases/modules"
mkdir -p "$directory"

check_case() {
    local name=$1 pressure=$2
    local source="$cases/$name.ab"
    "$compiler" --emit-llvm "$source" > "$directory/$name.ll" || exit 1
    if grep -Fq 'call void @abla_runtime_memory_pressure()' \
        "$directory/$name.ll"; then
        [[ $pressure == yes ]] || {
            printf '%s: unexpected pressure safe points\n' "$name" >&2
            exit 1
        }
    else
        [[ $pressure == no ]] || {
            printf '%s: missing pressure safe points\n' "$name" >&2
            exit 1
        }
    fi
    "$compiler" build "$source" -o "$directory/$name" --no-cache || exit 1
    set +e
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" "$directory/$name"
    local status=$?
    set -e
    [[ $status -eq 42 ]] || {
        printf '%s: exit %s\n' "$name" "$status" >&2
        exit 1
    }
}

check_case runtime-memory-default-collection yes
check_case runtime-memory-manual-collection no
check_case runtime-memory-manual-then-growth yes
printf '%s\n' \
    'collection modes: pressure by default + manual opt-out + manual collect + growth re-enables passed'
