#!/usr/bin/env bash
# Cross-build the RV64 compiler with the real shim and test its native ELF path.
# Supply the RV64 LLVM/lld archives and target libraries to build-static-compiler.sh.
set -euo pipefail
export LC_ALL=C
ulimit -c 0
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
qemu=$(command -v qemu-riscv64) || { echo 'static compiler riscv64: qemu-riscv64 is required' >&2; exit 1; }
out="$root/build/static-compiler-riscv64"
mkdir -p "$out"
guest_path=$(mktemp -d "$out/empty-path.XXXXXX")
trap 'rmdir -- "$guest_path"' EXIT
fail() { printf 'static compiler riscv64: %s\n' "$*" >&2; exit 1; }

check_image() {
    local image=$1
    readelf -hlWd "$image" > "$image.elf"
    grep -q 'Machine:.*RISC-V' "$image.elf" || fail "$image has the wrong architecture"
    grep -q 'Type:.*DYN' "$image.elf" || fail "$image is not PIE"
    grep -q 'double-float ABI' "$image.elf" || fail "$image is not LP64D"
    if grep -Eq 'INTERP|\(NEEDED\)' "$image.elf"; then fail "$image needs a loader or shared library"; fi
}

binary="$out/ablac-static-riscv64-linux"
ABLA_STATIC_TARGET=riscv64-linux tools/build-static-compiler.sh "$compiler" "$binary" > "$out/build.log" 2>&1 ||
    { tail -50 "$out/build.log" >&2; fail 'could not cross-build the RV64 compiler'; }
check_image "$binary"
sha256sum "$binary" > "$out/compiler.sha256"

# One same-target object and an ELF link need no guest child process. The
# fresh environment also rules out external LLVM tools or archive overrides.
guest=(env -i PATH="$guest_path" HOME="$out" ABLA_SYSROOT="$root" ABLA_CODEGEN_UNITS=1 "$qemu" "$binary")
for mode in release fast; do
    flags=()
    if [[ $mode == fast ]]; then flags+=(--fast); fi
    executable="$out/hello-$mode"
    "${guest[@]}" build tests/cases/libc-imports/hello.ab --no-cache \
        -o "$executable" "${flags[@]}" > "$executable.build.log" 2>&1 ||
        { cat "$executable.build.log" >&2; fail "hello $mode did not build with an empty PATH"; }
    check_image "$executable"
    "$qemu" "$executable" > "$executable.out" 2> "$executable.err" ||
        { cat "$executable.err" >&2; fail "hello $mode did not run"; }
    [[ $(cat "$executable.out") == hello ]] || fail "hello $mode printed an unexpected result"
done
echo 'static compiler riscv64: release and fast hello passed under QEMU with an empty PATH'

# A self-build uses the assembler in the shim for its libc data object.
cat > "$out/mc.s" <<'ASM'
.text
.globl abla_mc_probe
abla_mc_probe:
    fadd.d fa0, fa0, fa1
    ret
ASM
"${guest[@]}" --llvm-tool llvm-mc -triple=riscv64-unknown-linux-gnu \
    -mattr=+m,+a,+f,+d,+c,+zicsr,+zifencei -target-abi=lp64d -filetype=obj -o "$out/mc.o" "$out/mc.s" \
    > "$out/mc.log" 2>&1 || { cat "$out/mc.log" >&2; fail 'llvm-mc failed with an empty PATH'; }
readelf -hsW "$out/mc.o" > "$out/mc.elf"
grep -q 'Machine:.*RISC-V' "$out/mc.elf" &&
    grep -q 'double-float ABI' "$out/mc.elf" &&
    grep -q ' abla_mc_probe$' "$out/mc.elf" || fail 'llvm-mc did not produce the expected LP64D object'
echo 'static compiler riscv64: llvm-mc assembled an LP64D object with an empty PATH'
