#!/usr/bin/env bash
# The macOS counterpart of tools/test-libc-imports.sh (#811): lists the libSystem
# imports of the programs in tests/cases/libc-imports (release and --fast) and of
# the compiler, and fails on one that tools/libsystem-imports-allowlist.txt does
# not hold. The list is the union of CI's Apple Silicon and Intel runners (tools/macos-libsystem-
# inventory.sh) and may only shrink: remove a line when its import goes away. A
# line is "<subject> <symbol>"; a needed library is "needed:<install name>". An
# import that only the other architecture has is fine: stale lines are reported,
# never failed. Darwin only; Linux has tools/test-libc-imports.sh.
# Usage: tools/test-libsystem-imports.sh [compiler]
set -euo pipefail
export LC_ALL=C
if [[ $(uname -s) != Darwin ]]; then
    echo 'libsystem imports: Darwin only (Linux has test-libc-imports.sh)'
    exit 0
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compiler=${1:-build/ablac}
allow=tools/libsystem-imports-allowlist.txt
[[ -f $allow ]] || { echo "libsystem imports: missing $allow" >&2; exit 1; }
if ! sort -cu "$allow"; then
    echo "libsystem imports: $allow must be sorted and unique" >&2
    exit 1
fi
# The list was taken with ABLA_DEBUG=0, as the suite runs.
export ABLA_DEBUG=0
unset ABLA_TEST_FAST_BUILDS
mkdir -p build
out=build/libsystem-imports
tools/macos-libsystem-inventory.sh "$compiler" "$out" > "$out.log" 2>&1 || { tail -n 30 "$out.log" >&2; exit 1; }
actual=$out/actual.txt
if grep -q BUILD-FAILED "$actual"; then
    echo "libsystem imports: a program did not build:" >&2
    grep BUILD-FAILED "$actual" >&2
    exit 1
fi
new=$(comm -13 "$allow" "$actual")
if [[ -n $new ]]; then
    echo 'libsystem imports: not in tools/libsystem-imports-allowlist.txt (a new libSystem import is a regression):' >&2
    echo "$new" >&2
    exit 1
fi
stale=$(comm -23 "$allow" "$actual")
if [[ -n $stale ]]; then
    echo 'libsystem imports: no longer imported here, remove from tools/libsystem-imports-allowlist.txt (unless only the other architecture has it):'
    echo "$stale"
fi
echo "libsystem imports: $(wc -l < "$actual" | tr -d ' ') imports, all within the allowed list"
