#!/usr/bin/env bash
# A module value first demanded while lowering (through an extension method call)
# initializes after the values its initializer reads, not before them; so does one
# whose initializer reads through a call lowering inserts (a float template part's
# f64Text reads abla/float/text's tables), at run time and under `#` in both tiers.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
output_root=$project_root/build/global-init-order-test
mkdir -p "$output_root"
cd "$project_root/tests/cases/global-init-order"
"$compiler" build main.ab -o "$output_root/global-init-order" --no-cache
"$output_root/global-init-order"

expect_42() { # name program
    set +e
    "$project_root/tools/run-limited.sh" "$2"
    local status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "global init order: $1 exited $status, expected 42" >&2; exit 1; }
}
template_case="$project_root/tests/cases/modules/global-init-template-floats.ab"
"$compiler" build "$template_case" -o "$output_root/template" --no-cache
expect_42 "template floats at run time" "$output_root/template"
sed -E 's/^fun main: int =/fun checked(): int =/' "$template_case" > "$output_root/staged.ab"
printf '\nfun main: int = #checked()\n' >> "$output_root/staged.ab"
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$output_root/staged.ab" \
        -o "$output_root/staged-$mode" --no-cache
    expect_42 "template floats under # ($mode)" "$output_root/staged-$mode"
done
echo "global init order: initializers see the values they read, also through the text writers templates call"
