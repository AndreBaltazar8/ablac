#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/for-constant-array
mkdir -p "$out"
for profile in release fast o1; do
    arguments=(build tests/cases/modules/for-constant-array.ab -o "$out/program" --no-cache)
    case "$profile" in fast) arguments+=(--fast);; o1) arguments+=(--o1);; esac
    "$compiler" "${arguments[@]}"
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$out/program" || status=$?
        [[ $status == 42 ]] || { echo "literal for $profile stress=$stress: $status" >&2; exit 1; }
    done
done
"$compiler" --emit-llvm tests/cases/modules/for-constant-array.ab > "$out/program.ll"
cat > "$out/constant-array.awk" <<'AWK'
BEGIN {
    n = split("literalForInts literalForBool literalForFloat literalForEmpty literalForSingleton literalForControl literalForReturn literalForSixteen", e, " ")
    for (i = 1; i <= n; i++) eligible[e[i]]
    n = split("literalForFallback literalForLarge literalForStrings", f, " ")
    for (i = 1; i <= n; i++) fallback[f[i]]
}
NR == FNR {
    if (match($0, /^attributes #[0-9]+ = /) && match($0, /"abla\.source"="[^"]+"/)) {
        id = $0; sub(/^attributes #/, "", id); sub(/ = .*/, "", id)
        attr[id] = substr($0, RSTART + 15, RLENGTH - 16)
    }
    next
}
/^define / && /\{$/ && !inside {
    line = $0; id = ""
    while (match(line, / #[0-9]+/)) { id = substr(line, RSTART + 2, RLENGTH - 2); line = substr(line, RSTART + RLENGTH) }
    if (id != "") { inside = 1; name = attr[id]; created = 0 }
}
inside {
    if (index($0, "@abla_array_create(")) created = 1
    if ($0 == "}") {
        inside = 0
        if (name in eligible) {
            if (created) { print "materialized constant array: " name; bad = 1 }
            delete eligible[name]
        }
        if (name in fallback) {
            if (!created) { print "missing ordinary fallback: " name; bad = 1 }
            delete fallback[name]
        }
    }
}
END {
    for (n in eligible) { print "definition not found: " n; bad = 1 }
    for (n in fallback) { print "definition not found: " n; bad = 1 }
    exit bad
}
AWK
awk -f "$out/constant-array.awk" "$out/program.ll" "$out/program.ll" || { echo 'for constant array: IR guard failed' >&2; exit 1; }
status=0
"$compiler" build tests/cases/bootstrap/invalid-for-constant-array.ab \
    -o "$out/invalid" --no-cache > "$out/invalid.log" 2>&1 || status=$?
[[ $status == 1 ]]
grep -q 'assignment.immutable:value' "$out/invalid.log"
grep -q 'missingInEmptyLiteralLoop' "$out/invalid.log"
echo 'literal for: scalar constants, fallback effects, captures, loop exits/cleanup and IR passed'
