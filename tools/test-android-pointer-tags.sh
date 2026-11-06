#!/usr/bin/env bash
# TBI guest executes production hosted runtime; no tag-stripping load shim.
set -euo pipefail
# The released descriptor guard deliberately traps in the negative control.
ulimit -S -c 0
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sysroot=${ABLA_SYSROOT:-$root}
cd "$root"
out=${ABLA_TAGGED_POINTERS_OUT:-$root/build/android-pointer-tags}
mkdir -p "$out"
python3 -I tests/cases/android-pointer-tags/prepare.py "$root" "$sysroot" "$out"
failures=0
run_case() {
    local name=$1 expected=$2 status=0
    shift 2
    "$@" > "$out/$name.log" 2>&1 || status=$?
    if [[ $status != "$expected" ]]; then
        echo "tagged pointers: FAIL $name: exit $status" >&2
        cat "$out/$name.log" >&2
        failures=$((failures + 1))
    else
        echo "tagged pointers: ok $name (exit $status)"
    fi
}
for profile in release fast; do
    flag=()
    [[ $profile == fast ]] && flag=(--fast)
    "$compiler" build tests/cases/android-pointer-tags/tls.ab -o "$out/tls-$profile" \
        --no-cache ${flag[@]+"${flag[@]}"}
    run_case "tls-$profile" 0 "$out/tls-$profile"
    "$compiler" build "$out/$profile-build.ab" -o "$out/$profile-driver" --fast --no-cache
    for entry in values pages descriptor rsa bad_free bad_realloc; do
        llvm-mc -triple aarch64-linux-gnu -filetype=obj "$out/$entry-start.s" -o "$out/$entry-start.o"
        ld.lld -static --no-pie -z notext "$out/$profile.o" "$out/$entry-start.o" -o "$out/$entry-$profile"
        expected=0
        [[ $entry == bad_* ]] && expected=66
        run_case "$entry-$profile" "$expected" timeout 60 qemu-aarch64 -cpu max "$out/$entry-$profile"
    done
done
[[ $failures == 0 ]] || { echo "tagged pointers: $failures cases failed" >&2; exit 1; }
echo 'tagged pointers: release/fast, negative TLS handle, TBI loads/GC/page keys/sort/descriptors/RSA and original-tag free passed'
