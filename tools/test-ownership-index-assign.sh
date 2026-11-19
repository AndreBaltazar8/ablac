#!/usr/bin/env bash
# `list[i] = item` is an ownership transfer (todo #1039): without `move(item)` it is refused (ownership.move-required), with it
# the replaced element is dropped once and the new one stays in the array. Before the check the store was accepted, `item` was
# dropped with the local while the array held it, and its resource (a TLS connection's AES key) was freed twice.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/ownership-index-assign
rm -rf "$out"
mkdir -p "$out"
cases=tests/cases/ownership-index-assign
if "$compiler" build "$cases/refused.ab" -o "$out/refused" --fast --no-cache > "$out/refused.log" 2>&1; then
    echo "ownership-index-assign: list[0] = item compiled without move" >&2
    exit 1
fi
grep -q 'ownership.move-required:index.assign:session' "$out/refused.log" || { cat "$out/refused.log" >&2; echo "ownership-index-assign: the refusal is not the move-required one" >&2; exit 1; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build "$cases/main.ab" -o "$out/main.$mode" "${flags[@]}" > "$out/main.$mode.build" 2>&1 || { cat "$out/main.$mode.build" >&2; echo "ownership-index-assign: main ($mode) did not build" >&2; exit 1; }
    result=$("$out/main.$mode" 2>&1) || { echo "ownership-index-assign ($mode): $result" >&2; exit 1; }
    [[ $result == *"ownership index assign ok: 3 drops"* ]] || { echo "ownership-index-assign ($mode): $result" >&2; exit 1; }
done
echo "ownership index assign: the store needs move, and drops each element once"
