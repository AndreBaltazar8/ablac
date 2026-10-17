#!/usr/bin/env bash
# One mistake, one diagnostic: an unknown `$name` subparser is named (with an import
# hint), an ambiguous overload isn't also reported as a missing call target, and a
# named-argument error carries its file and adds no code-generation errors.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/diagnostic-noise"
mkdir -p "$output_directory"

check() { # file count expected… (count = number of `error[` lines)
    local file=$1 count=$2; shift 2
    set +e
    diagnostics=$("$compiler" build "$project_root/tests/cases/modules/$file.ab" \
        -o "$output_directory/$file" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    local errors; errors=$(grep -c '^error\[' <<<"$diagnostics" || true)
    [[ $errors -eq $count ]] || { echo "$file: $errors errors, expected $count"; echo "$diagnostics"; exit 1; }
    for text in "$@"; do
        [[ $diagnostics == *"$text"* ]] || { echo "$file: missing '$text'"; echo "$diagnostics"; exit 1; }
    done
    if [[ $diagnostics == *E_LLVM_* || $diagnostics == *E_IR_* ]]; then
        echo "$file: code-generation noise"; echo "$diagnostics"; exit 1
    fi
}

check subparser-unknown 1 "subparser.unknown:nothing" "abla/json"
check overload-ambiguous-single 1 "call.overload-ambiguous:pick"
check named-argument-required 1 "E_NAMED_ARGUMENT_REQUIRED" "source[named-argument]:$project_root/tests/cases/modules/named-argument-required.ab:"
echo "diagnostic noise: one error per mistake"
