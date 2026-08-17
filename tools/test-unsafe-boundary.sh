#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/unsafe-boundary"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/unsafe-boundary.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "unsafe-boundary: expected 42, got $status" >&2
    exit 1
fi

for fixture in invalid-unsafe-call invalid-unsafe-function; do
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq 'native.trust:' "$output.err"; then
        echo "native boundary: $fixture bypassed trusted-call checking" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    if [[ -e $output ]]; then
        echo "unsafe-boundary: $fixture produced an executable" >&2
        exit 1
    fi
done

echo "native boundary: trusted implementation + raw memory + closed-resource checks passed"
