#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* || $compiler != */* ]] || compiler=$PWD/$compiler
out="$root/build/auto-copy"
mkdir -p "$out"
cd "$root/tests/cases/auto-copy"
"$compiler" build main.ab --fast --strict-imports --no-cache -o "$out/main"
"$out/main" > "$out/actual"
expected='7 true true true 7 keep 3 2 7 12 9 6 rnc'
printf '%s\n%s\n' "$expected" "$expected" > "$out/expected"
cmp "$out/expected" "$out/actual"
reject() {
    local fixture=$1 message=$2
    if "$compiler" build "$fixture.ab" --fast --strict-imports --no-cache -o "$out/$fixture" > "$out/$fixture.log" 2>&1; then
        echo "auto copy: $fixture unexpectedly compiled" >&2
        exit 1
    fi
    if ! grep -F "$message" "$out/$fixture.log" >/dev/null; then
        cat "$out/$fixture.log" >&2
        exit 1
    fi
}
reject hidden-import 'the primary constructor of `Model` is not visible here'
reject hidden-private 'the primary constructor of `Hidden` is not visible here'
reject affine 'the receiver has affine ownership'
reject unknown-field 'E_NAMED_ARGUMENT_UNKNOWN'
reject written-kind 'E_NAMED_ARGUMENT_TARGET'
echo 'auto copy: constructor visibility, ownership, named overrides and written targets passed'
