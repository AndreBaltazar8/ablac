#!/usr/bin/env bash
# Where a build spends its compile-time evaluation (tests/cases/ct-site-times): a site that takes five seconds or more
# is noted under any tier, with its place, time and tier, and a quick one isn't; ABLA_COMPILE_EVAL_TIMES=1 lists every
# site, slowest first, and each native generation's costs.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-site-times
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-site-times"
fail() { echo "ct site times: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
build() { # tier log [times]
    local status=0
    ABLA_COMPILE_EVAL=$1 ABLA_COMPILE_EVAL_TIMES=${3:-0} timeout 300 "$compiler" build slow.ab -o "$out/$2" --fast \
        --no-cache > "$out/$2.log" 2>&1 || status=$?
    [[ $status == 0 ]] || fail "$2: the compiler exited $status" "$out/$2.log"
    status=0; "$out/$2" || status=$?
    [[ $status == 42 ]] || fail "$2: the program exited $status, not 42" "$out/$2.log"
}
for tier in interp jit; do
    build $tier $tier
    want=$([[ $tier == jit ]] && echo native || echo evaluator)
    grep -q "^note: the \`#\` site at slow.ab:12:14 took [5-9]\.[0-9] s ($want); ABLA_COMPILE_EVAL_TIMES=1 lists every site's time\$" \
        "$out/$tier.log" || fail "$tier: the slow site isn't noted" "$out/$tier.log"
    [[ $(grep -c 'took [0-9]*\.[0-9] s' "$out/$tier.log") == 1 ]] || fail "$tier: more than the slow site noted" "$out/$tier.log"
    echo "ok   $tier: the slow site is noted ($want), the quick one isn't"
done
build jit listed 1
sed -n '/^compile-time evaluation times:$/,$p' "$out/listed.log" > "$out/listing.txt"
[[ $(sed -n 2p "$out/listing.txt") =~ ^\ \ [5-9]\.[0-9]\ s\ \ native\ \ slow.ab:12:14\ \`#nap\(\)\`$ ]] ||
    fail "the listing doesn't start with the slow site" "$out/listing.txt"
grep -q '^  0\.[0-9] s  .*slow.ab:13:13 `#(1 + 1)`$' "$out/listing.txt" || fail "the quick site isn't listed" "$out/listing.txt"
grep -q '^  generation 1: .* code [0-9]* ms$' "$out/listing.txt" || fail "no generation costs" "$out/listing.txt"
echo "ok   ABLA_COMPILE_EVAL_TIMES=1 lists both sites, slowest first, and the generation"
echo "ct site times: slow sites are noted in every tier, and the listing says where the time went"
