#!/usr/bin/env bash
# Unpacks Google's Android NDK r27c (Linux x86-64) into <directory> (#811): the NDK that tools/test-android-run.sh,
# tools/test-android-link.sh and the Android build tests find through ABLA_ANDROID_NDK=<directory>/android-ndk-r27c.
# Needs curl, unzip and sha1sum. The download is 664 MB; it is pinned by the SHA-1 Google publishes for it
# (https://dl.google.com/android/repository/repository2-3.xml), which the checksum below equals.
set -euo pipefail
dest=${1:?usage: prepare-android-ndk.sh <directory>}
url=https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
sha1=090e8083a715fdb1a3e402d0763c388abb03fb4e
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -sfL --retry 3 -o "$work/ndk.zip" "$url"
[[ $(sha1sum "$work/ndk.zip" | cut -d' ' -f1) == "$sha1" ]] || { echo "prepare-android-ndk: the download does not match its checksum" >&2; exit 1; }
mkdir -p "$dest"
unzip -q -o "$work/ndk.zip" -d "$dest"
[[ -x $dest/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang ]] \
    || { echo "prepare-android-ndk: no aarch64-linux-android24-clang in the NDK" >&2; exit 1; }
echo "Android NDK in $dest/android-ndk-r27c"
