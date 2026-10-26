#!/usr/bin/env bash
# Instances changed layout (typed fields, 2026-10): every cache that keeps
# compiled code names the layout's version, so no entry an older compiler left
# (keyed by the older version) is reused, even by a compiler whose image hash
# matched. The native build's entries name v14 (and its partitions v3); the
# `ablac run` record names abla-run-object-v2, and a record with the older
# header is a miss.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
work="$project_root/build/cache-layout-version"
rm -rf "$work"
mkdir -p "$work/copy" "$work/cache"
cp -R "$project_root/tests/cases/cache-dir/." "$work/copy/"
fail() {
    echo "cache layout version: $1" >&2
    exit 1
}
unset ABLA_CACHE_DIR

(cd "$work/copy" && "$compiler" build main.ab -o out/main --fast --cache-dir "$work/cache" \
    > build.log 2>&1) || { cat "$work/copy/build.log" >&2; fail "the build failed"; }
entries=$(ls "$work/cache")
grep -q -- '-llvm21-v14-' <<<"$entries" || fail "no native entry names v14: $entries"
if grep -q -- '-llvm21-v13-' <<<"$entries"; then fail "a native entry names v13"; fi

run() { # the run's cache decision, as ABLA_JIT_CACHE_TRACE reports it
    (cd "$work/copy" && ABLA_JIT_CACHE_TRACE=1 "$compiler" run --cache-dir "$work/cache" main.ab \
        2>&1 >/dev/null | grep '^\[jit-cache\] \(hit\|miss\|off\)' | head -1 | cut -d' ' -f2) || true
}
run > /dev/null
[[ $(run) == hit ]] || fail "a second run missed its own record"
record=$(ls "$work/cache"/run-*.record 2>/dev/null | head -1)
[[ -n $record ]] || fail "the run left no record"
[[ $(head -1 "$record") == abla-run-object-v2 ]] || fail "the record's header is $(head -1 "$record")"
# The record an older compiler would have written: the same, under the older header.
{ echo abla-run-object-v1; tail -n +2 "$record"; } > "$record.older"
mv "$record.older" "$record"
[[ $(run) == miss ]] || fail "a record with the older header was reused"
echo "cache layout version: native entries name v14, run records abla-run-object-v2; an older record is a miss"
