#!/usr/bin/env bash
# Root frames pushed lazily: a function's frame (and its pressure safe point) is
# pushed at the start of the first block that may collect or allocate, so a
# path that returns before one pushes nothing. The case's output is the same
# with a collection at every safe point (ABLA_GC_STRESS=1), threads and STM
# conflicts abandoning bodies included.
set -euo pipefail
# This test reads the module's LLVM text, which a development build keeps only when asked.
export ABLA_KEEP_LLVM_TEXT=1
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/lazy-root-frames"
program="$output_directory/frames"
mkdir -p "$output_directory"
"$compiler" build "$project_root/tests/cases/lazy-root-frames/frames.ab" \
    -o "$program" --no-cache

expected='halves 1759925.000000038
labels 0 70 318
trees 87227
words 1892
measured 63945
bumps 15000 counter true'
actual=$("$program")
[[ $actual == "$expected" ]] || {
    printf 'lazy root frames: output\n%s\nexpected\n%s\n' "$actual" "$expected" >&2
    exit 1
}
stressed=$(ABLA_GC_STRESS=1 "$program")
[[ $stressed == "$expected" ]] || {
    printf 'lazy root frames: under ABLA_GC_STRESS=1, output\n%s\nexpected\n%s\n' \
        "$stressed" "$expected" >&2
    exit 1
}

# A function's body in the module text, by its source name.
body_of() {
    local attribute
    attribute=$(sed -n "s/^attributes \(#[0-9]*\) = .*\"abla.source\"=\"$1\".*/\1/p" "$program.ll")
    [[ -n $attribute ]] || { echo "lazy root frames: $1 is not in the module text" >&2; exit 1; }
    awk -v attribute="$attribute" '
        /^define / && index($0, " " attribute " {") { inside = 1 }
        inside { print }
        inside && /^}/ { exit }' "$program.ll"
}

# halfOrBoxed's first block (up to its first branch) pushes no frame and runs
# no safe point. Its slow path always pushes and its fast path never does: the
# push and the pop are plain calls.
body=$(body_of halfOrBoxed)
entry=$(awk '/^entry:/ { inside = 1 } inside { print } inside && /^  br / { exit }' <<<"$body")
if grep -Eq 'abla_runtime_roots_push|abla_runtime_memory_pressure' <<<"$entry"; then
    printf '%s\n' "$entry" >&2
    echo 'lazy root frames: the fast path still pushes its frame at entry' >&2
    exit 1
fi
grep -q 'call void @abla_runtime_roots_push' <<<"$body" &&
    grep -q 'call void @abla_runtime_roots_pop' <<<"$body" || {
    echo 'lazy root frames: halfOrBoxed has no push or no pop' >&2
    exit 1
}
# labels allocates in a loop, so some iterations would find the frame pushed and
# some not: it pushes at entry instead of testing a flag.
entry=$(awk '/^entry:/ { inside = 1 } inside { print } inside && /^  br / { exit }' <<<"$(body_of labels)")
grep -q 'call void @abla_runtime_roots_push' <<<"$entry" || {
    echo 'lazy root frames: labels does not push its frame at entry' >&2
    exit 1
}
echo 'lazy root frames: fast paths push no frame; collections at every safe point keep the slow paths rooted'
