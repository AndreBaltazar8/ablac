#!/usr/bin/env bash
# A hook (an `@exportLocal` or `@export` name) has one definer in a program. When a second declaration repeats a name, the error names the first one:
# `note: the export name "..." is already exported by `<function>`` and its place (`= note: `<function>` is declared at <file>:<line>:<column>`), with the
# place of the second declaration under the error itself. Checks, with the compiler under test:
#   1. two modules each define @exportLocal("abla_dup"): E_EXPORT_ANNOTATION, the note naming the first definer and the line of it in its module;
#   2. the same for @export (a global symbol);
#   3. a single definer builds and runs (the mutation check of 1 and 2: nothing is reported for a unique name).
# Usage: tools/test-export-duplicate.sh [compiler]       (default build/ablac)
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
out=$root/build/export-duplicate
rm -rf "${out:?}"
mkdir -p "$out"
fail() { echo "export-duplicate: $1" >&2; [[ ! -f ${2:-} ]] || cat "$2" >&2; exit 1; }
for kind in exportLocal export; do
    dir=$out/$kind
    mkdir -p "$dir"
    cat > "$dir/first.ab" <<ABLA
// a comment line, so the definer is not on line 1

@$kind("abla_dup")
fun firstDefinition(recv: int): bool = recv == 1
ABLA
    cat > "$dir/main.ab" <<ABLA
import "./first.ab"
noescape extern:"c" fun abla_dup(recv: int): bool
@$kind("abla_dup")
fun secondDefinition(recv: int): bool = recv == 2
fun main: int = if (abla_dup(2)) 0 else 1
ABLA
    if "$compiler" build "$dir/main.ab" -o "$dir/main.bin" --fast --no-cache > "$dir/main.log" 2>&1; then fail "$kind: two definers of one name built" "$dir/main.log"; fi
    grep -F 'error[E_EXPORT_ANNOTATION]: @'"$kind"' on `secondDefinition`' "$dir/main.log" > /dev/null || fail "$kind: not the E_EXPORT_ANNOTATION error" "$dir/main.log"
    grep -F 'is already exported by `firstDefinition`' "$dir/main.log" > /dev/null || fail "$kind: the error does not name the first definer" "$dir/main.log"
    grep -E '= note: `firstDefinition` is declared at .*first\.ab:3:1' "$dir/main.log" > /dev/null || fail "$kind: the first definer's place (first.ab:3:1) is not shown" "$dir/main.log"
    grep -E -- '--> .*main.ab:3:1' "$dir/main.log" > /dev/null || fail "$kind: the second definer's own place (main.ab:3:1) is not shown" "$dir/main.log"
done
# One definer: no error.
mkdir -p "$out/single"
cat > "$out/single/main.ab" <<'ABLA'
noescape extern:"c" fun abla_one(recv: int): bool
@exportLocal("abla_one")
fun onlyDefinition(recv: int): bool = recv == 2
fun main: int = if (abla_one(2)) 0 else 1
ABLA
"$compiler" build "$out/single/main.ab" -o "$out/single/main.bin" --fast --no-cache > "$out/single/main.log" 2>&1 || fail "single: a unique name did not build" "$out/single/main.log"
"$out/single/main.bin" || fail "single: the program returned non-zero"
echo "export-duplicate: a repeated export name names its first definer and its place, for @exportLocal and @export; a unique name builds"
