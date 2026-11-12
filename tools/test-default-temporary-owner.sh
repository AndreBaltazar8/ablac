#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac.bin}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/default-temporary-owner
"$compiler" build tests/cases/default-temporary-owner/main.ab -o build/default-temporary-owner/main --fast --no-cache
actual=$(build/default-temporary-owner/main)
expected='F1LHI1|F8L|M3LHI3|HI4C4|F5LHI5|F15LSHI15|D9I9|E6LHI6|E0L|Q10I10|Q11|I11|P12I12|P14SI14|N16I16S|UI17|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'default temporary owners: got %s\n' "$actual" >&2; exit 1; }
"$compiler" build tests/cases/default-temporary-owner/managed.ab -o build/default-temporary-owner/managed --fast --no-cache
actual=$(build/default-temporary-owner/managed)
expected='H0|H0'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'managed defaults: got %s\n' "$actual" >&2; exit 1; }
for case in return capture task store; do
    if "$compiler" build "tests/cases/default-temporary-owner/refused-$case.ab" -o build/default-temporary-owner/refused --fast --no-cache >"build/default-temporary-owner/$case.log" 2>&1; then
        echo "$case unexpectedly compiled" >&2; exit 1
    fi
    case $case in
        return) expected='ownership.borrow-return-source-default' ;;
        capture|task) expected='ownership.borrow-capture' ;;
        store) expected='ownership.borrow-escape' ;;
    esac
    grep -q "$expected" "build/default-temporary-owner/$case.log" || { cat "build/default-temporary-owner/$case.log" >&2; exit 1; }
done
echo 'default temporary owners: ok'
