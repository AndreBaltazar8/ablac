#!/usr/bin/env bash
# Programs built for valgrind (#1217; `ablac build --valgrind`, or ABLA_VALGRIND=1): the runtime tells memcheck about its heap, which memcheck cannot see
# otherwise (the runtime takes its memory from the system, not from a malloc valgrind replaces), so
#   - standard-library programs report nothing under memcheck, with the collector's stress mode (a collection at every
#     safe point) and without, and end as they do without valgrind (42);
#   - a use of freed memory through the runtime's memcpy (extern:"c") is reported: a native buffer read after close() and
#     a string's bytes read after a collection freed the string (tests/cases/valgrind/use-after-free.ab), each as an
#     invalid read inside a freed block; without an argument the same program reports nothing;
#   - a build for valgrind and a plain one never share the prebuilt runtime object (src/toolchain.ab,
#     bootstrapFastRuntimeEligible): built one after the other, the plain program makes no requests (memcheck counts no
#     heap block) and the valgrind one does.
# x86-64 Linux only here (the suite's host). Without valgrind it skips with a message, except in the development shell
# (shell.nix, which CI's Linux suite runs in, has valgrind and sets ABLAC_DEV_SHELL): there a missing valgrind fails, so
# a skip never passes for a run.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/valgrind
rm -rf "$out"
mkdir -p "$out"
fail() { echo "valgrind: $1" >&2; exit 1; }
[[ $(uname -s)/$(uname -m) == Linux/x86_64 ]] || { echo 'valgrind: x86-64 Linux only; skipped'; exit 0; }
if ! command -v valgrind > /dev/null; then
    [[ -z ${ABLAC_DEV_SHELL:-} ]] || fail 'no valgrind in the development shell (shell.nix lists it)'
    echo 'valgrind: no valgrind; skipped'
    exit 0
fi
suppressions=$root/tools/valgrind.supp
# memcheck <log> <program> [arguments...]: the run's status in $status; 9 when memcheck reported anything.
memcheck() {
    local log=$1
    shift
    status=0
    timeout 600 valgrind --error-exitcode=9 --suppressions="$suppressions" --log-file="$log" "$@" \
        > "$log.out" 2>&1 || status=$?
}
build() { # build <source> <output> flag|env|plain: --valgrind, ABLA_VALGRIND=1 or neither
    local source=$1 output=$2 how=$3 flags=() environment=()
    [[ $how == flag ]] && flags=(--valgrind)
    [[ $how == env ]] && environment=(ABLA_VALGRIND=1)
    # -g: the suite builds with ABLA_DEBUG=0, which makes a bare --fast build one without the names the reports check.
    env "${environment[@]}" "$compiler" build "$source" -o "$output" --fast -g --no-cache "${flags[@]}" > "$output.log" 2>&1 ||
        { cat "$output.log" >&2; fail "$source did not build"; }
}

# Standard-library programs: nothing reported, the program's own status.
# (Each allocates: memcheck must see its heap. defer.ab and date.ab, for one, allocate almost nothing.)
programs=(modules/bytes modules/collections modules/concurrency modules/classes modules/crypto modules/json-document
    modules/text-unicode)
for program in "${programs[@]}"; do
    name=${program//\//-}
    build "tests/cases/$program.ab" "$out/$name" flag
    for stress in 0 1; do
        ABLA_GC_STRESS=$stress memcheck "$out/$name-$stress.vg" "$out/$name"
        [[ $status == 42 ]] ||
            fail "$program (GC stress $stress) under memcheck: status $status: $(grep -m3 -E 'Invalid|uninitialised|ERROR SUMMARY' "$out/$name-$stress.vg")"
        grep -q 'ERROR SUMMARY: 0 errors' "$out/$name-$stress.vg" || fail "$program (GC stress $stress): no clean summary"
        # The heap is memcheck's to see: the program's objects are blocks.
        grep -qE 'total heap usage: [1-9][0-9,]* allocs' "$out/$name-$stress.vg" ||
            fail "$program (GC stress $stress): memcheck saw no heap: $(grep 'total heap usage' "$out/$name-$stress.vg")"
    done
done

# The planted uses of freed memory.
build tests/cases/valgrind/use-after-free.ab "$out/use-after-free" flag
memcheck "$out/use-after-free-none.vg" "$out/use-after-free"
[[ $status == 0 ]] || fail "use-after-free without an argument: status $status: $(grep -m3 -E 'Invalid|ERROR SUMMARY' "$out/use-after-free-none.vg")"
for case in buffer collected; do
    memcheck "$out/use-after-free-$case.vg" "$out/use-after-free" "$case"
    [[ $status == 9 ]] || fail "the $case use after free was not reported (status $status)"
    grep -q 'Invalid read of size 8' "$out/use-after-free-$case.vg" &&
        grep -qE "is 0 bytes inside a block of size [0-9,]+ free'd" "$out/use-after-free-$case.vg" ||
        fail "the $case use after free: $(grep -m4 -E 'Invalid|inside|ERROR SUMMARY' "$out/use-after-free-$case.vg")"
done
grep -q 'memory.NativeByteBuffer.close' "$out/use-after-free-buffer.vg" || fail 'the buffer was not freed by its close()'
grep -q '__ablaRuntimeHostCollectionSweep' "$out/use-after-free-collected.vg" || fail 'the string was not freed by a sweep'

# No shared runtime object: valgrind, plain, valgrind again, with the prebuilt runtime object allowed.
source=tests/cases/valgrind/use-after-free.ab
for step in valgrind-1:flag plain:plain valgrind-2:env; do
    IFS=: read -r name how <<< "$step"
    build "$source" "$out/object-$name" "$how"
    memcheck "$out/object-$name.vg" "$out/object-$name"
    [[ $status == 0 ]] || fail "object-$name under memcheck: status $status"
    usage=$(grep 'total heap usage' "$out/object-$name.vg")
    if [[ $how != plain ]]; then
        grep -qE 'total heap usage: [1-9]' <<< "$usage" || fail "the $name build makes no requests: $usage"
    else
        grep -q 'total heap usage: 0 allocs, 0 frees' <<< "$usage" || fail "the plain build makes requests (a shared runtime object): $usage"
    fi
done
# --valgrind is refused for a target valgrind does not run (a Windows program).
if "$compiler" build tests/cases/valgrind/use-after-free.ab -o "$out/windows.exe" --target x86_64-windows-hosted --fast --no-cache \
    --valgrind > "$out/windows.log" 2>&1; then fail "a Windows build took --valgrind"; fi
grep -q 'E_BUILD_VALGRIND_TARGET' "$out/windows.log" || fail "the Windows refusal: $(head -3 "$out/windows.log")"
echo "valgrind: ${#programs[@]} programs built with --valgrind report nothing under memcheck (GC stress on and off), two uses of freed memory are reported, a plain build next to a valgrind one (--valgrind, ABLA_VALGRIND=1) makes no requests, and a Windows target is refused"
