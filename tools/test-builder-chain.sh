#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/builder-chain-test"
mkdir -p "$out"
"$compiler" build tests/cases/builder-chain/main.ab -o "$out/main" --fast --no-cache
"$out/main"
for case in shared saved alias live-view returned-child; do
    if "$compiler" build "tests/cases/builder-chain/$case.ab" -o "$out/$case" --fast --no-cache > "$out/$case.log" 2>&1; then
        echo "builder chain $case unexpectedly compiled" >&2; exit 1
    fi
    case "$case" in
        shared|saved|returned-child) error=ownership.borrow-exclusive ;;
        alias) error=ownership.mutable-alias ;;
        live-view) error=E_BORROW_CONFLICT ;;
    esac
    grep -Fq "$error" "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
for links in 20 40; do
    {
        printf 'class Counter(var n: int) { fun step(): borrow(this) Counter { this.n = this.n + 1; this } }\n'
        printf 'fun main: int { val x = Counter(0)\nx'
        for ((i=0; i<links; i++)); do printf '.step()'; done
        printf '\nif (x.n == %d) 0 else 1\n}\n' "$links"
    } > "$out/$links.ab"
    timeout 30 "$compiler" build "$out/$links.ab" -o "$out/$links" --fast --no-cache
    "$out/$links"
done
echo 'mutable receiver chains preserve exclusive borrows and scale'
