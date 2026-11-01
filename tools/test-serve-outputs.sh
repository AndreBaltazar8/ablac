#!/usr/bin/env bash
# Two `ablac serve` from one directory keep their builds apart: each runs what it
# built, under a name of its own, and removes a generation once it replaced it.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_directory=$(mktemp -d "$project_root/build/serve-outputs.XXXXXX")
servers=()

cleanup() {
    for server in "${servers[@]}"; do
        kill -TERM -- "-$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
    done
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

new_session=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"')

wait_for() { # file pattern
    local attempt=0
    while [[ $attempt -lt 1200 ]]; do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
        attempt=$((attempt + 1))
    done
    printf 'serve outputs: timed out waiting for %s in %s\n' "$2" "$1" >&2
    return 1
}

# (Its own directory, so that only these two write there.)
mkdir "$test_directory/build"
cd "$test_directory"
for name in one two; do
    mkdir "$test_directory/$name"
    printf 'import "abla/io"\nfun main { println("%s-a") }\n' "$name" > "$test_directory/$name/app.ab"
    "${new_session[@]}" env ABLA_SYSROOT="$project_root" ABLA_CACHE_DIR="$project_root/build/.abla-cache" ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=150 \
        "$compiler" serve "$test_directory/$name/app.ab" \
        > "$test_directory/$name/stdout.txt" 2> "$test_directory/$name/stderr.txt" &
    servers+=($!)
done
wait_for "$test_directory/one/stdout.txt" 'one-a'
wait_for "$test_directory/two/stdout.txt" 'two-a'
outputs() { find build -maxdepth 1 -name '.abla-serve-*' ! -name '*.o*' ! -name '*.ll' ! -name '*.json' -type f -printf '%f\n' | sort; }
[[ $(outputs | wc -l) -eq 2 && $(outputs | grep -c -- '-0$') -eq 2 ]] ||
    { echo 'serve outputs: expected one first generation for each' >&2; outputs >&2; exit 1; }

printf 'import "abla/io"\nfun main { println("one-b") }\n' > "$test_directory/one/app.ab"
wait_for "$test_directory/one/stdout.txt" 'one-b'
wait_for "$test_directory/one/stderr.txt" 'reloaded generation 2'
[[ $(outputs | wc -l) -eq 2 && $(outputs | grep -c -- '-1$') -eq 1 ]] ||
    { echo 'serve outputs: the replaced generation stayed' >&2; outputs >&2; exit 1; }
if grep -q 'two' "$test_directory/one/stdout.txt" || grep -q 'one' "$test_directory/two/stdout.txt"; then
    echo "serve outputs: one ran the other's build" >&2
    exit 1
fi
echo 'serve outputs: each serve runs its own build'
