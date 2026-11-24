#!/usr/bin/env bash
# The browser compiler's build product (tools/build-playground.sh, #1138): two builds at once give the same archive byte for byte, and the
# unpacked package checks out (tools/playground/package-check.mjs: manifest hashes, the sizes under their limits, the stdlib bundle loaded over
# HTTP, a program run with the evaluator).
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/playground-test"
rm -rf "$out"
mkdir -p "$out"

# The two release builds compete with the other suite commands on small runners.
# Preserve each compiler invocation's CPU ceiling and allow more time for scheduling.
suite_jobs=${ABLA_SUITE_JOBS:-0}
if [[ -z ${ABLA_MAX_SECONDS:-} && $suite_jobs =~ ^[1-9][0-9]*$ ]]; then
    cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo "$suite_jobs")
    if [[ $cpus =~ ^[1-9][0-9]*$ ]] && (( suite_jobs > cpus )); then
        export ABLA_MAX_SECONDS=900
        export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-600}
        echo "playground build: $suite_jobs suite jobs on $cpus CPUs, wall limit ${ABLA_MAX_SECONDS}s, CPU limit ${ABLA_MAX_CPU_SECONDS}s per process"
    fi
fi

"$root/tools/build-playground.sh" "$compiler" "$out/one" > "$out/one.path" 2> "$out/one.log" &
first=$!
"$root/tools/build-playground.sh" "$compiler" "$out/two" > "$out/two.path" 2> "$out/two.log" &
second=$!
status=0
wait "$first" || status=1
wait "$second" || status=1
if ((status)); then
    tail -n 20 "$out/one.log" "$out/two.log" >&2
    echo "playground build: a build failed" >&2
    exit 1
fi
cmp "$(cat "$out/one.path")" "$(cat "$out/two.path")" || { echo "playground build: two builds differ" >&2; exit 1; }
mkdir -p "$out/unpacked"
tar -xzf "$(cat "$out/one.path")" -C "$out/unpacked"
node "$root/tools/playground/package-check.mjs" "$out/unpacked"/abla-playground-*
echo "playground build: two builds gave the same archive, $(stat -c %s "$(cat "$out/one.path")") bytes"
