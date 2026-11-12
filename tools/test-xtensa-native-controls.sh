#!/usr/bin/env bash
# Additional CLI controls, using the native suite's existing fixture archives.
set -euo pipefail
binary=$1
base=$2
project=$(cd -- "$(dirname -- "$0")/.." && pwd)
version=23.1.3-1
catalog="$base/good.json"
archive="$base/good.tar.gz"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) host=x86_64-linux ;;
    Darwin/arm64) host=arm64-macos ;;
    Darwin/x86_64) host=x86_64-macos ;;
    *) echo 'unsupported native test host' >&2; exit 1 ;;
esac
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
run() { env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY "$binary" --toolchain-root "$1" --catalog "$2" "${@:3}"; }
root="$base/good"
parent="$root/lib/abla/xtensa-llvm"
library="$parent/$version/lib/libLLVM.test"
cp -p "$library" "$base/original-library"
chmod u+w "$library"
printf X | dd of="$library" bs=1 count=1 conv=notrunc 2>/dev/null
touch -r "$base/original-library" "$library"
chmod 0444 "$library"
for args in verify install; do
    if [[ $args == verify ]]; then options=(--verify --version "$version"); else options=(--version "$version" --archive "$archive"); fi
    if run "$root" "$catalog" "${options[@]}" > "$base/tamper.out" 2>&1; then echo 'tampered file accepted' >&2; exit 1; fi
    grep -q 'file_hash' "$base/tamper.out"
    [[ $(readlink "$parent/current") == "$version" ]]
done
chmod u+w "$library"
cp -p "$base/original-library" "$library"
chmod 0444 "$library"
manifest="$parent/$version/manifest.json"
cp -p "$manifest" "$base/original-manifest"
chmod u+w "$manifest"
oldhash=$(sha "$library")
sed "s/$oldhash/0000000000000000000000000000000000000000000000000000000000000000/" "$base/original-manifest" > "$manifest"
chmod 0444 "$manifest"
if run "$root" "$catalog" --verify --version "$version" > "$base/manifest.out" 2>&1; then echo 'edited manifest accepted' >&2; exit 1; fi
grep -q 'manifest_hash' "$base/manifest.out"
chmod u+w "$manifest"; cp -p "$base/original-manifest" "$manifest"; chmod 0444 "$manifest"
for var in HTTPS_PROXY https_proxy ALL_PROXY; do
    target="$base/proxy-$var"; mkdir -p "$target/libexec"; : > "$target/libexec/ablac.bin"
    if env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY "$var=http://private:secret@127.0.0.1:1" "$binary" --toolchain-root "$target" --catalog "$catalog" --version "$version" > "$base/proxy.out" 2>&1; then echo 'proxy was ignored' >&2; exit 1; fi
    grep -Fq "$var is set" "$base/proxy.out"
    grep -q 'proxies are not supported' "$base/proxy.out"
    grep -q -- '--archive PATH' "$base/proxy.out"
    if grep -q 'secret' "$base/proxy.out"; then echo 'proxy credential leaked' >&2; exit 1; fi
    [[ -z $(find "$target" -name '.download-*' -print) ]]
    env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY "$var=http://private:secret@127.0.0.1:1" "$binary" --toolchain-root "$target" --catalog "$catalog" --version "$version" --archive "$archive" > /dev/null
done
target="$base/proxy-empty"; mkdir -p "$target/libexec"; : > "$target/libexec/ablac.bin"
if env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY HTTPS_PROXY= "$binary" --toolchain-root "$target" --catalog "$catalog" --version "$version" > "$base/proxy-empty.out" 2>&1; then echo 'empty proxy setting was ignored' >&2; exit 1; fi
grep -q 'HTTPS_PROXY is set' "$base/proxy-empty.out"
oldhash=$(sha "$archive")
for kind in traversal symlink hardlink device unpack-limit; do
    input="$project/tests/cases/xtensa-native/malicious/$host-$kind.gz"
    target="$base/evil-$kind"; mkdir -p "$target/libexec" "$target/lib/abla/xtensa-llvm"; : > "$target/libexec/ablac.bin"
    ln -s old "$target/lib/abla/xtensa-llvm/current"
    sed "s/$oldhash/$(sha "$input")/g" "$catalog" > "$base/evil-$kind.json"
    if run "$target" "$base/evil-$kind.json" --version "$version" --archive "$input" > "$base/evil.out" 2>&1; then echo "accepted $kind" >&2; exit 1; fi
    grep -Eq 'archive_path|tar_' "$base/evil.out"
    if [[ $kind == unpack-limit ]]; then grep -q 'tar_limit' "$base/evil.out"; fi
    [[ $(readlink "$target/lib/abla/xtensa-llvm/current") == old ]]
    [[ -z $(find "$target/lib/abla/xtensa-llvm" \( -name '.install-*' -o -name '.spool-*' \) -print) ]]
    [[ ! -e "$base/escape" ]]
