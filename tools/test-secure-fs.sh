#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
out="$root/build/secure-fs"
mkdir -p "$out"
"$compiler" build tests/cases/secure-fs/main.ab -o "$out/check" --fast --no-cache
run_case() {
    local dir=$1
    mkdir -p "$dir/dir"
    printf file > "$dir/existing"
    printf source > "$dir/source"
    printf destination > "$dir/destination"
    ln -s dir "$dir/directory-link"
    ln -s existing "$dir/file-link"
    ln -s old "$dir/current"
    ln -s occupied "$dir/occupied"
    (ulimit -n 64; ABLA_SECURE_FS_ROOT="$dir" "$out/check")
    [[ $(cat "$dir/created") == payload && $(cat "$dir/renamed") == source ]]
    [[ $(cat "$dir/destination") == destination && $(readlink "$dir/current") == new ]]
    [[ ! -e "$dir/temp-regular" && ! -e "$dir/temp-directory" ]]
}
dir=$(mktemp -d "$out/real.XXXXXXXX")
cleanup() {
    rm -rf "$dir"
    if [[ -n ${memory_dir:-} ]]; then rm -rf "$memory_dir"; fi
}
trap cleanup EXIT
run_case "$dir"
if [[ $(uname -s) == Linux ]]; then
    [[ -d /dev/shm && -w /dev/shm ]] || { echo 'secure-fs: writable tmpfs /dev/shm required' >&2; exit 1; }
    memory_dir=$(mktemp -d /dev/shm/abla-secure-fs.XXXXXXXX)
    run_case "$memory_dir"
fi
echo 'secure-fs: nofollow, exclusive creation, no-replace rename, atomic symlink, sync and descriptor drops'
