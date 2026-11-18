#!/usr/bin/env bash
# bootstrapCtMayHoldResource is exact (#972's neighbour): a resource class held eight classes down is found (the search
# stopped at depth 6 and said "no", so the global was taken for plain data and its site stayed in the interpreter), and
# a class that refers to itself, or to another that refers back, is searched once and holds no resource.
# tests/cases/ct-resource-deep/deep.ab: the global's site runs natively, the global "holds resources", and the value
# agrees with run time; recursive.ab: no global is called a resource holder.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-resource-deep"
rm -rf "$out"; mkdir -p "$out"
cases="$project_root/tests/cases/ct-resource-deep"
fail() { echo "ct resource deep: $*" >&2; exit 1; }
build() { # $1 = case, $2 = mode
    ABLA_COMPILE_EVAL=$2 ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$cases/$1.ab" -o "$out/$1-$2" --fast --no-cache \
        > "$out/$1-$2.log" 2>&1 || { cat "$out/$1-$2.log" >&2; fail "$1 ($2): the build failed"; }
}
for mode in interp jit; do
    build deep "$mode"
    read -r runtime compiled again < <("$out/deep-$mode")
    [[ $runtime == "1:42:deep" && $compiled == "$runtime" && $again == "$runtime" ]] || fail "deep ($mode): printed '$runtime $compiled $again'"
done
grep -q 'note\[ct-jit\]: native at ' "$out/deep-jit.log" || { grep 'ct-jit' "$out/deep-jit.log" >&2; fail "deep: the site did not run natively"; }
grep -q 'chain (it holds resources) is native for this pass' "$out/deep-jit.log" ||
    { grep 'ct-jit' "$out/deep-jit.log" >&2; fail "deep: a resource eight classes down was not found (the global is not the generation's)"; }
for mode in interp jit; do
    build recursive "$mode"
    read -r size compiled < <("$out/recursive-$mode")
    [[ $size == 15 && $compiled == 15 ]] || fail "recursive ($mode): printed '$size $compiled'"
done
if grep -q 'it holds resources' "$out/recursive-jit.log"; then
    grep 'it holds resources' "$out/recursive-jit.log" >&2; fail "recursive: a class that refers to itself was taken for a resource holder"
fi
echo "ct resource deep: a resource eight classes down is found; recursive classes are not resource holders"
