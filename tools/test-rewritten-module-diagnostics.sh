#!/usr/bin/env bash
set -euo pipefail
# An error in a module whose names are rewritten (imported under an alias)
# reports its position in the module's file, not in the rewritten text.

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case_directory=tests/cases/rewritten-diagnostics
output_directory="$project_root/build/rewritten-diagnostics"
mkdir -p "$output_directory"

if (cd "$project_root" && "$compiler" build "$case_directory/main.ab" \
    -o "$output_directory/main" --no-cache) > "$output_directory/out.txt" 2>&1; then
    echo "rewritten module diagnostics: the build was expected to fail" >&2
    exit 1
fi
location=$(grep -m1 "^source\[semantic\]:.*shapes.ab:" "$output_directory/out.txt" || true)
[ -n "$location" ] || {
    echo "rewritten module diagnostics: no position in shapes.ab" >&2
    cat "$output_directory/out.txt" >&2
    exit 1
}
begin=$(echo "$location" | awk -F: '{print $(NF-1)}')
# The line and column of that offset in the file.
actual=$(head -c "$begin" "$project_root/$case_directory/shapes.ab" |
    awk 'END { print NR ":" length($0) + 1 }')
# The error is the initializer's: the string literal on the `val text` line.
expected=$(grep -n 'val text: int' "$project_root/$case_directory/shapes.ab" |
    awk -F: '{ line = $1; sub(/^[0-9]+:/, ""); print line ":" index($0, "\"not a number\"") }')
if [ "$actual" != "$expected" ]; then
    echo "rewritten module diagnostics: reported at $actual, expected $expected" >&2
    cat "$output_directory/out.txt" >&2
    exit 1
fi
