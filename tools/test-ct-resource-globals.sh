#!/usr/bin/env bash
# A `#` site whose code writes a global holding resources (tests/cases/ct-resource-globals: a private
# array<Handle> of a resource class, the shape of abla/tls/pure's pureTlsHandleTable) runs natively: the native tier
# owns the global for the pass and never hands it back (ct_jit.ab, bootstrapCtUnexchanged). It agrees with run time
# in both tiers. Before, the site ran in the interpreter ("ordinary mutable global ... may be written"), which for TLS
# meant the step limit inside the first handshake.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-resource-globals"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-resource-globals"
fail() { echo "ct resource globals: $*" >&2; exit 1; }
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/$mode" --fast --no-cache \
        > "$out/$mode.log" 2>&1 || { cat "$out/$mode.log" >&2; fail "the $mode build failed"; }
    read -r runtime compiled < <("$out/$mode")
    [[ -n $runtime && $runtime == "$compiled" ]] || fail "$mode: run time '$runtime', under # '$compiled'"
    [[ $runtime == "2:one,handle-three:true,false:1" ]] || fail "$mode: unexpected result '$runtime'"
done
grep -q 'note\[ct-jit\]: native at main.ab' "$out/jit.log" || { cat "$out/jit.log" >&2; fail "the site didn't run natively"; }
if grep -q 'interpreted at' "$out/jit.log"; then grep 'interpreted at' "$out/jit.log" >&2; fail "a site was interpreted"; fi
grep -q 'handleTable (it holds resources) is native for this pass' "$out/jit.log" ||
    { grep 'ct-jit' "$out/jit.log" >&2; fail "the resource global wasn't owned by the native tier"; }
echo "ct resource globals: a site writing a global array of a resource class runs natively and agrees with run time"
