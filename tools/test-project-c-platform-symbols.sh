#!/usr/bin/env bash
# The raw-Linux tests (test-linux-io, -sleep, -arguments, -process) look for a global project C platform symbol with
# tools/lib/project-c-platform-symbols.sh. This checks the check: a raw (no libc) program that defines and calls a global abla_platform_*
# function is found, one with only a local (static) abla_platform_panic, as the Abla-defined platform runtime has, is not, and neither is
# a program without any.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
. "$root/tools/lib/project-c-platform-symbols.sh"
[[ $(uname -s) == Linux ]] || { echo 'project C platform symbols: Linux only'; exit 0; }
out="$root/build/project-c-platform-symbols"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "project C platform symbols: $1" >&2; exit 1; }
build() { # name, C source: a raw program that exits with the function's result
    printf '%s\n' "$2" > "$out/$1.c"
    clang -O0 -nostdlib -static -fno-stack-protector -o "$out/$1" "$out/$1.c" || fail "$1 did not build"
}
build global 'int abla_platform_probe(void) { return 3; }
void _start(void) { __asm__ volatile("syscall" :: "a"(60), "D"(abla_platform_probe())); }'
build local '__attribute__((noinline, used)) static int abla_platform_panic(void) { return 3; }
void _start(void) { __asm__ volatile("syscall" :: "a"(60), "D"(abla_platform_panic())); }'
build none 'void _start(void) { __asm__ volatile("syscall" :: "a"(60), "D"(3)); }'
for program in global local none; do
    "$out/$program" && status=0 || status=$?
    [[ $status -eq 3 ]] || fail "$program: unexpected exit status $status"
done
has_project_c_platform_symbol "$out/global" || fail "a program with a global abla_platform_ function was not reported"
! has_project_c_platform_symbol "$out/local" || fail "a local abla_platform_panic was reported (it is the Abla-defined one)"
! has_project_c_platform_symbol "$out/none" || fail "a program with no platform symbol was reported"
echo 'project C platform symbols: a global abla_platform_ symbol is reported; a local one and none are not'
