#!/usr/bin/env bash
# A parse error stops the build after the parser: only E_PARSE_* errors are
# reported (no semantic, IR or LLVM consequences), a missing expression before
# a closing delimiter is one error, and recovery never hangs.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/parse-errors-stop"
mkdir -p "$output_directory"

check() { # file count (count = expected `error[` lines, 0 = any)
    local file=$1 count=$2 status errors
    set +e
    diagnostics=$(ABLA_MAX_SECONDS=30 ABLA_MAX_CPU_SECONDS=30 \
        "$project_root/tools/run-limited.sh" "$compiler" build \
        "$project_root/tests/cases/modules/$file.ab" \
        -o "$output_directory/$file" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    [[ $status -ne 124 ]] || { echo "$file: parser recovery hung"; exit 1; }
    if grep '^error\[' <<<"$diagnostics" | grep -qv '^error\[E_PARSE_'; then
        echo "$file: errors after the parse errors"; echo "$diagnostics"; exit 1
    fi
    errors=$(grep -c '^error\[E_PARSE_' <<<"$diagnostics" || true)
    [[ $errors -gt 0 ]] || { echo "$file: no parse error"; echo "$diagnostics"; exit 1; }
    [[ $count -eq 0 || $errors -eq $count ]] || {
        echo "$file: $errors parse errors, expected $count"; echo "$diagnostics"; exit 1; }
}

check invalid-parse-stops-paren 1
check invalid-parse-stops-delimiters 0
echo "parse errors stop the build: no semantic/IR/LLVM errors after them, (1 +) is one error"
