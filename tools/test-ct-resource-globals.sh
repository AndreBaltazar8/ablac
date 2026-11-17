#!/usr/bin/env bash
# A `#` site whose code writes a global holding resources (tests/cases/ct-resource-globals: a private
# array<Handle> of a resource class, the shape of abla/tls/pure's pureTlsHandleTable) runs natively: the native tier
# owns the global for the pass and never hands it back (ct_jit.ab, bootstrapCtUnexchanged). It agrees with run time
# in both tiers. Before, the site ran in the interpreter ("ordinary mutable global ... may be written"), which for TLS
# meant the step limit inside the first handshake. So do sites writing a global that always holds a closure or a raw
# pointer (tests/cases/ct-held-globals).
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

# tests/cases/ct-held-globals: globals the interpreter's journal never keeps (a class that always holds a closure, a
# raw pointer) and one typed by a plain function's declared result, all written by the site: under jit and auto the
# site runs natively, the generation keeping each for the pass (bootstrapCtGenerationOnly), and agrees with run time.
# (The interpreter has no raw memory: interp isn't asked.)
cd "$project_root/tests/cases/ct-held-globals"
for mode in jit auto; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/held-$mode" --fast --no-cache \
        > "$out/held-$mode.log" 2>&1 || { cat "$out/held-$mode.log" >&2; fail "the held $mode build failed"; }
    read -r runtime compiled < <("$out/held-$mode")
    [[ $runtime == "r2:route-22:3:true" && $runtime == "$compiled" ]] ||
        fail "held $mode: run time '$runtime', under # '$compiled'"
    grep -q 'note\[ct-jit\]: native at main.ab' "$out/held-$mode.log" ||
        { grep 'ct-jit' "$out/held-$mode.log" >&2; fail "held $mode: the site didn't run natively"; }
    for owned in 'router (it holds a closure)' 'counter' 'held (a raw pointer)'; do
        grep -qF "ordinary global $owned is native for this pass" "$out/held-$mode.log" ||
            { grep 'ct-jit' "$out/held-$mode.log" >&2; fail "held $mode: $owned wasn't the native tier's"; }
    done
done
echo "ct resource globals: sites writing a global of a resource class, a closure, a raw pointer run natively and agree with run time"
