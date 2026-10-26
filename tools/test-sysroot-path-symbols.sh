#!/usr/bin/env bash
set -euo pipefail
# A program built against two copies of the sysroot at paths of different
# lengths is the same program: the same symbols, the same output, byte for
# byte, natively and in WebAssembly. A module's private names are rewritten
# to a prefix that spells its path, so whatever is named after the source
# (a lambda's symbol, from its span) must use the file's own offsets.

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
sysroot=${ABLA_SYSROOT:-$project_root}
cases="$project_root/tests/cases/sysroot-path-symbols"
output_directory="$project_root/build/sysroot-path-symbols"
rm -rf "$output_directory"
mkdir -p "$output_directory/roots"

fail() {
    echo "sysroot path symbols: $1" >&2
    exit 1
}

# The compiler binary itself: a launcher sets its own ABLA_SYSROOT, which
# would replace the copies'. (Beside the launcher, beside the launcher a link
# points at, or in a released toolchain's libexec.)
compiler_payload=$compiler
resolved=$compiler
while [[ -L $resolved ]]; do
    target=$(readlink "$resolved")
    [[ $target == /* ]] || target=$(dirname "$resolved")/$target
    resolved=$target
done
if [[ -x $compiler.bin ]]; then
    compiler_payload=$compiler.bin
elif [[ -x $resolved.bin ]]; then
    compiler_payload=$resolved.bin
elif [[ -x $(dirname "$resolved")/../libexec/ablac.bin ]]; then
    compiler_payload=$(dirname "$resolved")/../libexec/ablac.bin
fi

# Copies, not links: a link resolves to the same path.
roots=()
for name in s a-sysroot-path-much-longer-than-the-first-one; do
    root="$output_directory/roots/$name"
    mkdir -p "$root"
    cp -R "$sysroot/stdlib" "$sysroot/runtime" "$root/"
    mkdir -p "$root/stdlib/abla/sysroot-path-fixture"
    cp "$cases/fixture.ab" "$root/stdlib/abla/sysroot-path-fixture/entry.ab"
    roots+=("$root")
done

for index in 0 1; do
    root=${roots[$index]}
    side="$output_directory/side-$index"
    mkdir -p "$side"
    (cd "$project_root" && ABLA_SYSROOT="$root" "$compiler_payload" build \
        "$cases/main.ab" -o "$output_directory/program" --no-cache)
    mv "$output_directory/program" "$side/program"
    nm -U "$side/program" | awk '{print $NF}' | sort > "$side/symbols"
    set +e
    "$side/program" > "$side/output"
    status=$?
    set -e
    [[ $status == 42 ]] || fail "the program built against ${root##*/} exited with $status"
    (cd "$project_root" && ABLA_SYSROOT="$root" "$compiler_payload" build \
        tests/cases/sysroot-path-symbols/build.ab \
        -o "$output_directory/build-driver" --no-cache)
    mv "$output_directory/module.wasm" "$side/module.wasm"
done
[[ $(cat "$output_directory/side-0/output") == "42 1 example.test" ]] ||
    fail "the program printed $(cat "$output_directory/side-0/output")"
cmp -s "$output_directory/side-0/output" "$output_directory/side-1/output" ||
    fail "the output differs between sysroot paths"
cmp -s "$output_directory/side-0/symbols" "$output_directory/side-1/symbols" || {
    diff "$output_directory/side-0/symbols" "$output_directory/side-1/symbols" | head -10 >&2
    fail "the native symbols differ between sysroot paths"
}
cmp -s "$output_directory/side-0/program" "$output_directory/side-1/program" ||
    fail "the native program differs between sysroot paths"
cmp -s "$output_directory/side-0/module.wasm" "$output_directory/side-1/module.wasm" ||
    fail "module.wasm differs between sysroot paths"
echo "sysroot path symbols: the same native program (symbols, output, bytes) and Wasm module from sysroots at two path lengths"
