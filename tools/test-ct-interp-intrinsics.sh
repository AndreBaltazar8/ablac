#!/usr/bin/env bash
# The interpreter performs the intrinsics the standard library's crypto reaches (ablaCtScrubBounded, nativeStaticBytes,
# nativeStaticMutableBytes; src/ct_native.ab), so each `#` line of tests/cases/ct-interp-intrinsics agrees with run
# time, in both tiers. Before, the interpreter failed every site that reached a stack wipe or a static table (aes,
# chacha20poly1305, sha3, ed25519, mlkem, pbe).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-interp-intrinsics"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-interp-intrinsics"
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build main.ab -o "$out/$mode" --fast --no-cache > "$out/$mode.log" 2>&1 ||
        { cat "$out/$mode.log" >&2; echo "ct interp intrinsics: the $mode build failed" >&2; exit 1; }
    "$out/$mode" > "$out/$mode.out"
    [[ $(wc -l < "$out/$mode.out") -eq 4 ]] || { cat "$out/$mode.out" >&2; echo "ct interp intrinsics: $mode printed too little" >&2; exit 1; }
    while read -r name runtime compiled; do
        [[ $runtime == "$compiled" ]] || { echo "ct interp intrinsics ($mode): $name: run time $runtime, under # $compiled" >&2; exit 1; }
    done < "$out/$mode.out"
done
grep -qx 'mutable 7,true 7,true' "$out/interp.out" || { cat "$out/interp.out" >&2; echo "ct interp intrinsics: a site's mutable bytes didn't persist" >&2; exit 1; }
echo "ct interp intrinsics: stack wipes and static tables under \`#\` agree with run time, in both tiers"
