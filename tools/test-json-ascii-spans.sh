#!/usr/bin/env bash
# Serializer ASCII spans against a per-byte reference (tests/cases/modules/json-ascii-spans.ab),
# built normally, with --fast, and under collection at every safe point. The --fast and GC-stress passes
# run the boundary lengths (corpus.run(true): its comment says which); `make test-full` (RUN_TESTS_FULL=1,
# or JSON_SPANS_FULL=1) runs the full length schedule in all three.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory="$project_root/build/json-ascii-spans"
mkdir -p "$output_directory"
cd "$project_root"
check() {
    local status=0
    "$@" || status=$?
    if [[ $status -ne 42 ]]; then
        echo "json ASCII spans: expected 42, got $status" >&2
        exit 1
    fi
}
"$compiler" build tests/cases/modules/json-ascii-spans.ab \
    -o "$output_directory/default" --no-cache
check "$output_directory/default"
boundary=true
if [[ -n ${JSON_SPANS_FULL:-${RUN_TESTS_FULL:-}} ]]; then boundary=false; fi
cat > "$output_directory/fast.ab" <<AB
import "../../tests/cases/modules/json-ascii-spans.ab" as corpus
fun main(): int = corpus.run($boundary)
AB
"$compiler" build "$output_directory/fast.ab" \
    -o "$output_directory/fast" --fast --no-cache
check "$output_directory/fast"
cat > "$output_directory/gc.ab" <<'AB'
import "../../tests/cases/modules/json-ascii-spans.ab" as corpus
import "abla/memory"
fun main(): int {
    memorySetLimit(16777216)
    corpus.run(BOUNDARY)
}
AB
sed -i "s/BOUNDARY/$boundary/" "$output_directory/gc.ab"
"$compiler" build "$output_directory/gc.ab" \
    -o "$output_directory/gc" --no-cache
check env ABLA_GC_STRESS=1 "$output_directory/gc"
echo "json ASCII spans: reference, fast and GC stress ($([[ $boundary == true ]] && echo boundary || echo full) lengths for the last two)"
