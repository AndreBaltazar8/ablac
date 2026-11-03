#!/usr/bin/env bash
# Resource locals run drop() at the end of their scope (an inner block, then the
# function, latest declared first), whatever the length of their type's name.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/resource-scope-drops"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/resource-short-name-drop.ab" \
    -o "$output_directory/program"
output=$("$output_directory/program")
expected=$'inner 3\ndrop File 3\nwork 2 4\ndrop Files 4\ndrop Doc 2\ndrop A 1\ndone'
[[ $output == "$expected" ]] || { echo "unexpected output:"; echo "$output"; exit 1; }
echo "resource scope drops: every local's drop runs, short type names too"

for fixture in discarded-if unchanged-if; do
    for profile in release fast; do
        flags=()
        [[ $profile != fast ]] || flags=(--fast)
        "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
            -o "$output_directory/$fixture-$profile" "${flags[@]}"
        for stress in 0 1; do
            status=0
            ABLA_GC_STRESS=$stress "$output_directory/$fixture-$profile" || status=$?
            [[ $status == 42 ]] || {
                echo "$fixture ($profile, GC stress $stress): exit $status"
                exit 1
            }
        done
    done
done

"$compiler" --emit-llvm "$project_root/tests/cases/bootstrap/discarded-if.ab" \
    > "$output_directory/discarded-if.ll"
python3 - "$output_directory/discarded-if.ll" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
attrs = dict(re.findall(r'attributes #(\d+) = .*?"abla.source"="([^"]+)"', text))
for match in re.finditer(r'^define [^\n]+ #(\d+)[^\n]*\{\n.*?^\}', text, re.M | re.S):
    if attrs.get(match[1]) == 'discardedIfScalar':
        # A scalar-only statement if needs no boxed join. One unused void
        # literal remains permitted; the old lowering allocates four values.
        assert len(re.findall(r'alloca %AblaValue\b', match[0])) <= 1, 'boxed discarded-if join'
        break
else:
    raise AssertionError('missing scalar fixture')
PY
echo "discarded if: arm drops, loop control, refinements and affine joins are preserved"
