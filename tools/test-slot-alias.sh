#!/usr/bin/env bash
# Declared field slots (ablaRuntimeLoadSlot*/StoreSlot*, the typed field
# accessors) and raw memory carry separate TBAA tags. Stack values, dense
# array headers and dense array elements are children of the raw-memory type.
# The program reads what was last written, including under ABLA_GC_STRESS=1.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/slot-alias"
mkdir -p "$output_directory"
source="$project_root/tests/cases/bootstrap/slot-alias.ab"

"$compiler" --emit-llvm "$source" > "$output_directory/program.ll"
ir="$output_directory/program.ll"
# Find the type node by name and, when supplied, require its parent.
type_of() {
    local pattern="^![0-9]+ = ![{]!\"$1\", ${2:-![0-9]+}, i64 0[}]$"
    local type
    type=$(awk -v pattern="$pattern" '$0 ~ pattern {print $1; exit}' "$ir")
    [[ -n $type ]] || { echo "slot alias: missing type '$1' with expected parent" >&2; exit 1; }
    printf '%s\n' "$type"
}

tag_of() {
    local type=$1 tag
    tag=$(awk -v node="!{$type, $type, i64 0}" '$1 ~ /^![0-9]+$/ && substr($0, index($0, " = ") + 3) == node {print $1; exit}' "$ir")
    [[ -n $tag ]] || { echo "slot alias: missing access tag for $type" >&2; exit 1; }
    printf '%s\n' "$tag"
}

raw_type=$(type_of "abla raw memory")
slot_type=$(type_of "abla field slot")
stack_type=$(type_of "abla stack value" "$raw_type")
header_type=$(type_of "abla dense array header" "$raw_type")
element_type=$(type_of "abla dense array element" "$raw_type")
slot=$(tag_of "$slot_type")
raw=$(tag_of "$raw_type")
stack=$(tag_of "$stack_type")
header=$(tag_of "$header_type")
element=$(tag_of "$element_type")
grep -qE "load i64, ptr .*!tbaa $slot( |,|$)" "$ir" || { echo "slot alias: no slot-tagged load" >&2; exit 1; }
grep -qE "store i64 .*!tbaa $slot( |,|$)" "$ir" || { echo "slot alias: no slot-tagged store" >&2; exit 1; }
grep -qE "store i64 .*!tbaa $raw( |,|$)" "$ir" || { echo "slot alias: no raw-tagged store" >&2; exit 1; }
grep -qE "load i64, ptr .*!tbaa $raw( |,|$)" "$ir" || { echo "slot alias: no raw-tagged load" >&2; exit 1; }
grep -qE "load %AblaValue, ptr .*!tbaa $stack( |,|$)" "$ir" || { echo "slot alias: no stack-tagged value load" >&2; exit 1; }
for field in length data; do
    grep -qE "%dense[.]array[.]$field[0-9]* = load i64, ptr .*!tbaa $header( |,|$)" "$ir" ||
        { echo "slot alias: no header-tagged $field load" >&2; exit 1; }
done
grep -qE "%dense[.]array[.]word[0-9]* = load i64, ptr .*!tbaa $element( |,|$)" "$ir" || { echo "slot alias: no element-tagged load" >&2; exit 1; }
grep -qE "store i64 .*, ptr %dense[.]array[.]element[0-9]*, .*!tbaa $element( |,|$)" "$ir" || { echo "slot alias: no element-tagged store" >&2; exit 1; }
tagged=$(grep -cE "!tbaa " "$ir")
recognized=$(grep -cE "!tbaa ($slot|$raw|$stack|$header|$element)( |,|$)" "$ir")
[[ $tagged -eq $recognized ]] || { echo "slot alias: $tagged tagged accesses, $recognized recognized" >&2; exit 1; }

"$compiler" build "$source" -o "$output_directory/program" --no-cache \
    > "$output_directory/build.log" 2>&1 || { cat "$output_directory/build.log" >&2; exit 1; }
expected='run 1325 count 25 scale 4 open true
swap 608 size 8
named second 0'
for stress in 0 1; do
    set +e
    output=$(ABLA_GC_STRESS=$stress ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" "$output_directory/program" 2>&1)
    status=$?
    set -e
    if [[ $status -ne 42 || $output != "$expected" ]]; then
        echo "slot alias (ABLA_GC_STRESS=$stress): status $status, output:" >&2
        echo "$output" >&2
        exit 1
    fi
done
echo "slot alias: field slots and raw memory tagged apart ($recognized accesses), with separate tags under raw memory for stack values, array headers and dense elements; runtime output agrees under GC stress"
