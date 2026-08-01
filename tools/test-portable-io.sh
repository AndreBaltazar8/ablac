#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/portable-io"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/portable-io.ab" \
    -o "$output_directory/program"

set +e
"$project_root/tools/run-limited.sh" "$output_directory/program" \
    > "$output_directory/actual.txt"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "portable io: expected status 42, got $status" >&2
    exit 1
fi

printf 'Hello, world!\nportable io\n' > "$output_directory/expected.txt"
if ! cmp "$output_directory/expected.txt" "$output_directory/actual.txt"; then
    echo 'portable io: println/print output mismatch' >&2
    exit 1
fi

echo 'portable io: target-backed libc-free print + println surface passed'
