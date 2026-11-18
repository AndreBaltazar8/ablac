#!/usr/bin/env bash
# A `#` site that writes a global made by a constructor call leaving defaults out (tests/cases/ct-default-globals,
# the shape of abla-forge's `val nativeWindow = NativeWindow(...)`) runs natively: the native tier owns the global
# for the pass. Defaults left out make the call a block (named_arguments.ab), whose type wasn't read, so the site ran
# in the interpreter ("its type is not written out"), which can't call the C functions such code goes on to (#1022).
# So do globals with no written type whose initializer is a float literal, literal arithmetic or an array literal
# (`var period = 0.0`, `-2.0`, `0 - 1`, `[1, 2, 3]`, as abla-forge's `var vkxTimerPeriod = 0.0` and
# `val __LENGTH_EXTRA = [0, ...]`), which weren't typed either. It agrees with run time in both tiers.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-default-globals"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-default-globals"
fail() { echo "ct default globals: $*" >&2; exit 1; }
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/$mode" --fast --no-cache \
        > "$out/$mode.log" 2>&1 || { cat "$out/$mode.log" >&2; fail "the $mode build failed"; }
    read -r runtime compiled < <("$out/$mode")
    [[ $runtime == "21:42:true:1.5:1:20:4" && $compiled == "21:42:true:1.5:1:20:4" ]] ||
        fail "$mode: run time '$runtime', under # '$compiled'"
done
grep -q 'note\[ct-jit\]: native at main.ab' "$out/jit.log" || { cat "$out/jit.log" >&2; fail "the site didn't run natively"; }
if grep -q 'interpreted at' "$out/jit.log"; then grep 'interpreted at' "$out/jit.log" >&2; fail "a site was interpreted"; fi
for global in window period offset last lengths; do
    grep -q "ordinary global $global is native for this pass" "$out/jit.log" ||
        { grep 'ct-jit' "$out/jit.log" >&2; fail "the global $global wasn't owned by the native tier"; }
done
echo "ct default globals: a site writing globals made with defaults left out or from literals runs natively and agrees with run time"
