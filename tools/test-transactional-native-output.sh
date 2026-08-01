#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
directory="$project_root/build/transactional-native-output"
program="$directory/program"
mkdir -p "$directory"

"$compiler" build "$project_root/tests/cases/bootstrap/function.ab" \
    --fast --no-cache -o "$program"
before=$(sha256sum "$program")

set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-condition.ab" \
    --fast --no-cache -o "$program" \
    > "$directory/invalid.out" 2> "$directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
after=$(sha256sum "$program")
[[ $before == "$after" ]]

set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program"
program_status=$?
set -e
[[ $program_status -eq 42 ]]

if compgen -G "$program.tmp.*" > /dev/null; then
    echo 'transactional native build left a publish temporary behind' >&2
    exit 1
fi

printf '%s\n' 'native publication: failed rebuild preserved the prior executable atomically'
