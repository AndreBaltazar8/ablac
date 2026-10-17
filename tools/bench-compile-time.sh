#!/usr/bin/env bash
# Compile-time evaluation benchmarks: what a workload costs under `#` against the
# same workload compiled and run as native code.
#
#   tools/bench-compile-time.sh <ablac.bin> [mode…]      (modes: interp jit auto; default interp)
#
# Each tests/benchmarks/compile-time/*.ab has `@RESULT@` where its `work()` result is
# bound: the compile-time variant binds `#work()`, the runtime one `work()`. Per
# workload and mode it reports, in instructions retired (the metric that survives a
# loaded machine; walls are printed for reference):
#   eval    compiling the `#` variant minus compiling the runtime variant (--emit-llvm),
#           i.e. what evaluating `work()` cost the compiler;
#   native  running the runtime variant's --o1 executable minus an empty program's run;
#   factor  eval / native.
# Generated workloads: `tiny` (500 one-line `#` expressions) and `parsers` (300 `$jsons`
# literals under `#`): eval against the same file without `#`, and the whole compile.
# ONLY="loop tiny …" limits the run to those workloads. ABLA_COMPILE_EVAL selects the evaluator per mode. Copy the compiler to a private path
# before comparing two of them.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    printf 'usage: %s <ablac.bin> [interp|jit|auto]…\n' "$0" >&2
    exit 2
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
shift
modes=("$@")
[[ ${#modes[@]} -eq 0 ]] && modes=(interp)
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-ct-bench.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"

# Prints "<instructions> <wall seconds>" of a command (its output discarded); fails
# with the command's stderr when it fails.
measure() {
    local log=$work/time.log
    if ! /usr/bin/time -l "$@" >"$work/out.txt" 2>"$log"; then
        cat "$log" >&2
        return 1
    fi
    local instructions wall
    instructions=$(awk '/instructions retired/{print $1}' "$log")
    wall=$(awk '/ real /{print $1; exit}' "$log")
    printf '%s %s\n' "${instructions:-0}" "${wall:-0}"
}

# Runs a build quietly; shows its output when it fails.
quiet() { "$@" >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; return 1; }; }

wanted() { [[ -z ${ONLY:-} || " $ONLY " == *" $1 "* ]]; }

human() { awk -v n="$1" 'BEGIN{a=n<0?-n:n; s=n<0?"-":""; if(a>=1e9)printf "%s%.2fG",s,a/1e9; else if(a>=1e6)printf "%s%.1fM",s,a/1e6; else printf "%s%dK",s,a/1e3}'; }

printf 'fun main: int = 0\n' >empty.ab
quiet "$compiler" build empty.ab -o empty --o1 --no-cache
read -r empty_native _ < <(measure ./empty)

{
    printf 'import "abla/io"\nfun square(value: int): int = value * value + 1\n'
    for i in $(seq 0 499); do printf 'val v%d = #square(%d)\n' "$i" "$i"; done
    printf 'val all = ['
    for i in $(seq 0 499); do printf 'v%d, ' "$i"; done
    printf '0]\nfun main: int {\n    println("${all.size}")\n    0\n}\n'
} >tiny.ab
{
    printf 'import "abla/io"\nimport "abla/json"\n'
    for i in $(seq 0 299); do
        printf 'val j%d = #$jsons {"id": %d, "name": "item %d", "tags": [1, 2.5, true, null], "nested": {"a": [%d]}}\n' "$i" "$i" "$i" "$i"
    done
    printf 'fun main: int {\n    println(j299)\n    0\n}\n'
} >parsers.ab

printf '%-9s %-7s %10s %10s %9s %9s %8s\n' workload mode eval native factor eval-wall exe-wall
for source in "$root"/tests/benchmarks/compile-time/*.ab; do
    name=$(basename "$source" .ab)
    wanted "$name" || continue
    sed 's/@RESULT@/#work()/' "$source" >"$name-ct.ab"
    sed 's/@RESULT@/work()/' "$source" >"$name-rt.ab"
    quiet "$compiler" build "$name-rt.ab" -o "$name-rt" --o1 --no-cache
    read -r native_total native_wall < <(measure "./$name-rt")
    expected=$(cat "$work/out.txt")
    native=$((native_total - empty_native))
    read -r base _ < <(measure "$compiler" --emit-llvm "$name-rt.ab")
    for mode in "${modes[@]}"; do
        read -r total wall < <(ABLA_COMPILE_EVAL=$mode measure "$compiler" --emit-llvm "$name-ct.ab")
        # The `#` variant must compute what the program computes.
        ABLA_COMPILE_EVAL=$mode quiet "$compiler" build "$name-ct.ab" -o "$name-ct" --o1 --no-cache
        if [[ $(./"$name-ct") != "$expected" ]]; then
            printf '%s (%s): `#` result differs from the runtime result\n' "$name" "$mode" >&2
            exit 1
        fi
        eval_cost=$((total - base))
        factor=$(awk -v e="$eval_cost" -v n="$native" 'BEGIN{if(n<=0)print "-"; else printf "%.1fx", e/n}')
        printf '%-9s %-7s %10s %10s %9s %8ss %7ss\n' "$name" "$mode" "$(human "$eval_cost")" \
            "$(human "$native")" "$factor" "$wall" "$native_wall"
    done
done
# The generated workloads: eval = compiling the `#` variant minus the plain one;
# "native" here is the whole `#` variant's compile.
sed 's/#square(/square(/' tiny.ab >tiny-rt.ab
sed 's/#\$jsons/$jsons/' parsers.ab >parsers-rt.ab
for name in tiny parsers; do
    wanted "$name" || continue
    read -r base _ < <(measure "$compiler" --emit-llvm "$name-rt.ab")
    for mode in "${modes[@]}"; do
        read -r total wall < <(ABLA_COMPILE_EVAL=$mode measure "$compiler" --emit-llvm "$name.ab")
        printf '%-9s %-7s %10s %10s %9s %8ss\n' "$name" "$mode" "$(human $((total - base)))" \
            "$(human "$total")" "(total)" "$wall"
    done
done
