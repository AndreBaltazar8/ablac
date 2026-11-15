#!/usr/bin/env bash
# Runtime internals at compile time: under ABLA_COMPILE_EVAL=interp a site that reaches the runtime's own representation
# (tests/cases/ct-interp-runtime, and the module cases narrow-array-getters and scalar-array-setters) ends the build with
# a diagnostic, never a signal. The interpreter used to go on past its first error into the runtime's panic path and
# call the real _longjmp with a made-up buffer (SIGSEGV). Under jit the same sites run natively and give the run-time
# answer.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-interp-runtime
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-interp-runtime"
fail() { echo "ct interp runtime: $1" >&2; [[ -z ${2:-} ]] || tail -20 "$2" >&2; exit 1; }
status=0
ABLA_COMPILE_EVAL=interp "$compiler" build array-get.ab -o "$out/interp" --fast --no-cache > "$out/interp.log" 2>&1 || status=$?
[[ $status == 1 ]] || fail "interp: the compiler exited $status, not 1 (a signal is a crash)" "$out/interp.log"
grep -q '^error\[E_' "$out/interp.log" || fail "interp: no diagnostic" "$out/interp.log"
ABLA_COMPILE_EVAL=jit "$compiler" build array-get.ab -o "$out/jit" --fast --no-cache > "$out/jit.log" 2>&1 ||
    fail "jit: the build failed" "$out/jit.log"
status=0; "$out/jit" || status=$?
[[ $status == 7 ]] || fail "jit: the program returned $status, not 7"
echo "ct interp runtime: the interpreter refuses runtime internals with a diagnostic; jit runs them"
