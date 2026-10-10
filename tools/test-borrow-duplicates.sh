#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/borrow-duplicates"
cases="$project_root/tests/cases/borrow-duplicates"
mkdir -p "$output_directory"

# A method and an extension of the same name on one class name different
# borrow sources; the later declaration wins, in either order. The borrow
# checker finds them through a name index, which must keep that order.
"$compiler" build "$cases/later-extension.ab" -o "$output_directory/later-extension" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/later-extension"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "borrow-duplicates: the later extension's borrow source: expected 42, got $status" >&2
    exit 1
fi

set +e
"$compiler" --emit-llvm "$cases/later-method.ab" >"$output_directory/later-method.out" 2>&1
status=$?
set -e
if [[ $status -ne 1 ]] ||
    ! grep -Fq 'error[E_BORROW_CONFLICT]: in `main`, `left` is changed while `picked`' \
        "$output_directory/later-method.out"; then
    echo "borrow-duplicates: the later method's borrow source was not enforced (exit $status)" >&2
    sed -n '1,20p' "$output_directory/later-method.out" >&2
    exit 1
fi

echo "borrow-duplicates: the later of a method and an extension of the same name gives the borrow source, in either order"
