#!/usr/bin/env bash
# An extension's receiver may be any type (array<T>, Map<K, V>, T?), and a
# malformed receiver is one error.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/extension-receivers"
mkdir -p "$output_directory"
cases="$project_root/tests/cases/modules"

"$compiler" build "$cases/extension-receiver-types.ab" -o "$output_directory/types" --no-cache >/dev/null
actual=$("$output_directory/types")
[[ $actual == "6 2 true false" ]] || { echo "extension receivers: '$actual'"; exit 1; }

set +e
diagnostics=$("$compiler" build "$cases/invalid-extension-receiver.ab" -o "$output_directory/invalid" --no-cache 2>&1)
status=$?
set -e
[[ $status -ne 0 ]] || { echo "invalid receiver: built"; exit 1; }
[[ $(grep -c '^error\[' <<<"$diagnostics") -eq 1 && $diagnostics == *E_PARSE_EXTENSION_RECEIVER* ]] ||
    { echo "invalid receiver:"; echo "$diagnostics"; exit 1; }
echo "extension receivers: array<int>, Map<string, int>, string?; a malformed one is one error"
