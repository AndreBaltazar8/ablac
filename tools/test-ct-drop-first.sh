#!/usr/bin/env bash
# A `#` site whose only use of a global is a local's drop (tests/cases/ct-drop-first) runs natively and agrees with run
# time and the interpreter. An export's need to initialize the globals followed calls but not resource.drop, the call
# of a type's drop helper, so the site's entry was a bare alias and the drop appended to an unset array ("a runtime check
# failed"). An earlier site's global read-back used to initialize them first and hid it (#1022).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-drop-first"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-drop-first"
fail() { echo "ct drop first: $*" >&2; exit 1; }
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build main.ab -o "$out/$mode" --fast --no-cache \
        > "$out/$mode.log" 2>&1 || { cat "$out/$mode.log" >&2; fail "the $mode build failed"; }
    got=$("$out/$mode")
    [[ $got == "2 2 1" ]] || fail "$mode: '$got', expected '2 2 1'"
done
grep -q 'note\[ct-jit\]: native at main.ab' "$out/jit.log" || { grep 'ct-jit' "$out/jit.log" >&2; fail "the site didn't run natively"; }
echo "ct drop first: a site whose only use of a global is a drop runs natively and agrees with run time"
