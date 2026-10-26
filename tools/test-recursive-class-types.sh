#!/usr/bin/env bash
# Classes that reach themselves through more than one field build in bounded
# time: the walk over a class's fields deciding whether references to it need
# alias tracking (sema's typeNeedsManagedAliasTrackingAt) goes 32 levels deep,
# and walking every path made two such fields 2^32 walks: the build never
# finished. Each program must build within 60 CPU seconds and print what it
# computes.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
output_directory="$project_root/build/recursive-class-types"
rm -rf "$output_directory"
mkdir -p "$output_directory"

# A tree class built by a recursive function returning it (nullable).
cat >"$output_directory/tree.ab" <<'EOF'
import "abla/io"

class Node(val value: int, val left: Node?, val right: Node?)

fun chain(depth: int, seed: int): Node? {
    if (depth == 0) return null
    val rest = chain(depth - 1, seed + 1)
    Node(seed, rest, null)
}

fun main: int {
    val built = chain(3, 1)
    println(if (built == null) "none" else "${built.value}")
    0
}
EOF

# Two classes reaching each other through two fields each, built by mutually
# recursive functions.
cat >"$output_directory/pair.ab" <<'EOF'
import "abla/io"

class Even(val value: int, val left: Odd?, val right: Odd?)
class Odd(val value: int, val left: Even?, val right: Even?)

fun evens(depth: int, seed: int): Even? {
    if (depth == 0) return null
    val rest = odds(depth - 1, seed + 1)
    Even(seed, rest, null)
}

fun odds(depth: int, seed: int): Odd? {
    if (depth == 0) return null
    val rest = evens(depth - 1, seed + 1)
    Odd(seed, rest, null)
}

fun main: int {
    val built = evens(3, 1)
    println(if (built == null) "none" else "${built.value} ${built.left?.value ?? 0}")
    0
}
EOF

check() { # name expected-output
    local name=$1 expected=$2 status=0
    ABLA_MAX_SECONDS=120 ABLA_MAX_CPU_SECONDS=60 \
        "$project_root/tools/run-limited.sh" "$compiler" build \
        "$output_directory/$name.ab" -o "$output_directory/$name" \
        >"$output_directory/$name.build.out" 2>&1 || status=$?
    if [[ $status -ne 0 ]]; then
        cat "$output_directory/$name.build.out" >&2
        echo "recursive class types: $name did not build (status $status)" >&2
        exit 1
    fi
    local printed
    printed=$("$project_root/tools/run-limited.sh" "$output_directory/$name")
    if [[ $printed != "$expected" ]]; then
        echo "recursive class types: $name printed '$printed', expected '$expected'" >&2
        exit 1
    fi
}

check tree 1
check pair "1 2"
echo "recursive class types: ok"
