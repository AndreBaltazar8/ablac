#!/usr/bin/env bash
# Locals in root frames by liveness: a local is in its function's root frame
# only when a collection can happen while it holds a value the function still
# reads (a place, borrow or resource view keeps it there too). The case prints
# the same with a collection at every safe point (ABLA_GC_STRESS=1), and its
# statement-`if` temporaries stay out of `pick`'s frame.
set -euo pipefail
# This test reads the module's LLVM text, which a development build keeps only when asked.
export ABLA_KEEP_LLVM_TEXT=1
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/local-root-liveness"
program="$output_directory/locals"
mkdir -p "$output_directory"
"$compiler" build "$project_root/tests/cases/local-root-liveness/locals.ab" \
    -o "$program" --no-cache

expected='picked 1729396
kept 110100
carried 188160
conditioned 63
closure 20220'
actual=$("$program")
[[ $actual == "$expected" ]] || {
    printf 'local root liveness: output\n%s\nexpected\n%s\n' "$actual" "$expected" >&2
    exit 1
}
stressed=$(ABLA_GC_STRESS=1 "$program")
[[ $stressed == "$expected" ]] || {
    printf 'local root liveness: under ABLA_GC_STRESS=1, output\n%s\nexpected\n%s\n' \
        "$stressed" "$expected" >&2
    exit 1
}

# No local of pick's is stored into its root frame's slots.
attribute=$(sed -n 's/^attributes \(#[0-9]*\) = .*"abla.source"="pick".*/\1/p' "$program.ll")
[[ -n $attribute ]] || { echo 'local root liveness: pick is not in the module text' >&2; exit 1; }
body=$(awk -v attribute="$attribute" '
    /^define / && index($0, " " attribute " {") { inside = 1 }
    inside { print }
    inside && /^}/ { exit }' "$program.ll")
[[ -n $body ]] || { echo 'local root liveness: no body for pick' >&2; exit 1; }
if grep -Eq 'store ptr %local[0-9]*, ptr %gc\.root' <<<"$body"; then
    grep -E 'store ptr %local[0-9]*, ptr %gc\.root' <<<"$body" >&2
    echo 'local root liveness: pick still roots a local no collection can see' >&2
    exit 1
fi
echo 'local root liveness: frames hold only the locals a collection can see; collections at every safe point keep them'
