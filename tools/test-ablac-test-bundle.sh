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
# private names share one. Two runs at once in one directory, over other files, each
# report their own results (each bundle's build is named by its files).
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
"$compiler" test -v "$cases" > "$work/bundled.out" 2> "$work/bundled.err" || status=$?
[[ $status -eq 1 ]] || { cat "$work/bundled.out" "$work/bundled.err" >&2; fail "a suite with failures exited $status"; }
status=0
"$compiler" test --each "$cases" > "$work/each.out" 2> "$work/each.err" || status=$?
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
"$compiler" test -v "$shared" > "$work/shared.out" 2> "$work/shared.err" || status=$?
[[ $status -eq 0 ]] || { cat "$work/shared.out" "$work/shared.err" >&2; fail "the shared-module suite exited $status"; }
status=0
"$compiler" test --each "$shared" > "$work/shared-each.out" 2>&1 || status=$?
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
# Runs over other files never write the same build (-v names each bundle's), so two at
# once in one directory can't run each other's programs.
paths() { sed -nE 's/^bundle [0-9]+ \([0-9]+ files, (.*)\):$/\1/p' "$1" | sort; }
[[ -n $(paths "$work/bundled.out") && -n $(paths "$work/shared.out") ]] || fail "-v named no bundle builds"
[[ -z $(comm -12 <(paths "$work/bundled.out") <(paths "$work/shared.out")) ]] ||
    fail "runs over other files share a bundle build: $(comm -12 <(paths "$work/bundled.out") <(paths "$work/shared.out") | tr '\n' ' ')"
# Two runs at once in one directory, over other files: each reports what it did alone.
s1=0; s2=0
"$compiler" test "$cases" > "$work/both-cases.out" 2>/dev/null & first=$!
"$compiler" test "$shared" > "$work/both-shared.out" 2>/dev/null & second=$!
wait $first || s1=$?
wait $second || s2=$?
[[ $s1 -eq 1 && $s2 -eq 0 ]] || fail "concurrent runs exited $s1 and $s2"
grep -E '^(PASS|FAIL) ' "$work/both-cases.out" | sort | diff "$work/bundled.results" - > "$work/both.diff" ||
    { cat "$work/both.diff" >&2; fail "a concurrent run's results differ"; }
grep -E '^(PASS|FAIL) ' "$work/both-shared.out" | sort | diff "$work/shared.results" - > "$work/both.diff" ||
    { cat "$work/both.diff" >&2; fail "the other concurrent run's results differ"; }
echo "test bundle: bundled results match --each (duplicate names, extension clash, broken import, crash, exit status, shared-module clash, concurrent runs)"

# Discovery may be shared with the first build, but a test can change input
# for a later bundle. Preserve size and mtime to catch accidentally retaining
# the old discovery state across those executions.
mutation="$work/mutation"
mkdir -p "$mutation"
cat > "$mutation/change.py" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = p.stat()
p.write_text('fun secondValue(): int = 2\n')
os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
assert p.stat().st_size == before.st_size
assert p.stat().st_mtime_ns == before.st_mtime_ns
PY
cat > "$mutation/first.ab" <<EOF
import "abla/sys/linux/process"
fun string.discoveryClash(): int = 1
fun firstMutation(): int {
    val command = linuxCommand("python3")
    command.argument("$mutation/change.py")
    command.argument("$mutation/value.ab")
    command.run()
}
EOF
cat > "$mutation/second.ab" <<'AB'
fun string.discoveryClash(): int = 2
AB
for name in first first-again; do
    cat > "$mutation/$name.test.ab" <<'AB'
import "first.ab"
fun main: int = firstMutation()
AB
done
for name in second second-again; do
    cat > "$mutation/$name.test.ab" <<'AB'
import "second.ab"
import "value.ab"
fun main: int = if (secondValue() == 2) 0 else 1
AB
done
for round in cold warm; do
    printf '%s\n' 'fun secondValue(): int = 1' > "$mutation/value.ab"
    "$compiler" test -v "$mutation/first.test.ab" "$mutation/first-again.test.ab" \
        "$mutation/second.test.ab" "$mutation/second-again.test.ab" \
        > "$work/mutation-$round.out" 2> "$work/mutation-$round.err" ||
        { cat "$work/mutation-$round.out" "$work/mutation-$round.err" >&2; fail "discovery persisted across a test's input edit ($round)"; }
    grep -q '^4 files, 2 bundles (' "$work/mutation-$round.out" || fail "the discovery-mutation partition"
    grep -qx '4 passed, 0 failed' "$work/mutation-$round.out" || fail "the discovery-mutation results"
done
echo 'test bundle: discovery is scoped before test execution, including same-size edits with restored mtime'

# An unchanged generated bundle is a stable source input. Compare content,
# not timestamps, and regenerate a file whose bytes were replaced.
stable="$work/stable"
mkdir -p "$stable"
for name in one two; do
    printf '%s\n' 'fun main: int = 0' > "$stable/$name.test.ab"
done
"$compiler" test -v "$stable" > "$work/stable-first.out" 2> "$work/stable-first.err" || fail 'initial stable bundle'
stable_output=$(paths "$work/stable-first.out")
[[ -n $stable_output && $(printf '%s\n' "$stable_output" | wc -l) -eq 1 ]] || fail 'one stable bundle'
stable_root="$stable_output.ab"
python3 - "$stable_root" "$work/stable-state.json" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.stat()
pathlib.Path(sys.argv[2]).write_text(json.dumps([s.st_dev, s.st_ino, s.st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest()]))
PY
"$compiler" test -v "$stable" > "$work/stable-again.out" 2> "$work/stable-again.err" || fail 'unchanged stable bundle'
python3 - "$stable_root" "$work/stable-state.json" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.stat()
assert [s.st_dev, s.st_ino, s.st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest()] == json.loads(pathlib.Path(sys.argv[2]).read_text()), 'unchanged generated bundle was rewritten'
p.write_text('invalid generated input\n')
PY
"$compiler" test -v "$stable" > "$work/stable-repair.out" 2> "$work/stable-repair.err" || fail 'repaired stable bundle'
python3 - "$stable_root" "$work/stable-state.json" <<'PY'
import hashlib, json, pathlib, sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == json.loads(pathlib.Path(sys.argv[2]).read_text())[3], 'generated bundle was not repaired'
PY
for run in first again repair; do
    grep -qx '2 passed, 0 failed' "$work/stable-$run.out" || fail "stable bundle results ($run)"
done
echo 'test bundle: unchanged generated input keeps its inode and mtime, changed content is regenerated'
