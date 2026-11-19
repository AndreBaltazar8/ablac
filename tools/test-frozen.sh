#!/usr/bin/env bash
# Frozen groups (docs/design/frozen-heap.md): a graph copied into read-only memory the collector neither marks nor sweeps.
# tests/cases/frozen: graph (sharing, a cycle, ropes, array slack, scalars; unchanged across collections), limits (more live groups than the table holds: refused, value returned whole), churn (groups
# returned whole and their address space reused: more freezing than the window holds), threads (readers and a collector
# beside a freeze), fork (a child reads, collects and freezes), and fault (a store into a frozen object faults, never a silent
# write). Each runs release and --fast; graph, threads and fork also under ABLA_GC_STRESS=1 (a collection at every safe point).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux ]]; then echo 'frozen: Linux only (the window and its protection use system calls)'; exit 0; fi
out=build/frozen
rm -rf "$out"
mkdir -p "$out"
fail() { echo "frozen: $1" >&2; exit 1; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    for name in graph churn limits threads fork fault; do
        "$compiler" build "tests/cases/frozen/$name.ab" -o "$out/$name.$mode" "${flags[@]}" > "$out/$name.$mode.build" 2>&1 \
            || { cat "$out/$name.$mode.build" >&2; fail "$name ($mode) did not build"; }
    done
    for name in graph churn limits threads fork; do
        status=0
        result=$("$root/tools/run-limited.sh" "$out/$name.$mode" 2>&1) || status=$?
        [[ $status -eq 0 && $result == *"frozen $name ok"* ]] || fail "$name ($mode) failed ($status): $result"
        printf '%s (%s): %s\n' "$name" "$mode" "$(printf '%s\n' "$result" | tail -n 1)"
    done
    for name in graph threads fork; do
        status=0
        result=$(ABLA_GC_STRESS=1 "$root/tools/run-limited.sh" "$out/$name.$mode" 2>&1) || status=$?
        [[ $status -eq 0 && $result == *"frozen $name ok"* ]] || fail "$name ($mode, GC stress) failed ($status): $result"
    done
    status=0
    result=$("$root/tools/run-limited.sh" "$out/fault.$mode" 2>&1) || status=$?
    # The program's own lines, not the whole result: run-limited's crash line names the script's path, and a checkout whose
    # path has the word "after" in it (a worktree called release-after) must not look like the program printed `after`.
    [[ $status -ne 0 ]] && grep -qx 'before 1' <<<"$result" && ! grep -q '^after ' <<<"$result" \
        || fail "fault ($mode): a store into a frozen object did not fault (status $status): $result"
    echo "fault ($mode): the store faulted ($status)"
done
echo 'frozen: graph, churn, threads, fork and fault pass, release and --fast, and graph, threads and fork under GC stress'
