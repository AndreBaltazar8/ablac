#!/usr/bin/env bash
# tools/run-tests.sh's own files around a command must never decide its verdict in silence. A command's CPU seconds go to
# <output>/<n>.cpu; when that file cannot be written the runner used to exit 1 with no word, so a passing test showed as
# "FAIL (exit 1)" after its last "ok". It now says why in the command's log and keeps the command's own status.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work=$(mktemp -d "${TMPDIR:-/tmp}/run-tests-bookkeeping.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'run-tests bookkeeping: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

# Command 1 passes but leaves a directory where its CPU seconds go; command 2 fails the same way with its own status.
cat > "$work/commands" <<EOF
mkdir $work/out/1.cpu && echo first ok
mkdir $work/out/2.cpu && exit 3
EOF
status=0
JOBS=1 RUN_TESTS_MIN_FREE=0 RUN_TESTS_LIST= RUN_TESTS_SHARD= RUN_TESTS_FILTER= RUN_TESTS_EXCLUDE= \
    RUN_TESTS_OUTPUT=$work/out RUN_TESTS_COMMANDS=$work/commands RUN_TESTS_HISTORY=$work/none \
    timeout 120 tools/run-tests.sh "$compiler" > "$work/runner.log" 2>&1 || status=$?
[[ $status == 1 ]] || fail "the runner exited $status, not 1 (one command fails)" "$work/runner.log"
result() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$work/out/results.tsv"; }
[[ $(result 1) == 0 ]] || fail "a passing command whose CPU file could not be written was not a pass: $(cat "$work/out/results.tsv")"
[[ $(result 2) == 3 ]] || fail "a failing command lost its own status 3: $(cat "$work/out/results.tsv")"
for n in 1 2; do
    grep -F "run-tests: cannot record the CPU seconds in $work/out/$n.cpu" "$work/out/$n.log" > /dev/null ||
        fail "command $n's log does not say why its CPU seconds were not recorded" "$work/out/$n.log"
done
echo 'run-tests bookkeeping: a CPU file that cannot be written is named in the log and leaves the command its status'
