#!/usr/bin/env bash
# CI-only stock-parent build. No LLVM source build or global patched tools.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || { echo 'stock Xtensa toolchain probe is CI-only' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/xtensa-stock"
mkdir -p "$out"
export ABLA_NATIVE_JOBS=4 ABLA_CODEGEN_JOBS=4 ABLA_SYSROOT="$root"
unset ABLA_XTENSA_LLVM_ROOT
llc --version > "$out/parent-llc-version.txt"
# Newer stock distributions may enable the upstream Xtensa backend. They must
# still be ordinary, unpatched tools; actual routing is proved with poisoned
# PATH and exact objects, not by assuming a backend is absent forever.
llc --help-hidden > "$out/parent-llc-options.txt"
for option in xtensa-direct-calls xtensa-narrow-branches xtensa-text-section-literals; do
    if grep -q -- "--$option" "$out/parent-llc-options.txt"; then
        echo "expected stock parent LLVM without private --$option" >&2
        exit 1
    fi
done
tools/bootstrap-compiler.sh "$out/bootstrap.bin"
if [[ $(uname -s) == Linux ]]; then
    # The standalone artifact retains the release builder's interpreter/RPATH;
    # adapt only this private bootstrap copy to the stock container.
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$out/bootstrap.bin"
    patchelf --set-rpath "$(llvm-config --libdir)" "$out/bootstrap.bin"
    ldd "$out/bootstrap.bin" > "$out/bootstrap-dependencies.txt"
    if grep -q "not found" "$out/bootstrap-dependencies.txt"; then
        cat "$out/bootstrap-dependencies.txt" >&2
        exit 1
    fi
fi
ABLA_COMPILER_PAYLOAD="$out/bootstrap.bin" ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1200 \
    tools/run-limited-compiler.sh build src/orc_main.ab -o "$out/compiler.bin" --no-cache
case $(uname -s) in
    Linux)
        tools/package-linux-toolchain.sh "$out/compiler.bin" "$root" "$out/toolchain.tar.gz"
        ;;
    Darwin)
        tools/package-macos-toolchain.sh "$(uname -m)" "$out/compiler.bin" "$root" "$out/toolchain.tar.gz"
        ;;
    *) exit 2 ;;
esac
mkdir -p "$out/installed"
tar -xzf "$out/toolchain.tar.gz" -C "$out/installed"
prefix=$(find "$out/installed" -mindepth 1 -maxdepth 1 -type d -print)
python3 tools/test-xtensa-routing-installed.py "$prefix" "$out"
