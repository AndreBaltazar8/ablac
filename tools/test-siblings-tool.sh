#!/usr/bin/env bash
# tools/test-siblings.sh on made-up siblings (no compiler, no network): a candidate "compiler" that refuses bad.ab and a
# baseline that builds everything. A program the baseline builds and the candidate doesn't is a regression, with its
# first error; a failing test command is reported; a listed repository that isn't there is skipped; the summary and
# the exit status say so; the layout's worktrees are gone afterwards and the repositories themselves are untouched.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "$project_root/build/siblings-tool.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { echo "siblings tool: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c; }

projects=$work/projects
mkdir -p "$projects/sib-good" "$projects/sib-bad" "$projects/cand/build"
for repo in sib-good sib-bad; do git -C "$projects/$repo" init --quiet --initial-branch=main; done
echo 'fun main: int = 0' > "$projects/sib-good/main.ab"
echo 'fun main: int = 0' > "$projects/sib-bad/ok.ab"
echo 'fun main: int = 0' > "$projects/sib-bad/bad.ab"
commit "$projects/sib-good"
commit "$projects/sib-bad"
cat > "$projects/cand/build/ablac" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && { echo fake-candidate; exit 0; }
for argument in "$@"; do
    if [[ $argument == *bad.ab ]]; then echo "error[E_FAKE]: the candidate refuses $argument" >&2; exit 1; fi
    if [[ $argument == main.ab ]]; then
        for file in main.ab src/lib.ab; do
            echo "warning[W_UNUSED_IMPORT]: $PWD/$file: nothing \`import \"abla/text\"\` declares is used here" >&2
        done
    fi
done
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/baseline"
chmod +x "$projects/cand/build/ablac" "$work/baseline"
# sib-good's test runs `ablac` from PATH, as a Makefile's `COMPILER ?= ablac` does: it must be the candidate. Its
# warnings: one of the program build's two again (counted once), a test file's (a root `fix-imports --project`
# misses) and a generated file's under build/ (not counted): 3 in all.
warn() { printf 'echo "warning[W_UNUSED_IMPORT]: %s: nothing \\`import \\"abla/text\\"\\` declares is used here" >&2; ' "$@"; }
printf 'sib-good\tablac --version > v.txt && grep fake-candidate v.txt >/dev/null && %s%s%s true\nsib-bad\tfalse\nsib-missing\t-\n' \
    "$(warn main.ab)" "$(warn tests/a_test.ab)" "$(warn build/gen/main.ab)" > "$work/list"

status=0
"$project_root/tools/test-siblings.sh" "$projects/cand" --baseline "$work/baseline" --list "$work/list" \
    --projects "$projects" --out "$work/out" --jobs 2 > "$work/run.log" 2>&1 || status=$?
[[ $status == 1 ]] || fail "exit $status, wanted 1 (a regression and a failing test)" "$work/run.log"
grep -qE '^sib-good +1/1 +0 +3 +0/0 +pass$' "$work/out/summary.txt" || fail "sib-good's line" "$work/out/summary.txt"
grep -qE '^sib-bad +1/2 +1 +0 +0/0 +FAIL \(1, test-sib-bad.log\)$' "$work/out/summary.txt" || fail "sib-bad's line" "$work/out/summary.txt"
grep -qx 'sib-good tests/a_test.ab: nothing `import "abla/text"` declares is used here' "$work/out/unused.txt" ||
    fail "the test file's unused import isn't listed" "$work/out/unused.txt"
grep -q 'sib-missing is listed but not beside ablac; skipped' "$work/run.log" || fail "the missing one wasn't reported" "$work/run.log"
grep -q '^### sib-bad bad.ab' "$work/out/regressions.txt" || fail "the regression isn't named" "$work/out/regressions.txt"
grep -q 'E_FAKE' "$work/out/regressions.txt" || fail "the regression's error isn't kept" "$work/out/regressions.txt"
for repo in sib-good sib-bad; do
    [[ $(git -C "$projects/$repo" worktree list | wc -l) == 1 ]] || fail "$repo still has the layout's worktree"
    [[ -z $(git -C "$projects/$repo" status --porcelain) ]] || fail "$repo was changed"
done
[[ ! -e $work/out/layout ]] || fail "the layout is still there"

# With no baseline every program the candidate can't build counts; all good: exit 0.
status=0
"$project_root/tools/test-siblings.sh" "$projects/cand" --list <(printf 'sib-good\ttrue\n') --projects "$projects" \
    --out "$work/out2" > "$work/run2.log" 2>&1 || status=$?
[[ $status == 0 ]] || fail "exit $status for a clean sibling" "$work/run2.log"

# Expected-fail programs: a repository's negative test (bad.ab, which the candidate refuses) named in the expected-fail file is no regression and
# shows in the xfail column (1/1); a program named there that builds (ok.ab) is an unexpected pass and fails the run; a repository with a
# shell.nix has its builds run through nix-shell (a fake one on PATH records the call), one without it does not.
mkdir -p "$projects/sib-neg" "$work/fakebin"
echo 'fun main: int = 0' > "$projects/sib-neg/ok.ab"
echo 'fun main: int = 0' > "$projects/sib-neg/bad.ab"
echo '{}' > "$projects/sib-neg/shell.nix"
git -C "$projects/sib-neg" init --quiet --initial-branch=main
commit "$projects/sib-neg"
printf '#!/usr/bin/env bash\n[[ $1 == shell.nix && $2 == --run ]] || exit 99\necho "$PWD" >> %q\nexec bash -c "$3"\n' "$work/nix-shell.log" > "$work/fakebin/nix-shell"
chmod +x "$work/fakebin/nix-shell"
printf 'sib-neg\tbad.ab\n' > "$work/xfail"
status=0
PATH="$work/fakebin:$PATH" "$project_root/tools/test-siblings.sh" "$projects/cand" --list <(printf 'sib-neg\t-\nsib-good\t-\n') --projects "$projects" \
    --expected-fail "$work/xfail" --programs-only --out "$work/out3" > "$work/run3.log" 2>&1 || status=$?
[[ $status == 0 ]] || fail "exit $status for an expected failure" "$work/run3.log"
grep -qE '^sib-neg +1/1 +0 +0 +1/1 +-$' "$work/out3/summary.txt" || fail "sib-neg's line (1/1 built, 1/1 expected-fail)" "$work/out3/summary.txt"
[[ ! -s $work/out3/regressions.txt ]] || fail "an expected failure counted as a regression" "$work/out3/regressions.txt"
grep -q 'sib-neg' "$work/nix-shell.log" || fail "the repository with a shell.nix was not built inside it"
[[ $(grep -c . "$work/nix-shell.log") == 2 ]] || fail "only sib-neg's two programs go through nix-shell" "$work/nix-shell.log"
printf 'sib-neg\tok.ab\n' > "$work/xfail2"
status=0
PATH="$work/fakebin:$PATH" "$project_root/tools/test-siblings.sh" "$projects/cand" --list <(printf 'sib-neg\t-\n') --projects "$projects" \
    --expected-fail "$work/xfail2" --programs-only --out "$work/out4" > "$work/run4.log" 2>&1 || status=$?
[[ $status == 1 ]] || fail "exit $status, wanted 1 for an unexpected pass" "$work/run4.log"
grep -q 'unexpected pass' "$work/run4.log" || fail "the unexpected pass isn't reported" "$work/run4.log"
echo "siblings tool: expected-fail programs are no regression, and an unexpected pass fails; a repository shell.nix is used. A regression (with its error) and a failing test fail the run, unused imports are counted once from both layers, a missing sibling is skipped, nothing is left behind"
