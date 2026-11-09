#!/usr/bin/env bash
# Raw invalid UTF-8 in a JSON text is rejected by jsonParse, jsonValidate and jsonDocument with the
# first bad sequence's byte offset, and valid multibyte text is accepted (tests/cases/json-utf8): fast and
# release builds. A copy that expects one offset too many must fail.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/json-utf8"
mkdir -p "$out"
source="$project_root/tests/cases/json-utf8/main.ab"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$out/program" $mode --no-cache
    set +e
    "$out/program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "json utf8: status $status (mode '$mode')" >&2; exit 1; }
done
mutated="$out/mutated.ab"
sed 's|check("0xff", "\[1,\\"\\xff\\"\]", 4)|check("0xff", "[1,\\"\\xff\\"]", 5)|' "$source" > "$mutated"
cmp -s "$mutated" "$source" && { echo "json utf8: the negative control changed nothing" >&2; exit 1; }
"$compiler" build "$mutated" -o "$out/mutated" --fast --no-cache
set +e
"$out/mutated" > "$out/mutated.log" 2>&1
status=$?
set -e
[[ $status -eq 1 ]] && grep -q '0xff' "$out/mutated.log" ||
    { echo "json utf8: the negative control was not caught" >&2; exit 1; }
echo "json utf8: invalid bytes rejected with their offsets by parse, validate and document; valid multibyte accepted"
