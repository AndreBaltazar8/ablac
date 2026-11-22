#!/usr/bin/env bash
# The AArch64 static compiler builds itself on real hardware with nothing but itself (#1124): an empty PATH (no clang, llc, ld or assembler: the shim carries lld,
# llc, opt, the archiver and LLVM MC, which assembles the generated libc data file), pass 2 by the artifact and pass 3 by pass 2, and the two are byte for byte the
# same. Prints each pass's seconds and the compiler's peak resident memory (about 14 minutes and 1.8 GB on a Raspberry Pi 4 with 8 GB).
# Usage: tools/test-aarch64-self-build.sh <static-aarch64-compiler> <shim-object> <deps-dir>   (ABLA_AARCH64_HOSTS: the board pool, the first host is used)
#   shim-object: the abla_lld_shim.o the artifact was built with (tools/build-static-compiler.sh leaves it beside the artifact).
#   deps-dir:    nix/aarch64-static-native-deps.nix's output (llvm/, lld/, libs/).
# Everything is kept in ~/abla-self-build-<pid> on the board and removed afterwards; nothing else on it is touched.
set -euo pipefail
artifact=${1:?usage: tools/test-aarch64-self-build.sh <static-aarch64-compiler> <shim-object> <deps-dir>}
shim=${2:?shim object}
deps=${3:?deps directory}
[[ -x $artifact && -f $shim && -d $deps/llvm && -d $deps/lld && -d $deps/libs ]] || { echo 'aarch64 self-build: missing artifact, shim object or deps' >&2; exit 2; }
[[ -n ${ABLA_AARCH64_HOSTS:-} ]] || { echo 'aarch64 self-build: set ABLA_AARCH64_HOSTS to the SSH board pool' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
read -r host _ <<< "$ABLA_AARCH64_HOSTS"
dir=abla-self-build-$$
cleanup() { ssh -q "$host" "chmod -R u+w ~/$dir; rm -rf ~/$dir" || :; }
trap cleanup EXIT
ssh -q "$host" "mkdir -p ~/$dir/tree ~/$dir/empty ~/$dir/deps"
git -C "$root" archive HEAD | ssh -q "$host" "tar -x -C ~/$dir/tree"
tar -C "$deps" -c llvm lld libs | ssh -q "$host" "tar -x -C ~/$dir/deps"
scp -q "$artifact" "$host:$dir/pass1"
scp -q "$shim" "$host:$dir/shim.o"
# The whole run in one ssh session: a board without lingering ends its background jobs with the session.
remote_output=$(mktemp); ssh -q "$host" "bash -s" "$dir" <<'REMOTE' > "$remote_output" || :
set -u
dir=$HOME/$1
export ABLA_SYSROOT=$dir/tree ABLA_MAX_MEMORY_MB=7000 ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1
export ABLA_STATIC_LLVM_LIB=$dir/deps/llvm ABLA_STATIC_TARGET_LIBS=$dir/deps/libs ABLA_STATIC_LLD_OBJECT=$dir/shim.o ABLA_STATIC_LLD_LIB=$dir/deps/lld
cd "$dir/tree"
chmod +x "$dir/pass1"
build() { # compiler output tag
    export ABLA_CACHE_DIR=$dir/cache-$3
    start=$(date +%s)
    ( while true; do for pid in $(pgrep -f "^$1 "); do grep VmHWM "/proc/$pid/status" 2>/dev/null; done; sleep 15; done ) > "$dir/$3.hwm" &
    watcher=$!
    env PATH="$dir/empty" "$1" build src/orc_main_static.ab -o "$2" --no-cache > "$dir/$3.log" 2>&1
    status=$?
    kill "$watcher" 2>/dev/null
    peak=$(awk '{ if ($2 > m) m = $2 } END { print m + 0 }' "$dir/$3.hwm")
    echo "$3: status $status, $(( $(date +%s) - start )) s, peak $(( peak / 1024 )) MB"
    return $status
}
build "$dir/pass1" "$dir/pass2" pass2 || { grep -v warning "$dir/pass2.log" | tail -5; exit 1; }
build "$dir/pass2" "$dir/pass3" pass3 || { grep -v warning "$dir/pass3.log" | tail -5; exit 1; }
cmp "$dir/pass2" "$dir/pass3" || { echo 'pass 2 and pass 3 differ'; exit 1; }
echo "pass 2 == pass 3 ($(wc -c < "$dir/pass2") bytes)"
echo 'SELF-BUILD OK'
REMOTE
cat "$remote_output"; ok=0; grep -q "^SELF-BUILD OK$" "$remote_output" && ok=1; rm -f -- "$remote_output"
((ok)) || { echo "aarch64 self-build: failed (see above)" >&2; exit 1; }
echo 'aarch64 self-build: the compiler builds itself on an empty PATH on hardware, pass 2 == pass 3'
