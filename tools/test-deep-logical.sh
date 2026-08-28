#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/deep-logical"
source_file="$output_directory/deep-logical.ab"
program="$output_directory/deep-logical"
operand_count=${ABLA_DEEP_LOGICAL_OPERANDS:-2048}

if [[ ! $operand_count =~ ^[1-9][0-9]*$ ]] || (( operand_count < 8 )); then
    printf 'ABLA_DEEP_LOGICAL_OPERANDS must be an integer >= 8\n' >&2
    exit 2
fi
stop=$((operand_count * 3 / 4))

mkdir -p "$output_directory"
{
    printf '%s\n' \
        'var deepLogicalCursor = 0' \
        '' \
        'fun deepLogicalAndStep(index: int, stop: int): bool {' \
        '    val ordered = deepLogicalCursor == index' \
        '    deepLogicalCursor = deepLogicalCursor + 1' \
        '    ordered && index != stop' \
        '}' \
        '' \
        'fun deepLogicalOrStep(index: int, stop: int): bool {' \
        '    val ordered = deepLogicalCursor == index' \
        '    deepLogicalCursor = deepLogicalCursor + 1' \
        '    ordered && index == stop' \
        '}' \
        '' \
        'fun main: int {' \
        '    val andValue ='
    index=0
    while (( index < operand_count )); do
        if (( index + 1 < operand_count )); then
            printf '        deepLogicalAndStep(%s, %s) &&\n' "$index" "$stop"
        else
            printf '        deepLogicalAndStep(%s, %s)\n' "$index" "$stop"
        fi
        index=$((index + 1))
    done
    printf '%s\n' \
        '    val andCount = deepLogicalCursor' \
        '    deepLogicalCursor = 0' \
        '    val orValue ='
    index=0
    while (( index < operand_count )); do
        if (( index + 1 < operand_count )); then
            printf '        deepLogicalOrStep(%s, %s) ||\n' "$index" "$stop"
        else
            printf '        deepLogicalOrStep(%s, %s)\n' "$index" "$stop"
        fi
        index=$((index + 1))
    done
    printf '%s\n' \
        "    if (!andValue && andCount == $((stop + 1)) &&" \
        "        orValue && deepLogicalCursor == $((stop + 1))) 42 else 1" \
        '}'
} > "$source_file"

"$compiler" build "$source_file" -o "$program" --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'deep logical chain returned %s, expected 42\n' "$status" >&2
    exit 1
fi

printf 'deep logical chain: operands=%s stop=%s ordered=true\n' \
    "$operand_count" "$stop"
