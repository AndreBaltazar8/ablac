#!/usr/bin/env bash
# The pre-semantic pipeline answers its probes' "does the program use STM?" once, from its input (bootstrapPreSemanticPipeline,
# src/frontend.ab; bootstrapProgramUsesStm, src/sema.ab): when the input has no `atomic` and no declaration named Transactional,
# no stage's rewrite of it has one. That holds while only the parser makes an "atomic" node and no stage makes a Transactional
# declaration. This test keeps it so:
#   - every "atomic" and "Transactional" string literal in src/ is one of the known readers (comparisons, the parser's own
#     node and keyword, the STM note, source prefilters); a new one fails here until the pipeline's shortcut is reviewed for it;
#     a planted construction in a copy of src/ is caught (the control);
#   - with ABLA_CHECK_STM_SCAN=1 every skipped probe scan is made anyway and a found `atomic` ends the build: programs that
#     exercise generics, overloads, named arguments and delegated properties build under it, and an STM program (whose input
#     has `atomic`, so nothing is skipped) still gets its transaction diagnostic.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $compiler == /* || $compiler != */* ]] || compiler=$root/$compiler
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-stm-scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() {
    echo "stm scan invariant: $*" >&2
    exit 1
}
# The literals in SOURCE-DIR that are not known readers, one per line ("" when none).
unknown_literals() {
    { grep -rn --include=*.ab -E '"(atomic|Transactional)"' "$1" || true; } |
        grep -v -E '(==|!=) *"(atomic|Transactional)"' |
        grep -v -E 'BootstrapExpression\("atomic", "", start\.begin, body\.end, \[body\]\)' |
        grep -v -E 'atContextualKeyword\("atomic", BOOTSTRAP_TOKEN_LBRACE\)' |
        grep -v -E 'stmNote\("atomic", ' |
        grep -v -E 'source\.contains\("(atomic|Transactional)"\)' |
        grep -v -E 'bootstrapSourceNamesWord\(snapshot\.source, "Transactional"\)' |
        grep -v -E 'bootstrap(InterfaceIndexOf|TypeConformsVia)\(declarations, declarationNames, (declaration\.name, )?"Transactional"\)' |
        grep -v -E '^[^:]*:[0-9]+: *(//|/\*\*|\*)' || true
}
found=$(unknown_literals src)
[[ -z $found ]] || fail "a new \"atomic\" or \"Transactional\" literal in src/ (review bootstrapPreSemanticPipeline's STM shortcut):
$found"
# The control: a stage that makes an `atomic` node.
mkdir -p "$work/src"
cp src/generics.ab "$work/src/generics.ab"
printf '\nfun bootstrapPlantedAtomic(at: BootstrapExpression): BootstrapExpression =\n    BootstrapExpression(\n        "atomic", "", at.begin, at.end, [at]\n    )\n' >> "$work/src/generics.ab"
[[ -n $(unknown_literals "$work/src") ]] || fail 'the planted construction of an "atomic" node was not caught'

build() { # SOURCE OUTPUT: build under the check; the build's diagnostics go to OUTPUT.err
    ABLA_CHECK_STM_SCAN=1 "$compiler" build "$1" --no-cache -o "$2" > "$2.out" 2> "$2.err"
}
for program in tests/cases/generics/main.ab tests/cases/named-overloads/main.ab tests/cases/generic-default/main.ab; do
    [[ -f $program ]] || continue
    name=$(basename "$(dirname "$program")")
    if ! build "$program" "$work/$name"; then
        cat "$work/$name.err" >&2
        fail "$program does not build under ABLA_CHECK_STM_SCAN=1"
    fi
    checked=$((${checked:-0} + 1))
done
[[ ${checked:-0} -gt 0 ]] || fail 'none of the programs to check exists'
# A program with transactions: its input has `atomic`, so nothing is skipped, and it builds and runs as tools/test-stm.sh expects.
build tests/cases/stm/basic.ab "$work/stm" || { cat "$work/stm.err" >&2; fail 'the STM program does not build under the check'; }
set +e
"$work/stm" > "$work/stm.run"
status=$?
set -e
[[ $status -eq 42 && $(cat "$work/stm.run") == 'single thread: 0 failed, commits 201 abandoned 0' ]] ||
    fail "the STM program printed $(cat "$work/stm.run") with status $status"
echo "stm scan invariant: src/ makes no \"atomic\" or Transactional outside the parser (planted one caught); $checked programs built under the check; an STM program builds and runs"
