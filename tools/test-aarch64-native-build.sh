#!/usr/bin/env bash
# The AArch64 static compiler builds programs on real hardware with nothing but itself (#1124): on a board with an empty PATH it builds tests/cases/libc-imports'
# programs (the ones tools/test-static-compiler-aarch64.sh builds under qemu), and each program it built behaves, there, as the x86-64 compiler's cross build of the same
# source does: the same output and exit status, run in a directory of its own. (The executables are not byte for byte the same: the compiler's code generation is
# its own, not the external llc's.) Unlike under qemu the compiler starts itself (its codegen units, --emit-object), the way it is used on a board.
# Usage: tools/test-aarch64-native-build.sh <x86-64 compiler> <static-aarch64-compiler>   (ABLA_AARCH64_HOSTS: the board pool, the first host is used)
# Everything is kept in ~/abla-native-build-<pid> on the board and removed afterwards.
set -euo pipefail
compiler=${1:?usage: tools/test-aarch64-native-build.sh <x86-64 compiler> <static-aarch64-compiler>}
artifact=${2:?static AArch64 compiler}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
[[ $artifact == /* ]] || artifact="$PWD/$artifact"
[[ -x $compiler && -x $artifact ]] || { echo 'aarch64 native build: missing compiler or artifact' >&2; exit 2; }
[[ -n ${ABLA_AARCH64_HOSTS:-} ]] || { echo 'aarch64 native build: set ABLA_AARCH64_HOSTS to the SSH board pool' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
read -r host _ <<< "$ABLA_AARCH64_HOSTS"
programs=(hello strings-arrays files float-remainder tasks threads jwt-verify)
work=$(mktemp -d "${TMPDIR:-/tmp}/aarch64-native.XXXXXX")
dir=abla-native-build-$$
cleanup() { ssh -q "$host" "chmod -R u+w ~/$dir; rm -rf ~/$dir" || :; rm -rf -- "$work"; }
trap cleanup EXIT
for name in "${programs[@]}"; do
    "$compiler" build "tests/cases/libc-imports/$name.ab" --target aarch64-linux -o "$work/$name.cross" --no-cache > "$work/$name.cross.log" 2>&1 ||
        { echo "aarch64 native build: the cross build of $name failed" >&2; exit 1; }
done
ssh -q "$host" "mkdir -p ~/$dir/tree ~/$dir/empty ~/$dir/cross"
git archive HEAD | ssh -q "$host" "tar -x -C ~/$dir/tree"
scp -q "$artifact" "$host:$dir/ablac"
for name in "${programs[@]}"; do scp -q "$work/$name.cross" "$host:$dir/cross/$name"; done
remote_output=$(mktemp); ssh -q "$host" "bash -s" "$dir" "${programs[*]}" <<'REMOTE' > "$remote_output" || :
set -u
dir=$HOME/$1
export ABLA_SYSROOT=$dir/tree ABLA_MAX_MEMORY_MB=7000 ABLA_CACHE_DIR=$dir/cache
chmod +x "$dir/ablac" "$dir"/cross/*
cd "$dir/tree"
run() { # executable output
    mkdir -p "$dir/run"; rm -rf "$dir/run"/*
    (cd "$dir/run" && "$1" > "$2" 2>&1 < /dev/null; echo "exit $?" >> "$2")
}
failed=0
for name in $2; do
    env PATH="$dir/empty" "$dir/ablac" build "tests/cases/libc-imports/$name.ab" -o "$dir/$name.native" --no-cache > "$dir/$name.log" 2>&1 ||
        { echo "$name: the native build failed"; grep -v warning "$dir/$name.log" | tail -5; failed=1; continue; }
    run "$dir/$name.native" "$dir/$name.native.out"
    run "$dir/cross/$name" "$dir/$name.cross.out"
    if cmp -s "$dir/$name.native.out" "$dir/$name.cross.out"; then echo "$name: native build behaves as the cross build ($(wc -c < "$dir/$name.native") bytes, exit $(tail -1 "$dir/$name.native.out"))"
    else echo "$name: native build differs from the cross build"; diff "$dir/$name.native.out" "$dir/$name.cross.out" | head -5; failed=1; fi
done
[[ $failed == 0 ]] && echo 'NATIVE-BUILD OK'
REMOTE
cat "$remote_output"; ok=0; grep -q "^NATIVE-BUILD OK$" "$remote_output" && ok=1; rm -f -- "$remote_output"
((ok)) || { echo "aarch64 native build: failed (see above)" >&2; exit 1; }
echo 'aarch64 native build: the programs built on the board behave as the cross builds'
