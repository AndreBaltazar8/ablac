#!/usr/bin/env bash
# The frontend's module graph scales with its import edges, not with their
# square: a graph of 2N modules (each importing the 40 before it, 40
# declarations each) takes at most three times the CPU of a graph of N. A check
# of each edge against every edge of the graph, or of each module's edges
# against every edge, makes it four times.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
output_directory="$project_root/build/frontend-scaling"
rm -rf "$output_directory"
mkdir -p "$output_directory"
fan=40
declarations=40

# generate <directory> <modules>: m<i>.ab imports the $fan modules before it and
# declares $declarations functions; main.ab imports the last $fan and names
# one missing identifier, so the build stops after the frontend.
generate() {
    local directory=$1 modules=$2 module first import function
    mkdir -p "$directory"
    for ((module = 0; module < modules; module++)); do
        first=$((module > fan ? module - fan : 0))
        {
            for ((import = first; import < module; import++)); do
                printf 'import "./m%d.ab"\n' "$import"
            done
            for ((function = 0; function < declarations; function++)); do
                if ((module > 0)); then
                    printf 'fun m%df%d(x: int): int = m%df%d(x) + %d\n' \
                        "$module" "$function" "$((module - 1))" "$function" "$function"
                else
                    printf 'fun m0f%d(x: int): int = x + %d\n' "$function" "$function"
                fi
            done
        } >"$directory/m$module.ab"
    done
    {
        first=$((modules > fan ? modules - fan : 0))
        for ((import = first; import < modules; import++)); do
            printf 'import "./m%d.ab"\n' "$import"
        done
        printf 'fun broken(): int = missingName + 1\n'
        printf 'fun main: int = m%df0(1) - m%df0(1)\n' "$((modules - 1))" "$((modules - 1))"
    } >"$directory/main.ab"
}

# cpu <directory>: the build's CPU seconds (user + system), in hundredths.
cpu() {
    local directory=$1 status=0
    (cd "$directory" &&
        /usr/bin/time -p "$compiler" build main.ab -o program --fast --no-cache \
            >build.out 2>build.err) || status=$?
    [[ $status -ne 0 ]] || { echo "frontend scaling: $directory built despite its error" >&2; exit 1; }
    grep -q 'identifier:missingName' "$directory/build.err" ||
        { cat "$directory/build.err" >&2; echo "frontend scaling: $directory did not reach semantic analysis" >&2; exit 1; }
    awk '/^(user|sys) / { total += $2 } END { printf "%d\n", total * 100 }' "$directory/build.err"
}

generate "$output_directory/small" 300
generate "$output_directory/large" 600
small=$(cpu "$output_directory/small")
large=$(cpu "$output_directory/large")
if ((large > 3 * small)); then
    printf 'frontend scaling: 600 modules took %d.%02d CPU s, 300 modules %d.%02d (more than 3x)\n' \
        "$((large / 100))" "$((large % 100))" "$((small / 100))" "$((small % 100))" >&2
    exit 1
fi
printf 'frontend scaling: 300 modules %d.%02d CPU s, 600 modules %d.%02d (12,000 and 24,000 import edges)\n' \
    "$((small / 100))" "$((small % 100))" "$((large / 100))" "$((large % 100))"
