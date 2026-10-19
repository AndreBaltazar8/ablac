#!/usr/bin/env bash
# A direct function's value parameters are `noalias`, except a closure's drop
# function's and the runtime's implementations' (bootstrapLlvmDirectValuesNoAlias).
# The program reading arguments across raw stores, field writes through other
# arguments, moves, closures, generators and drops gives the same output as is
# and when every safe point collects (ABLA_GC_STRESS=1).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/value-arguments"
mkdir -p "$output_directory"
source="$project_root/tests/cases/bootstrap/value-arguments.ab"

"$compiler" --emit-llvm "$source" > "$output_directory/program.ll"
# The parameters of the direct definition whose abla.source is $1.
parameters() {
    awk -v source="$1" '
        /^attributes #[0-9]+ = \{/ && index($0, "\"abla.source\"=\"" source "\"") {
            group = $2; sub(/^#/, "", group); groups[group] = 1
        }
        { lines[NR] = $0 }
        END {
            for (n = 1; n <= NR; n++) {
                line = lines[n]
                if (line !~ /^define .*_direct\(/) continue
                attribute = line; sub(/.*\) *#/, "", attribute); sub(/ .*/, "", attribute)
                if (attribute in groups) {
                    sub(/^[^(]*\(/, "", line); sub(/\) *#.*/, "", line); print line
                }
            }
        }' "$output_directory/program.ll"
}
expect_noalias() { # source want
    local found
    found=$(parameters "$1")
    [[ -n $found ]] || { echo "value arguments: no direct definition for $1" >&2; exit 1; }
    if [[ $2 == yes && $found != *noalias* ]]; then
        echo "value arguments: $1 lacks noalias: $found" >&2; exit 1
    fi
    if [[ $2 == no && $found == *noalias* ]]; then
        echo "value arguments: $1 has noalias: $found" >&2; exit 1
    fi
}
expect_noalias extension_Grid_fill yes
expect_noalias relabel yes
expect_noalias consume yes
expect_noalias __ablaRuntimeFieldGetIndexed no
closure_drop=$(grep -o '"abla.source"="__abla_closure_drop_[^"]*"' "$output_directory/program.ll" |
    head -1 | sed 's/.*="//; s/"$//')
[[ -n $closure_drop ]] || { echo "value arguments: no closure drop function" >&2; exit 1; }
expect_noalias "$closure_drop" no

"$compiler" build "$source" -o "$output_directory/program" --no-cache \
    > "$output_directory/build.log" 2>&1 || { cat "$output_directory/build.log" >&2; exit 1; }
expected='fill 126 filled 6
again 78 filled 12
relabel start/next next/back
sum 1212 12
first then first
closure 50 then 6
generator 2 4 6 8 10 12
captured 8
drop first
drop captured'
for stress in 0 1; do
    set +e
    output=$(ABLA_GC_STRESS=$stress ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" "$output_directory/program" 2>&1)
    status=$?
    set -e
    if [[ $status -ne 42 || $output != "$expected" ]]; then
        echo "value arguments (ABLA_GC_STRESS=$stress): status $status, output:" >&2
        echo "$output" >&2
        exit 1
    fi
done
echo "value arguments: noalias on direct value parameters (not drop functions or the runtime's); the program agrees with and without collection at every safe point"
