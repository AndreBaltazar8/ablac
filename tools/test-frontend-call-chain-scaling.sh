#!/usr/bin/env bash
# The frontend's summaries of what each function does (whether it may mutate
# its receiver, whether it may keep or leak what it is given) settle in time
# proportional to the program, not to its square: a chain of 2N functions,
# each calling the next and declared before it, takes at most three times the
# CPU of a chain of N. Walking every body again until a pass changes nothing
# learns one link per pass, and makes it four times.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
output_directory="$project_root/build/frontend-call-chain-scaling"
rm -rf "$output_directory"
mkdir -p "$output_directory"

# generate <directory> <links>: a class whose method m<i> calls m<i+1>, the
# last one assigning a field, and functions c<i> calling c<i+1>, the last one
# calling its function parameter; then a missing identifier stops the build
# after the frontend.
generate() {
    local directory=$1 links=$2 link
    mkdir -p "$directory"
    {
        printf 'class Counter(var total: int) {\n'
        for ((link = 0; link + 1 < links; link++)); do
            printf '    fun m%d(): void { this.m%d() }\n' "$link" "$((link + 1))"
        done
        printf '    fun m%d(): void { this.total = this.total + 1 }\n}\n' "$((links - 1))"
        for ((link = 0; link + 1 < links; link++)); do
            printf 'fun c%d(f: () -> int): int = c%d(f)\n' "$link" "$((link + 1))"
        done
        printf 'fun c%d(f: () -> int): int = f()\n' "$((links - 1))"
        printf 'fun broken(): int = missingName + 1\n'
        printf 'fun main: int = 0\n'
    } >"$directory/main.ab"
}

# cpu <directory>: the build's CPU seconds (user + system), in hundredths.
cpu() {
    local directory=$1 status=0
    (cd "$directory" &&
        /usr/bin/time -p "$compiler" build main.ab -o program --fast --no-cache \
            >build.out 2>build.err) || status=$?
    [[ $status -ne 0 ]] || { echo "frontend call-chain scaling: $directory built despite its error" >&2; exit 1; }
    grep -q 'identifier:missingName' "$directory/build.err" ||
        { cat "$directory/build.err" >&2; echo "frontend call-chain scaling: $directory did not reach semantic analysis" >&2; exit 1; }
    awk '/^(user|sys) / { total += $2 } END { printf "%d\n", total * 100 }' "$directory/build.err"
}

generate "$output_directory/small" 1500
generate "$output_directory/large" 3000
small=$(cpu "$output_directory/small")
large=$(cpu "$output_directory/large")
if ((large > 3 * small)); then
    printf 'frontend call-chain scaling: 3,000 links took %d.%02d CPU s, 1,500 links %d.%02d (more than 3x)\n' \
        "$((large / 100))" "$((large % 100))" "$((small / 100))" "$((small % 100))" >&2
    exit 1
fi
printf 'frontend call-chain scaling: chains of 1,500 links %d.%02d CPU s, of 3,000 %d.%02d\n' \
    "$((small / 100))" "$((small % 100))" "$((large / 100))" "$((large % 100))"
