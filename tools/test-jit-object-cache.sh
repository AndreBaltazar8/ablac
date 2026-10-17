#!/usr/bin/env bash
# `ablac run` keeps the object the JIT generated: a rerun of an unchanged program
# adds it without compiling (same output and status), and editing any module of the
# program compiles afresh. (The program imports abla/json, whose subparser
# registrations are top-level compile actions: they do not prevent caching.)
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
compiler=$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-jit-cache.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"

printf 'fun greeting(): string = "first"\n' >helper.ab
cat >main.ab <<'SOURCE'
import "abla/io"
import "abla/json"
import "abla/process/arguments"
import "./helper.ab"

fun word(): string = "seven"
val input = #word()
val document = $json {"answer": 42}

fun main: int {
    println("${greeting()} $input ${processArgument(0)}")
    32 + input.size + jsonStringify(document).size - 8
}
SOURCE

# Runs main.ab with argument $1; prints "<exit> <stdout>|<cache decisions>".
run() {
    local status=0
    ABLA_JIT_CACHE_TRACE=1 "$compiler" run main.ab -- "$1" >out.txt 2>err.txt || status=$?
    printf '%s %s|%s\n' "$status" "$(cat out.txt)" "$(grep -o '\[jit-cache\] [a-z]*' err.txt | tr '\n' ' ')"
}
expect() {
    if [[ $2 != "$1" ]]; then
        printf 'jit object cache: expected %q, got %q\n' "$1" "$2" >&2
        cat err.txt >&2
        exit 1
    fi
}

expect '42 first seven a|[jit-cache] miss [jit-cache] stored ' "$(run a)"
expect '42 first seven b|[jit-cache] hit ' "$(run b)"
printf 'fun greeting(): string = "second"\n' >helper.ab
expect '42 second seven c|[jit-cache] miss [jit-cache] stored ' "$(run c)"
expect '42 second seven d|[jit-cache] hit ' "$(run d)"
sed 's/"seven"/"eight"/' main.ab >main.next && mv main.next main.ab
expect '42 second eight e|[jit-cache] miss [jit-cache] stored ' "$(run e)"
expect '42 second eight f|[jit-cache] hit ' "$(run f)"
status=0
ABLA_JIT_CACHE=0 ABLA_JIT_CACHE_TRACE=1 "$compiler" run main.ab -- g >out.txt 2>err.txt || status=$?
expect '42 second eight g|[jit-cache] off ' "$status $(cat out.txt)|$(grep -o '\[jit-cache\] [a-z]*' err.txt | tr '\n' ' ')"
# One record per entry: the replaced records' objects are gone.
expect 1 "$(find build/.abla-cache -name 'run-*.o' | wc -l | tr -d ' ')"

printf '%s\n' 'JIT object cache: hit on rerun, miss on a changed module'
