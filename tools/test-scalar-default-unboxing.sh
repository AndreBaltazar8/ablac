#!/usr/bin/env bash
set -euo pipefail
# This test reads the module's LLVM text, which a development build keeps only when asked.
export ABLA_KEEP_LLVM_TEXT=1
compiler=${1:-build/ablac}
fixture=tests/cases/modules/scalar-default-unboxing.ab
output=build/tests/scalar-default-unboxing
mkdir -p build/tests
"$compiler" run "$fixture"
for triple in x86_64-unknown-linux-gnu i386-unknown-linux-gnu; do
    "$compiler" build "$fixture" -o "$output-$triple.o" \
        --target-triple "$triple" --object-format elf --emit object
    opt '-passes=default<Oz>,globaldce' -S "$output-$triple.o.ll" -o "$output-$triple.opt.ll"
    # Dynamic input must reduce to an integer add, without boxing or calls.
    symbol=abla_scalar_default_unboxing
    alias_target=$(sed -n 's/^@abla_scalar_default_unboxing = alias .*ptr @\([^ ,]*\).*/\1/p' "$output-$triple.opt.ll")
    if [[ -n $alias_target ]]; then symbol=$alias_target; fi
    body=$(sed -n "/^define .*@$symbol(/,/^}/p" "$output-$triple.opt.ll")
    test -n "$body"
    if printf '%s\n' "$body" | grep -Eq 'alloca|\bcall\b|\binvoke\b|load|store'; then
        printf '%s\n' "$body" >&2
        echo "scalar default unboxing retained runtime machinery on $triple" >&2
        exit 1
    fi
    printf '%s\n' "$body" | grep -Eq 'add( (nuw|nsw))* i32 .*[, ]2$'
done
echo 'PASS: scalar defaults eliminate boxes on 32/64-bit LLVM; pointer byte offsets and wrapping execute correctly'
