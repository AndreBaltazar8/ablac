#!/usr/bin/env bash
# Declared field slots (ablaRuntimeLoadSlot*/StoreSlot*, the typed field
# accessors) and abla/unsafe memory carry separate TBAA tags; nothing else is
# tagged. The program interleaving raw and field accesses reads what was last
# written, as is and when every safe point collects (ABLA_GC_STRESS=1).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/slot-alias"
mkdir -p "$output_directory"
source="$project_root/tests/cases/bootstrap/slot-alias.ab"

"$compiler" --emit-llvm "$source" > "$output_directory/program.ll"
ir="$output_directory/program.ll"
# The tag a node named $1 gives: its access-tag metadata id.
tag_of() {
    local type
    type=$(grep -E "^![0-9]+ = !\{!\"$1\", " "$ir" | head -1 | cut -d' ' -f1)
    [[ -n $type ]] || { echo "slot alias: no type node named '$1'" >&2; exit 1; }
    grep -E "^![0-9]+ = !\{$type, $type, i64 0\}" "$ir" | head -1 | cut -d' ' -f1
}
slot=$(tag_of "abla field slot")
raw=$(tag_of "abla raw memory")
[[ -n $slot && -n $raw ]] || { echo "slot alias: missing access tags" >&2; exit 1; }
grep -qE "load i64, ptr .*!tbaa $slot( |,|$)" "$ir" || { echo "slot alias: no slot-tagged load" >&2; exit 1; }
grep -qE "store i64 .*!tbaa $slot( |,|$)" "$ir" || { echo "slot alias: no slot-tagged store" >&2; exit 1; }
grep -qE "store i64 .*!tbaa $raw( |,|$)" "$ir" || { echo "slot alias: no raw-tagged store" >&2; exit 1; }
grep -qE "load i64, ptr .*!tbaa $raw( |,|$)" "$ir" || { echo "slot alias: no raw-tagged load" >&2; exit 1; }
tagged=$(grep -cE "!tbaa " "$ir")
slot_or_raw=$(grep -cE "!tbaa ($slot|$raw)( |,|$)" "$ir")
[[ $tagged -eq $slot_or_raw ]] || { echo "slot alias: $tagged tagged accesses, $slot_or_raw slot or raw" >&2; exit 1; }

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
echo "slot alias: field slots and raw memory tagged apart ($slot_or_raw accesses), nothing else tagged; the program agrees with and without collection at every safe point"
