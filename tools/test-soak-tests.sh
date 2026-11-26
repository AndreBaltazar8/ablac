#!/usr/bin/env bash
# Exercise the real suite runner in a private tree: no compiler or shared cache is touched.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tools" "$work/build"
cp "$root/tools/soak-tests.sh" "$root/tools/run-tests.sh" "$work/tools/"
printf 'fixture compiler\n' >"$work/build/ablac"
cp "$work/build/ablac" "$work/build/ablac.bin"
export RUN_TESTS_COMMANDS=$work/commands.txt JOBS=2 RUN_TESTS_MIN_FREE=0
unset RUN_TESTS_EXCLUDE RUN_TESTS_SHARD RUN_TESTS_LIST RUN_TESTS_HISTORY
cat >"$RUN_TESTS_COMMANDS" <<'COMMANDS'
echo passing
if test -f build/once; then echo recovered; else touch build/once; echo first-failure; exit 7; fi
echo always-failure; exit 9
COMMANDS
expect_status() {
    local expected=$1 actual=0
    shift
    "$@" >"$work/output.log" 2>&1 || actual=$?
    [[ $actual == "$expected" ]] || { cat "$work/output.log" >&2; echo "soak fixture: wanted $expected, got $actual" >&2; exit 1; }
}
expect_status 1 "$work/tools/soak-tests.sh" 3 '' build/ablac "$work/evidence"
summary=$work/evidence/summary.tsv
grep -q $'^3\t0\t0.00%\techo passing$' "$summary"
grep -q $'^3\t1\t33.33%\tif test' "$summary"
grep -q $'^3\t3\t100.00%\techo always-failure' "$summary"
[[ $(wc -l <"$work/evidence/results.tsv") == 9 && $(wc -l <"$work/evidence/failures.tsv") == 4 ]]
while IFS=$'\t' read -r iteration number status command log; do
    [[ $status == 7 || $status == 9 ]]
    [[ -n $command ]]
    [[ -s $log && $log == "$work/evidence/run-$iteration/$number.log" ]]
done <"$work/evidence/failures.tsv"
grep -q first-failure "$work/evidence/run-1/2.log"
grep -q recovered "$work/evidence/run-2/2.log"
expect_status 0 "$work/tools/soak-tests.sh" 2 '^echo passing$' build/ablac "$work/pass"
[[ $(wc -l <"$work/pass/summary.tsv") == 1 ]]
expect_status 2 "$work/tools/soak-tests.sh" 1 '' build/ablac "$work/evidence"
grep -q first-failure "$work/evidence/run-1/2.log"
expect_status 2 "$work/tools/soak-tests.sh" 1 'no-such-command' build/ablac "$work/empty"
expect_status 2 "$work/tools/soak-tests.sh" 0 ''
expect_status 2 "$work/tools/soak-tests.sh" 1 '['
# A focused parent must not shrink the shard check's whole-recipe universe.
# Only listing runs here: none of the recipe's commands (or its compiler) execute.
cp "$root/Makefile" "$work/Makefile"
cp "$root/tools/test-shards.sh" "$root/tools/test-times.tsv" "$root/tools/test-libc-free-programs.sh" "$work/tools/"
mkdir -p "$work/src" "$work/stdlib" "$work/tests/cases/modules"
touch "$work/tests/cases/modules/"{first,second,third,fourth}.ab
expect_status 0 env RUN_TESTS_FILTER='no-such-command' RUN_TESTS_EXCLUDE='.*' \
    RUN_TESTS_COMMANDS="$work/no-such-recipe" "$work/tools/test-shards.sh" build/ablac
# A bare compiler has no .bin companion: keep its cache between identical runs,
# invalidate it when its bytes change, and prefer the payload for launchers.
printf 'echo cache-probe\n' >"$work/cache-commands.txt"
cache_step=0
cache_run() {
    cache_step=$((cache_step + 1))
    RUN_TESTS_FILTER='' RUN_TESTS_COMMANDS="$work/cache-commands.txt" \
        RUN_TESTS_OUTPUT="$work/cache-$cache_step" "$work/tools/run-tests.sh" "$1" \
        >"$work/cache-$cache_step.console.log" 2>&1
    [[ $(wc -l <"$work/cache-$cache_step/results.tsv") == 1 ]]
}
sentinel=$work/build/.abla-cache/sentinel
printf 'direct-v1\n' >"$work/build/direct"
cache_run "$work/build/direct"
mkdir -p "$work/build/.abla-cache"
touch "$sentinel"
cache_run "$work/build/direct"
[[ -f $sentinel && -n $(cat "$work/build/.abla-cache.compiler") ]] ||
    { echo 'runner cache: unchanged bare compiler lost its cache/fingerprint' >&2; exit 1; }
printf 'direct-v2-changed\n' >"$work/build/direct"
cache_run "$work/build/direct"
[[ ! -f $sentinel ]] || { echo 'runner cache: changed bare compiler kept stale cache' >&2; exit 1; }
printf 'launcher-v1\n' >"$work/build/wrapper"
printf 'payload-v1\n' >"$work/build/wrapper.bin"
cache_run "$work/build/wrapper"
mkdir -p "$work/build/.abla-cache"
touch "$sentinel"
printf 'launcher-v2-changed\n' >"$work/build/wrapper"
cache_run "$work/build/wrapper"
[[ -f $sentinel ]] || { echo 'runner cache: launcher text invalidated an unchanged payload' >&2; exit 1; }
printf 'payload-v2-changed\n' >"$work/build/wrapper.bin"
cache_run "$work/build/wrapper"
[[ ! -f $sentinel ]] || { echo 'runner cache: changed payload kept stale cache' >&2; exit 1; }
# A runner that drops a result but returns success must not produce a clean rate.
mv "$work/tools/run-tests.sh" "$work/tools/real-runner"
cat >"$work/tools/run-tests.sh" <<'RUNNER'
#!/usr/bin/env bash
if [[ -n ${RUN_TESTS_LIST:-} ]]; then
    exec "$(dirname -- "$0")/real-runner" "$@"
fi
mkdir -p "$RUN_TESTS_OUTPUT"
printf '1\t0\t0.1\techo passing\t0.1\n' >"$RUN_TESTS_OUTPUT/results.tsv"
RUNNER
chmod +x "$work/tools/run-tests.sh"
expect_status 2 "$work/tools/soak-tests.sh" 2 '' build/ablac "$work/incomplete"
[[ ! -f $work/incomplete/summary.tsv ]]
cat >"$work/tools/run-tests.sh" <<'RUNNER'
#!/usr/bin/env bash
status=0
"$(dirname -- "$0")/real-runner" "$@" || status=$?
[[ -z ${RUN_TESTS_LIST:-} ]] || exit "$status"
exit "${SOAK_FIXTURE_STATUS:-0}"
RUNNER
# Results, rather than a falsely successful wrapper, determine the failure rate.
expect_status 1 "$work/tools/soak-tests.sh" 1 '' build/ablac "$work/false-success"
# A failed runner with no failed row is an infrastructure error, not a clean sample.
expect_status 2 env SOAK_FIXTURE_STATUS=1 "$work/tools/soak-tests.sh" 1 '^echo passing$' build/ablac "$work/false-failure"
echo 'soak: flake rates, failure logs, filtering, evidence preservation and incomplete-result refusal passed'
