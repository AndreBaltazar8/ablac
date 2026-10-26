#!/usr/bin/env bash
set -euo pipefail
# A build that removes one of its outputs on purpose keeps it removed: a release
# Wasm module built after a development build of it leaves no object beside it
# (the build's transaction used to put the earlier one back), and so does a hosted
# release executable built without its sidecar (the default, or --no-sidecar) after
# one built with it (--sidecar; the executable is the same). A development build
# that hands its module on without LLVM text leaves no earlier text beside it. A
# build that fails still puts every earlier output back.

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

printf 'stale\n' > "$module.ll"
"$compiler" build "$cases/dev.ab" -o "$output_directory/dev-driver" --no-cache
[ -f "$module" ] || fail "the development build wrote no module"
[ -f "$module.o" ] || fail "the development build wrote no object"
[ ! -e "$module.ll" ] || fail "the development module kept an earlier build's LLVM text"
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

# A hosted development build: an earlier text is gone (Mach-O emits none) or replaced.
fast="$output_directory/fast"
printf 'stale\n' > "$fast.ll"
"$compiler" build "$cases/hosted.ab" -o "$fast" --no-cache --fast
[ -x "$fast" ] || fail "the development build wrote no executable"
if [ -e "$fast.ll" ] && grep -qx stale "$fast.ll"; then
    fail "the development executable kept an earlier build's LLVM text"
fi

# A hosted release executable: its sidecar object with --sidecar (or ABLA_SIDECAR=1),
# none by default or with --no-sidecar, which wins over the environment.
hosted="$output_directory/hosted"
"$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache --sidecar
[ -f "$hosted.o" ] || fail "--sidecar built no sidecar"
cp "$hosted" "$output_directory/hosted.with-sidecar"
cp "$hosted.o" "$output_directory/hosted.o.with-sidecar"
"$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache
[ ! -e "$hosted.o" ] || fail "a default build kept the earlier sidecar"
cmp -s "$hosted" "$output_directory/hosted.with-sidecar" ||
    fail "a build without the sidecar changed the executable"
ABLA_SIDECAR=1 "$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache
cmp -s "$hosted.o" "$output_directory/hosted.o.with-sidecar" ||
    fail "the sidecar differs after a build without it"
ABLA_SIDECAR=1 "$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache --no-sidecar
[ ! -e "$hosted.o" ] || fail "--no-sidecar kept the earlier sidecar"
"$compiler" build "$cases/hosted.ab" -o "$hosted" --no-cache --sidecar
if "$compiler" build "$cases/broken-hosted.ab" -o "$hosted" --no-cache \
    > "$output_directory/broken-hosted.log" 2>&1; then
    fail "the broken program built"
fi
cmp -s "$hosted" "$output_directory/hosted.with-sidecar" ||
    fail "a failing build did not restore the executable"
cmp -s "$hosted.o" "$output_directory/hosted.o.with-sidecar" ||
    fail "a failing build without the sidecar did not restore it"
