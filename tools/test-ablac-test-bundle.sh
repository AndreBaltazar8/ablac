#!/usr/bin/env bash
# `ablac test` over many files builds them as bundles (test_runner.ab) and reports
# exactly what building and running each file on its own (--each) reports: files with
# the same top-level names (`main`, helpers) share a bundle under their aliases, two
# that declare the same extension member go to separate bundles, a file whose import
# has an error is dropped from its bundle and built on its own (which reports the
# error), a crash fails only its own test, and a test's exit status is reported as is.
# Shared modules count too: two that declare the same public name (`ApiResult`), each
# imported by other tests, put those tests in separate bundles with no file built on
# its own, while overloads (`render(int)` and `render(string)`, two `Box.label`s) and
# private names share one.
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

shared=tests/cases/test-bundle-shared
status=0
"$compiler" test -v --no-cache "$shared" > "$work/shared.out" 2> "$work/shared.err" || status=$?
[[ $status -eq 0 ]] || { cat "$work/shared.out" "$work/shared.err" >&2; fail "the shared-module suite exited $status"; }
status=0
"$compiler" test --each --no-cache "$shared" > "$work/shared-each.out" 2>&1 || status=$?
[[ $status -eq 0 ]] || fail "the shared-module suite's --each exited $status"
grep -E '^(PASS|FAIL) ' "$work/shared.out" | sort > "$work/shared.results"
grep -E '^(PASS|FAIL) ' "$work/shared-each.out" | sort > "$work/shared-each.results"
diff "$work/shared-each.results" "$work/shared.results" > "$work/shared.diff" ||
    { cat "$work/shared.diff" >&2; fail "shared-module bundled results differ from --each's"; }
grep -qx "8 passed, 0 failed" "$work/shared.out" || { cat "$work/shared.out" >&2; fail "the shared-module summary"; }
grep -q "^8 files, 2 bundles (" "$work/shared.out" || { cat "$work/shared.out" >&2; fail "the shared-module partition"; }
! grep -q "on their own" "$work/shared.out" || { cat "$work/shared.out" >&2; fail "a shared-module file was built on its own"; }
# The bundle a file landed in: the last "bundle <n> (" line above its own line.
bundle_of() {
    awk -v file="  $shared/$1" '/^bundle [0-9]+ \(/ { bundle = $2 } $0 == file { print bundle }' "$work/shared.out"
}
for name in label-number label-text number number-again render-number render-text; do
    [[ $(bundle_of "$name.test.ab") == 0 ]] || { cat "$work/shared.out" >&2; fail "$name.test.ab is not in bundle 0"; }
done
for name in text text-again; do
    [[ $(bundle_of "$name.test.ab") == 1 ]] || { cat "$work/shared.out" >&2; fail "$name.test.ab is not in bundle 1"; }
done
echo "test bundle: bundled results match --each (duplicate names, extension clash, broken import, crash, exit status, shared-module clash)"
