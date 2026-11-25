#!/usr/bin/env bash
# #1208: every module program (tests/cases/modules/*.ab) that builds libc-free for a Linux cross target runs under QEMU and prints and exits
# what the x86-64 build prints and exits (tools/survey-linux-parity.sh). tools/linux-parity-blockers.tsv names the programs that do not, and why;
# it may only shrink: a program that differs and is not listed fails the test, and so does a listed program that matches now.
# Usage: tools/test-linux-parity.sh <aarch64-linux|riscv64-linux> [compiler] [image-dir]
#   image-dir: build/libc-free-programs of tools/test-libc-free-programs.sh for the target (NAME.a64 or NAME.rv64); the x86-64 builds of the
#   same programs (--fast) are made here, into build/linux-parity/<target>/x86.
set -euo pipefail
export LC_ALL=C TZ=UTC
target=${1:-}
compiler=${2:-build/ablac}
images=${3:-build/libc-free-programs}
case $target in
    aarch64-linux) suffix=a64 ;;
    riscv64-linux) suffix=rv64 ;;
    *) echo 'usage: tools/test-linux-parity.sh <aarch64-linux|riscv64-linux> [compiler] [image-dir]' >&2; exit 2 ;;
esac
if [[ $(uname -sm) != 'Linux x86_64' ]]; then
    echo 'linux parity: the native reference requires x86-64 Linux' >&2
    exit 2
fi
[[ $compiler == /* || $compiler != */* ]] || compiler=$PWD/$compiler
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $images == /* ]] || images=$root/$images
blockers=${LINUX_PARITY_BLOCKERS:-tools/linux-parity-blockers.tsv}
[[ -f $blockers ]] || { echo "linux parity: missing $blockers" >&2; exit 1; }
[[ $blockers == /* ]] || blockers=$root/$blockers
sort -c "$blockers" || { echo "linux parity: $blockers must be sorted" >&2; exit 1; }
unset ABLA_DEBUG ABLA_GC_STRESS ABLA_TEST_FAST_BUILDS
work=$root/build/linux-parity/$target
rm -rf -- "$work"
mkdir -p "$work/x86"
for image in "$images"/*."$suffix"; do
    [[ -x $image ]] && basename -- "${image%."$suffix"}"
done | sort > "$work/names.txt"
[[ -s $work/names.txt ]] || { echo "linux parity: no .$suffix images in $images" >&2; exit 1; }
# `skip`: a program that needs its harness is not run here (tools/test-runtime-memory.sh runs runtime-out-of-memory under ulimit -v; without one
# the native program takes memory until the timeout kills it).
awk -F'\t' -v t="$suffix" '$3 == "skip" && ($2 == t || $2 == "both") { print $1 }' "$blockers" | sort > "$work/skipped.txt"
comm -23 "$work/names.txt" "$work/skipped.txt" > "$work/names.run"
mv "$work/names.run" "$work/names.txt"
workers=${ABLA_TEST_JOBS:-4}
[[ $workers =~ ^[1-9][0-9]*$ ]] || { echo 'linux parity: ABLA_TEST_JOBS must be positive' >&2; exit 2; }
# The native reference: the same source built --fast for x86-64 (a program that only builds for the guest has no reference and is a failure).
build_native() {
    local name=$1
    "$compiler" build "tests/cases/modules/$name.ab" --target x86_64-linux --fast --no-cache -o "$work/x86/$name.x86" > "$work/x86/$name.log" 2>&1 ||
        printf 'linux parity: %s has no x86-64 build (%s)\n' "$name" "$work/x86/$name.log" >&2
}
export -f build_native
export compiler work
xargs -P "$workers" -I{} bash -c 'build_native {}' < "$work/names.txt"
for name in $(cat "$work/names.txt"); do
    [[ -x $work/x86/$name.x86 ]] || exit 1
    ln -s "$images/$name.$suffix" "$work/x86/$name.$suffix"
done
tools/survey-linux-parity.sh "$suffix" "$work/x86" "$work/survey" | tail -1
# What differs, against the list (the lines of the list for this target: "<program> <target> <verdict> <reason>", tab-separated).
awk -F'\t' '$2 != "match" { print $1 "\t" $2 }' "$work/survey/results.tsv" | sort > "$work/actual.txt"
awk -F'\t' -v t="$suffix" '($2 == t || $2 == "both") && $3 != "skip" { print $1 "\t" $3 }' "$blockers" | sort > "$work/listed.txt"
failed=0
while IFS=$'\t' read -r name verdict; do
    printf 'linux parity: %s is %s on %s and not in %s (%s)\n' "$name" "$verdict" "$target" "$blockers" "$work/survey/runs/$name" >&2
    failed=1
done < <(comm -23 "$work/actual.txt" "$work/listed.txt")
while IFS=$'\t' read -r name verdict; do
    printf 'linux parity: %s is listed as %s but is not on %s now: remove its line from %s\n' "$name" "$verdict" "$target" "$blockers" >&2
    failed=1
done < <(comm -13 "$work/actual.txt" "$work/listed.txt")
((failed == 0)) || exit 1
printf 'linux parity (%s): %s module programs print and exit what x86-64 does under QEMU, %s listed blockers\n' \
    "$target" "$(awk -F'\t' '$2 == "match"' "$work/survey/results.tsv" | wc -l)" "$(wc -l < "$work/listed.txt")"
