#!/usr/bin/env bash
# What a native `#` site leaves in the globals it owns is read back into the compiler only when a later evaluation
# reads it (tests/cases/ct-lazy-readback): unread.ab's writes are never read back, while read.ab's interpreted site
# after the native one sees them. Every native call's globals were read back as it returned, so the game client's
# compile-time run encoded the engine's loaded models after its last site, gigabytes that nothing read, and at 120
# frames failed doing it (#1022). Both agree with run time and the interpreter.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-lazy-readback"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-lazy-readback"
fail() { echo "ct lazy readback: $*" >&2; exit 1; }
for program in unread read; do
    expected="1000 0"; [[ $program == read ]] && expected="1000 0 1"
    for mode in interp jit; do
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build $program.ab -o "$out/$program-$mode" \
            --fast --no-cache > "$out/$program-$mode.log" 2>&1 ||
            { cat "$out/$program-$mode.log" >&2; fail "the $mode build of $program.ab failed"; }
        got=$("$out/$program-$mode")
        [[ $got == "$expected" ]] || fail "$program.ab, $mode: '$got', expected '$expected'"
    done
    grep -q "note\[ct-jit\]: native at $program.ab" "$out/$program-jit.log" ||
        { grep 'ct-jit' "$out/$program-jit.log" >&2; fail "$program.ab's site didn't run natively"; }
done
if grep 'read back' "$out/unread-jit.log" >&2; then fail "unread.ab's globals were read back, though nothing read them"; fi
grep -q 'note\[ct-jit\]: read back [0-9]* compile globals left after read.ab' "$out/read-jit.log" ||
    { grep 'ct-jit' "$out/read-jit.log" >&2; fail "read.ab's globals weren't read back for the interpreted site"; }
echo "ct lazy readback: a native site's globals are read back only for a later evaluation that reads them"
