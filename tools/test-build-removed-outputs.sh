#!/usr/bin/env bash
set -euo pipefail
# A build that removes one of its outputs on purpose keeps it removed: a release
# Wasm module built after a development build of it leaves no object beside it
# (the build's transaction used to put the earlier one back), and so does a hosted
# release executable built --no-sidecar after one built with its sidecar (the
# executable is the same). A build that fails still puts every earlier output back.

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

# A hosted release executable: its sidecar object by default, none with --no-sidecar.
hosted="$output_directory/hosted"
"$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache
[ -f "$hosted.o" ] || fail "a release executable built no sidecar"
cp "$hosted" "$output_directory/hosted.with-sidecar"
cp "$hosted.o" "$output_directory/hosted.o.with-sidecar"
"$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache --no-sidecar
[ ! -e "$hosted.o" ] || fail "--no-sidecar kept the earlier sidecar"
cmp -s "$hosted" "$output_directory/hosted.with-sidecar" ||
    fail "--no-sidecar changed the executable"
"$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache
cmp -s "$hosted.o" "$output_directory/hosted.o.with-sidecar" ||
    fail "the sidecar differs after a --no-sidecar build"
if "$compiler" build "$cases/broken-hosted.ab" -o "$hosted" --no-cache --no-sidecar \
    > "$output_directory/broken-hosted.log" 2>&1; then
    fail "the broken program built"
fi
cmp -s "$hosted" "$output_directory/hosted.with-sidecar" ||
    fail "a failing build did not restore the executable"
cmp -s "$hosted.o" "$output_directory/hosted.o.with-sidecar" ||
    fail "a failing --no-sidecar build did not restore the sidecar"
