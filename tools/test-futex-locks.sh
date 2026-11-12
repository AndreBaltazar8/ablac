#!/usr/bin/env bash
# The runtime's locks under contention (#806: futexes on x86-64 Linux):
# tests/cases/futex-locks, release and --fast, twenty runs each.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/futex-locks
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/futex-locks/main.ab -o "$out/$mode" "${flags[@]}"
    for run in $(seq 20); do
        actual=$("$out/$mode") || { printf 'futex locks (%s, run %s): %s\n' "$mode" "$run" "$actual" >&2; exit 1; }
    done
done
echo "$actual (release and --fast, 20 runs each)"
