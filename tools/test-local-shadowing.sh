#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/local-shadowing"
mkdir -p "$output_directory"

# A nested block's local shadows a parameter, an outer local or a field, and
# the outer binding returns when the block ends: natively, in the
# compile-time evaluator, and in WebAssembly.
"$compiler" build "$project_root/tests/cases/local-shadowing/main.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "local-shadowing: expected 42, got $status" >&2
    exit 1
fi

(cd "$project_root" && "$compiler" build tests/cases/local-shadowing/build.ab \
    -o "$output_directory/build-driver" --no-cache)
"$output_directory/build-driver"
node "$project_root/tests/cases/local-shadowing/run.mjs" \
    "$output_directory/local-shadowing.wasm"

# A local of a function's or lambda's body block redeclaring one of its
# parameters is rejected, as two locals of one block are.
fixtures=(
    "invalid-local-shadows-parameter:local.shadows-parameter:flag"
    "invalid-local-shadows-lambda-parameter:local.shadows-parameter:amount"
)
for entry in "${fixtures[@]}"; do
    fixture=${entry%%:*}
    expected=${entry#*:}
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    status=$?
    set -e
    if [[ $status -ne 1 ]] || ! grep -Fq "$expected" "$output.err"; then
        echo "local-shadowing: $fixture was not rejected with $expected" >&2
        sed -n '1,40p' "$output.err" >&2
        exit 1
    fi
    if [[ -e $output ]]; then
        echo "local-shadowing: $fixture produced an executable" >&2
        exit 1
    fi
done

echo "local-shadowing: parameter/local/field shadowing native, compile-time and wasm checks passed"
