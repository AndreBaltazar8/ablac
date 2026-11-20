#!/usr/bin/env bash
# The YAML parser against the one before its plain-scalar and line-lookup changes (tests/cases/yaml-diff/old-yaml.ab): the same value or error over the YAML test-suite corpus, prefixes of each file and one-byte replacements. Usage: tools/test-yaml-diff.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/yaml-diff
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/yaml-diff/main.ab -o "$out/test" --no-cache
result=$(ABLA_MAX_SECONDS=1200 "$root/tools/run-limited.sh" "$out/test" tests/cases/yaml/corpus tests/cases/yaml/corpus.list) || { echo "yaml-diff: $result" >&2; exit 1; }
[[ $result == 'yaml-diff ok'* ]] || { echo "yaml-diff: $result" >&2; exit 1; }
echo "ok   $result"
