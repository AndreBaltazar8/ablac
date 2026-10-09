#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory="$project_root/build/value-slot-addresses"
fixture="$project_root/tests/cases/value-slot-addresses.ab"
mkdir -p -- "$output_directory"

"$compiler" build "$fixture" -o "$output_directory/value-slot-addresses" \
    --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/value-slot-addresses"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'value slot addresses: expected 42, got %s\n' "$status" >&2
    exit 1
fi

"$compiler" --emit-llvm "$fixture" > "$output_directory/value-slot-addresses.ll"

# The bodies of the functions whose attributes name this source function.
bodies() {
    local llvm="$output_directory/value-slot-addresses.ll"
    local groups
    groups=$(sed -n "s/^attributes \(#[0-9]*\) = .*\"abla.source\"=\"$1\".*/\1/p" "$llvm")
    [[ -n $groups ]] || return 0
    awk -v groups=" $(tr '\n' ' ' <<<"$groups")" '
        /^define / {
            inside = 0
            for (i = 1; i <= NF; i++) if (index(groups, " " $i " ")) inside = 1
        }
        inside { print }
        /^}/ { inside = 0 }
    ' "$llvm"
}

for function in slotTag slotWord1 slotLocal; do
    body=$(bodies "$function")
    if [[ -z $body ]] || ! grep -q 'runtime.value.field' <<<"$body" ||
        grep -q 'ptrtoint' <<<"$body"; then
        printf 'value slot addresses: %s should read its value slot directly\n' \
            "$function" >&2
        printf '%s\n' "$body" >&2
        exit 1
    fi
done

for function in slotEscapes slotPast slotTwoStores; do
    body=$(bodies "$function")
    if [[ -z $body ]] || grep -q 'runtime.value.field' <<<"$body" ||
        ! grep -q 'ptrtoint' <<<"$body" || ! grep -q 'inttoptr' <<<"$body"; then
        printf 'value slot addresses: %s should keep its integer address\n' \
            "$function" >&2
        printf '%s\n' "$body" >&2
        exit 1
    fi
done

printf '%s\n' 'value slot addresses: slot reads fold, escaping, out-of-slot and reassigned addresses stay'
