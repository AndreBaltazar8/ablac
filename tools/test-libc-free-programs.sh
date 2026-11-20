#!/usr/bin/env bash
# #806: the module test programs (tests/cases/modules/*.ab) built --fast for x86-64 Linux and for AArch64 Linux link no C
# library. tools/libc-free-programs-allowlist.txt holds the exceptions, one per line, and may only shrink:
#   <program> x86       an x86-64 build that links libc (it brings a C library: OpenSSL, extern "host", an extern:"c" call, or
#                       the compiler's own modules, which link libLLVM)
#   nobuild <program>   an x86-64 build that fails (the negative cases, and programs that need a manifest or flags)
#   nobuild-a64 <program>  builds for x86-64 but not for AArch64 Linux (libLLVM and OpenSSL have no AArch64 build here)
# A line whose program is now static and building fails the test, so the line gets removed; a new libc link or a new build
# failure fails it too.
# LIBC_FREE_TARGETS="x86" builds the x86-64 half only (the suite does), "a64" the AArch64 half only (CI does: the whole is 22
# CPU-minutes, 4 minutes on 8 cores, and took 25 on a CI runner); the default is "x86 a64".
# Usage: tools/test-libc-free-programs.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'libc free programs: Linux only'; exit 0; }
targets=${LIBC_FREE_TARGETS:-x86 a64}
[[ $targets == x86 || $targets == a64 || $targets == 'x86 a64' ]] ||
    { echo "libc free programs: LIBC_FREE_TARGETS must be x86, a64 or 'x86 a64'" >&2; exit 2; }
allow=tools/libc-free-programs-allowlist.txt
[[ -f $allow ]] || { echo "libc free programs: missing $allow" >&2; exit 1; }
sort -cu "$allow" || { echo "libc free programs: $allow must be sorted and unique" >&2; exit 1; }
out=build/libc-free-programs
rm -rf "$out"
mkdir -p "$out"
workers=${ABLA_TEST_JOBS:-}
if [[ -z $workers ]]; then
    if [[ -n ${ABLA_SUITE_JOBS:-} ]]; then workers=2; else workers=$(nproc 2> /dev/null || echo 2); ((workers <= 8)) || workers=8; fi
fi
build_one() { # source target -> a line in $out/<name>.<target>.result
    local source=$1 target=$2 name options=() status needed
    name=$(basename -- "$source" .ab)
    [[ $target == a64 ]] && options=(--target aarch64-linux)
    if "$compiler" build "$source" -o "$out/$name.$target" --fast --no-cache "${options[@]}" > "$out/$name.$target.log" 2>&1; then
        needed=$(readelf -d "$out/$name.$target" 2> /dev/null | grep -c '(NEEDED)' || true)
        if ((needed == 0)); then status=static; else status=libc; fi
    else
        status=nobuild
    fi
    echo "$name $target $status" > "$out/$name.$target.result"
}
export -f build_one
export compiler out
# The programs known not to build for x86-64 (the negative cases and the ones needing a manifest) fail for AArch64 too: the AArch64
# half alone does not build them again (a third of the programs, and the slowest to fail).
printf '%s\n' tests/cases/modules/*.ab > "$out/programs.txt"
{ sed -n 's/^nobuild \(.*\)$/tests\/cases\/modules\/\1.ab/p' "$allow" || true; } | sort > "$out/skip.txt"
for target in $targets; do
    if [[ $target == a64 && $targets == a64 ]]; then
        grep -vxF -f "$out/skip.txt" "$out/programs.txt" > "$out/programs-a64.txt" || true
        xargs -P "$workers" -I{} bash -c 'build_one {} a64' < "$out/programs-a64.txt"
    else
        xargs -P "$workers" -I{} bash -c 'build_one {} '"$target" < "$out/programs.txt"
    fi
done
cat "$out"/*.result | sort > "$out/results.txt"
# What happened, as allowlist lines.
awk '$2 == "x86" && $3 == "libc" { print $1, "x86" }
     $2 == "x86" && $3 == "nobuild" { print "nobuild", $1 }
     $2 == "a64" && $3 == "nobuild" { failed[$1] = 1 }
     END { for (name in failed) print "nobuild-a64", name }' "$out/results.txt" | sort -u > "$out/actual.txt"
# An x86-64 build that failed too is not a failure of the AArch64 build only.
if [[ $targets == a64 ]]; then
    { sed -n 's/^nobuild \(.*\)$/\1/p' "$allow" || true; } | sort > "$out/x86-failed.txt"
else
    awk '$2 == "x86" && $3 == "nobuild" { bad[$1] = 1 } END { for (name in bad) print name }' "$out/results.txt" | sort > "$out/x86-failed.txt"
fi
grep -v '^nobuild-a64 ' "$out/actual.txt" > "$out/actual-x86.txt" || true
{ grep '^nobuild-a64 ' "$out/actual.txt" || true; } | while read -r _ name; do
    grep -qx "$name" "$out/x86-failed.txt" || echo "nobuild-a64 $name"
done | sort > "$out/actual-a64.txt"
cat "$out/actual-x86.txt" "$out/actual-a64.txt" | sort -u > "$out/actual.txt"
# The allowlist lines of the targets built.
expected=$out/expected.txt
case $targets in
    x86) { grep -v '^nobuild-a64 ' "$allow" || true; } > "$expected" ;;
    a64) { grep '^nobuild-a64 ' "$allow" || true; } > "$expected" ;;
    *) cp "$allow" "$expected" ;;
esac
new=$(comm -13 "$expected" "$out/actual.txt" || true)
gone=$(comm -23 "$expected" "$out/actual.txt" || true)
if [[ -n $new ]]; then echo "libc free programs: not on $allow, but linking libc or not building:" >&2; echo "$new" >&2; fi
if [[ -n $gone ]]; then echo "libc free programs: on $allow, but static and building now (remove the line):" >&2; echo "$gone" >&2; fi
[[ -z $new && -z $gone ]] || exit 1
echo "libc free programs ($targets): $(grep -c ' static$' "$out/results.txt") static builds of $(wc -l < "$out/results.txt"), $(wc -l < "$expected") allowed exceptions"
