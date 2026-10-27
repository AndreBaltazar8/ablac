#!/usr/bin/env bash
# The frontend scales with a function's locals, not with their square: a
# function of 2N locals (each using the two before it) takes at most three
# times the CPU of one of N. A name looked up through every local of its
# function, or a block's names copied at each local, makes it four times.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
output_directory="$project_root/build/frontend-locals-scaling"
rm -rf "$output_directory"
mkdir -p "$output_directory"

# generate <directory> <locals>: main.ab's function declares $locals locals,
# then a missing identifier stops the build after the frontend.
generate() {
    local directory=$1 locals=$2 local
    mkdir -p "$directory"
    {
        printf 'fun big(seed: int): int {\n    val v0 = seed\n    val v1 = seed + 1\n'
        for ((local = 2; local < locals; local++)); do
            printf '    val v%d = v%d + v%d %% 7\n' "$local" "$((local - 1))" "$((local - 2))"
        done
        printf '    v%d\n}\n' "$((locals - 1))"
        printf 'fun broken(): int = missingName + 1\n'
        printf 'fun main: int = big(1) - big(1)\n'
    } >"$directory/main.ab"
}

# cpu <directory>: the build's CPU seconds (user + system), in hundredths.
cpu() {
    local directory=$1 status=0
    (cd "$directory" &&
        "${ABLA_TIME:-$(type -P time)}" -p "$compiler" build main.ab -o program --fast --no-cache \
            >build.out 2>build.err) || status=$?
    [[ $status -ne 0 ]] || { echo "frontend locals scaling: $directory built despite its error" >&2; exit 1; }
    grep -q 'identifier:missingName' "$directory/build.err" ||
        { cat "$directory/build.err" >&2; echo "frontend locals scaling: $directory did not reach semantic analysis" >&2; exit 1; }
    awk '/^(user|sys) / { total += $2 } END { printf "%d\n", total * 100 }' "$directory/build.err"
}

generate "$output_directory/small" 8000
generate "$output_directory/large" 16000
small=$(cpu "$output_directory/small")
large=$(cpu "$output_directory/large")
if ((large > 3 * small)); then
    printf 'frontend locals scaling: 16,000 locals took %d.%02d CPU s, 8,000 locals %d.%02d (more than 3x)\n' \
        "$((large / 100))" "$((large % 100))" "$((small / 100))" "$((small % 100))" >&2
    exit 1
fi
printf 'frontend locals scaling: a function of 8,000 locals %d.%02d CPU s, of 16,000 %d.%02d\n' \
    "$((small / 100))" "$((small % 100))" "$((large / 100))" "$((large % 100))"
