#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/lambda-borrow-return"
cases="$root/tests/cases/lambda-borrow-return"
mkdir -p "$out"
"$compiler" build "$cases/main.ab" -o "$out/main" --fast --no-cache
"$out/main"
for case in direct branch explicit named; do
    if "$compiler" build "$cases/invalid-$case.ab" -o "$out/invalid" --fast --no-cache > "$out/$case.log" 2>&1; then
        echo "borrow-return: $case unexpectedly compiled" >&2; exit 1
    fi
    case $case in
        direct|branch) expected='ownership.borrow-escape:lambda' ;;
        explicit) expected='ownership.managed-return-borrow-contract:return' ;;
        named) expected='global.type:keep' ;;
    esac
    grep -Fq "$expected" "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
echo 'lambda borrowed results cannot escape; fresh, static and scalar results work'
