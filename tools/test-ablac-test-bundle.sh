#!/usr/bin/env bash
# `ablac test` over many files builds them as bundles (test_runner.ab) and reports
# exactly what building and running each file on its own (--each) reports: files with
# the same top-level names (`main`, helpers) share a bundle under their aliases, two
# that declare the same extension member go to separate bundles, a file whose import
# has an error is dropped from its bundle and built on its own (which reports the
# error), a crash fails only its own test, and a test's exit status is reported as is.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
cd "$project_root"
cases=tests/cases/test-bundle
work=build/test-bundle-check
rm -rf "$work"
mkdir -p "$work"
fail() {
    echo "test bundle: $1" >&2
    exit 1
}
status=0
"$compiler" test -v --no-cache "$cases" > "$work/bundled.out" 2> "$work/bundled.err" || status=$?
[[ $status -eq 1 ]] || { cat "$work/bundled.out" "$work/bundled.err" >&2; fail "a suite with failures exited $status"; }
status=0
"$compiler" test --each --no-cache "$cases" > "$work/each.out" 2> "$work/each.err" || status=$?
[[ $status -eq 1 ]] || fail "--each exited $status"
grep -E '^(PASS|FAIL) ' "$work/bundled.out" | sort > "$work/bundled.results"
grep -E '^(PASS|FAIL) ' "$work/each.out" | sort > "$work/each.results"
diff "$work/each.results" "$work/bundled.results" > "$work/results.diff" ||
    { cat "$work/results.diff" >&2; fail "bundled results differ from --each's"; }
expect() { grep -qx "$1" "$work/bundled.results" || { cat "$work/bundled.out" >&2; fail "expected: $1"; }; }
for name in pass-number pass-text state extension-one extension-two; do
    expect "PASS $cases/$name.test.ab"
done
expect "FAIL $cases/exit.test.ab (exit 3)"
expect "FAIL $cases/broken.test.ab (build)"
grep -q "^FAIL $cases/crash.test.ab (exit [1-9][0-9]*)$" "$work/bundled.results" || fail "the crash was not reported"
grep -qx "5 passed, 3 failed" "$work/bundled.out" || fail "the summary"
# Two bundles (the extension clash): the second has one file, built on its own; the
# broken file is dropped from the first and built alone, which reports its error.
grep -q "^bundle 0 (6 files" "$work/bundled.out" || { cat "$work/bundled.out" >&2; fail "bundle 0"; }
grep -qx "bundle 1: one file, built on its own: $cases/extension-two.test.ab" "$work/bundled.out" ||
    fail "bundle 1"
grep -qx "  $cases/broken.test.ab" "$work/bundled.out" || fail "the broken file was not dropped"
grep -q "missing.ab" "$work/bundled.err" || fail "the broken file's own build did not report its error"
echo "test bundle: bundled results match --each (duplicate names, extension clash, broken import, crash, exit status)"
