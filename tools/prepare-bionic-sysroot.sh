#!/usr/bin/env bash
# Extracts bionic's linker and libraries (libc, libm, libdl, liblog) from Google's arm64 Android 36 system image into
# <directory>, the layout tools/test-android-run.sh expects (ABLA_BIONIC_ROOT=<directory>) (#811). Needs curl, unzip,
# debugfs (e2fsprogs) and sha1sum. The image is a download of 810 MB; it is pinned by its SHA-1, and the system
# partition's offset is fixed (the image is a GPT disk with one `super` partition whose first logical partition,
# an ext4 system-as-root file system, starts 1 MiB in).
set -euo pipefail
dest=${1:?usage: prepare-bionic-sysroot.sh <directory>}
url=https://dl.google.com/android/repository/sys-img/android/arm64-v8a-36_r02.zip
sha1=62ad6714df790f89c8a8ad32552ffe20bb16fe87
# partition 2 starts at sector 4096 of the disk, the ext4 file system 1 MiB into it
offset=$((4096 * 512 + 1048576))
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -sfL -o "$work/image.zip" "$url"
[[ $(sha1sum "$work/image.zip" | cut -d' ' -f1) == "$sha1" ]] || { echo "prepare-bionic-sysroot: the download does not match its checksum" >&2; exit 1; }
unzip -q -o "$work/image.zip" 'arm64-v8a/system.img' -d "$work"
mkdir -p "$dest/system/bin/bootstrap" "$dest/system/lib64/bootstrap"
for file in bin/bootstrap/linker64 lib64/bootstrap/libc.so lib64/bootstrap/libm.so lib64/bootstrap/libdl.so \
    lib64/bootstrap/libdl_android.so lib64/liblog.so; do
    debugfs -R "dump /system/$file $dest/system/$file" "$work/arm64-v8a/system.img?offset=$offset" > /dev/null
    [[ -s $dest/system/$file ]] || { echo "prepare-bionic-sysroot: /system/$file is not in the image" >&2; exit 1; }
done
chmod +x "$dest/system/bin/bootstrap/linker64"
echo "bionic sysroot in $dest"
