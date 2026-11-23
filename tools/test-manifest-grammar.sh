#!/usr/bin/env bash
# The grammar of abla.toml and abla.lock the compiler's readers understand (src/manifest_grammar.ab, #1139 area 2, round 2): the minimal files that the readers read differently
# from a TOML parser are refused, the forms the repository's own manifests and locks use are admitted, and every abla.toml and abla.lock that git tracks in this repository is
# admitted (a few test fixtures are meant to be bad: tests/cases/manifest-grammar/fixtures.txt lists them).
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
