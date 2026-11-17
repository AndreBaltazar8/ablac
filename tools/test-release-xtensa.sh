#!/usr/bin/env bash
# A released toolchain archive, unpacked, builds for Xtensa once the optional companion is installed (#575).
# 1. Before the install, an Xtensa build stops with E_XTENSA_LLVM_MISSING naming this archive's installer.
# 2. The archive's own bin/abla-install-xtensa installs and verifies the published companion (a network download, checked
#    against the catalog the archive ships).
# 3. The packaged compiler builds objects with that companion, and each is byte-identical to the one the same compiler
#    builds with the reference cohort (the Nix full-backend LLVM): the portable companion must not change the code.
#    The compiler is the same in both, so a hash recorded for an older compiler cannot go stale here.
# 4. With `opt` and `llc` on PATH poisoned, the compiler still finds the installed cohort from its own image.
# The reference cohort's root (a nix-shell exports it as ABLA_XTENSA_LLVM_ROOT) is the second argument or
# ABLA_XTENSA_REFERENCE_ROOT; macOS has none, and then step 3 only checks that the objects build and are ELF.
# Usage: test-release-xtensa.sh <unpacked toolchain> [reference cohort root] [output dir]
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "release xtensa: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
prefix=$(cd -- "${1:?usage: test-release-xtensa.sh <unpacked toolchain> [reference cohort root] [output dir]}" && pwd)
reference=${2:-${ABLA_XTENSA_REFERENCE_ROOT:-}}
[[ -z $reference || -f $reference/manifest.json ]] || fail "the reference cohort root $reference has no manifest.json"
out=${3:-$root/build/release-xtensa}
mkdir -p "$out"
out=$(cd -- "$out" && pwd)
[[ -x $prefix/bin/abla-install-xtensa && -x $prefix/bin/ablac ]] || fail "$prefix is not an unpacked toolchain"
unset ABLA_XTENSA_LLVM_ROOT ABLA_ESP_CPU ABLA_XTENSA_FEATURES ABLA_XTENSA_NARROW ABLA_CACHE_DIR
compiler=$prefix/bin/ablac
object() { # object <source> <output> [extra build arguments]
    local source=$1 output=$2; shift 2
    "$compiler" build "$source" -o "$output" --target-triple xtensa-esp-unknown-elf --object-format elf --emit object \
        --no-cache --no-debug "$@"
}

printf 'fun main: int = 0\n' > "$out/empty.ab"
status=0
object "$out/empty.ab" "$out/before.o" > "$out/before.log" 2>&1 || status=$?
[[ $status != 0 ]] || fail "an Xtensa build with no companion installed succeeded" "$out/before.log"
grep -q 'E_XTENSA_LLVM_MISSING' "$out/before.log" || fail "no E_XTENSA_LLVM_MISSING before the install" "$out/before.log"
grep -q "$prefix/bin/abla-install-xtensa" "$out/before.log" ||
    fail "the error does not name this toolchain's installer, $prefix/bin/abla-install-xtensa" "$out/before.log"

"$prefix/bin/abla-install-xtensa" --version 23.1.3-1 > "$out/install.log" 2>&1 || fail "the install failed" "$out/install.log"
"$prefix/bin/abla-install-xtensa" --verify >> "$out/install.log" 2>&1 || fail "the verify failed" "$out/install.log"

# One object per (source, CPU, mode); the last two are the narrowing off and the optimized build.
cases=(
    "tests/cases/f32/xtensa.ab esp32 1"
    "tests/cases/xtensa-routing/intrinsics.ab esp32s3 1 --fast"
    "tests/cases/xtensa-routing/intrinsics.ab esp32 0"
)
index=0
for entry in "${cases[@]}"; do
    read -r source cpu narrow extra <<< "$entry"
    index=$((index + 1))
    for kind in installed ${reference:+reference}; do
        if [[ $kind == reference ]]; then export ABLA_XTENSA_LLVM_ROOT=$reference; else unset ABLA_XTENSA_LLVM_ROOT; fi
        ABLA_ESP_CPU=$cpu ABLA_XTENSA_NARROW=$narrow object "$root/$source" "$out/$index-$kind.o" ${extra:-} \
            > "$out/$index-$kind.log" 2>&1 || fail "$source ($kind cohort) did not build" "$out/$index-$kind.log"
    done
    unset ABLA_XTENSA_LLVM_ROOT
    [[ -z $reference ]] || cmp "$out/$index-installed.o" "$out/$index-reference.o" ||
        fail "$source ($cpu, narrowing $narrow): the installed companion's object differs from the reference cohort's"
    [[ $(head -c 4 "$out/$index-installed.o" | od -An -c | tr -d ' ') == '177ELF' ]] || fail "$source: not an ELF object"
    grep -q 'abla-xtensa-tools-v1' "$out/$index-installed.o.xtensa-tools.json" 2>/dev/null ||
        fail "$source: no build manifest $out/$index-installed.o.xtensa-tools.json"
done

# `opt` and `llc` on PATH must not matter: the cohort comes from the installed toolchain.
poison=$out/poison
mkdir -p "$poison"
for tool in opt llc; do printf '#!/bin/sh\necho XTENSA_PATH_POISON >&2\nexit 91\n' > "$poison/$tool"; chmod +x "$poison/$tool"; done
PATH=$poison:$PATH object "$root/tests/cases/xtensa-routing/intrinsics.ab" "$out/poison.o" > "$out/poison.log" 2>&1 ||
    fail "the build used a tool from PATH" "$out/poison.log"
echo "release xtensa: passed ($prefix; ${#cases[@]} objects${reference:+ equal those of the reference cohort})"
