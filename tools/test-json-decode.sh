#!/usr/bin/env bash
# jsonDecode / jsonDecodeDocument (abla/json, the typed outcome of decoding): the three cases (JsonParsed, JsonMalformed, JsonLimitExceeded), every error code in
# the right one, the same answers as jsonParse and jsonDocument, and a `when` that leaves a case out is an error (when.non-exhaustive). Release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/json-decode
rm -rf "${out:?}"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/json-decode/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode") || { echo "json-decode ($mode): $result" >&2; exit 1; }
    [[ $result == 'json-decode ok' ]] || { echo "json-decode ($mode): $result" >&2; exit 1; }
done
if "$compiler" build tests/cases/json-decode/invalid-missing-case.ab -o "$out/invalid" --no-cache --fast > "$out/invalid.out" 2>&1; then
    echo "json-decode: a when that leaves JsonLimitExceeded out compiled" >&2; exit 1
fi
grep -F 'when.non-exhaustive:JsonDecoded' "$out/invalid.out" > /dev/null || { echo "json-decode: the refusal is not when.non-exhaustive" >&2; cat "$out/invalid.out" >&2; exit 1; }
echo "ok   jsonDecode: three cases, every code in its case, same answers as jsonParse, a missing case is an error, release and --fast"
