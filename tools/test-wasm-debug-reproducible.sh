#!/usr/bin/env bash
set -euo pipefail
# A development Wasm build's module, source map and DWARF module are the same
# from one build to the next, and from a sysroot reached through another path
# up to that path itself (they name the sources by absolute path). Their lines
# are the files' own, also in a module whose names are rewritten (shapes.ab is
# imported under an alias) and in the runtime's platform module.

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sysroot=${ABLA_SYSROOT:-$project_root}
output_directory="$project_root/build/wasm-debug-reproducible"
module="$output_directory/module.wasm"
roots="$output_directory/roots"
rm -rf "$output_directory"
mkdir -p "$roots"
short="$roots/s"
long="$roots/a-sysroot-path-much-longer-than-the-first-one"
ln -s "$sysroot" "$short"
ln -s "$sysroot" "$long"

# build NAME ROOT: builds the module against ROOT into $output_directory/NAME.
build() {
    (cd "$project_root" && ABLA_SYSROOT="$2" "$compiler" build \
        tests/cases/wasm-debug-reproducible/build.ab \
        -o "$output_directory/build-driver" --no-cache)
    mkdir -p "$output_directory/$1"
    cp "$module" "$module.map" "$module.debug.wasm" "$output_directory/$1/"
    if [ -f "$module.ll" ]; then cp "$module.ll" "$output_directory/$1/"; fi
}
# normalized NAME ROOT: the map and the DWARF line table with ROOT as a token.
normalized() {
    sed "s#$2#SYSROOT#g" "$output_directory/$1/module.wasm.map" \
        > "$output_directory/$1/map.normalized"
    llvm-dwarfdump --debug-line "$output_directory/$1/module.wasm.debug.wasm" |
        grep -v 'file format' | sed "s#$2#SYSROOT#g" \
        > "$output_directory/$1/lines.normalized"
}
fail() {
    echo "wasm debug reproducibility: $1" >&2
    exit 1
}

build first "$short"
build second "$short"
build longer "$long"
for file in module.wasm module.wasm.map module.wasm.debug.wasm; do
    cmp -s "$output_directory/first/$file" "$output_directory/second/$file" ||
        fail "$file differs between two builds"
done
cmp -s "$output_directory/first/module.wasm" "$output_directory/longer/module.wasm" ||
    fail "module.wasm differs between sysroot paths"
normalized first "$short"
normalized longer "$long"
cmp -s "$output_directory/first/map.normalized" \
    "$output_directory/longer/map.normalized" ||
    fail "the source map differs between sysroot paths"
cmp -s "$output_directory/first/lines.normalized" \
    "$output_directory/longer/lines.normalized" ||
    fail "the DWARF line table differs between sysroot paths"
if strings "$output_directory/first/module.wasm.debug.wasm" |
    grep -q 'module\.wasm\.tmp\.'; then
    fail "the DWARF module names a temporary file"
fi

# A function's line is its declaration's line in its file.
ABLA_KEEP_LLVM_TEXT=1 build text "$long"
# declared_line MODULE FUNCTION: its subprogram's line (a rewritten name keeps
# its module prefix).
declared_line() {
    grep -o "DISubprogram(name: \"$1\.\(__abla_module_[0-9a-f]*__\)\{0,1\}$2\"[^)]*" \
        "$output_directory/text/module.wasm.ll" |
        grep -o ' line: [0-9]*' | head -1 | grep -o '[0-9]*'
}
source_line() {
    grep -n "fun $2(" "$1" | head -1 | cut -d: -f1
}
for check in \
    "shapes|perimeter|$project_root/tests/cases/wasm-debug-reproducible/shapes.ab" \
    "main|total|$project_root/tests/cases/wasm-debug-reproducible/main.ab" \
    "wasm|__ablaRuntimeWasmBump|$sysroot/stdlib/abla/runtime/platform/wasm.ab"
do
    IFS='|' read -r module function file <<< "$check"
    declared=$(declared_line "$module" "$function")
    expected=$(source_line "$file" "$function")
    [ -n "$declared" ] || fail "no subprogram for $module.$function"
    [ "$declared" = "$expected" ] ||
        fail "$module.$function is at line $declared, declared at $expected"
done
