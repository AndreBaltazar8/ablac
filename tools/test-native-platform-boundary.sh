#!/usr/bin/env bash
# A native program is one generated module that carries its own Abla runtime:
# the host platform runtime (stdlib/abla/runtime/platform/host.ab) is compiled
# into it from source, each platform symbol defined there once, and the build
# packages one self-contained object (plus, on macOS, the Linux syscall layer
# as `<output>.host.o`). No separately linked value or platform runtime.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/native-platform-boundary-test"
mkdir -p "$output_directory"
darwin=false
[[ $(uname -s) == Darwin ]] && darwin=true

fail() {
    echo "native platform boundary: $*" >&2
    exit 1
}

expect_exit() { # status memory-mb program
    local status
    set +e
    ABLA_MAX_MEMORY_MB=$2 ABLA_MAX_SECONDS=30 \
        "$project_root/tools/run-limited.sh" "$3"
    status=$?
    set -e
    [[ $status -eq $1 ]] || fail "$3 exited $status, expected $1"
}

# The packaging of one built program: its object, no value runtime, the host
# object only on macOS, and no Abla symbol left for another object to supply
# (on macOS the syscall layer's entry, which its host object defines).
check_packaging() { # output
    local output=$1 unresolved
    [[ -s $output.o ]] || fail "$output.o is missing"
    [[ ! -e $output.value-runtime.o ]] || fail "$output has a separate value runtime"
    if $darwin; then
        [[ -s $output.host.o ]] || fail "$output.host.o (the syscall layer) is missing"
        unresolved=$(nm -u "$output.o" | awk '{print $NF}' | sed 's/^_//' |
            grep '^abla_' | grep -v '^abla_darwin_linux_syscall$' || true)
    else
        [[ ! -e $output.host.o ]] || fail "$output has a host object"
        unresolved=$(nm -u "$output.o" | awk '{print $NF}' | grep '^abla_' || true)
    fi
    [[ -z $unresolved ]] ||
        fail "$output.o leaves Abla runtime symbols unresolved: $unresolved"
    if grep -qx '__longjmp_chk' <<<"$(nm -u "$output.o" | awk '{print $NF}')"; then
        fail "$output.o needs a glibc-only fortified symbol"
    fi
}

pure_output="$output_directory/pure-collections"
"$compiler" build "$project_root/tests/cases/modules/collections.ab" \
    -o "$pure_output"
"$compiler" --emit-llvm "$project_root/tests/cases/modules/collections.ab" \
    > "$output_directory/pure-collections.ll"

# The platform runtime is in the module, once: every platform symbol it uses
# is defined there (none left to a library), none twice (LLVM would rename a
# second definition with a numeric suffix).
module="$output_directory/pure-collections.ll"
defined=$(grep -oE '^define [^@]*@abla_(platform_[a-z0-9_]+|runtime_set_arguments)\(' "$module" |
    sed -E 's/.*@([a-z0-9_]+)\(/\1/' | sort)
[[ -n $defined ]] || fail "the module defines no platform symbol"
duplicated=$(uniq -d <<<"$defined")
[[ -z $duplicated ]] || fail "platform symbols defined more than once: $duplicated"
if grep -qE '@abla_(platform_[a-z0-9_]+|runtime_set_arguments)\.[0-9]+\b' "$module"; then
    fail "a platform symbol was defined twice (renamed copy in the module)"
fi
declared=$(grep -oE '^declare [^@]*@abla_platform_[a-z0-9_]+\(' "$module" |
    sed -E 's/.*@([a-z0-9_]+)\(/\1/' | sort -u || true)
[[ -z $declared ]] || fail "platform symbols declared but not defined: $declared"
for symbol in abla_platform_panic abla_platform_free abla_runtime_set_arguments; do
    grep -qx "$symbol" <<<"$defined" || fail "the module does not define $symbol"
done

check_packaging "$pure_output"
expect_exit 42 64 "$pure_output"

# The object relinks on its own (ELF: lld with section garbage collection).
if $darwin; then
    echo "native platform boundary: relink skipped (ELF linker flags; Linux only)"
else
    clang -fuse-ld=lld -Wl,--gc-sections \
        "$pure_output.o" -o "$pure_output.relinked"
    expect_exit 42 64 "$pure_output.relinked"
fi

panic_output="$output_directory/pure-panic"
"$compiler" build "$project_root/tests/cases/bootstrap/emitted-runtime-panic.ab" \
    -o "$panic_output"
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$panic_output" \
    2> "$output_directory/pure-panic-errors.txt"
panic_status=$?
set -e
[[ $panic_status -eq 101 ]] || fail "the runtime panic exited $panic_status, expected 101"
grep -qx 'panic: index 1 out of bounds for array of size 1' \
    "$output_directory/pure-panic-errors.txt" || fail "the runtime panic's message changed"

for fixture in linux-filesystem filesystem process-capture; do
    output="$output_directory/$fixture"
    "$compiler" build "$project_root/tests/cases/modules/$fixture.ab" -o "$output"
    check_packaging "$output"
    memory=64
    [[ $fixture == linux-filesystem ]] && memory=128
    expect_exit 42 "$memory" "$output"
done

host_output="$output_directory/host-runtime"
"$compiler" build "$project_root/tests/cases/modules/host-runtime.ab" \
    -o "$host_output"
check_packaging "$host_output"

echo "native platform boundary: each program is one module with its platform runtime, defined once"
