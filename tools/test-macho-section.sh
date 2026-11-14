#!/usr/bin/env bash
# `@section(".text.NAME")` on a Mach-O target (tests/cases/macho-section reaches the crypto allocation entry,
# which carries one): the section is "__TEXT,__NAME" cut to 14 characters, not the ELF spelling LLVM rejects.
# On a Mac the program is built and run; elsewhere it builds the module for both Mac targets and assembles it with llc.
# Usage: tools/test-macho-section.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/macho-section
rm -rf "$out"
mkdir -p "$out"
source=tests/cases/macho-section/main.ab
if [[ $(uname -s) == Darwin ]]; then
    for mode in release fast; do
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        "$compiler" build "$source" -o "$out/$mode" "${flags[@]}"
        [[ $("$out/$mode") == 'macho section: ok' ]] || { echo "macho section ($mode): wrong output" >&2; exit 1; }
        if ! nm -m "$out/$mode" | grep -q '__abla_ct_alloca'; then
            echo "macho section ($mode): the allocation entry is not in its own section" >&2
            exit 1
        fi
    done
    echo 'macho section: built and run on this Mac (release and --fast), the entry in its own section'
    exit 0
fi
# Off a Mac the link needs an SDK (ABLA_MACOS_SDK); the module is written before it, and LLVM's assembler is
# the judge of the section name.
for target in arm64-macos x86_64-macos; do
    "$compiler" build "$source" -o "$out/$target" --no-cache --target "$target" > "$out/$target.log" 2>&1 || true
    [[ -s $out/$target.ll ]] || { cat "$out/$target.log" >&2; echo "macho section ($target): no module written" >&2; exit 1; }
    llc -O0 -filetype=obj "$out/$target.ll" -o "$out/$target.o" 2> "$out/$target.err" || {
        echo "macho section ($target): llc refused the module" >&2; head -n 5 "$out/$target.err" >&2; exit 1
    }
    llvm-objdump -h "$out/$target.o" | grep -q '__abla_ct_alloca' || {
        echo "macho section ($target): no section __abla_ct_alloca in the object" >&2; exit 1
    }
    # The hidden memory routines' labels are assembler-private ("L"), not symbols a linker may dead-strip as atoms.
    if llvm-nm "$out/$target.o" | grep -q ' [tT] \.Labla_'; then
        echo "macho section ($target): a routine label is a symbol (.Labla_...)" >&2; exit 1
    fi
    llvm-nm "$out/$target.o" | grep -q ' _memcpy$' || { echo "macho section ($target): no _memcpy of its own" >&2; exit 1; }
done
echo 'macho section: both Mac targets assemble, the allocation entry in __TEXT,__abla_ct_alloca'
