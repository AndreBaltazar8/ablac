#!/usr/bin/env bash
# Exercise the shebang guard against an isolated index without modifying this repo.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/abla-shebang-guard.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/tools" "$scratch/tests/cases/deep"
cp "$root/tools/test-repo-shebang-guard.sh" "$scratch/tools/"
cd "$scratch"
git init -q
git config core.autocrlf false
git add tools
bash tools/test-repo-shebang-guard.sh >/dev/null
expect_blocked() {
    local name=$1 output
    if output=$(bash tools/test-repo-shebang-guard.sh 2>&1); then
        printf 'shebang guard self-test: accepted %s\n' "$name" >&2; exit 1
    fi
    [[ $output == *"$name"* ]] || { printf 'shebang guard self-test: missing path %s\n' "$name" >&2; exit 1; }
}
# A line above the shebang, as the slips were.
printf 'step\n#!/usr/bin/env bash\necho ok\n' >tools/test-slipped.sh
git add tools/test-slipped.sh
expect_blocked tools/test-slipped.sh
git rm --cached -q tools/test-slipped.sh
# No shebang at all, under tests/ and deeper.
printf 'echo ok\n' >tests/cases/deep/run.sh
git add tests/cases/deep/run.sh
expect_blocked tests/cases/deep/run.sh
git rm --cached -q tests/cases/deep/run.sh
# An executable without one, whatever its name.
printf 'echo ok\n' >tools/run-thing
chmod +x tools/run-thing
git add tools/run-thing
expect_blocked tools/run-thing
git rm --cached -q tools/run-thing
# A non-executable file that is not a .sh script is not checked; a good script passes.
printf 'data\n' >tests/cases/deep/notes.txt
printf '#!/usr/bin/env bash\necho ok\n' >tools/test-good.sh
git add tests/cases/deep/notes.txt tools/test-good.sh
bash tools/test-repo-shebang-guard.sh >/dev/null
echo 'shebang guard: a line above the shebang, a script without one and a bare executable fail; good scripts pass'
