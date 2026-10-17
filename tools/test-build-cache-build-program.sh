#!/usr/bin/env bash
# A programmable build (compilerBuildProgram) must run on every build, so a program
# whose compile-time code can reach one is never served from the native object
# cache. A program that only imports abla/compiler, whose Compiler.buildProgram
# wrapper nothing calls, is cached like any other.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
compiler=$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-build-program-cache.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"

cat >unreached.ab <<'SOURCE'
import "abla/compiler"

fun main: int = 42
SOURCE
cat >reached.ab <<'SOURCE'
import "abla/compiler"

compile fun maybe(flag: bool): int {
    if (flag) {
        val built = compilerBuildProgram("p", "p.ab", "p", "host", "executable", true, true)
    }
    7
}

val seven = #maybe(false)

fun main: int = seven * 6
SOURCE

# cached <name>: builds twice; a hit leaves the marker written over the first
# build's LLVM text in place.
cached() {
    "$compiler" build "$1.ab" -o "$1" --fast >/dev/null 2>&1
    printf 'native-object-cache-hit\n' >"$1.ll"
    "$compiler" build "$1.ab" -o "$1" --fast >/dev/null 2>&1
    local status=0
    "./$1" || status=$?
    [[ $status -eq 42 ]] || { printf '%s exited %s\n' "$1" "$status" >&2; exit 1; }
    grep -q '^native-object-cache-hit$' "$1.ll"
}

cached unreached || { echo 'build cache: an unreached Compiler.buildProgram disabled caching' >&2; exit 1; }
if cached reached; then
    echo 'build cache: a reachable compilerBuildProgram was served from the cache' >&2
    exit 1
fi
printf '%s\n' 'build cache: only a reachable compilerBuildProgram disables caching'
