#!/usr/bin/env bash
# The action journal (ABLA_ACTION_JOURNAL, off by default): an evaluation that only asks the compiler
# questions is journaled replayable, and asking again of the same program gives the same answers
# (check); every recorded answer changed by one byte is reported as a mismatch (mutate); an action
# that changes the program is unreplayable (negative control); with the journal off nothing is
# printed. The shift mode replays against a program with every handle moved.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/action-journal"

journal() { # $1 = mode, $2 = case
    ABLA_ACTION_JOURNAL=$1 "$compiler" --emit-llvm "$cases/$2.ab" 2>&1 >/dev/null | grep '^ACTION-JOURNAL' || true
}

report=$(journal check queries)
[[ $report == *"ACTION-JOURNAL-CHECK survey checked="* && $report == *"mismatched=0"* ]] ||
    { echo "action-journal: check mode did not replay the queries cleanly:"; echo "$report"; exit 1; }
[[ $report == *"calls="*"replayable=true"* ]] ||
    { echo "action-journal: the query-only action is not replayable:"; echo "$report"; exit 1; }
checked=$(sed -n 's/.*checked=\([0-9]*\).*/\1/p' <<<"$report" | head -1)
(( checked >= 20 )) || { echo "action-journal: only $checked queries were replayed"; exit 1; }

mutated=$(journal mutate queries | grep '^ACTION-JOURNAL-CHECK')
[[ $mutated == *"checked=$checked mismatched=$checked"* ]] ||
    { echo "action-journal: a changed answer was not reported for every query:"; echo "$mutated"; exit 1; }

# Shifted program (the first declaration moved to the end: every handle moves). A handle's NUMBER is
# observable to the action (it can be interpolated or sorted by), so a journal that holds one is a miss
# when the number moved even though the identity is found again: every query that takes or returns a
# function handle must be reported. (Class handles are raw positions: a miss as well.)
shifted=$(journal shift queries | grep '^ACTION-JOURNAL-CHECK')
[[ $shifted == *"checked=$checked "* && $shifted != *"functions=0"* ]] ||
    { echo "action-journal: a moved function handle was not reported:"; echo "$shifted"; exit 1; }

# Native compile-time routes (ABLA_COMPILE_EVAL=jit) call the API through the bridge: no journal there.
[[ -z $(ABLA_COMPILE_EVAL=jit journal 1 queries) ]] ||
    { echo "action-journal: journal output under ABLA_COMPILE_EVAL=jit"; exit 1; }

negative=$(journal 1 mutating)
[[ $negative == *"replayable=false extern compilerAddFunctionAnnotation"* ]] ||
    { echo "action-journal: the mutating action is not unreplayable:"; echo "$negative"; exit 1; }

[[ -z $(journal 0 queries) ]] ||
    { echo "action-journal: output with the journal off"; exit 1; }
echo "action-journal: record, check, mutate, shifted program, negative control, off"
