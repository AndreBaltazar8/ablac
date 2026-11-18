#!/usr/bin/env bash
# A `#` site that compares int128s and writes one in a template (tests/cases/ct-wide-compare) runs natively under jit:
# the slice keeps abla/int128's comparisons and text, which only lowering calls. Without them the slice's analysis
# failed and the pass ran in the interpreter (#1022). It agrees with run time in both tiers.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-wide-compare"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-wide-compare"
fail() { echo "ct wide compare: $*" >&2; exit 1; }
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/$mode" --fast --no-cache \
        > "$out/$mode.log" 2>&1 || { cat "$out/$mode.log" >&2; fail "the $mode build failed"; }
    read -r runtime compiled < <("$out/$mode")
    [[ $runtime == "14:true" && $compiled == "14:true" ]] || fail "$mode: run time '$runtime', under # '$compiled'"
done
if grep -q 'slice analysis' "$out/jit.log"; then grep 'slice analysis' "$out/jit.log" >&2; fail "the slice's analysis failed"; fi
grep -q 'note\[ct-jit\]: native at main.ab' "$out/jit.log" || { cat "$out/jit.log" >&2; fail "the site didn't run natively"; }
echo "ct wide compare: a site comparing int128s runs natively and agrees with run time"
