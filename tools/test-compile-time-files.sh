#!/usr/bin/env bash
# Under `#`, file writes, directories, moves and removals are staged and
# published only when the build succeeds; compile-time code sees the disk with
# the staging laid over it, so the same operations agree at run time and under
# `#`, and a failed build leaves the disk as it was.
set -euo pipefail

compiler=${1:-build/ablac.bin}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/compile-time-files"
work="$project_root/build/compile-time-files-test"
rm -rf "$work"
mkdir -p "$work"
cp "$cases"/*.ab "$cases/abla.toml" "$work/"
cd "$work"

"$compiler" build view.ab -o view --no-cache
output=$(./view)
runtime=$(sed -n 1p <<<"$output")
staged=$(sed -n 2p <<<"$output")
expected='true true true true true 2 true true true one two false:2 true true false'
[[ $runtime == "$expected" && $staged == "$expected" ]] || {
    echo "compile-time files: run time and \`#\` disagree:"; echo "$output"; exit 1
}
[[ ! -e build/compile-time-files/view ]] || {
    echo "compile-time files: the view case left files behind"; exit 1
}

mkdir -p build/compile-time-files/publish build/compile-time-files/failed
printf 'old' > build/compile-time-files/publish/old.txt
printf 'gone' > build/compile-time-files/publish/gone.txt
printf 'kept' > build/compile-time-files/failed/old.txt
"$compiler" build publish.ab -o publish --no-cache
./publish && status=0 || status=$?
[[ $status -eq 4 ]] || { echo "compile-time files: publish staged $status of 4"; exit 1; }
[[ $(cat build/compile-time-files/publish/written.txt) == written ]]
[[ -d build/compile-time-files/publish/made ]]
[[ ! -e build/compile-time-files/publish/old.txt ]]
[[ $(cat build/compile-time-files/publish/moved.txt) == old ]]
[[ ! -e build/compile-time-files/publish/gone.txt ]]

if "$compiler" build publish-failed.ab -o failed --no-cache > failed.err 2>&1; then
    echo "compile-time files: the failing build built"; exit 1
fi
[[ ! -e build/compile-time-files/failed/written.txt ]]
[[ $(cat build/compile-time-files/failed/old.txt) == kept ]]
echo "compile-time files: staged writes, moves and removals agree with run time and publish on success"
