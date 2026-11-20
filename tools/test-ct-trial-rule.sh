#!/usr/bin/env bash
# auto's trials leave out a site that reaches a compiler API (tests/cases/ct-trial-rule, #1042): a trial that doesn't
# finish, then the site's native run, would make its call twice (here: read the environment twice). A pure site in the
# same pass still gets its trial.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-trial-rule
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-trial-rule"
fail() { echo "ct trial rule: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
status=0
ABLA_COMPILE_EVAL=auto ABLA_COMPILE_EVAL_TRACE=1 timeout 300 "$compiler" build environment.ab -o "$out/environment" \
    --fast --no-cache > "$out/environment.log" 2>&1 || status=$?
[[ $status == 0 ]] || fail "the compiler exited $status" "$out/environment.log"
status=0; "$out/environment" || status=$?
[[ $status == 42 ]] || fail "the program exited $status, not 42" "$out/environment.log"
grep -q '^note\[ct-jit\]: no trial at .*environment.ab:[0-9]*: it reaches the compiler API compilerEnvironment$' \
    "$out/environment.log" || fail "the environment site wasn't left out of the trials" "$out/environment.log"
grep -q '^note\[ct-jit\]: interpreted at [0-9]*: auto: finished in the interpreter in [0-9]* steps (a trial' \
    "$out/environment.log" || fail "the pure site got no trial" "$out/environment.log"
echo "ct trial rule: a site that reaches a compiler API gets no trial; a pure one in its pass does"
