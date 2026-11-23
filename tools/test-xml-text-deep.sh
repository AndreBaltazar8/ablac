#!/usr/bin/env bash
# XmlElement.text() on a tree 300,000 levels deep (abla/xml tree.ab, xmlAppendText with a stack of its own; it overflowed the call stack from about 35,000 levels): release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/xml-text-deep
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/xml-text-deep/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "xml text deep ($mode) failed" >&2; exit 1; }
    [[ $result == 'xml text deep ok' ]] || { echo "xml text deep ($mode): $result" >&2; exit 1; }
done
echo "ok   XmlElement.text() on a tree 300,000 levels deep, release and --fast"
