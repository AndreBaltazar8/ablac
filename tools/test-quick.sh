#!/usr/bin/env bash
# The quick lane, `make test-quick`: the suite's guards, its short commands, and the tests of the areas a change
# touched (tools/test-quick.txt), through tools/run-tests.sh. About two minutes after a compiler change at JOBS=8; the
# gate is still `make test`. QUICK_BASE is the commit the change is measured from (default: the merge base with
# origin/master), QUICK_AREAS=all runs every area's tests. QUICK_LIST=1 prints the commands instead of running them.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
list=tools/test-quick.txt
output=${RUN_TESTS_OUTPUT:-build/test-results/quick}
mkdir -p "$(dirname "$output")"

# The suite's commands, as tools/run-tests.sh takes them, keyed with COMPILER for the compiler.
suite=$output.suite-commands.txt
MAKEFLAGS= MFLAGS= make -s -n -o ablac -o "$compiler" test-serial COMPILER="$compiler" >"$suite"
key() { local command=$1; printf '%s\n' "${command//$compiler/COMPILER}"; }

# What changed: committed since the base, staged and not, and untracked files.
base=${QUICK_BASE:-$(git merge-base HEAD origin/master 2>/dev/null || git rev-parse HEAD)}
changed=$( { git diff --name-only "$base" HEAD; git diff --name-only; git diff --name-only --cached;
    git ls-files --others --exclude-standard; } | sort -u)

# The scripts the touched areas name.
wanted=" "
while IFS= read -r line; do
    [[ $line == area\ * ]] || continue
    spec=${line#area }
    pattern=${spec%%: *}
    tests=${spec#*: }
    if [[ ${QUICK_AREAS:-} == all ]] || grep -Eq -- "$pattern" <<<"$changed"; then
        for test in $tests; do wanted+="$test "; done
    fi
done <"$list"

# Beside the output, which tools/run-tests.sh empties before it starts.
selected=$output.commands.txt
: >"$selected"
while IFS= read -r command; do
    [[ -z $command ]] && continue
    k=$(key "$command")
    take=false
    grep -Fxq -- "core $k" "$list" && take=true
    [[ $command =~ tools/test-[a-z0-9-]*guard[a-z0-9-]*\.sh ]] && take=true
    if [[ $command =~ tools/test-([a-z0-9-]+)\.sh ]] && [[ $wanted == *" ${BASH_REMATCH[1]} "* ]]; then take=true; fi
    [[ $take == true ]] && printf '%s\n' "$command" >>"$selected"
done <"$suite"

echo "quick: $(wc -l <"$selected") of $(grep -c . "$suite") commands (areas:${wanted% })"
if [[ -n ${QUICK_LIST:-} ]]; then cat "$selected"; exit 0; fi
RUN_TESTS_COMMANDS=$selected RUN_TESTS_OUTPUT=$output exec tools/run-tests.sh "$compiler"
