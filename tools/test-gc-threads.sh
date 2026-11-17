#!/usr/bin/env bash
# Stop-the-world collection (#811): threads that allocate while the collector runs, and a thread held at a collection
# point while another collects. Each program is built once and run as it is, with a small collection growth and under
# ABLA_GC_STRESS=1 (every safe point collects, and what is freed is poisoned); each must exit 42, and the churn must
# have stopped threads (ABLA_GC_TRACE=1 says so on standard error). `blocked` keeps a thread in a sleep while another
# collects twenty times: none may be abandoned. `waiting` does the same with a thread waiting on the runtime's own
# condition (a transaction's retry) and `lock-wait` with one waiting for a Mutex another holds; both used to count as running.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
output_directory=build/gc-threads
rm -rf "$output_directory"
mkdir -p "$output_directory"

# A wall-clock limit: GNU timeout where there is one, the repository's limiter elsewhere (the Mac runners have no timeout).
limited() {
    if command -v timeout > /dev/null; then timeout 120 "$@"; else ABLA_MAX_SECONDS=120 tools/run-limited.sh "$@"; fi
}

fail() { echo "gc threads: $*" >&2; exit 1; }

for name in churn hold stale-claim manual blocked waiting lock-wait hammer echo; do
    "$compiler" build "tests/cases/gc-threads/$name.ab" -o "$output_directory/$name" --fast --no-cache \
        || fail "$name did not build"
done

for name in churn hold stale-claim manual blocked waiting lock-wait hammer echo; do
    # echo raced one run in two before the fix: run it several times.
    repeat=1; [[ $name == echo ]] && repeat=6
    for mode in "ABLA_GC_GROWTH=1048576" "ABLA_GC_STRESS=1"; do
      for ((round = 0; round < repeat; round++)); do
        status=0
        ( export "$mode" ABLA_GC_TRACE=1; limited "$output_directory/$name" ) \
            > "$output_directory/$name.out" 2> "$output_directory/$name.err" < /dev/null || status=$?
        [[ $status -eq 42 ]] || { cat "$output_directory/$name.out" "$output_directory/$name.err" >&2; fail "$name under $mode: status $status"; }
        if [[ $name == churn ]]; then
            grep -q '^gc: stopped [1-9] thread' "$output_directory/$name.err" \
                || fail "churn under $mode: no collection stopped another thread"
        fi
      done
    done
done
echo "gc threads: threads stop at safe points for a collection, a held thread's roots survive it, under growth and stress"
