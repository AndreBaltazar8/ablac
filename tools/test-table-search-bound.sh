#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/table-search-bound"
source="$root/tests/cases/loop-optimization/table-search-bound.ab"
mkdir -p "$out"
"$compiler" --emit-llvm "$source" > "$out/program.ll"

body_of() {
    local attribute
    attribute=$(sed -n "s/^attributes \(#[0-9]*\) = .*\"abla.source\"=\"$1\".*/\1/p" "$out/program.ll")
    [[ -n $attribute ]]
    awk -v attribute="$attribute" '
        /^define / && index($0, " " attribute " {") { inside = 1 }
        inside { print }
        inside && /^}/ { exit }' "$out/program.ll"
}

body_of tableSearch > "$out/search.ll"
body_of changingSearch > "$out/changing.ll"
awk '
    /^source.label[^:]*:/ { inside_loop = 1 }
    /call i64 @abla_string_length_i64\(/ { found++; if (inside_loop) misplaced++ }
    END { exit found != 1 || misplaced }
' "$out/search.ll" || { echo 'table search: bound must be evaluated before the inner loop' >&2; exit 1; }
awk '
    /^source.label[^:]*:/ { inside_loop = 1 }
    /call i64 @abla_string_length_i64\(/ && inside_loop { found++ }
    END { exit !found }
' "$out/changing.ll" || { echo 'table search: changing bound must stay in the loop' >&2; exit 1; }

for profile in release fast; do
    flags=()
    [[ $profile == release ]] || flags=(--fast)
    "$compiler" build "$source" --no-cache -o "$out/program-$profile" "${flags[@]}"
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$out/program-$profile" || status=$?
        [[ $status == 42 ]]
    done
    status=0
    "$out/program-$profile" bounds > "$out/bounds.out" 2> "$out/bounds.err" || status=$?
    [[ $status == 101 ]]
    IFS= read -r message < "$out/bounds.err"
    [[ $message == "panic: index 1 out of bounds for array of size 1" ]]
done
echo 'table search: fixed string bound is evaluated once, changing bounds and array checks are preserved'
