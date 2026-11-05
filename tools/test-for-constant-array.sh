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
python3 - "$out/program.ll" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
attrs=dict(re.findall(r'attributes #(\d+) = .*?"abla.source"="([^"]+)"',text))
eligible={'literalForInts','literalForBool','literalForFloat','literalForEmpty',
          'literalForSingleton','literalForControl','literalForReturn','literalForSixteen'}
fallback={'literalForFallback','literalForLarge','literalForStrings'}
for match in re.finditer(r'^define [^\n]+ #(\d+)[^\n]*\{\n.*?^\}',text,re.M|re.S):
 name=attrs.get(match[1]);body=match[0]
 if name in eligible:
  assert '@abla_array_create(' not in body, 'materialized constant array: '+name
  eligible.remove(name)
 if name in fallback:
  assert '@abla_array_create(' in body, 'missing ordinary fallback: '+name
  fallback.remove(name)
assert not eligible and not fallback,(eligible,fallback)
PY
status=0
"$compiler" build tests/cases/bootstrap/invalid-for-constant-array.ab \
    -o "$out/invalid" --no-cache > "$out/invalid.log" 2>&1 || status=$?
[[ $status == 1 ]]
grep -q 'assignment.immutable:value' "$out/invalid.log"
grep -q 'missingInEmptyLiteralLoop' "$out/invalid.log"
echo 'literal for: scalar constants, fallback effects, captures, loop exits/cleanup and IR passed'
