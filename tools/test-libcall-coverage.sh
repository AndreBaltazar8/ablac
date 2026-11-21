#!/usr/bin/env bash
# #806 / #648: every library call the optimiser or the code generator can introduce is one the static compiler's JIT knows. The JIT'd code of
# `ablac run`, the compile-time jit tier and a program's compile-time `extern:"c"` calls find their C functions in the table of
# src/static_libc_symbols.ab (the dynamic compiler found them in glibc); a function the table lacks fails the user's build with "Symbols not
# found" (exp2 was one: LLVM's library-call simplifier rewrites pow(2, x) into it). tools/gen-libcall-probe.sh writes IR that makes LLVM
# introduce them (every math intrinsic in double and float, the libm functions by name and the rewrites of pow/exp/sqrt, mem* and str*
# functions and the loop idioms, wide integer division and float conversions, an frem); this optimises it at O2 and generates code for
# x86-64 and AArch64 with the pinned LLVM's opt and llc (the version the static archives are), and requires every undefined symbol to be in
# the table. Usage: tools/test-libcall-coverage.sh
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'libcall coverage: Linux only'; exit 0; }
for tool in opt llc nm; do
    command -v "$tool" > /dev/null || { echo "libcall coverage: $tool is needed" >&2; exit 1; }
done
out=build/libcall-coverage
rm -rf "$out"
mkdir -p "$out"
tools/gen-libcall-probe.sh > "$out/probe.ll"
# The table: the quoted names of the first array of src/static_libc_symbols.ab (bootstrapStaticLibcSymbolNames).
awk '/^fun bootstrapStaticLibcSymbolNames/ { inside = 1 } inside { print } inside && /^\]/ { exit }' src/static_libc_symbols.ab |
    grep -o '"[A-Za-z_0-9.]*"' | tr -d '"' | sort -u > "$out/table.txt"
[[ $(wc -l < "$out/table.txt") -gt 200 ]] || { echo 'libcall coverage: the symbol table could not be read' >&2; exit 1; }
status=0
for triple in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    opt -mtriple="$triple" -passes='default<O2>' "$out/probe.ll" -o "$out/probe.$triple.bc"
    llc -mtriple="$triple" -O2 -filetype=obj -relocation-model=pic "$out/probe.$triple.bc" -o "$out/probe.$triple.o"
    nm -u "$out/probe.$triple.o" | awk '{ print $NF }' | sort -u > "$out/undefined.$triple.txt"
    count=$(wc -l < "$out/undefined.$triple.txt")
    [[ $count -gt 50 ]] || { echo "libcall coverage: $triple: only $count undefined symbols (is the probe still making calls?)" >&2; exit 1; }
    missing=$(comm -23 "$out/undefined.$triple.txt" "$out/table.txt" | tr '\n' ' ')
    if [[ -n $missing ]]; then
        echo "libcall coverage: $triple code can call these, and the static compiler's JIT table lacks them: $missing" >&2
        status=1
    fi
done
[[ $status == 0 ]] || { echo 'libcall coverage: add each missing name to src/static_libc_symbols.ab and define it in src/static_libc' >&2; exit 1; }
echo "libcall coverage: every library call LLVM introduces for x86-64 and AArch64 ($(cat "$out"/undefined.*.txt | sort -u | wc -l) names) is in the JIT symbol table"
