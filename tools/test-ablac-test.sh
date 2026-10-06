#!/usr/bin/env bash
# `ablac test` builds and runs test programs; abla/test's checks report each
# failing check and set the exit status.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
cases="$project_root/tests/cases/test-runner"
cd "$project_root"

"$compiler" test "$cases/passing.ab" --no-cache > build/ablac-test-pass.out
grep -q '^5 checks, 0 failed$' build/ablac-test-pass.out
grep -q "^PASS $cases/passing.ab$" build/ablac-test-pass.out
set +e
"$compiler" test "$cases/failing.ab" "$cases/passing.ab" --no-cache \
    > build/ablac-test-fail.out
status=$?
set -e
[[ $status -eq 1 ]] || exit 1
grep -q '^FAIL arithmetic: expected 5, got 4$' build/ablac-test-fail.out
grep -q "^FAIL $cases/failing.ab (exit 1)$" build/ablac-test-fail.out
grep -q '^1 passed, 1 failed$' build/ablac-test-fail.out
echo "ablac test: runs test programs and reports failing checks"
