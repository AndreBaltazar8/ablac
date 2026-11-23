#!/usr/bin/env bash
# Hosted RV64 Linux executables use Abla's runtime and their own entry.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'riscv64 linux: Linux only'; exit 0; }
command -v qemu-riscv64 > /dev/null || { echo 'riscv64 linux: qemu-riscv64 is required' >&2; exit 1; }
mkdir -p build
out=$(mktemp -d "$PWD/build/riscv64-linux.XXXXXX")
echo "riscv64 linux: logs in $out"
ulimit -c 0

fail() { printf 'riscv64 linux: %s\n' "$*" >&2; exit 1; }

build_rv64() {
    local source=$1 target=$2
    shift 2
    ABLA_TEST_FAST_BUILDS=0 "$compiler" build "tests/cases/$source.ab" --target riscv64-linux \
        -o "$target" --no-cache "$@" > "$target.build.log" 2>&1 ||
        { cat "$target.build.log" >&2; fail "$source did not build"; }
    readelf -hW "$target" > "$target.header"
    readelf -lW "$target" > "$target.segments"
    readelf -dW "$target" > "$target.dynamic"
    grep -q 'Machine:.*RISC-V' "$target.header" || fail "$source has the wrong ELF machine"
    grep -q 'Type:.*DYN' "$target.header" || fail "$source is not static PIE"
    if grep -q 'INTERP' "$target.segments" || grep -q '(NEEDED)' "$target.dynamic"; then
        fail "$source needs a loader or shared library"
    fi
}

run_rv64() {
    local target=$1 expected=$2 status=0
    shift 2
    (cd "$out" && timeout 120 qemu-riscv64 "$target" "$@") \
        < /dev/null > "$target.out" 2> "$target.err" || status=$?
    [[ $status == "$expected" ]] || {
        cat "$target.out" "$target.err" >&2
        fail "$target returned $status, expected $expected"
    }
}

for mode in fast release; do
    flags=()
    if [[ $mode == fast ]]; then flags+=(--fast); fi
    for source in libc-imports/{hello,files,float-remainder,threads} linux-syscall/{main,legacy,epoll,random} thread-local-image/main stm/basic gc-threads/waiting; do
        bin="$out/${source//\//-}-$mode"
        expected=42
        case $source in libc-imports/*|linux-syscall/random) expected=0 ;; esac
        build_rv64 "$source" "$bin" "${flags[@]}"
        run_rv64 "$bin" "$expected"
        case $source in
            libc-imports/hello) grep -Fxq hello "$bin.out" || fail 'hello output differed' ;;
            libc-imports/files) grep -Fxq abc "$bin.out" || fail 'file contents differed' ;;
            libc-imports/threads) grep -Fxq 42 "$bin.out" || fail 'worker result differed' ;;
        esac
    done

    for source in stack-overflow thread-stack-overflow; do
        bin="$out/$source-$mode"
        build_rv64 "linux-syscall/$source" "$bin" "${flags[@]}"
        run_rv64 "$bin" 101
        grep -Fxq 'panic: stack overflow' "$bin.err" || fail "$source lacked the overflow diagnostic"
    done
done
ABLA_GC_STRESS=1 run_rv64 "$out/gc-threads-waiting-fast" 42
ABLA_DEBUG=1 build_rv64 linux-syscall/fault "$out/fault" --fast
run_rv64 "$out/fault" 139
grep -q '^fatal signal' "$out/fault.err" || fail 'expected a fatal signal diagnostic'
grep -q '^0x' "$out/fault.err" || fail 'expected a fault frame'
echo 'riscv64 linux: static PIE programs passed under QEMU in fast and release'
