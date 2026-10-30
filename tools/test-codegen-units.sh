#!/usr/bin/env bash
# Code generation units (src/codegen_units.ab): a fast build cut into eight
# units after optimization runs as the one-object build does and defines the
# same symbols, and building it twice gives the same bytes. Native programs,
# and WebAssembly modules with and without exception handling.
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
output_directory="$project_root/build/codegen-units"
rm -rf "$output_directory"
mkdir -p "$output_directory/again"
cd "$project_root"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
# Units without the code generation cache (tools/test-codegen-cache.sh has it).
export ABLA_CODEGEN_CACHE=0
if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
fail() {
    echo "codegen units: $1" >&2
    exit 1
}
one() { ABLA_CODEGEN_UNITS=1 "$@"; }
# (Every module is cut, however small, and says so.)
units() { ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0 ABLA_CODEGEN_UNITS_TRACE=1 "$@"; }
# A program's defined external symbols, without the names units give locals.
symbols() { llvm-nm -g --defined-only "$1" | awk '{print $NF}' | grep -v '__abla_unit\.' | sort; }

# Native units are only for a Mach-O executable's object, built from the
# module held in process (toolchain.ab nativeUnits); elsewhere a native build
# is one object, so only WebAssembly is cut.
native_cases=()
if [[ $(uname) == Darwin ]]; then
    native_cases=(closure-captures collections classes defer strings-runtime global-init-template-call)
fi
for case in "${native_cases[@]}"; do
    source="tests/cases/modules/$case.ab"
    one "$compiler" build "$source" -o "$output_directory/$case-one" --fast --no-cache
    units "$compiler" build "$source" -o "$output_directory/$case-units" --fast --no-cache \
        2> "$output_directory/$case.trace" || { cat "$output_directory/$case.trace" >&2; fail "$case: the units build failed"; }
    grep -q '^codegen units: 8 units' "$output_directory/$case.trace" || fail "$case was not cut into units"
    # (At another path: the object names no directory.)
    units "$compiler" build "$source" -o "$output_directory/again/$case" --fast --no-cache 2> /dev/null
    cmp -s "$output_directory/$case-units.o" "$output_directory/again/$case.o" ||
        fail "$case: two builds in units differ"
    ! LC_ALL=C grep -q "$output_directory" "$output_directory/$case-units.o" ||
        fail "$case: the object names the directory it was built in"
    set +e
    expected=$("$output_directory/$case-one" 2>&1)
    expected_status=$?
    actual=$("$output_directory/$case-units" 2>&1)
    actual_status=$?
    set -e
    [[ $expected == "$actual" && $expected_status == "$actual_status" ]] ||
        fail "$case: in units it exited $actual_status (not $expected_status) or printed otherwise"
    cmp -s <(symbols "$output_directory/$case-one") <(symbols "$output_directory/$case-units") ||
        fail "$case: the defined symbols differ"
    # macOS: the object is an archive of the units (the data's, and those of
    # the 8 of functions that have any: they go to units by their source
    # file, so a small program leaves some empty), whose members with DWARF the
    # executable's debug map names.
    if [[ $(uname) == Darwin ]]; then
        members=$(llvm-ar t "$output_directory/$case-units.o")
        [[ $members == unit0.o$'\n'* && $(wc -l <<< "$members") -ge 3 ]] ||
            fail "$case: the object is not an archive of the units: $members"
        # (A unit of only the backend's own functions has no DWARF.)
        named=$(nm -ap "$output_directory/$case-units" | sed -n "s#.* OSO $output_directory/$case-units.o(\(.*\))\$#\1#p")
        [[ -n $named ]] || fail "$case: the debug map names no unit"
        for member in $named; do
            [[ $'\n'$members$'\n' == *$'\n'$member$'\n'* ]] || fail "$case: the debug map names $member, not a member"
        done
    fi
done

# WebAssembly: the modules land in build/codegen-units/wasm, kept aside per build.
wasm_build() { # $1 = one or units, $2 = where to keep the modules
    rm -rf "$output_directory/wasm"
    mkdir -p "$output_directory/wasm"
    "$1" "$compiler" build tests/cases/codegen-units/wasm-build.ab \
        -o "$output_directory/wasm-driver" --no-cache 2> "$output_directory/$2.trace" ||
        { cat "$output_directory/$2.trace" >&2; fail "the WebAssembly build ($2) failed"; }
    "$output_directory/wasm-driver"
    mv "$output_directory/wasm" "$output_directory/$2"
}
wasm_build one wasm-one
wasm_build units wasm-units
wasm_build units wasm-again
[[ $(grep -c '^codegen units: 8 units' "$output_directory/wasm-units.trace") == 2 ]] ||
    fail "the WebAssembly modules were not cut into units"
for module in unwinding plain; do
    cmp -s "$output_directory/wasm-units/$module.wasm" "$output_directory/wasm-again/$module.wasm" ||
        fail "$module.wasm: two builds in units differ"
    [[ $("$wasm_runner" tests/cases/codegen-units/interface.mjs "$output_directory/wasm-one/$module.wasm") == \
       $("$wasm_runner" tests/cases/codegen-units/interface.mjs "$output_directory/wasm-units/$module.wasm") ]] ||
        fail "$module.wasm: the imports or exports differ"
    [[ $("$wasm_runner" tests/cases/stm/unwinding/sections.mjs "$output_directory/wasm-one/$module.wasm") == \
       $("$wasm_runner" tests/cases/stm/unwinding/sections.mjs "$output_directory/wasm-units/$module.wasm") ]] ||
        fail "$module.wasm: the tag section differs"
done
[[ $("$wasm_runner" tests/cases/stm/run.mjs "$output_directory/wasm-units/unwinding.wasm") == 0 ]] ||
    fail "unwinding.wasm in units: checks failed"
echo "codegen units: ${native_cases[*]:+native and }WebAssembly (exception handling too) as one unit and as eight: same results, symbols and interface; reproducible"
