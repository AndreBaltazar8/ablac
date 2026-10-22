#!/usr/bin/env bash
# Objects the build cache keeps for the external tools: a cache hit of a release
# executable takes the LTO object its entry's first build made (it neither
# prepares the module with `opt` nor compiles it with clang again), keyed by the
# tools it was made with; and a Mach-O build takes the Darwin adapter's object,
# keyed by the adapter's source, clang, SDK and target. `--no-cache` uses
# neither.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
# The compiler binary itself (beside the launcher, or beside the launcher a link
# points at): a launcher puts its own LLVM tools first on PATH, and this test
# puts its own `opt` there.
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
if [[ -z $real_opt ]]; then
    echo 'tool object cache: no opt on PATH' >&2
    exit 1
fi

# The build cache is build/.abla-cache under the working directory: a directory
# of its own, so the counts below are this test's.
work="$project_root/build/tool-object-cache-test"
rm -rf -- "$work"
mkdir -p "$work/shims"
cd "$work"
printf 'fun main: int = 42\n' >main.ab
# An `opt` that notes each run in opt.runs, then runs the real one.
write_opt() { # comment
    printf '#!/bin/sh\n# %s\necho run >>%q\nexec %q "$@"\n' "$1" "$work/opt.runs" "$real_opt" \
        >shims/opt.next
    chmod +x shims/opt.next
    mv -f shims/opt.next shims/opt
}
write_opt first
darwin=false
[[ $(uname -s) == Darwin ]] && darwin=true

fail() {
    printf 'tool object cache: %s\n' "$1" >&2
    exit 1
}
build() { # build arguments
    PATH="$work/shims:$PATH" ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 \
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
opt_runs() { wc -l <opt.runs 2>/dev/null | tr -d ' ' || echo 0; }

build -o program
runs program
[[ $(opt_runs) == 1 ]] || fail "the first build ran opt $(opt_runs) times"
[[ $(count '*.lto-v1-*.o') == 1 ]] || fail "the release build kept no LTO object"
cp program program.first

# A hit takes the LTO object from the cache: opt does not run again.
build -o program
runs program
[[ $(opt_runs) == 1 ]] || fail "a cache hit prepared the module again"
cmp -s program program.first || fail "the hit linked another executable"
# Without the cache, the same build prepares its module.
build -o uncached --no-cache
runs uncached
[[ $(opt_runs) == 2 ]] || fail "a --no-cache build did not prepare its module"
# Another opt (here the same path, another file) is another key: the hit prepares
# and compiles the module again, and keeps a second LTO object.
sleep 1
write_opt second
build -o program
runs program
[[ $(opt_runs) == 3 ]] || fail "another opt reused the first opt's LTO object"
[[ $(count '*.lto-v1-*.o') == 2 ]] || fail "another opt kept no LTO object of its own"

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

echo "tool object cache: a hit reuses its LTO object (keyed by opt and clang)$($darwin && echo ' and the Darwin adapter object (keyed by its source)')"