done
target="$base/current-file"; mkdir -p "$target/libexec" "$target/lib/abla/xtensa-llvm"; : > "$target/libexec/ablac.bin"
printf reserved > "$target/lib/abla/xtensa-llvm/current"
if run "$target" "$catalog" --version "$version" --archive "$archive" > "$base/current.out" 2>&1; then echo 'regular current accepted' >&2; exit 1; fi
grep -q 'current is not a symlink' "$base/current.out"
[[ $(cat "$target/lib/abla/xtensa-llvm/current") == reserved ]]
target="$base/hash-old"; mkdir -p "$target/libexec" "$target/lib/abla/xtensa-llvm"; : > "$target/libexec/ablac.bin"
ln -s old "$target/lib/abla/xtensa-llvm/current"
if run "$target" "$base/bad-hash.json" --version "$version" --archive "$base/bad-hash.tar.gz" > "$base/hash-old.out" 2>&1; then echo 'corrupt archive accepted' >&2; exit 1; fi
grep -q 'archive_hash' "$base/hash-old.out"
[[ $(readlink "$target/lib/abla/xtensa-llvm/current") == old ]]
[[ ! -e "$target/lib/abla/xtensa-llvm/$version" ]]
# Correct archive/manifest pins must not make a helper with the wrong LLVM
# version acceptable, and a failed helper must leave the old selection.
target="$base/wrong-version"; mkdir -p "$target/libexec" "$target/lib/abla/xtensa-llvm"; : > "$target/libexec/ablac.bin"
ln -s old "$target/lib/abla/xtensa-llvm/current"
wrong="$project/tests/cases/xtensa-native/malicious/$host-wrong-version.gz"
oldmanifest=$(sha "$manifest")
newmanifest=$(cat "$project/tests/cases/xtensa-native/malicious/$host-wrong-version-manifest.sha256")
sed -e "s/$oldhash/$(sha "$wrong")/g" -e "s/$oldmanifest/$newmanifest/g" "$catalog" > "$base/wrong-version.json"
if run "$target" "$base/wrong-version.json" --version "$version" --archive "$wrong" > "$base/wrong-version.out" 2>&1; then echo 'wrong helper version accepted' >&2; exit 1; fi
grep -q 'helper' "$base/wrong-version.out"
[[ $(readlink "$target/lib/abla/xtensa-llvm/current") == old ]]
[[ ! -e "$target/lib/abla/xtensa-llvm/$version" ]]
# The only visible link values during a real publication are the previous
# target and the fully published version, never an intermediate staging name.
target="$base/activation"; mkdir -p "$target/libexec" "$target/lib/abla/xtensa-llvm" "$target/bin"
: > "$target/libexec/ablac.bin"; printf parent > "$target/bin/clang"
ln -s old "$target/lib/abla/xtensa-llvm/current"
run "$target" "$catalog" --version "$version" --archive "$archive" > "$base/activation.out" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    selected=$(readlink "$target/lib/abla/xtensa-llvm/current")
    [[ $selected == old || $selected == "$version" ]]
    if [[ $selected == "$version" ]]; then
        [[ -f "$target/lib/abla/xtensa-llvm/$version/manifest.json" ]]
        if [[ $(uname -s) == Darwin ]]; then
            mode=$(stat -f '%Lp' "$target/lib/abla/xtensa-llvm/$version")
        else
            mode=$(stat -c '%a' "$target/lib/abla/xtensa-llvm/$version")
        fi
        [[ $mode == 555 ]]
    fi
done
wait "$pid"
[[ $(readlink "$target/lib/abla/xtensa-llvm/current") == "$version" ]]
[[ $(cat "$target/bin/clang") == parent ]]
if [[ $(uname -s) == Linux ]] && command -v strace >/dev/null; then
    if strace -qq -f -e trace=execve -o "$base/hash-exec.trace" \
        env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY "$binary" --toolchain-root "$base/bad-hash" \
        --catalog "$base/bad-hash.json" --version "$version" --archive "$base/bad-hash.tar.gz" \
        > "$base/hash-exec.out" 2>&1; then echo 'bad hash accepted' >&2; exit 1; fi
    grep -q 'archive_hash' "$base/hash-exec.out"
    if grep -Eq 'execve\("[^\"]*/bin/(opt|llc)"' "$base/hash-exec.trace"; then
        echo 'helper ran before archive hash validation' >&2; exit 1
    fi
    target="$base/connect-failure"; mkdir -p "$target/libexec"; : > "$target/libexec/ablac.bin"
    if strace -qq -f -e inject=connect:error=ECONNREFUSED:when=1+ -o "$base/connect.trace" \
        env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY "$binary" --toolchain-root "$target" \
        --catalog "$catalog" --version "$version" > "$base/connect.out" 2>&1; then
        echo 'injected connection failure was accepted' >&2; exit 1
    fi
    grep -q 'proxies are not supported' "$base/connect.out"
    grep -q -- '--archive PATH' "$base/connect.out"
    [[ -z $(find "$target" -name '.download-*' -print) ]]
fi
printf '%s\n' 'native installer: proxy, tamper, unsafe members and current-file controls passed'
