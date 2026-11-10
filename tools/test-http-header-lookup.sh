#!/usr/bin/env bash
# HttpRequest.header answers as its previous form did (length, then a full case-insensitive
# compare, last duplicate wins) for case variants, last bytes that fold together under `| 32`,
# duplicates, empty and missing names: fast and release builds, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-header-lookup"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/http-header-lookup/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "http header lookup: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo 'HTTP header lookup: case variants, folded last bytes, duplicates and missing names agree with the previous form'
