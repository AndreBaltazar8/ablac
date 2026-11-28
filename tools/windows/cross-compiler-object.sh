#!/usr/bin/env bash
# Produce the Windows compiler COFF object and generated libraries for the MSVC link.
set -euo pipefail
[[ $# == 3 || $# == 4 ]] || { echo 'usage: tools/windows/cross-compiler-object.sh <compiler> <entry.ab> <output-dir> [target]' >&2; exit 2; }
compiler=$1
entry=$2
out=$3
target=${4:-x86_64-windows}
[[ $target == x86_64-windows || $target == x86_64-windows-hosted || $target == aarch64-windows ]] ||
    { echo "Unsupported Windows compiler target: $target" >&2; exit 2; }
mkdir -p "$out"
if [[ -e $out/ablac.exe.o || -e $out/ablac.exe.imports ]]; then
    echo "The Windows compiler output directory already contains a compiler object or import libraries: $out" >&2
    exit 2
fi
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-8192}
export ABLA_WINDOWS_LINK_KEEP=1
# The normal Windows program link omits the compiler's LLVM SDK and CRT.
"$compiler" build "$entry" --target "$target" --no-cache -o "$out/ablac.exe" >"$out/build.log" 2>&1 || true
[[ -s $out/ablac.exe.o && -s $out/ablac.exe.imports/exports.def ]] || {
    tail -n 30 "$out/build.log" >&2
    echo 'The Windows compiler object or export list was not generated' >&2
    exit 1
}
llvm-nm --undefined-only "$out/ablac.exe.o" >"$out/undefined.txt"
grep -Eq '[[:space:]]abla_shim_version$' "$out/undefined.txt" || {
    echo 'The Windows compiler object does not reference the in-process shim' >&2
    exit 1
}
