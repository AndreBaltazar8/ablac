#!/usr/bin/env bash
# Guards any change that lets a boxed local (or parameter) read only by runtime readers share its slot
# instead of copying it (held: TODO "Per-call boxing in the lowering"); today every load copies.
# A local read only by runtime readers may share its slot instead of copying it;
# changing the local between the load and the last read must still read the old value.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/load-alias"
output_directory="$project_root/build/load-alias"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main"
set +e
"$output_directory/main"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "load-alias: case $status failed" >&2; exit 1; }
echo "load-alias: a changed local keeps the value an earlier load read"
