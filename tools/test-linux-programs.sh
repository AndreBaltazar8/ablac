#!/usr/bin/env bash
# Runs selected libc-free programs natively on x86-64 and under QEMU for a Linux cross target.
# Usage: tools/test-linux-programs.sh <aarch64-linux|riscv64-linux> [compiler] [module-build-dir] [part]
# Pass the existing test-libc-free-programs output directory to reuse that job's module images.
# A part (1/3, 2/3 or 3/3) reuses that part's images. Part 1 also runs the non-module cases.
set -euo pipefail
export LC_ALL=C TZ=UTC
target=${1:-}
compiler=${2:-build/ablac}
module_builds=${3:-}
part=${4:-}
case $target in
    aarch64-linux) emulator=qemu-aarch64; suffix=a64; machine=AArch64 ;;
    riscv64-linux) emulator=qemu-riscv64; suffix=rv64; machine=RISC-V ;;
    *) echo 'usage: tools/test-linux-programs.sh <aarch64-linux|riscv64-linux> [compiler] [module-build-dir]' >&2; exit 2 ;;
esac
if [[ $(uname -sm) != 'Linux x86_64' ]]; then
    echo 'linux programs: the native reference requires x86-64 Linux' >&2
    exit 2
fi
command -v "$emulator" >/dev/null || { echo "linux programs: $emulator is required" >&2; exit 2; }
[[ $compiler == /* || $compiler != */* ]] || compiler=$PWD/$compiler
[[ -z $module_builds || $module_builds == /* ]] || module_builds=$PWD/$module_builds
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_GC_STRESS ABLA_TEST_FAST_BUILDS
list=tests/cases/linux/programs.txt
out="$root/build/linux-programs/$target"
if [[ -n $part ]]; then
    case $part in
        1/3|2/3|3/3) out=$out-part-${part%/*} ;;
        *) echo 'linux programs: part must be 1/3, 2/3 or 3/3' >&2; exit 2 ;;
    esac
fi
rm -rf -- "$out"
mkdir -p "$out"
awk '
    NF && $1 !~ /^#/ {
        if (NF != 2 || $1 !~ /^tests\/cases\/[a-zA-Z0-9_./-]+\.ab$/ ||
            $1 ~ /(^|\/)\.\.(\/|$)/ || $2 !~ /^[0-9]+$/ || $2 > 255 || seen[$1]++) {
            print FILENAME ":" FNR ": invalid or duplicate program" > "/dev/stderr"
            bad = 1
        } else print $1, $2
    }
    END { exit bad }
' "$list" > "$out/selected.txt"
[[ -s $out/selected.txt ]] || { echo "linux programs: no programs in $list" >&2; exit 1; }
if [[ -n $part ]]; then
    while read -r source _; do
        [[ -f $source ]] || { echo "linux programs: missing $source" >&2; exit 1; }
    done < "$out/selected.txt"
    LIBC_FREE_TARGETS=$suffix tools/test-libc-free-programs.sh "$compiler" --part "$part" --list > "$out/modules.txt"
    awk -v part="$part" '
        FNR == NR { selected[$1] = 1; next }
        $1 in selected || (part == "1/3" && $1 !~ /^tests\/cases\/modules\/[^/]+\.ab$/)
    ' "$out/modules.txt" "$out/selected.txt" > "$out/selected.part"
    mv "$out/selected.part" "$out/selected.txt"
fi

check_elf() {
    local source=$1 image=$2 machine=$3 log=$4
    readelf -hldW "$image" > "$log" || return 1
    if ! grep -Eq "Machine:.*$machine" "$log" || grep -E 'INTERP|\(NEEDED\)' "$log" > /dev/null; then
        printf 'linux programs: %s expected a libc-free %s ELF (%s)\n' "$source" "$machine" "$log" >&2
        return 1
    fi
}

check_program() {
    local source=$1 expected=$2 dir image native cross status
    if [[ ! -f $source ]]; then
        printf 'linux programs: missing %s\n' "$source" >&2
        return 1
    fi
    dir="$out/${source#tests/cases/}"
    mkdir -p "$dir"/{x86_64,cross}
    native="$dir/native"
    "$compiler" build "$source" --target x86_64-linux --fast --no-cache -o "$native" > "$dir/native.build.log" 2>&1 ||
        { printf 'linux programs: %s failed to build for x86-64 (%s)\n' "$source" "$dir/native.build.log" >&2; return 1; }
    if [[ -n $module_builds && $source =~ ^tests/cases/modules/([^/]+)\.ab$ ]]; then
        cross="$module_builds/${BASH_REMATCH[1]}.$suffix"
        [[ -x $cross ]] || { printf 'linux programs: missing module image %s\n' "$cross" >&2; return 1; }
    else
        cross="$dir/guest"
        "$compiler" build "$source" --target "$target" --fast --no-cache -o "$cross" > "$dir/guest.build.log" 2>&1 ||
            { printf 'linux programs: %s failed to build for %s (%s)\n' "$source" "$target" "$dir/guest.build.log" >&2; return 1; }
    fi
    check_elf "$source" "$native" 'Advanced Micro Devices X86-64' "$dir/native.elf.log" || return 1
    check_elf "$source" "$cross" "$machine" "$dir/guest.elf.log" || return 1
    status=0
    (cd "$dir/x86_64" && timeout -k 2 30 "$native" < /dev/null) > "$dir/native.out" 2> "$dir/native.err" || status=$?
    printf '%s\n' "$status" > "$dir/native.status"
    if [[ $status != "$expected" ]]; then
        printf 'linux programs: %s exited %s on x86-64, expected %s (%s)\n' "$source" "$status" "$expected" "$dir/native.err" >&2
        return 1
    fi
    status=0
    (cd "$dir/cross" && timeout -k 2 30 "$emulator" "$cross" < /dev/null) > "$dir/guest.out" 2> "$dir/guest.err" || status=$?
    printf '%s\n' "$status" > "$dir/guest.status"
    if [[ $status != "$expected" ]]; then
        printf 'linux programs: %s exited %s on %s, expected %s (%s)\n' "$source" "$status" "$target" "$expected" "$dir/guest.err" >&2
        return 1
    fi
    if ! cmp -s "$dir/native.out" "$dir/guest.out"; then
        printf 'linux programs: %s stdout differs on %s\n' "$source" "$target" >&2
        diff -u "$dir/native.out" "$dir/guest.out" >&2 || true
        return 1
    fi
}

export -f check_program check_elf
export compiler target emulator out module_builds suffix machine
workers=${ABLA_TEST_JOBS:-4}
[[ $workers =~ ^[1-9][0-9]*$ ]] || { echo 'linux programs: ABLA_TEST_JOBS must be positive' >&2; exit 2; }
xargs -r -P "$workers" -n 2 bash -euo pipefail -c 'check_program "$@"' _ < "$out/selected.txt"
printf 'linux programs (%s): %s libc-free programs match x86-64 stdout and exit status\n' "$target" "$(wc -l < "$out/selected.txt")"
