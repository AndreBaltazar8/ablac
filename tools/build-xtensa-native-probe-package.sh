#!/usr/bin/env bash
# Build the candidate with the pinned published compiler and current sysroot.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/native-probe-package"
mkdir -p "$out"
tools/bootstrap-compiler.sh "$out/ablac"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) platform=x86_64-linux; expected=38624ff8f10469873d40d4a9485bde9850e673630f94a91f9c8561be676b63ea ;;
    Darwin/arm64) platform=arm64-macos; expected=f69edd153eda8ec10bd6fcb243968eb95b943be3c2c988cce7f056b40dc562cb ;;
    Darwin/x86_64) platform=x86_64-macos; expected=e366330d5209810b14c4ea940b161110bded2fedcddf37999034b072d16d2b1a ;;
    *) echo 'unsupported native probe host' >&2; exit 2 ;;
esac
archive="$out/published-v0.2.56-$platform.tar.gz"
if [[ ! -f $archive ]]; then
    curl --fail --location --retry 3 --output "$archive.download" \
        "https://github.com/AndreBaltazar8/ablac/releases/download/v0.2.56/abla-toolchain-$platform.tar.gz"
    mv "$archive.download" "$archive"
fi
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$archive" | cut -d' ' -f1)
else actual=$(shasum -a 256 "$archive" | cut -d' ' -f1); fi
if [[ $actual != "$expected" ]]; then echo 'published build toolchain checksum mismatch' >&2; exit 1; fi
mkdir "$out/unpacked"
tar -xzf "$archive" -C "$out/unpacked"
bundle="$out/unpacked/abla-toolchain-$platform"
[[ -x $bundle/libexec/ablac.bin && -d $bundle/share/abla/stdlib ]] || { echo 'invalid published build toolchain' >&2; exit 1; }
# Invoke the packaged compiler directly: its launcher would override ABLA_SYSROOT
# with the older release's stdlib. The packaged LLVM tools remain first in PATH.
export ABLA_SYSROOT="$root" PATH="$bundle/bin:$PATH"
"$bundle/libexec/ablac.bin" build "$root/tools/xtensa-native/main.ab" --no-cache -o "$out/native-installer"
mkdir -p "$bundle/bin" "$bundle/libexec" "$bundle/share/abla"
cp "$out/native-installer" "$bundle/libexec/abla-install-xtensa-native"
rm -f "$bundle/bin/abla-install-xtensa" "$bundle/libexec/abla/"*
ln -s ../libexec/abla-install-xtensa-native "$bundle/bin/abla-install-xtensa"
cp "$root/tools/xtensa-companions.json" "$bundle/share/abla/xtensa-companions.json"
if [[ $(uname -s) == Linux ]]; then
    # Match package-linux-toolchain.sh's dependency and loader handling.
    while IFS= read -r dependency; do
        case $(basename "$dependency") in
            ld-linux-*.so.*|libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*) continue ;;
        esac
        destination="$bundle/lib/$(basename "$dependency")"
        if [[ ! -e $destination ]]; then cp -L "$dependency" "$destination"; chmod u+w "$destination"; fi
    done < <(ldd "$bundle/libexec/abla-install-xtensa-native" | awk '/=> \/[^ ]+/ { print $3 }')
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$bundle/libexec/abla-install-xtensa-native"
    patchelf --set-rpath '$ORIGIN/../lib' "$bundle/libexec/abla-install-xtensa-native"
fi
tar -C "$out/unpacked" -czf "$out/candidate.tar.gz" "abla-toolchain-$platform"
