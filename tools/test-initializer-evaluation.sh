#!/usr/bin/env bash
set -euo pipefail

# A global's `#` initializer runs whether or not anything reads the global and
# whether or not the program has `main`: the same registrations reach the
# object built from a program with `main` and from one without. The assembly
# is x86-64, so both are built as x86_64-linux objects on every host.
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
cases=$project_root/tests/cases/initializer-evaluation
output=$project_root/build/initializer-evaluation
mkdir -p "$output"
symbol_reader=$(command -v llvm-nm || command -v nm)

for program in with-main object; do
    printed=$("$compiler" build "$cases/$program.ab" \
        --target x86_64-linux --emit object \
        -o "$output/$program.o" --no-cache)
    if ! rg -q 'unread initializer evaluated' <<<"$printed"; then
        echo "$program: the unread global's compile-time code did not run" >&2
        exit 1
    fi
    symbols=$("$symbol_reader" "$output/$program.o")
    for symbol in abla_test_unread_export abla_test_unread_required \
        abla_test_unread_assembly_link abla_test_unread_assembly_root; do
        if ! rg -q " $symbol\$" <<<"$symbols"; then
            echo "$program: $symbol is missing" >&2
            exit 1
        fi
    done
    # Required and assembly-reached names stay local; only exports are public.
    rg -q ' T abla_test_unread_export$' <<<"$symbols" || exit 1
    rg -q ' t abla_test_unread_required$' <<<"$symbols" || exit 1
    rg -q ' t abla_test_unread_assembly_link$' <<<"$symbols" || exit 1
done
echo 'Unread compile-time initializers passed'
