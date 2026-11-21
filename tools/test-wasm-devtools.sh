#!/usr/bin/env bash
# A development WebAssembly module in a browser's developer tools (headless Chrome, where one is installed;
# skipped otherwise): its source map resolves, a breakpoint at an Abla line pauses there, the frame is named after
# its Abla function, and stepping over a line does not stop in the standard library's code inlined into it (the
# map's ignore list). tools/wasm-devtools-check.mjs drives the browser.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
chrome=${ABLA_CHROME:-}
for candidate in google-chrome-stable google-chrome chromium chromium-browser; do
    [[ -n $chrome ]] && break
    chrome=$(command -v "$candidate" 2>/dev/null || true)
done
if [[ -z $chrome ]] || ! command -v node >/dev/null 2>&1; then
    echo 'wasm devtools: skipped (no Chrome or no node)'
    exit 0
fi
out="$project_root/build/wasm-devtools"
rm -rf "$out"
mkdir -p "$out"
export ABLA_DEBUG=1
(cd "$project_root" && "$compiler" build tests/cases/wasm-devtools/build.ab -o "$out/build-driver" --no-cache &&
    "$out/build-driver")
cp "$project_root/tests/cases/wasm-devtools/page.html" "$out/page.html"
timeout 120 node "$project_root/tools/wasm-devtools-check.mjs" "$out" "$chrome" 13
echo 'wasm devtools: the map resolves, a breakpoint pauses at its Abla line in a named frame, stepping stays in the program'
