#!/usr/bin/env bash
# #806: the module test programs (tests/cases/modules/*.ab) built --fast for x86-64, AArch64 and RISC-V Linux link no C
# library. tools/libc-free-programs-allowlist.txt holds the exceptions, one per line, and may only shrink:
#   <program> x86       an x86-64 build that links libc (it brings a C library: extern "host", an extern:"c" call, or
#                       the compiler's own modules, which link libLLVM). These are the by-design cases: import-alias-externs and unsafe-boundary
#                       (the program names C functions), and the 13 programs that import src/ (libLLVM in process: the pinned shell's libLLVM is
#                       dynamic and needs libc; only the compiler itself is built on the static archives, #806 step C, because the
#                       C library it carries is Abla modules of src/static_libc that a program must contain itself).
#   nobuild <program>   an x86-64 build that fails (the negative cases, and programs that need a manifest or flags)
#   nobuild-a64 <program>  builds for x86-64 but not for AArch64 Linux (libLLVM has no AArch64 build here)
#   nobuild-rv64 <program>  builds for x86-64 but not for RISC-V Linux
# A line whose program is now static and building fails the test, so the line gets removed; a new libc link or a new build
# failure fails it too.
# LIBC_FREE_TARGETS="x86" builds the x86-64 half only (the suite does), "a64" the AArch64 half only (CI does: the whole is 22
# CPU-minutes, 4 minutes on 8 cores, and took 25 on a CI runner); the default is "x86 a64".
# LIBC_FREE_TARGETS=rv64 checks the RISC-V Linux lane.
# LIBC_FREE_RUNNER="qemu-aarch64" runs the compiler under that command, for the statically linked AArch64 compiler (#806 step C): with
# LIBC_FREE_TARGETS=a64 the AArch64 half then has an AArch64 builder end to end, no x86-64 compiler involved (it needs ABLA_SYSROOT for the
# stdlib, and ABLA_STATIC_LLVM_LIB unset, so the programs that import LLVM stay the exceptions the list names).
# Usage: tools/test-libc-free-programs.sh [compiler] [--part 1/3|2/3|3/3] [--list]
# The x86 suite runs three disjoint parts. Standalone and cross-target runs still check the whole directory.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
if (($# > 0)); then shift; fi
part=0
list=0
while (($# > 0)); do
    case $1 in
        --part)
            case ${2:-} in
                1/3|2/3|3/3) part=${2%/*} ;;
                *) echo 'libc free programs: --part must be 1/3, 2/3 or 3/3' >&2; exit 2 ;;
            esac
            shift
            ;;
        --list) list=1 ;;
        *) echo "libc free programs: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
targets=${LIBC_FREE_TARGETS:-x86 a64}
runner=${LIBC_FREE_RUNNER:-}
[[ -z $runner || $targets == a64 ]] || { echo "libc free programs: LIBC_FREE_RUNNER needs LIBC_FREE_TARGETS=a64" >&2; exit 2; }
[[ $targets == x86 || $targets == a64 || $targets == rv64 || $targets == 'x86 a64' ]] ||
    { echo "libc free programs: LIBC_FREE_TARGETS must be x86, a64, rv64 or 'x86 a64'" >&2; exit 2; }
[[ $part == 0 || $targets == x86 ]] ||
    { echo 'libc free programs: --part requires LIBC_FREE_TARGETS=x86' >&2; exit 2; }
programs=(tests/cases/modules/*.ab)
select_programs() {
    printf '%s\n' "${programs[@]}" |
        awk -v part="$part" 'part == 0 || (NR - 1) % 3 + 1 == part'
}
if ((list)); then select_programs; exit 0; fi
[[ $(uname -s) == Linux ]] || { echo 'libc free programs: Linux only'; exit 0; }
allow=tools/libc-free-programs-allowlist.txt
[[ -f $allow ]] || { echo "libc free programs: missing $allow" >&2; exit 1; }
sort -cu "$allow" || { echo "libc free programs: $allow must be sorted and unique" >&2; exit 1; }
out=build/libc-free-programs
if ((part)); then out=$out-part-$part; fi
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
    [[ $target == rv64 ]] && options=(--target riscv64-linux)
    if $runner "$compiler" build "$source" -o "$out/$name.$target" --fast --no-cache "${options[@]}" > "$out/$name.$target.log" 2>&1; then
        if [[ $target == rv64 ]]; then
            local elf
            elf=$(readelf -hlWd "$out/$name.$target") || return 1
            grep -q 'Machine:.*RISC-V' <<< "$elf" && grep -q 'Type:.*DYN' <<< "$elf" ||
                { echo "libc free programs: $name did not build a RISC-V PIE" >&2; return 1; }
            status=static
            if [[ $elf == *INTERP* || $elf == *'(NEEDED)'* ]]; then status=libc; fi
        else
            needed=$(readelf -d "$out/$name.$target" 2> /dev/null | grep -c '(NEEDED)' || true)
            if ((needed == 0)); then status=static; else status=libc; fi
        fi
    else
        status=nobuild
    fi
    echo "$name $target $status" > "$out/$name.$target.result"
}
export -f build_one
export compiler out runner
# The negative cases and programs needing a manifest also fail on the cross targets. A cross-only run skips these known x86-64 failures.
select_programs > "$out/programs.txt"
{ sed -n 's/^nobuild \(.*\)$/tests\/cases\/modules\/\1.ab/p' "$allow" || true; } | sort > "$out/skip.txt"
for target in $targets; do
    if [[ $targets == a64 || $targets == rv64 ]]; then
        grep -vxF -f "$out/skip.txt" "$out/programs.txt" > "$out/programs-$target.txt" || true
        xargs -P "$workers" -I{} bash -c 'build_one "$1" "$2"' _ {} "$target" < "$out/programs-$target.txt"
    else
        xargs -P "$workers" -I{} bash -c 'build_one {} '"$target" < "$out/programs.txt"
    fi
done
cat "$out"/*.result | sort > "$out/results.txt"
# What happened, as allowlist lines.
awk '$2 == "x86" && $3 == "libc" { print $1, "x86" }
     $2 == "x86" && $3 == "nobuild" { print "nobuild", $1 }
     ($2 == "a64" || $2 == "rv64") && $3 == "nobuild" { print "nobuild-" $2, $1 }
     $2 == "rv64" && $3 == "libc" { print $1, "rv64" }' "$out/results.txt" | sort -u > "$out/actual.txt"
# Only count cross failures for programs that build on x86-64.
if [[ $targets == a64 || $targets == rv64 ]]; then
    { sed -n 's/^nobuild \(.*\)$/\1/p' "$allow" || true; } | sort > "$out/x86-failed.txt"
else
    awk '$2 == "x86" && $3 == "nobuild" { bad[$1] = 1 } END { for (name in bad) print name }' "$out/results.txt" | sort > "$out/x86-failed.txt"
fi
grep -vE '^nobuild-(a64|rv64) ' "$out/actual.txt" > "$out/actual-other.txt" || true
{ grep -E '^nobuild-(a64|rv64) ' "$out/actual.txt" || true; } | while read -r reason name; do
    grep -qx "$name" "$out/x86-failed.txt" || printf '%s %s\n' "$reason" "$name"
done | sort > "$out/actual-cross.txt"
cat "$out/actual-other.txt" "$out/actual-cross.txt" | sort -u > "$out/actual.txt"
# With LIBC_FREE_RUNNER the builder is the AArch64 compiler under an emulator, which differs from the x86-64 cross compiler in two named ways
# (tools/libc-free-programs-qemu.txt, may only shrink): `exec NAME`: a program big enough to be built in parts, each by the compiler re-executing
# /proc/self/exe, which qemu-user cannot do without binfmt_misc (execve fails with ENOEXEC; on an AArch64 machine it works), so it must still fail
# to build here; `differs NAME`: the AArch64 compiler builds it where the x86-64 cross compiler cannot, so its nobuild-a64 line does not apply.
runner_failed=0
if [[ -n $runner ]]; then
    qemu_list=tools/libc-free-programs-qemu.txt
    sort -cu "$qemu_list" || { echo "libc free programs: $qemu_list must be sorted and unique" >&2; exit 1; }
    for kind in exec differs; do sed -n "s/^$kind \\(.*\\)\$/\\1/p" "$qemu_list" | sort > "$out/qemu-$kind.txt"; done
    for name in $(cat "$out/qemu-exec.txt"); do
        if grep -qx "$name a64 static" "$out/results.txt"; then
            echo "libc free programs: $name builds under the emulator now (remove its exec line from $qemu_list)" >&2
            runner_failed=1
        fi
    done
    # Their failures are the expected ones: not new.
    { grep -vxF -f <(sed 's/^/nobuild-a64 /' "$out/qemu-exec.txt") "$out/actual.txt" || true; } > "$out/actual.filtered"
    mv "$out/actual.filtered" "$out/actual.txt"
fi
# The allowlist lines of the targets built.
expected=$out/expected.txt
case $targets in
    x86) { grep -vE '^nobuild-(a64|rv64) ' "$allow" || true; } > "$expected" ;;
    a64) { grep '^nobuild-a64 ' "$allow" || true; } > "$expected" ;;
    rv64) { grep '^nobuild-rv64 ' "$allow" || true; } > "$expected" ;;
    *) { grep -v '^nobuild-rv64 ' "$allow" || true; } > "$expected" ;;
esac
if ((part)); then
    # Assign stale allowlist entries to part 1 so they still fail the comparison.
    awk -v part="$part" '
        FNR == NR {
            name = $0
            sub(/^.*\//, "", name); sub(/\.ab$/, "", name)
            owner[name] = (NR - 1) % 3 + 1
            next
        }
        { name = ($1 == "nobuild" ? $2 : $1) }
        (name in owner ? owner[name] : 1) == part
    ' <(printf '%s\n' "${programs[@]}") "$expected" > "$out/expected.part"
    mv "$out/expected.part" "$expected"
fi
if [[ -n $runner ]]; then
    { grep -vxF -f <(sed 's/^/nobuild-a64 /' "$out/qemu-differs.txt") "$expected" || true; } > "$out/expected.filtered"
    mv "$out/expected.filtered" "$expected"
fi
new=$(comm -13 "$expected" "$out/actual.txt" || true)
gone=$(comm -23 "$expected" "$out/actual.txt" || true)
if [[ -n $new ]]; then echo "libc free programs: not on $allow, but linking libc or not building:" >&2; echo "$new" >&2; fi
if [[ -n $gone ]]; then echo "libc free programs: on $allow, but static and building now (remove the line):" >&2; echo "$gone" >&2; fi
[[ -z $new && -z $gone && $runner_failed == 0 ]] || exit 1
echo "libc free programs ($targets): $(grep -c ' static$' "$out/results.txt") static builds of $(wc -l < "$out/results.txt"), $(wc -l < "$expected") allowed exceptions"
