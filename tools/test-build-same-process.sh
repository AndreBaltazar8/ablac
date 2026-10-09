#!/usr/bin/env bash
set -euo pipefail
# A development Wasm build sets up its own optimization (an inliner threshold, code
# generation in process). A release module built after one in the same compiler process
# must be byte-identical to one built in a process of its own, and so must a release
# native object, which is optimized in process.

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/build-same-process"
cases="tests/cases/build-same-process"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"
fail() {
    echo "build same process: $1" >&2
    exit 1
}

"$compiler" build "$cases/both.ab" -o "$output_directory/both-driver" --no-cache
[ -f "$output_directory/development.wasm" ] || fail "no development module"
[ -f "$output_directory/after-development.wasm" ] || fail "no release module"
"$compiler" build "$cases/release.ab" -o "$output_directory/release-driver" --no-cache
cmp -s "$output_directory/after-development.wasm" "$output_directory/alone.wasm" ||
    fail "a release module built after a development one differs from one built alone"
cmp -s "$output_directory/after-development.o" "$output_directory/alone.o" ||
    fail "a release native object built after a development module differs from one built alone"

echo "build same process: release outputs after a development module are the same as ones built alone"
