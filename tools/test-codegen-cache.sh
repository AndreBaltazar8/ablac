#!/usr/bin/env bash
# The code generation cache (src/codegen_units.ab): a unit's object is kept under
# a key of the unit's module, so a build reuses every unit nothing changed in,
# and gives the same object whether it reused them or not. An edit to one
# source file generates only its units again. On macOS the debug map names the
# cache's objects. A cache past ABLA_CODEGEN_CACHE_MB loses its oldest objects.
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
output_directory="$project_root/build/codegen-cache"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
cache="$output_directory/cache"
fail() {
    echo "codegen cache: $1" >&2
    exit 1
}
# (Every module is cut, however small, and says how many units it reused.)
units() {
    ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0 ABLA_CODEGEN_UNITS_TRACE=1 \
        "$compiler" build "$@" --fast --no-cache --cache-dir "$cache"
}
reused() { sed -n 's/^codegen units: .* \([0-9]*\) reused$/\1/p' "$1"; }

source="$output_directory/program.ab"
cp tests/cases/modules/collections.ab "$source"
units "$source" -o "$output_directory/program" 2> "$output_directory/cold.trace" ||
    { cat "$output_directory/cold.trace" >&2; fail "the cold build failed"; }
[[ $(reused "$output_directory/cold.trace") == 0 ]] || fail "a cold cache reused a unit"
cp "$output_directory/program.o" "$output_directory/cold.o"
units "$source" -o "$output_directory/program" 2> "$output_directory/warm.trace"
ran() { sed -n 's/^codegen units: .* the data, \([0-9]*\) with code.*/\1/p' "$1"; }
units_run=$(ran "$output_directory/warm.trace")
[[ $(reused "$output_directory/warm.trace") == "$units_run" ]] ||
    fail "a warm build reused $(reused "$output_directory/warm.trace") of $units_run units"
cmp -s "$output_directory/program.o" "$output_directory/cold.o" ||
    fail "the warm build's object differs from the cold one's"
"$output_directory/program" || [[ $? == 42 ]] || fail "the warm build's program failed"

# macOS: the executable's debug map names the archive's members.
if [[ $(uname) == Darwin ]]; then
    debug_map=$(nm -ap "$output_directory/program")
    named=$(grep -c " OSO $output_directory/program.o(unit[0-9]\.o)\$" <<< "$debug_map" || true)
    [[ $named -ge 2 ]] || fail "the debug map names $named units"
fi

# An edit to one function generates its file's units again, not the standard
# library's; the result is the build without the cache's, byte for byte (at the
# same path: the executable names its object).
sed -i.bak 's/values.size + values\[0\]/values.size + 0 + values[0]/' "$source"
units "$source" -o "$output_directory/program" 2> "$output_directory/edit.trace"
edit_reused=$(reused "$output_directory/edit.trace")
[[ $edit_reused -ge $((units_run - 2)) && $edit_reused -lt $units_run ]] ||
    fail "an edit reused $edit_reused of $units_run units"
"$output_directory/program" || [[ $? == 42 ]] || fail "the edited program failed"
cp "$output_directory/program.o" "$output_directory/edit.o"
ABLA_CODEGEN_CACHE=0 ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0 \
    "$compiler" build "$source" -o "$output_directory/program" --fast --no-cache 2> /dev/null
cmp -s "$output_directory/program.o" "$output_directory/edit.o" ||
    fail "the edited program's object differs from the build without the cache"

# WebAssembly, with exception handling: a second build reuses every unit and
# gives the same module.
wasm_build() { # $1 = where to keep the modules
    rm -rf "$output_directory/wasm"
    mkdir -p "$output_directory/wasm"
    ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0 ABLA_CODEGEN_UNITS_TRACE=1 \
        "$compiler" build tests/cases/codegen-cache/wasm-build.ab -o "$output_directory/wasm-driver" \
        --no-cache --cache-dir "$cache" 2> "$output_directory/$1.trace" ||
        { cat "$output_directory/$1.trace" >&2; fail "the WebAssembly build ($1) failed"; }
    "$output_directory/wasm-driver"
    mv "$output_directory/wasm" "$output_directory/$1"
}
wasm_build wasm-cold
wasm_build wasm-warm
[[ $(grep -cE ' ([0-9]+) with code, .* \1 reused$' "$output_directory/wasm-warm.trace") == 2 ]] ||
    fail "a warm WebAssembly build did not reuse every unit"
for module in unwinding plain; do
    cmp -s "$output_directory/wasm-cold/$module.wasm" "$output_directory/wasm-warm/$module.wasm" ||
        fail "$module.wasm: the warm build differs from the cold one"
done

# Past its size, the cache keeps only what the last build used.
before=$(find "$cache/codegen" -name '*.o' | wc -l)
ABLA_CODEGEN_CACHE_MB=0 units tests/cases/modules/classes.ab -o "$output_directory/classes" 2> /dev/null
after=$(find "$cache/codegen" -name '*.o' | wc -l)
[[ $after -le 9 && $after -lt $before ]] || fail "a full cache kept $after of $before objects"
echo "codegen cache: a warm build reuses every unit and gives the same object; an edit reuses $edit_reused of $units_run; WebAssembly too; a full cache sheds its oldest objects"
