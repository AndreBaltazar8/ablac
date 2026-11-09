#!/usr/bin/env bash
# How a collection finds the allocation a pointer names: from the registry alone when the pointer is
# a payload's start (reading only inside the ranges /proc/self/maps lists), through the page directory
# otherwise. ABLA_GC_LOOKUP forces each fallback (directory: never from the registry; nomaps: as if
# /proc/self/maps were unreadable; untagged: as if the heap's addresses were not in the mapped ranges,
# which is what tagged pointers look like), and ABLA_GC_STRESS=1 checks the registry's answer against the
# directory's at every pointer. The result is the same in every mode; memoryHeapStat 5 and 6 say which
# way the collections went.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/gc-lookup"
mkdir -p "$out"
fail() {
    echo "gc lookup: $1" >&2
    exit 1
}
"$compiler" build "$project_root/tests/cases/gc-lookup/main.ab" -o "$out/exact" --fast --no-cache
"$compiler" build "$project_root/tests/cases/gc-lookup/interior.ab" -o "$out/interior" --fast --no-cache

result='total 72045600000 kept 1999000'
default=$("$out/exact")
[[ $default == "$result"$'\n'"lazy true directory false" ]] || fail "default: '$default'"
if [[ -r /proc/self/maps ]]; then
    for mode in directory nomaps untagged; do
        forced=$(ABLA_GC_LOOKUP=$mode "$out/exact")
        [[ $forced == "$result"$'\n'"lazy false directory true" ]] || fail "ABLA_GC_LOOKUP=$mode: '$forced'"
    done
fi
stressed=$(ABLA_GC_STRESS=1 ABLA_GC_GROWTH=2097152 "$out/exact")
[[ $stressed == "$result"$'\n'"lazy false directory true" ]] || fail "under ABLA_GC_STRESS=1: '$stressed'"

# A kept slice points into its parent's block: the directory is needed, the result the same.
interior=$("$out/interior")
expected_interior='total 3948890 kept 66000 first 0-with-some-longer-text-to-slice- last 1999-with-some-longer-text-to-sli'
[[ $interior == "$expected_interior"$'\n'"directory true" ]] || fail "interior pointers: '$interior'"
forced=$(ABLA_GC_LOOKUP=directory "$out/interior")
[[ $forced == "$expected_interior"$'\n'"directory true" ]] || fail "interior pointers, ABLA_GC_LOOKUP=directory: '$forced'"

# The system calls themselves failing (a null path; a bad descriptor): the directory, the same result.
if [[ -r /proc/self/maps ]]; then
    for mode in openfail readfail; do
        forced=$(ABLA_GC_LOOKUP=$mode "$out/exact")
        [[ $forced == "$result"$'\n'"lazy false directory true" ]] || fail "ABLA_GC_LOOKUP=$mode: '$forced'"
    done
    "$compiler" build "$project_root/tests/cases/gc-lookup/mappings.ab" -o "$out/mappings" --fast --no-cache
    # Mappings: a few (lazy), about 2,200 (the listing outgrows 128 KiB, so its buffer is a mapping of its own;
    # still lazy), about 4,000 (over 256 KiB: the directory). The program's own answer is the same each way.
    base=$("$out/mappings" 0 | head -1)
    for pages in 64 4400; do
        answer=$("$out/mappings" "$pages")
        [[ $answer == "$base"$'\n'"lazy true directory false" ]] || fail "$pages pages: '$answer'"
    done
    answer=$("$out/mappings" 9000)
    [[ $answer == "$base"$'\n'"lazy false directory true" ]] || fail "9000 pages: '$answer'"
fi

# Garbage as candidates (0, -1, 2^63, the bytes around each mapped range, a PROT_NONE page, a page that is
# gone, the snapshot's own buffer): none is an allocation, none faults the lookup.
if [[ -r /proc/self/maps ]]; then
    sed "s|@HOST_PLATFORM@|$project_root/stdlib/abla/runtime/platform/host.ab|" \
        "$project_root/tests/cases/gc-lookup/garbage.ab" > "$out/garbage.ab"
    "$compiler" build "$out/garbage.ab" -o "$out/garbage" --fast --no-cache
    garbage=$("$out/garbage")
    [[ $garbage == 'garbage candidates taken for allocations: 0' ]] || fail "garbage candidates: '$garbage'"
fi
echo 'gc lookup: from the registry for payload starts, through the directory for interior pointers, under each forced fallback and under stress'
