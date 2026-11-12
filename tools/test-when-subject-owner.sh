#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/when-subject-owner
"$compiler" build tests/cases/when-subject-owner/main.ab -o build/when-subject-owner/main --fast --no-cache
actual=$(build/when-subject-owner/main)
expected='YI1|HI2YI1|YI1|I3|Y|I3|YI1D|YI1|B4H||T6I6Vitem6|T5I5|T7I7|YZI1|YI1||YDI1YDI2|YDI1|B8I8|CI9|B10I10|HI2I1B4I4|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'when subject owner: %s\n' "$actual" >&2; exit 1; }
for case in resource-key interpolation interface-cast; do
    case "$case" in
        resource-key) diagnostic=map.key-type:Item ;;
        interpolation) diagnostic=string.interpolation:Item ;;
        interface-cast) diagnostic=interface.cast-resource ;;
    esac
    if "$compiler" build "tests/cases/when-subject-owner/refused-$case.ab" \
        -o "build/when-subject-owner/refused-$case" --fast --no-cache \
        >"build/when-subject-owner/refused-$case.log" 2>&1; then
        echo "expected refusal: $case" >&2; exit 1
    fi
    grep -Fq "$diagnostic" "build/when-subject-owner/refused-$case.log"
done
echo 'when subject owner: ok'
