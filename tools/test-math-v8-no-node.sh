#!/usr/bin/env bash
# tools/test-math-v8.sh without a Node: skipped, saying why, rather than failed.
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/math-v8-no-node"
mkdir -p "$output_directory"
for tool in dirname mkdir; do
    ln -sfn "$(command -v "$tool")" "$output_directory/$tool"
done
bash=$(command -v bash)
output=$(env -u MATH_V8_NODE PATH="$output_directory" "$bash" "$project_root/tools/test-math-v8.sh" "${1:-build/ablac}")
[[ $output == *"math-v8: skipped: no node"* ]] || { echo "math-v8 without a Node said: $output" >&2; exit 1; }
echo "math-v8 without a Node: skipped, and says why"
