#!/usr/bin/env bash
# The standard library keeps the functions that take a raw address out of its public modules (#1139 area 7, R3-2): `aesWipe(16, 8)` in a
# program must not compile, whichever way the program is built, and the library's own tests and tools reach such a function only
# through `--stdlib-internals`. Checks, each with the compiler under test:
#   1. a strict program naming aesWipe fails with E_NAME_NOT_IMPORTED ("internal to the standard library");
#   2. the same program built --flat-imports, in a package with visibility = "flat", and as a module of a dependency that says
#      visibility = "flat" fails the same way (flat modules were the way round);
#   3. the safe surface of the module still builds and runs;
#   4. with --stdlib-internals the program that imports the library's file by name builds and runs, prints the notice once on standard
#      error, and the same program without the flag fails (E_IMPORT_NOT_FOUND): the mutation check of 4;
# Usage: tools/test-stdlib-internals.sh [compiler]       (default build/ablac)
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
out=$root/build/stdlib-internals
rm -rf "${out:?}"
mkdir -p "$out/flat-package" "$out/dependency/dep" "$out/cache"

cat > "$out/wipe.ab" <<'ABLA'
import "abla/crypto/aes"
fun main: int {
    aesWipe(16, 8)
    0
}
ABLA
cp "$out/wipe.ab" "$out/flat-package/main.ab"
printf 'visibility = "flat"\n' > "$out/flat-package/abla.toml"
cat > "$out/dependency/main.ab" <<'ABLA'
import "dep/lib.ab"
fun main: int = depWipe()
ABLA
cat > "$out/dependency/dep/lib.ab" <<'ABLA'
import "abla/crypto/aes"
fun depWipe(): int {
    aesWipe(16, 8)
    0
}
ABLA
printf 'visibility = "flat"\n' > "$out/dependency/dep/abla.toml"
cat > "$out/safe.ab" <<'ABLA'
import "abla/crypto/aes"
fun main: int {
    val sealed = aesGcmEncrypt("0123456789abcdef", "0123456789ab", "hello", "")
    if (sealed.ok) 42 else 1
}
ABLA
cat > "$out/internal.ab" <<'ABLA'
import "abla/crypto/aes/raw.ab"
fun main: int {
    aesWipe(0, 0)
    42
}
ABLA

fail() { echo "stdlib-internals: $1" >&2; [[ ! -f ${2:-} ]] || cat "$2" >&2; exit 1; }
# rejected <name> <expected text> <compiler arguments...>: the build fails, and says the text
rejected() {
    local name=$1 text=$2
    shift 2
    if "$compiler" build "$@" --no-cache --fast -o "$out/$name.bin" > "$out/$name.err" 2>&1; then
        fail "$name: built, but the library's internal function must not be visible" "$out/$name.err"
    fi
    grep -F "$text" "$out/$name.err" > /dev/null || fail "$name: no \`$text\` in the diagnostic" "$out/$name.err"
}

rejected strict 'E_NAME_NOT_IMPORTED' "$out/wipe.ab"
grep -F '`aesWipe` is internal to the standard library' "$out/strict.err" > /dev/null || fail "strict: not the internal-file diagnostic" "$out/strict.err"
rejected flat-flag 'E_NAME_NOT_IMPORTED' "$out/wipe.ab" --flat-imports
rejected flat-package 'E_NAME_NOT_IMPORTED' "$out/flat-package/main.ab"
rejected flat-dependency 'E_NAME_NOT_IMPORTED' "$out/dependency/main.ab"
grep -F 'lib.ab' "$out/flat-dependency.err" > /dev/null || fail "flat-dependency: the error is not in the dependency's module" "$out/flat-dependency.err"

"$compiler" build "$out/safe.ab" --no-cache --fast -o "$out/safe.bin" > "$out/safe.err" 2>&1 || fail "safe: the public surface does not build" "$out/safe.err"
status=0
"$out/safe.bin" || status=$?
[[ $status == 42 ]] || fail "safe: the program returned $status, not 42"

"$compiler" build "$out/internal.ab" --stdlib-internals --fast -o "$out/internal.bin" > "$out/internal.err" 2>&1 ||
    fail "stdlib-internals: the library's own file does not build with the flag" "$out/internal.err"
[[ $(grep -c '^stdlib internals visible: test/tool builds only$' "$out/internal.err") == 1 ]] ||
    fail "stdlib-internals: the notice is not printed exactly once" "$out/internal.err"
status=0
"$out/internal.bin" || status=$?
[[ $status == 42 ]] || fail "stdlib-internals: the program returned $status, not 42"
# The same program without the flag: not found (nothing it was built with is cached either; tools/test-build-cache-inputs.sh stdlib-internals).
rejected without-flag 'E_IMPORT_NOT_FOUND' "$out/internal.ab" --cache-dir "$out/cache"
# A strict program is not helped by the flag: it still has to import what it names.
rejected flag-strict 'E_NAME_NOT_IMPORTED' "$out/wipe.ab" --stdlib-internals

echo "stdlib-internals: raw-address functions are hidden from strict, flat and dependency modules; --stdlib-internals reaches them by file name only"
