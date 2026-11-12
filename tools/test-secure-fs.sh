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
    chmod 640 "$dir/existing"
    printf '\000\377' > "$dir/binary"
    mkfifo "$dir/fifo"
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
    if command -v strace >/dev/null; then
        "$compiler" build tests/cases/secure-fs/fault.ab -o "$out/fault" --fast --no-cache
        printf payload > "$out/read-input"
        strace -qq -yy -e trace=read -o "$out/read.trace" "$out/fault" "$out/read-input" read
        read_ordinal=$(python3 - "$out/read.trace" <<'PY'
import sys
count = 0
for line in open(sys.argv[1]):
    if line.startswith('read('):
        count += 1
        if '/read-input>' in line:
            print(count); break
else: raise SystemExit('missing fixture read')
PY
        )
        strace -qq -e "inject=read:error=EINTR:when=$read_ordinal" -o "$out/read-interrupted.trace" \
            "$out/fault" "$out/read-input" read
        : > "$out/interrupted"
        strace -qq -e inject=write:error=EINTR:when=1 -o "$out/interrupted.trace" \
            "$out/fault" "$out/interrupted" ''
        [[ $(cat "$out/interrupted") == payload ]]
        # A simulated two-byte successful write is skipped by strace; seed
        # those bytes so the real retry proves the subsequent offset is right.
        printf pa > "$out/short"
        strace -qq -e inject=write:retval=2:when=1 -o "$out/short.trace" \
            "$out/fault" "$out/short" ''
        [[ $(cat "$out/short") == payload ]]
        for error in ENOSPC EDQUOT; do
            : > "$out/full"
            strace -qq -e "inject=write:error=$error:when=1" -o "$out/$error.trace" \
                "$out/fault" "$out/full" disk_full
            [[ ! -s "$out/full" ]]
        done
        echo 'secure-fs: interrupted reads/writes, short writes and disk-full errors passed'
    else
        echo 'secure-fs: syscall fault injection unavailable; skipped'
    fi
fi
echo 'secure-fs: nofollow, exclusive creation, no-replace rename, atomic symlink, sync and descriptor drops'
