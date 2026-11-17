#!/usr/bin/env bash
# abla/date against Node's Date (tests/cases/date-edges): 728 instants (the epoch and its neighbours, day, leap-year and
# century boundaries, years 0, 1, 9999, 10000 and the extremes of JS's range, and 500 pseudo-random ones) give the same
# civil fields, weekday and day of the year as Date's getUTC* methods and, for years 0..9999, the text JS writes; a
# time rebuilt from the fields, and the formatted text parsed back, give the time; 1309 ISO 8601 texts (valid
# and invalid dates, 24:00, 60 minutes, short and long fractions, offsets, spaces, lower case, other digits) and 26 HTTP dates
# parse to what an independent check in JS says or are refused. The results are recorded in cases.expected so that the test
# also runs without node; every case runs as ordinary code and under `#` (interpreter and ABLA_COMPILE_EVAL=jit).
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/date-edges
out=build/date-edges
rm -rf "$out"
mkdir -p "$out"

for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/cases.ab" -o "$out/cases-$tier" --fast --no-cache
    set +e
    "$out/cases-$tier" > "$out/cases-$tier.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 0 ]] || { echo "date edges ($tier): run time and compile time differ:" >&2; grep -a '^DIFF' "$out/cases-$tier.txt" | head -10 >&2; exit 1; }
    if ! cmp -s "$cases/cases.expected" "$out/cases-$tier.txt"; then
        echo "date edges ($tier) differs from cases.expected:" >&2
        diff "$cases/cases.expected" "$out/cases-$tier.txt" | head -20 >&2
        exit 1
    fi
done
grep -a -q 'DIFFER' "$cases/cases.expected" && { echo "date edges: cases.expected records a failed round trip" >&2; exit 1; }
sed '1s/.*/mutated/' "$cases/cases.expected" > "$out/mutated.expected"
! cmp -s "$out/mutated.expected" "$out/cases-interp.txt" || { echo "date edges: the negative control matched" >&2; exit 1; }

node=${DATE_EDGES_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then
    echo "date edges: recorded results match; the comparison with Node is skipped (no node)"
    exit 0
fi
"$node" "$cases/gen.mjs" "$out/cases.ab" "$out/node.txt" > /dev/null
cmp -s "$out/cases.ab" "$cases/cases.ab" || { echo "date edges: cases.ab is not what gen.mjs makes" >&2; exit 1; }
cmp -s "$out/node.txt" "$cases/cases.expected" || { echo "date edges: Node's results differ from cases.expected:" >&2; diff "$out/node.txt" "$cases/cases.expected" | head -20 >&2; exit 1; }
echo "date edges: $(wc -l < "$cases/cases.expected" | tr -d ' ') results equal Node's and agree at run time and under # (interpreter and JIT)"
