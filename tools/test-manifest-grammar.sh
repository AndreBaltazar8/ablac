#!/usr/bin/env bash
# The grammar of abla.toml and abla.lock the compiler's readers understand (src/manifest_grammar.ab, #1139 area 2, round 2): the minimal files that the readers read differently
# from a TOML parser are refused, the forms the repository's own manifests and locks use are admitted, and every abla.toml and abla.lock that git tracks in this repository is
# admitted (a few test fixtures are meant to be bad: tests/cases/manifest-grammar/fixtures.txt lists them), and the compiler itself refuses a project whose manifest is outside it.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/manifest-grammar
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/manifest-grammar/main.ab -o "$out/main" --fast --no-cache
result=$(tools/run-limited.sh "$out/main" | tail -1) || { echo "manifest grammar failed: $result" >&2; "$out/main" | head -20 >&2; exit 1; }
[[ $result == 'manifest grammar ok' ]] || { echo "manifest grammar: $result" >&2; exit 1; }
mapfile -t files < <(git ls-files | grep -E '(^|/)abla\.(toml|lock)$' | grep -vxFf tests/cases/manifest-grammar/fixtures.txt)
[[ ${#files[@]} -ge 100 ]] || { echo "manifest grammar: only ${#files[@]} manifests found" >&2; exit 1; }
problems=$("$out/main" "${files[@]}" || true)
[[ -z $problems ]] || { echo "manifest grammar: the repository has manifests the readers would refuse:" >&2; echo "$problems" | head -20 >&2; exit 1; }
echo "ok   the manifest grammar refuses what the readers misread and admits ${#files[@]} manifests and locks of the repository"
# The compiler refuses a project whose manifest is outside the grammar, naming the line, and builds the same project without the line.
project=$out/project
mkdir -p "$project/src"
printf 'fun main: int = 0\n' > "$project/src/main.ab"
printf 'name = "grammar-project"\nentry = "src/main.ab"\n' > "$project/abla.toml"
"$compiler" build --project "$project" -o "$out/good" --fast --no-cache > "$out/good.log" 2>&1 || { echo "manifest grammar: a plain manifest did not build" >&2; cat "$out/good.log" >&2; exit 1; }
printf 'name = "grammar-project"\nentry = "src/main.ab"\n\n[extra]\ncompileCapabilities = ["process.io"]\n' > "$project/abla.toml"
if "$compiler" build --project "$project" -o "$out/bad" --fast --no-cache > "$out/bad.log" 2>&1; then
    echo "manifest grammar: a manifest with a capability under another table built" >&2
    exit 1
fi
grep -q 'error\[E_PACKAGE_MANIFEST\].*line 5' "$out/bad.log" || { echo "manifest grammar: the refusal does not name E_PACKAGE_MANIFEST and the line:" >&2; cat "$out/bad.log" >&2; exit 1; }
# A dependency that hides in a string is not added; the manifest is refused instead.
printf 'name = "grammar-project"\nentry = "src/main.ab"\n\n[dependencies]\nnote = %s\nevil = { git = "https://example.test/e.git", rev = "0123456789abcdef0123456789abcdef01234567" }\n%s\n' "'''" "'''" > "$project/abla.toml"
if "$compiler" package update --project "$project" > "$out/hidden.log" 2>&1; then
    echo "manifest grammar: a dependency in a multi-line string was taken" >&2
    exit 1
fi
grep -q 'error\[E_PACKAGE_MANIFEST\]' "$out/hidden.log" || { echo "manifest grammar: a dependency in a string was not refused as E_PACKAGE_MANIFEST:" >&2; cat "$out/hidden.log" >&2; exit 1; }
echo "ok   the compiler refuses a manifest outside the grammar, naming the line"
