#!/usr/bin/env bash
# A raw JSON node (jsonRaw / jsonRawUnchecked) is written verbatim by jsonStringify at the root, in arrays and in
# objects, at any size; jsonRaw accepts exactly one well-formed value; jsonParse never yields one
# (tests/cases/json-raw): fast and release builds. A copy that expects different text must fail.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/json-raw"
mkdir -p "$out"
source="$project_root/tests/cases/json-raw/main.ab"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$out/program" $mode --no-cache
    set +e
    "$out/program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "json raw: status $status (mode '$mode')" >&2; exit 1; }
done
mutated="$out/mutated.ab"
sed 's|"\[\[1, {\\"a\\":\\"b\\"} ,null\],null,\[1, {\\"a\\":\\"b\\"} ,null\]\]"|"[[1,{\\"a\\":\\"b\\"},null],null,[1,{\\"a\\":\\"b\\"},null]]"|' "$source" > "$mutated"
cmp -s "$mutated" "$source" && { echo "json raw: the negative control changed nothing" >&2; exit 1; }
"$compiler" build "$mutated" -o "$out/mutated" --fast --no-cache
set +e
"$out/mutated" > "$out/mutated.log" 2>&1
status=$?
set -e
[[ $status -eq 1 ]] && grep -q 'array: got' "$out/mutated.log" ||
    { echo "json raw: the negative control was not caught" >&2; exit 1; }
echo "json raw: raw nodes are written verbatim, jsonRaw checks its text, parsed trees are never raw"
