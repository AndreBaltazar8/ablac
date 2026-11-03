#!/usr/bin/env bash
# Arrays of numbers and bools are stored densely and box on demand.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/arrays-dense"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/arrays-dense.ab" \
    -o "$output_directory/program"
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "dense arrays: numbers and bools in 8-byte words, boxed on demand"

# Native scalar stores and boxed-storage fallback preserve every payload bit.
for profile in release fast o1; do
    flags=()
    [[ $profile == release ]] || flags=(--"$profile")
    "$compiler" build "$project_root/tests/cases/modules/scalar-array-setters.ab" \
        --no-cache -o "$output_directory/scalars-$profile" "${flags[@]}"
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$output_directory/scalars-$profile" || status=$?
        [[ $status == 42 ]] || exit 1
    done
    "$compiler" build "$project_root/tests/cases/modules/scalar-array-set-trap.ab" \
        --no-cache -o "$output_directory/trap-$profile" "${flags[@]}"
    for kind in i64 bool f64 f32; do
        for bound in upper negative; do
            arguments=("$kind")
            index=2
            if [[ $bound == negative ]]; then arguments+=(negative); index=-1; fi
            status=0
            "$output_directory/trap-$profile" "${arguments[@]}" \
                > "$output_directory/trap.out" 2> "$output_directory/trap.err" || status=$?
            [[ $status == 101 ]] || { cat "$output_directory/trap.err"; exit 1; }
            IFS= read -r message < "$output_directory/trap.err"
            [[ $message == "panic: index $index out of bounds for array of size 2" ]] || exit 1
        done
    done
done
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build \
        "$project_root/tests/cases/scalar-array-setters/staged.ab" \
        --no-cache -o "$output_directory/staged-$mode"
    status=0
    "$output_directory/staged-$mode" || status=$?
    [[ $status == 42 ]] || exit 1
done

"$compiler" --emit-llvm "$project_root/tests/cases/modules/scalar-array-setters.ab" \
    > "$output_directory/scalars.ll"
python3 - "$output_directory/scalars.ll" <<'PYGUARD'
import re,sys
text=open(sys.argv[1]).read()
attrs=dict(re.findall(r'attributes #(\d+) = .*?"abla.source"="([^"]+)"',text))
names={'scalarI64Store','scalarBoolStore','scalarF64Store','scalarF32Store'}
for match in re.finditer(r'^define [^\n]+ #(\d+)[^\n]*\{\n.*?^\}',text,re.M|re.S):
    name=attrs.get(match[1])
    if name in names:
        assert re.search(r'call void @abla_array_set_word\(i64 ',match[0]),name
        assert 'call void @abla_array_set(' not in match[0],name
        assert len(re.findall(r'alloca %AblaValue\b',match[0])) <= 1,name
        names.remove(name)
assert not names,names
PYGUARD
echo "scalar arrays: native words, exact float bits, boxed fallback, checked bounds and staged stores"
