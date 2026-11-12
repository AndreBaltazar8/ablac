#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/owned-container-loop
"$compiler" build tests/cases/owned-container-loop/main.ab -o build/owned-container-loop/main --fast --no-cache
actual=$(build/owned-container-loop/main)
expected='B1I1B2I2|B1I1I2|B1I1B2I2|B1I1I2|B1I1B2I2|T1I1T2I2|B1I1I2|B1DI1B2DI2|B1I1B2I2I1I2|B1B2I1I2|T1I1T2I2I1I2|B1I1B2I2|B1I1I2|B1I1B2I2I1I2|B1I1I2|B1DI1I2|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'owned container loop: got %s\n' "$actual" >&2; exit 1; }
for kind in move await when field; do
    if "$compiler" build "tests/cases/owned-container-loop/refused-mixed-$kind.ab" -o build/owned-container-loop/refused --fast --no-cache >"build/owned-container-loop/$kind.log" 2>&1; then
        echo "mixed borrowed $kind unexpectedly accepted" >&2; exit 1
    fi
    case $kind in
        await) diagnostic='ownership.await-borrow'; arm='jobs' ;;
        field) diagnostic='move.local'; arm='box' ;;
        *) diagnostic='move.local'; arm='owned' ;;
    esac
    grep -Fq "$diagnostic" "build/owned-container-loop/$kind.log"
    grep -Fq "borrowed from \`$arm\`" "build/owned-container-loop/$kind.log"
    grep -Fq 'fresh container or move the container' "build/owned-container-loop/$kind.log"
done
echo 'owned container loop: ok'
