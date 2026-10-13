#!/usr/bin/env bash
# A `void` main, and a main without a result type, exit 0 after they return.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/main-void"
mkdir -p "$output_directory"

check() {
    "$compiler" build "$project_root/tests/cases/modules/$1.ab" \
        -o "$output_directory/$1" --no-cache
    set +e
    output=$("$output_directory/$1")
    status=$?
    set -e
    [[ $status -eq 0 && $output == "$2" ]] || exit 1
}

check main-void "void main"
check main-unannotated "unannotated main"
echo "main void: exits 0"
