#!/usr/bin/env bash
# tools/release-check.sh and the static compiler (#806 step C): the static asset is an optional extra (neither expected nor an extra in
# the `assets` check, with or without it in the previous release's names), checked by `static` when present, and that check fails a
# file that is not a static-pie executable. Fake artifacts, no network: the convergence line fails without a run and is not judged.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
mkdir artifacts
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-x86_64-linux
chmod +x artifacts/ablac-x86_64-linux
cp artifacts/ablac-x86_64-linux stage2
printf 'toolchain' > artifacts/abla-toolchain-x86_64-linux.tar.gz
for name in ablac-x86_64-linux abla-toolchain-x86_64-linux.tar.gz; do (cd artifacts && sha256sum "$name" > "$name.sha256"); done
ls artifacts | sort > expected-without
run() { # EXPECTED-FILE OUT -> the output lines
    "$root/tools/release-check.sh" v9.9.9 1 stage2 --artifacts artifacts --assets-from "$1" --out "$2" --source-ref 0000000000000000000000000000000000000000 2>&1 || true
}
line() { grep -E "^(PASS|FAIL|SKIP) +$1 " <<< "$2" || true; }
without=$(run expected-without out1)
[[ $(line assets "$without") == PASS* ]] || { echo "assets without the static asset: $(line assets "$without")" >&2; exit 1; }
[[ -z $(line static "$without") ]] || { echo "a static line without a static asset" >&2; exit 1; }
# a static asset that is a script, not an executable image
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-static-x86_64-linux
(cd artifacts && sha256sum ablac-static-x86_64-linux > ablac-static-x86_64-linux.sha256)
with=$(run expected-without out2)
[[ $(line assets "$with") == PASS* ]] || { echo "assets with the static asset: $(line assets "$with")" >&2; exit 1; }
[[ $(line sha256 "$with") == PASS* ]] || { echo "sha256 with the static asset: $(line sha256 "$with")" >&2; exit 1; }
[[ $(line static "$with") == FAIL* ]] || { echo "a script passed as the static compiler: $(line static "$with")" >&2; exit 1; }
# the AArch64 static asset: also an optional extra (neither expected nor an extra), judged by its own line, `static-aarch64`. A file that is
# not an AArch64 ELF fails there where the host can run one; on a host without qemu-aarch64 (the PATH below has none) the line is SKIP, which
# does not fail the check.
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-static-aarch64-linux
(cd artifacts && sha256sum ablac-static-aarch64-linux > ablac-static-aarch64-linux.sha256)
aarch=$(run expected-without out4)
[[ $(line assets "$aarch") == PASS* ]] || { echo "assets with the aarch64 static asset: $(line assets "$aarch")" >&2; exit 1; }
[[ $(line sha256 "$aarch") == PASS* ]] || { echo "sha256 with the aarch64 static asset: $(line sha256 "$aarch")" >&2; exit 1; }
if command -v qemu-aarch64 > /dev/null || [[ $(uname -m) == aarch64 ]]; then
    [[ $(line static-aarch64 "$aarch") == FAIL* ]] || { echo "a script passed as the aarch64 static compiler: $(line static-aarch64 "$aarch")" >&2; exit 1; }
fi
bin=$(mktemp -d)
for tool in bash env ls sort uniq comm diff grep awk sed mktemp rm cat tr head tail cmp dirname uname readelf sha256sum date printf mv cp mkdir chmod wc cut basename tee find xargs ln; do
    path=$(command -v "$tool" 2> /dev/null || true)
    [[ -z $path ]] || ln -s "$path" "$bin/$tool"
done
noqemu=$(PATH=$bin "$root/tools/release-check.sh" v9.9.9 1 stage2 --artifacts artifacts --assets-from expected-without --out out5 --source-ref 0000000000000000000000000000000000000000 2>&1 || true)
! grep -q "command not found" <<< "$noqemu" || { echo "the restricted PATH lacks a tool release-check uses: $(grep "command not found" <<< "$noqemu" | head -2)" >&2; exit 1; }
rm -rf -- "$bin"
if [[ $(uname -m) != aarch64 ]]; then
    [[ $(line static-aarch64 "$noqemu") == SKIP* ]] || { echo "no qemu-aarch64: the aarch64 static line is not a SKIP:" >&2; echo "$noqemu" >&2; exit 1; }
    ! grep -q '^FAIL.*static-aarch64' <<< "$noqemu" || { echo "a SKIP failed the check" >&2; exit 1; }
