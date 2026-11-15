#!/usr/bin/env bash
# tools/test-libsystem-imports.sh's program check, run away from a Mac (#811): links each program of
# tests/cases/libc-imports for arm64-macos and x86_64-macos, release and --fast, with the macOS SDK
# in ABLA_MACOS_SDK, and lists each executable's libSystem imports the way the Mac job does
# ("<program>.<mode> <symbol>"; both architectures together, as the allowlist is their union).
# It fails on a line missing from tools/libsystem-imports-allowlist.txt (a new import). Lines of
# the list that no longer appear here are reported only, since the Mac's toolchain can differ
# (when this was written every program line matched except tasks.fast _pthread_join, which only
# the Mac links). Not checked: the compiler's lines (not linked here) and tls-http (it links
# Homebrew's OpenSSL). A local pre-check before a Mac CI round, not part of CI (the Linux runner
# has no macOS SDK). Needs llvm-nm (nix-shell).
# Usage: ABLA_MACOS_SDK=<MacOSX.sdk> tools/macos-local-imports.sh [compiler]
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ -n ${ABLA_MACOS_SDK:-} ]] || { echo 'macos local imports: set ABLA_MACOS_SDK to a macOS SDK' >&2; exit 2; }
command -v llvm-nm > /dev/null || { echo 'macos local imports: llvm-nm not found (run inside nix-shell)' >&2; exit 2; }
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export ABLA_DEBUG=0
unset ABLA_TEST_FAST_BUILDS
grep -v '^#' "$root/tools/libsystem-imports-allowlist.txt" |
    grep -v -e '^compiler ' -e '^tls-http\.' -e ' needed:<brew>/' | sed 's/ ?$//' | sort -u > "$out/allow.txt"
subjects=$(awk '{split($1, part, "."); print part[1]}' "$out/allow.txt" | sort -u)
for name in $subjects; do
    # A "dylib-<name>" subject is tests/cases/libsystem-dylibs/<name>.ab, built as a dylib (#833).
    emit=()
    if [[ $name == dylib-* ]]; then
        program=$root/tests/cases/libsystem-dylibs/${name#dylib-}.ab
        emit=(--emit shared-library)
    else
        program=$root/tests/cases/libc-imports/$name.ab
    fi
    [[ -f $program ]] || { echo "macos local imports: no $program for the list's $name lines" >&2; exit 1; }
    for arch in arm64 x86_64; do
        for mode in release fast; do
            flags=(--no-cache ${emit[@]+"${emit[@]}"})
            [[ $mode == fast ]] && flags+=(--fast)
            binary=$out/$name.$arch.$mode
            if ! "$compiler" build "$program" --target "$arch-macos" -o "$binary" "${flags[@]}" \
                > "$out/build.log" 2>&1; then
                echo "$name.$mode BUILD-FAILED ($arch)"
                tail -n 5 "$out/build.log" >&2
                continue
            fi
            # lld (the linker here) leaves dyld_stub_binder undefined in the symbol table of an image with
            # chained fixups, with nothing bound to it; Apple's ld, which the Mac links with, does not (#811 G5).
            chained=$(llvm-objdump --macho --private-headers "$binary" | grep -c LC_DYLD_CHAINED_FIXUPS || true)
            llvm-nm -u "$binary" | awk -v subject="$name.$mode" -v chained="$chained" \
                '!(chained > 0 && $NF == "dyld_stub_binder") {print subject, $NF}'
            echo "$name.$mode needed:/usr/lib/libSystem.B.dylib"
        done
    done
done | sort -u > "$out/actual.txt"
status=0
if grep -q BUILD-FAILED "$out/actual.txt"; then
    grep BUILD-FAILED "$out/actual.txt" >&2
    status=1
fi
grep -v BUILD-FAILED "$out/actual.txt" > "$out/imports.txt" || true
new=$(comm -13 "$out/allow.txt" "$out/imports.txt")
if [[ -n $new ]]; then
    printf 'macos local imports: not in the allowlist (a new libSystem import):\n%s\n' "$new" >&2
    status=1
fi
stale=$(comm -23 "$out/allow.txt" "$out/imports.txt")
if [[ -n $stale ]]; then
    printf 'macos local imports: in the allowlist, not imported here (check on the Mac):\n%s\n' "$stale" >&2
fi
if [[ $status -eq 0 ]]; then
    echo "macos local imports: $(wc -l < "$out/imports.txt" | tr -d ' ') imports, all in the allowlist (tls-http and the compiler not checked)"
fi
exit "$status"
