#!/usr/bin/env bash
# Every test script runs somewhere (#1294): a tools/test-*.sh, tools/*/test-*.sh or tools/*/test-*.mjs that nothing calls never fails,
# so its checks are silently gone (22 such scripts sat beside the suite until 2026-11-26, some for a month). Each must be named by
# the suite's recipe (Makefile), a workflow, tests/abla-tests.json (which test-self-hosted.sh runs) or another tracked script, or be
# listed with its reason in tools/tests-outside-suite.txt (a test that needs hardware, the network or a quarter of an hour). Lists
# that only select from the suite (tools/test-quick.txt, tools/test-fast-builds.txt, tools/test-times.tsv) do not count as callers.
# A listed script that no longer exists fails too, so the list stays true. (A listed one may still be named elsewhere: a manual
# driver such as tools/run-aarch64-hardware.sh, or a comment.)
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
outside=tools/tests-outside-suite.txt
work=$(mktemp -d "${TMPDIR:-/tmp}/test-reachability.XXXXXX")
trap 'rm -rf "$work"' EXIT

# (git pathspecs: `*` matches across directories.)
git ls-files 'tools/test-*.sh' 'tools/*/test-*.sh' 'tools/*/test-*.mjs' > "$work/tests"
[[ -s $work/tests ]] || { echo "test reachability: no test scripts found" >&2; exit 1; }
# The callers: the recipe, the workflows, the self-hosted test list and every tracked script (not the selection lists, not docs).
# One pass: each caller file and every test-script name it mentions.
git ls-files -z Makefile '.github/workflows/*.yml' tests/abla-tests.json 'tools/*.sh' 'tools/*.ps1' 'tools/*.mjs' 'tools/*.ab' \
    'tests/*.mjs' 'tests/*.sh' |
    xargs -0 grep -o -H -E 'test-[A-Za-z0-9_.-]+\.(sh|mjs)' > "$work/mentions" || true
grep -v -E '^[[:space:]]*(#|$)' "$outside" | awk '{ print $1 }' > "$work/outside"

failed=0
while IFS= read -r test; do
    name=${test##*/}
    # A mention of the name in a file other than the script itself.
    called=$(awk -F: -v self="$test" -v name="$name" '$1 != self && $2 == name { print $1; exit }' "$work/mentions")
    listed=$(grep -x -F -- "$test" "$work/outside" || true)
    if [[ -z $called && -z $listed ]]; then
        echo "test reachability: $test has no caller: add it to the Makefile's test-serial recipe (or a workflow), or to $outside with its reason"
        failed=1
    fi
done < "$work/tests"
while IFS= read -r listed; do
    grep -x -F -- "$listed" "$work/tests" > /dev/null || { echo "test reachability: $outside lists $listed, which is not a tracked test script"; failed=1; }
done < "$work/outside"
((failed == 0)) || exit 1
echo "test reachability: $(wc -l < "$work/tests") test scripts, each with a caller or listed in $outside ($(wc -l < "$work/outside") listed)"
