#!/usr/bin/env bash
# Objects the build cache keeps for the external tools: a cache hit of a release
# executable takes the LTO object its entry's first build made (it neither
# optimizes the module nor generates its code again with `llc`), keyed by the
# tools it was made with; and a Mach-O build takes the Darwin adapter's object,
# keyed by the adapter's source, clang, SDK and target. `--no-cache` uses
# neither.
set -euo pipefail
# (These checks read the default cache, build/.abla-cache under the working directory.)
unset ABLA_CACHE_DIR

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
# The compiler binary itself (beside the launcher, or beside the launcher a link
# points at): a host build takes its opt and llc from ABLA_LLVM_TOOLS, which
# this test points at a directory with its own `llc` (the module is optimized in
# the compiler, so it is llc that runs for each object).
resolved=$compiler
while [[ -L $resolved ]]; do
    target=$(readlink "$resolved")
    [[ $target == /* ]] || target=$(dirname "$resolved")/$target
    resolved=$target
done
payload=$compiler
if [[ -x $compiler.bin ]]; then
    payload=$compiler.bin
elif [[ -x $resolved.bin ]]; then
    payload=$resolved.bin
fi
sysroot=${ABLA_SYSROOT:-$project_root}
export ABLA_SYSROOT=$sysroot
real_opt=$(command -v opt || true)
real_llc=$(command -v llc || true)
if [[ -z $real_opt || -z $real_llc ]]; then
    echo 'tool object cache: no opt or llc on PATH' >&2
    exit 1
fi

# The build cache is build/.abla-cache under the working directory: a directory
# of its own, so the counts below are this test's.
work="$project_root/build/tool-object-cache-test"
rm -rf -- "$work"
mkdir -p "$work/shims"
cd "$work"
printf 'fun main: int = 42\n' >main.ab
# An `llc` that notes each run in llc.runs, then runs the real one.
write_llc() { # comment
    printf '#!/bin/sh\n# %s\necho run >>%q\nexec %q "$@"\n' "$1" "$work/llc.runs" "$real_llc" \
        >shims/llc.next
    chmod +x shims/llc.next
    mv -f shims/llc.next shims/llc
}
write_llc first
ln -s "$real_opt" shims/opt
darwin=false
[[ $(uname -s) == Darwin ]] && darwin=true

fail() {
    printf 'tool object cache: %s\n' "$1" >&2
    exit 1
}
build() { # build arguments
    PATH="$work/shims:$PATH" ABLA_LLVM_TOOLS="$work/shims" ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 \
        "$project_root/tools/run-limited.sh" "$payload" build main.ab "$@" \
        >build.log 2>&1 || { cat build.log >&2; fail "build $* failed"; }
}
runs() { # program
    local status=0
    ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
        "$project_root/tools/run-limited.sh" "./$1" || status=$?
    [[ $status -eq 42 ]] || fail "$1 exited $status, expected 42"
}
count() { # file pattern in the cache
    find build/.abla-cache -maxdepth 1 -name "$1" 2>/dev/null | wc -l | tr -d ' '
}
llc_runs() { wc -l <llc.runs 2>/dev/null | tr -d ' ' || echo 0; }

build -o program
runs program
[[ $(llc_runs) == 1 ]] || fail "the first build ran llc $(llc_runs) times"
[[ $(count '*.lto-v2-*.o') == 1 ]] || fail "the release build kept no LTO object"
cp program program.first

# A hit takes the LTO object from the cache: llc does not run again.
build -o program
runs program
[[ $(llc_runs) == 1 ]] || fail "a cache hit compiled the module again"
cmp -s program program.first || fail "the hit linked another executable"
# Without the cache, the same build prepares its module.
build -o uncached --no-cache
runs uncached
[[ $(llc_runs) == 2 ]] || fail "a --no-cache build did not compile its module"
# Another llc (here the same path, another file) is another key: the hit optimizes
# and compiles the module again, and keeps a second LTO object.
sleep 1
write_llc second
build -o program
runs program
[[ $(llc_runs) == 3 ]] || fail "another llc reused the first llc's LTO object"
[[ $(count '*.lto-v2-*.o') == 2 ]] || fail "another llc kept no LTO object of its own"

if $darwin; then
    [[ $(count 'darwin-adapter-v1-*.o') == 1 ]] || fail "no cached Darwin adapter object"
    adapter=$(find build/.abla-cache -maxdepth 1 -name 'darwin-adapter-v1-*.o')
    cmp -s program.host.o "$adapter" || fail "the build did not link the cached adapter"
    # An edited adapter (another sysroot's) is another key.
    edited="$work/sysroot"
    mkdir -p "$edited"
    cp -R "$sysroot/stdlib" "$sysroot/runtime" "$edited/"
    printf '\n/* An edit that changes no behavior. */\n' >>"$edited/runtime/abla_darwin_compat.c"
    ABLA_SYSROOT=$edited build -o edited --fast
    runs edited
    [[ $(count 'darwin-adapter-v1-*.o') == 2 ]] || fail "an edited adapter reused the cached object"
fi

echo "tool object cache: a hit reuses its LTO object (keyed by llc and clang)$($darwin && echo ' and the Darwin adapter object (keyed by its source)')"
