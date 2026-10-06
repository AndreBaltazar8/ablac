#!/usr/bin/env bash
# Recursive copy and removal: removeTree removes a symbolic link, never what
# it points to.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
output_directory="$project_root/build/fs-tree"
rm -rf "$output_directory"
mkdir -p "$output_directory/work/source/sub" "$output_directory/work/outside"
printf 'a\n' > "$output_directory/work/source/a.txt"
printf 'bee\n' > "$output_directory/work/source/sub/b.txt"
printf 'sea\n' > "$output_directory/work/outside/c.txt"
ln -s ../outside "$output_directory/work/source/link"

"$compiler" build "$project_root/tests/cases/modules/fs-tree.ab" \
    -o "$output_directory/program" --no-cache
set +e
(cd "$output_directory/work" && "$output_directory/program")
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
[[ -f $output_directory/work/outside/c.txt ]] || exit 1
echo "fs tree: copy and remove trees; links are removed, not followed"