fi
rm -f artifacts/ablac-static-aarch64-linux artifacts/ablac-static-aarch64-linux.sha256
# the previous release's names include the static asset: a release without it is not missing it
(cd artifacts && ls | sort) > expected-with
rm -f artifacts/ablac-static-x86_64-linux artifacts/ablac-static-x86_64-linux.sha256
again=$(run expected-with out3)
[[ $(line assets "$again") == PASS* ]] || { echo "assets, static expected, none built: $(line assets "$again")" >&2; exit 1; }
# Decision #90 A (the static compiler is ablac-x86_64-linux, the dynamic one ablac-dynamic-x86_64-linux): the dynamic asset is what is compared with
# stage 2 and is no extra name; check 7 judges ablac-x86_64-linux (here a script, so it fails as a non-static-pie file; without static LLVM archives
# the default asset fails for want of its fixpoint rather than passing without it).
printf '#!/bin/sh\necho "ablac 9.9.9"\necho static-not-really\n' > artifacts/ablac-x86_64-linux
chmod +x artifacts/ablac-x86_64-linux
cp stage2 artifacts/ablac-dynamic-x86_64-linux
for name in ablac-x86_64-linux ablac-dynamic-x86_64-linux; do (cd artifacts && sha256sum "$name" > "$name.sha256"); done
switched=$(run expected-without out6)
[[ $(line assets "$switched") == PASS* ]] || { echo "assets, switched layout: $(line assets "$switched")" >&2; exit 1; }
[[ $(line stage2 "$switched") == PASS* ]] || { echo "stage2 vs the dynamic asset, switched layout: $(line stage2 "$switched")" >&2; exit 1; }
[[ $(line static "$switched") == FAIL* ]] || { echo "a script passed as the static default asset: $(line static "$switched")" >&2; exit 1; }
# a switched layout whose dynamic asset differs from stage 2 fails check 4
printf '#!/bin/sh\necho other\n' > artifacts/ablac-dynamic-x86_64-linux
(cd artifacts && sha256sum ablac-dynamic-x86_64-linux > ablac-dynamic-x86_64-linux.sha256)
other=$(run expected-without out7)
[[ $(line stage2 "$other") == FAIL* ]] || { echo "a dynamic asset that is not stage 2 passed check 4: $(line stage2 "$other")" >&2; exit 1; }
# The portable toolchain (the static package is abla-toolchain-x86_64-linux.tar.gz, the dynamic one abla-toolchain-dynamic-x86_64-linux.tar.gz for one
# release): the dynamic archive is no extra name, and check 8 judges the default archive. Here it holds scripts, a shared library and a dynamic
# executable, which each fail; without the default archive the check fails too. (The passing case is the real package's, in the release job.)
mkdir -p pkg/abla-toolchain-x86_64-linux/bin pkg/abla-toolchain-x86_64-linux/libexec pkg/abla-toolchain-x86_64-linux/lib
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > pkg/abla-toolchain-x86_64-linux/bin/ablac
chmod +x pkg/abla-toolchain-x86_64-linux/bin/ablac
cp "$(command -v readelf)" pkg/abla-toolchain-x86_64-linux/libexec/ablac.bin
cp "$(command -v readelf)" pkg/abla-toolchain-x86_64-linux/libexec/abla-install-xtensa-native
printf 'x' > pkg/abla-toolchain-x86_64-linux/lib/libLLVM.so.23.1
tar -czf artifacts/abla-toolchain-x86_64-linux.tar.gz -C pkg abla-toolchain-x86_64-linux
cp artifacts/abla-toolchain-x86_64-linux.tar.gz artifacts/abla-toolchain-dynamic-x86_64-linux.tar.gz
for name in abla-toolchain-x86_64-linux.tar.gz abla-toolchain-dynamic-x86_64-linux.tar.gz; do (cd artifacts && sha256sum "$name" > "$name.sha256"); done
tc=$(run expected-without out8)
[[ $(line assets "$tc") == PASS* ]] || { echo "assets, dynamic toolchain archive: $(line assets "$tc")" >&2; exit 1; }
[[ $(line toolchain "$tc") == FAIL* ]] || { echo "a bad static package passed check 8: $(line toolchain "$tc")" >&2; exit 1; }
for want in "libLLVM" "is not static"; do
    [[ $(line toolchain "$tc") == *"$want"* ]] || { echo "check 8 did not say '$want': $(line toolchain "$tc")" >&2; exit 1; }
done
rm -f artifacts/abla-toolchain-x86_64-linux.tar.gz artifacts/abla-toolchain-x86_64-linux.tar.gz.sha256
notc=$(run expected-without out9)
[[ $(line toolchain "$notc") == FAIL* ]] || { echo "no default toolchain archive passed check 8: $(line toolchain "$notc")" >&2; exit 1; }
echo "release-check static: the optional assets (x86-64 and AArch64) and the static toolchain package are judged by their own checks"
