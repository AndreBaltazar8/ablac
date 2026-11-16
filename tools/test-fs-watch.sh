#!/usr/bin/env bash
# abla/fs/watch (fileEvents): tests/cases/fs-watch/main.ab in a fresh directory. It waits on inotify on Linux and
# on kqueue on macOS, with no libc: a quiet wait times out, an in-place write, a save by rename and a removal are
# seen, and on Linux a write to another file of the directory is not. Runs on Linux and in test-macos-host.
# Usage: tools/test-fs-watch.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/fs-watch
rm -rf "$out"
mkdir -p "$out/files"
cd "$root"
"$compiler" build tests/cases/fs-watch/main.ab -o "$out/watch" --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
status=0
"$out/watch" "$out/files" > "$out/run.log" 2>&1 || status=$?
if [[ $status -ne 42 ]]; then
    echo "fs watch: exit $status, not 42:" >&2
    cat "$out/run.log" >&2
    exit 1
fi
echo "fs watch: $(grep -c ': ok$' "$out/run.log") checks ok"
