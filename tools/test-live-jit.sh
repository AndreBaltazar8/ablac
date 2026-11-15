#!/usr/bin/env bash
# `ablac run --live` (docs/design/live-jit.md, src/backend/llvm/live.ab): every function of the
# program's own files is called through the live table, so that a later generation can redefine
# it. tests/cases/live-jit/calls.ab reaches functions every way a call can (direct, recursive, by
# value, by closure, from a thread, a generator, a method; struct, string and scalar results) and
# must print the same lines and exit 42 with and without --live, release (--o1) and --fast. The
# live runs must report that functions went through the table (ABLA_LIVE_TRACE), and a plain run
# must not. The object cache is off, so each run compiles.
# Then tests/cases/live-jit/reload.ab redefines its own functions while it runs (abla/live).
# Usage: tools/test-live-jit.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
cd "$root"
out=build/live-jit
rm -rf "$out"
mkdir -p "$out"
export ABLA_JIT_CACHE=0 ABLA_LIVE_TRACE=1
program=tests/cases/live-jit/calls.ab
run() {
    local name=$1
    shift
    local status=0
    "$compiler" run "$@" "$program" > "$out/$name.out" 2> "$out/$name.err" || status=$?
    if [[ $status -ne 42 ]]; then
        printf 'live jit (%s): exit status %s (42 expected)\n' "$name" "$status" >&2
        head -n 20 "$out/$name.out" "$out/$name.err" >&2
        exit 1
    fi
}
for profile in o1 fast; do
    run "plain-$profile" "--$profile"
    run "live-$profile" "--$profile" --live
    if ! cmp -s "$out/plain-$profile.out" "$out/live-$profile.out"; then
        echo "live jit ($profile): --live prints differently" >&2
        diff "$out/plain-$profile.out" "$out/live-$profile.out" | head -n 20 >&2
        exit 1
    fi
    count=$(sed -n 's/^live: \([0-9]*\) functions through the table$/\1/p' "$out/live-$profile.err")
    if [[ -z $count || $count -lt 10 ]]; then
        printf 'live jit (%s): the live run reports %s functions through the table (10 or more expected)\n' \
            "$profile" "${count:-no}" >&2
        cat "$out/live-$profile.err" >&2
        exit 1
    fi
    if grep -q '^live:' "$out/plain-$profile.err"; then
        echo "live jit ($profile): a run without --live went through the table" >&2
        exit 1
    fi
done
calls="$(wc -l < "$out/live-o1.out" | tr -d ' ') lines alike with and without --live (--o1 and --fast), $count functions through the table"
# Redefinition (stage 2): tests/cases/live-jit/reload.ab edits a copy of itself and calls liveReload();
# see its header for the checks. Without --live the same program must find reloading unavailable.
reload=$PWD/$out/reload/main.ab
mkdir -p "$out/reload"
for profile in o1 fast; do
    cp tests/cases/live-jit/reload.ab "$reload"
    status=0
    timeout 300 "$compiler" run "--$profile" --live "$reload" -- "$reload" \
        > "$out/reload-$profile.out" 2> "$out/reload-$profile.err" || status=$?
    if [[ $status -ne 42 ]] || grep -q ': FAIL' "$out/reload-$profile.out"; then
        printf 'live jit (reload, %s): exit status %s (42 expected)\n' "$profile" "$status" >&2
        cat "$out/reload-$profile.out" >&2
        head -n 30 "$out/reload-$profile.err" >&2
        exit 1
    fi
done
cp tests/cases/live-jit/reload.ab "$reload"
status=0
timeout 300 "$compiler" run "$reload" -- "$reload" > "$out/reload-plain.out" 2>&1 || status=$?
if [[ $status -eq 42 ]] || ! grep -q '^live available: FAIL' "$out/reload-plain.out"; then
    echo "live jit (reload without --live): reloading was not refused as unavailable (exit $status)" >&2
    cat "$out/reload-plain.out" >&2
    exit 1
fi
echo "live jit: $calls; reload: $(grep -c ': ok' "$out/reload-o1.out") checks (--o1 and --fast), unavailable without --live"
