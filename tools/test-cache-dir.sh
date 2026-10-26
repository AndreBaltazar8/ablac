#!/usr/bin/env bash
# A build cache outside the tree serves copies of a project: two copies of one
# program at different absolute paths, each built from its own root with the same
# --cache-dir. The second build is a hit, gives exactly what an uncached build there
# gives (a development object carries no working directory: its debug information's
# compilation directory is "."), and leaves no cache inside either copy; `ablac run` in
# the second copy reuses the first one's object. ABLA_CACHE_DIR names the directory as
# well; --cache-dir wins over it.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
work="$project_root/build/cache-dir"
rm -rf "$work"
mkdir -p "$work/first/copy" "$work/second/nested/copy" "$work/cache" "$work/environment-cache"
cp -R "$project_root/tests/cases/cache-dir/." "$work/first/copy/"
cp -R "$project_root/tests/cases/cache-dir/." "$work/second/nested/copy/"
fail() {
    echo "cache dir: $1" >&2
    exit 1
}
unset ABLA_CACHE_DIR
build() { # <copy> [options...]: builds main.ab from the copy's root into out/main
    local copy=$1; shift
    (cd "$copy" && "$compiler" build main.ab -o out/main --fast "$@" > build.log 2>&1) ||
        { cat "$copy/build.log" >&2; fail "a build in $copy failed"; }
}
runs() { # <executable>: the program answers 42
    local status=0
    "$1" || status=$?
    [[ $status -eq 42 ]] || fail "$1 exited $status"
}

first="$work/first/copy"
second="$work/second/nested/copy"
build "$first" --cache-dir "$work/cache"
runs "$first/out/main"
[[ -n $(ls -A "$work/cache") ]] || fail "the first build left nothing in the cache directory"
# A hit regenerates no LLVM: a marker left where the build writes its text survives it.
mkdir -p "$second/out"
printf '%s\n' cache-dir-hit > "$second/out/main.ll"
build "$second" --cache-dir "$work/cache"
grep -qx cache-dir-hit "$second/out/main.ll" ||
    fail "the second copy missed the cache the first one filled"
runs "$second/out/main"
for copy in "$first" "$second"; do
    [[ ! -e $copy/build/.abla-cache ]] || fail "a build with --cache-dir cached inside $copy"
done
# The hit is what an uncached build of the second copy gives.
cp "$second/out/main" "$work/hit"
cp "$second/out/main.o" "$work/hit.o"
rm -f "$second/out/main.ll"
build "$second" --no-cache
cmp -s "$second/out/main.o" "$work/hit.o" || fail "the cached object differs from an uncached build's"
cmp -s "$second/out/main" "$work/hit" || fail "the cached executable differs from an uncached build's"
# Neither copy's directory reaches a development object.
if LC_ALL=C grep -q "$work" "$second/out/main.o"; then
    fail "a development object names the directory it was built in"
fi

# `ablac run` keeps its object there as well, and a copy run from its own root finds it.
jit_run() { # <copy>: runs main.ab in process from the copy's root; prints the cache's decision
    local status=0
    (cd "$1" && ABLA_JIT_CACHE_TRACE=1 "$compiler" run --cache-dir "$work/jit-cache" main.ab \
        2> run.log) || status=$?
    [[ $status -eq 42 ]] || { cat "$1/run.log" >&2; fail "ablac run in $1 exited $status"; }
    grep -o '\[jit-cache\] [a-z]*' "$1/run.log" | head -1
}
[[ $(jit_run "$first") == "[jit-cache] miss" ]] || fail "the first run did not miss"
[[ $(jit_run "$second") == "[jit-cache] hit" ]] ||
    fail "a run in the second copy missed the record the first one left"

# ABLA_CACHE_DIR names the directory too, and --cache-dir wins over it.
ABLA_CACHE_DIR="$work/environment-cache" build "$first"
[[ -n $(ls -A "$work/environment-cache") ]] || fail "ABLA_CACHE_DIR was not used"
[[ ! -e $first/build/.abla-cache ]] || fail "a build with ABLA_CACHE_DIR cached inside the copy"
rm -rf "$work/environment-cache"/*
ABLA_CACHE_DIR="$work/environment-cache" build "$first" --cache-dir "$work/cache"
[[ -z $(ls -A "$work/environment-cache") ]] || fail "--cache-dir did not win over ABLA_CACHE_DIR"
# Without either, the cache stays under the working directory.
build "$first"
[[ -d $first/build/.abla-cache ]] || fail "the default cache directory moved"
echo "cache dir: a copy at another path hits the shared cache with identical output"
