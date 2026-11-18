#!/usr/bin/env bash
# A `#` site that calls an extern:"c" function the program defines itself under @export (tests/cases/ct-self-exports,
# as abla-forge's host_option) runs natively under jit and agrees with run time: the slice keeps the definition and
# exports it under the extern's name. Without that the generation's link failed on the missing symbol (#1022).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-self-exports"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-self-exports"
fail() { echo "ct self exports: $*" >&2; exit 1; }
ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/jit" --fast --no-cache \
    > "$out/jit.log" 2>&1 || { cat "$out/jit.log" >&2; fail "the jit build failed"; }
read -r runtime compiled < <("$out/jit")
[[ $runtime == "33" && $compiled == "33" ]] || fail "run time '$runtime', under # '$compiled'"
if grep -q 'Symbols not found' "$out/jit.log"; then grep 'Symbols not found' "$out/jit.log" >&2; fail "the link missed a symbol"; fi
grep -q 'note\[ct-jit\]: native at main.ab' "$out/jit.log" || { cat "$out/jit.log" >&2; fail "the site didn't run natively"; }
echo "ct self exports: a site calling an extern the program exports itself runs natively and agrees with run time"
