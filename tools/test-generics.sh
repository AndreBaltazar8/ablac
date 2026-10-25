#!/usr/bin/env bash
# Generic functions, extensions and classes (src/generics.ab): the cases compute
# what they should built ahead of time and under `ablac run`, private
# generics and a strict-imports package's work, each misuse is
# the error it should be (naming the instance where one is at fault), and an
# edit to a generic's body rebuilds its instances with the build cache.
set -euo pipefail
compiler=${1:-build/ablac}
# The incremental case builds from another directory: keep a relative compiler
# path pointing where it did.
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/generics
output_directory=$project_root/build/generics
mkdir -p "$output_directory"

run() { # program...
    local status
    set +e
    ABLA_MAX_SECONDS=120 "$project_root/tools/run-limited.sh" "$@" 2>&1
    status=$?
    set -e
    echo "status $status"
}

# Built under each compile-time evaluator: `#` code runs per instance.
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/main.ab" -o "$output_directory/generics" --no-cache
    output=$(run "$output_directory/generics")
    [[ $output == $'generics: 0 failed\nstatus 42' ]] ||
        { echo "generics ($mode): $output" >&2; exit 1; }
done
output=$(run "$compiler" run "$cases/main.ab")
[[ $output == $'generics: 0 failed\nstatus 42' ]] ||
    { echo "generics (ablac run): $output" >&2; exit 1; }

# A private generic stays its module's (another module's public generic of
# the same name is another generic), and is private there; a strict-imports
# package's generic sees its own module's imports wherever it is used.
"$compiler" build "$cases/private/main.ab" -o "$output_directory/private" --no-cache
output=$(run "$output_directory/private")
[[ $output == $'4 lib 2 s! 2 main\nstatus 42' ]] ||
    { echo "generics, private: $output" >&2; exit 1; }
set +e
log=$("$compiler" build "$cases/private/use-private.ab" -o "$output_directory/use-private" --no-cache 2>&1)
status=$?
set -e
[[ $status != 0 && $log == *"name.private:cached:"* ]] ||
    { echo "generics, private use: $log" >&2; exit 1; }
set +e
log=$("$compiler" build "$cases/private/use-private-extension.ab" -o "$output_directory/use-private" --no-cache 2>&1)
status=$?
set -e
[[ $status != 0 && $log == *"name.private:array:i64.lastOne:"* ]] ||
    { echo "generics, private extension use: $log" >&2; exit 1; }
"$compiler" build "$cases/strict/main.ab" -o "$output_directory/strict" --no-cache
output=$(run "$output_directory/strict")
[[ $output == $'<3> <s> 2\nstatus 42' ]] ||
    { echo "generics, strict imports: $output" >&2; exit 1; }

# The compiler API: instances listed, type arguments read, and an instance
# made because a transform asked for it (under each evaluator).
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/api/main.ab" -o "$output_directory/api" --no-cache
    output=$(run "$output_directory/api")
    [[ $output == $'1 2 true\n Box<string> Box<i64> | first<Square> first<i64> | Box<i64>: i64 | true: Square string bool | Box<i64> true\nstatus 42' ]] ||
        { echo "generics, compiler API ($mode): $output" >&2; exit 1; }
done

# `compiler.instantiate` from a `#` site: the instance is made for the next
# round of lowering; a site that never settles stops after 8 rounds.
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/rounds/made.ab" -o "$output_directory/made" --no-cache
    output=$(run "$output_directory/made")
    [[ $output == $'1 Box<string> true true 2\nstatus 42' ]] ||
        { echo "generics, instantiate from # ($mode): $output" >&2; exit 1; }
    set +e
    log=$(ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/rounds/fixpoint.ab" -o "$output_directory/fixpoint" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status != 0 && $log == *"E_COMPILE_EDIT_FIXPOINT"* &&
       $log == *"instantiate \`"*"fixpoint.ab:Box<Box<"*"(round 8: "*"fixpoint.ab:"* ]] ||
        { echo "generics, instantiation fixpoint ($mode): $log" >&2; exit 1; }
done

# Each error case, against its lines in expected.txt.
expected_file=$cases/errors/expected.txt
for source in "$cases"/errors/*.ab; do
    name=$(basename "$source" .ab)
    expected=$(awk -v name="$name" '
        /^[a-z-]+$/ { current = $0; next }
        current == name { print }' "$expected_file")
    set +e
    log=$("$compiler" build "$source" -o "$output_directory/error-$name" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status != 0 ]] || { echo "generics: errors/$name built" >&2; exit 1; }
    actual=$(grep -E '^(error|context)\[' <<< "$log" || true)
    [[ $actual == "$expected" ]] ||
        { printf 'generics: errors/%s:\nexpected:\n%s\ngot:\n%s\n' "$name" "$expected" "$log" >&2; exit 1; }
done

# A class's generic method keeps its class's name in debug information (and
# so in traces): `<module>.Sack.remap`, not the extension it is made into.
"$compiler" build "$cases/methods-label.ab" -o "$output_directory/methods-label.o" \
    --emit object -g --no-cache
llvm-dwarfdump --debug-info "$output_directory/methods-label.o" > "$output_directory/methods-label.dwarf"
grep -Fq '"methods-label.Sack.remap"' "$output_directory/methods-label.dwarf" ||
    { echo "generics: a generic method's instance isn't named Sack.remap in debug information" >&2; exit 1; }

# The incremental case, built with the build cache before and after the edit.
work=$output_directory/incremental
rm -rf "$work"
mkdir -p "$work"
cp "$cases/incremental/main.ab" "$cases/incremental/library.ab" "$work/"
incremental() { # expected output
    (cd "$work" && "$compiler" build main.ab -o program > build.log 2>&1) ||
        { cat "$work/build.log" >&2; exit 1; }
    local output
    output=$(run "$work/program")
    [[ $output == "$1"$'\nstatus 0' ]] ||
        { echo "generics, incremental: $output" >&2; exit 1; }
}
incremental $'first 1\n2'
cp "$cases/incremental/library-edited.ab" "$work/library.ab"
incremental $'second 1\n3'

echo "generics: generic functions, extensions and classes compute what they should (built and under ablac run), private and strict-imports generics resolve, the compiler API reads and makes instances, misuses are the errors they should be, and an edited generic rebuilds its instances"
