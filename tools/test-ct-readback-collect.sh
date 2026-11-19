#!/usr/bin/env bash
# A native `#` site's global read back while collections run inside its getter (tests/cases/ct-readback-collect, #1031).
# The getter's encoding allocates, so it can collect partway through a large value; its reply was a collected block
# that only an int held, so a collection freed it and the encoding wrote on into freed memory. The game client's
# `models` failed to read back that way, at random. Here the compiler collects every megabyte
# (ABLA_COMPILER_COLLECT_GROWTH_MB=1), so the encoding of the site's 16 MB value collects partway through, and
# poisons what it frees (ABLA_GC_POISON=1): a reply freed under the encoding fails at once, whether the heap gives
# its pages back (the bad access the client saw) or keeps them (then the bytes read as garbage). Both modes give the
# same value.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-readback-collect"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-readback-collect"
fail() { echo "ct readback collect: $*" >&2; exit 1; }
expected="3000 16786222"
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 ABLA_COMPILER_COLLECT_GROWTH_MB=1 ABLA_GC_POISON=1 \
        "$compiler" build collected.ab -o "$out/collected-$mode" --fast --no-cache > "$out/collected-$mode.log" 2>&1 ||
        { cat "$out/collected-$mode.log" >&2; fail "the $mode build failed"; }
    got=$("$out/collected-$mode")
    [[ $got == "$expected" ]] || fail "$mode: '$got', expected '$expected'"
done
grep -q 'note\[ct-jit\]: native at collected.ab' "$out/collected-jit.log" ||
    { grep 'ct-jit' "$out/collected-jit.log" >&2; fail "the site didn't run natively"; }
grep -q 'note\[ct-jit\]: read back [0-9]* compile globals left after collected.ab' "$out/collected-jit.log" ||
    { grep 'ct-jit' "$out/collected-jit.log" >&2; fail "the site's globals weren't read back"; }
echo "ct readback collect: a native site's large global reads back while the compiler collects and poisons"
