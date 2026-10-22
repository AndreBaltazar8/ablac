#!/usr/bin/env bash
# A transform's change to another module survives a rebuild that reuses the
# transforming module's parse (`ablac serve`): the change travels with the
# parse instead of being made again only when the transform reruns.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_directory=$(mktemp -d "$project_root/build/transform-reuse.XXXXXX")
server=0

cleanup() {
    if [[ $server -gt 0 ]]; then
        kill -TERM -- "-$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

new_session=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"')

cp "$project_root"/tests/cases/transform-reuse/*.ab "$test_directory/"

wait_for() { # file pattern
    local attempt=0
    while [[ $attempt -lt 300 ]]; do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
        attempt=$((attempt + 1))
    done
    printf 'transform reuse: timed out waiting for %s in %s\n' "$2" "$1" >&2
    tail -20 "$test_directory/stderr.txt" >&2 || true
    return 1
}

"${new_session[@]}" env ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 \
    "$compiler" serve "$test_directory/app.ab" \
    > "$test_directory/stdout.txt" 2> "$test_directory/stderr.txt" &
server=$!

wait_for "$test_directory/stdout.txt" 'other=1'
# Change only a module the transforming one doesn't import: its parse is reused.
printf 'fun otherValue(): int = 2\n' > "$test_directory/other.ab"
wait_for "$test_directory/stdout.txt" 'other=2'
grep -q 'reloaded generation 2; .*parsed: [0-9]* refreshed, [1-9][0-9]* reused' "$test_directory/stderr.txt" ||
    { echo "transform reuse: the second build reused no parse" >&2; cat "$test_directory/stderr.txt" >&2; exit 1; }
if ! grep -q '^tagged=1 other=2$' "$test_directory/stdout.txt"; then
    echo "transform reuse: the annotation on another module was lost when the parse was reused" >&2
    cat "$test_directory/stdout.txt" >&2
    exit 1
fi
echo "transform reuse: a reused parse keeps its transforms' changes to other modules"
