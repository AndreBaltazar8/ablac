#!/usr/bin/env bash
set -euo pipefail
# A build that removes one of its outputs on purpose keeps it removed: a release
# Wasm module built after a development build of it leaves no object beside it
# (the build's transaction used to put the earlier one back). A build that fails
# still puts every earlier output back.

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/build-removed-outputs"
cases="tests/cases/build-removed-outputs"
module="$output_directory/module.wasm"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"
fail() {
    echo "build removed outputs: $1" >&2
    exit 1
}

"$compiler" build "$cases/dev.ab" -o "$output_directory/dev-driver" --no-cache
[ -f "$module" ] || fail "the development build wrote no module"
[ -f "$module.o" ] || fail "the development build wrote no object"
"$compiler" build "$cases/release.ab" -o "$output_directory/release-driver" --no-cache
[ -f "$module" ] || fail "the release build wrote no module"
[ ! -e "$module.o" ] || fail "the release module kept the development build's object"
cp "$module" "$output_directory/release.wasm"

# A failing build of the same module leaves the release build's outputs as they were.
if "$compiler" build "$cases/broken-release.ab" \
    -o "$output_directory/broken-driver" --no-cache > "$output_directory/broken.log" 2>&1; then
    fail "the broken module built"
fi
cmp -s "$module" "$output_directory/release.wasm" ||
    fail "a failing build did not restore the module"
[ ! -e "$module.o" ] || fail "a failing build restored a removed object"
