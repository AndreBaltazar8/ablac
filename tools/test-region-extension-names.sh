#!/usr/bin/env bash
# An extension function is in the region summary as `Owner.name`: one that
# keeps its receiver (Node.floor) makes a member call `node.floor()` in a region
# region.call-retention, and leaves a free function of its name (`floor`) and
# its callers callable there. abla/math, abla/math/fast and abla/math/v8 (whose
# large-argument sin and cos call `floor` in a region) each build beside that
# extension as release and development WebAssembly.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/region-extension-names"
output_directory="$project_root/build/region-extension-names"
rm -rf "$output_directory"
mkdir -p "$output_directory"

"$compiler" build "$cases/allowed.ab" -o "$output_directory/allowed" --no-cache
status=0
"$project_root/tools/run-limited.sh" "$output_directory/allowed" || status=$?
[[ $status == 42 ]] ||
    { echo "region extension names: allowed exited $status, not 42" >&2; exit 1; }

if "$compiler" build "$cases/refused.ab" -o "$output_directory/refused" \
    --no-cache > "$output_directory/refused.err" 2>&1; then
    echo "region extension names: refused.ab compiled" >&2; exit 1
fi
grep -qxF 'error[E_SEMANTIC]: region.call-retention:floor' "$output_directory/refused.err" ||
    { echo "region extension names: Node.floor not refused" >&2; cat "$output_directory/refused.err" >&2; exit 1; }

(cd "$project_root" && "$compiler" build "$cases/build.ab" \
    -o "$output_directory/build-driver" --no-cache)
(cd "$project_root" && "$output_directory/build-driver")
for module in math math-dev fast fast-dev v8 v8-dev; do
    [[ -s $output_directory/$module.wasm ]] ||
        { echo "region extension names: $module.wasm not built" >&2; exit 1; }
done
echo "region extension names: an extension is reached by member calls only; abla/math, /fast and /v8 build for wasm (release, development) beside one"
