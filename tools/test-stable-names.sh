#!/usr/bin/env bash
# What the compiler names after where something is in the source (lambdas,
# a generator's slots, generated modules' declarations, a subparser's site)
# is named after the declaration that holds it and its offset there, never a
# position in the file. So a program whose files each get a line, a comment
# and an import of a module it already has added at the top is the same
# program: the same LLVM text and the same executable, byte for byte, with
# the same output. Previously every lambda after the edit was renamed.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
cases="$project_root/tests/cases"
output_directory="$project_root/build/stable-names"
rm -rf "$output_directory"
mkdir -p "$output_directory"

fail() {
    echo "stable names: $1" >&2
    exit 1
}

# <name> <case directory> <main file>
programs=(
    "corpus stable-names main.ab"
    "lambda-symbols lambda-symbols main.ab"
    "generated-modules modules cross-late-root.ab"
    "lifted-closures compile-time-lift closures.ab"
    "site-key subparser-site-key main.ab"
)
for program in "${programs[@]}"; do
    read -r name directory main <<<"$program"
    work="$output_directory/$name"
    # Both builds read the files at the same paths: a module's path is part
    # of some names, which this test isn't about.
    mkdir -p "$work/case"
    cp -R "$cases/$directory/." "$work/case/"
    for build in plain shifted; do
        if [[ $build == shifted ]]; then
            # The import only where the program already has the module.
            import=""
            if grep -q '^import "abla/io"$' "$work/case/$main"; then import='import "abla/io"'; fi
            while IFS= read -r -d '' file; do
                {
                    printf '\n// a line above every declaration\n'
                    if [[ -n $import ]] && ! grep -q '^import "abla/io"$' "$file"; then
                        printf '%s\n' "$import"
                    fi
                    cat "$file"
                } > "$file.next"
                mv "$file.next" "$file"
            done < <(find "$work/case" -name '*.ab' -print0)
        fi
        # One file name: a signed executable's signature names it.
        mkdir -p "$work/$build"
        (cd "$work/case" && "$compiler" --emit-llvm "$main" > "$work/$build/main.ll")
        "$compiler" build "$work/case/$main" -o "$work/$build/main" --no-cache
        set +e
        "$work/$build/main" > "$work/$build/output" 2>&1
        echo "status $?" >> "$work/$build/output"
        set -e
    done
    cmp -s "$work/plain/output" "$work/shifted/output" ||
        fail "$name: the output changed with lines added above its declarations"
    cmp -s "$work/plain/main.ll" "$work/shifted/main.ll" ||
        fail "$name: the LLVM text changed with lines added above its declarations"
    cmp -s "$work/plain/main" "$work/shifted/main" ||
        fail "$name: the executable changed with lines added above its declarations"
done
grep -q '^101 5 2 4 9 12$' "$output_directory/corpus/plain/output" ||
    fail "corpus: unexpected output: $(cat "$output_directory/corpus/plain/output")"
echo "stable names: lines and imports added above declarations change no LLVM text, no executable"
