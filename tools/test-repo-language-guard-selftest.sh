#!/usr/bin/env bash
# Exercise the guard against an isolated index without modifying this repo.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/abla-language-guard.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/tools"
cp "$root/tools/repo-language-inventory.sh" "$root/tools/test-repo-language-guard.sh" "$scratch/tools/"
cd "$scratch"
git init -q
git config core.autocrlf false
interpreter='py'"thon3"
suffix=p"y"
legacy="legacy.$suffix"
added="new.$suffix"
printf '#!/usr/bin/env %s\n' "$interpreter" >"$legacy"
printf '#!/bin/sh\n%s -c pass\n' "$interpreter" >legacy.sh
printf '%s\n' "$legacy" legacy.sh >tools/legacy-py-allowlist.txt
git add tools "$legacy" legacy.sh
bash tools/test-repo-language-guard.sh >/dev/null
expect_blocked() {
    local name=$1 output
    if output=$(bash tools/test-repo-language-guard.sh 2>&1); then
        printf 'language guard self-test: accepted %s\n' "$name" >&2; exit 1
    fi
    [[ $output == *"$name"* ]] || { printf 'language guard self-test: missing path %s\n' "$name" >&2; exit 1; }
}
printf 'pass\n' >"$added"
git add "$added"
expect_blocked "$added"
git rm --cached -q "$added"
printf '#!/usr/bin/env -S %s -I\n' "$interpreter" >new-tool
git add new-tool
expect_blocked new-tool
git rm --cached -q new-tool
printf '#!/bin/sh\n%s -c pass\n' "$interpreter" >new-call.sh
git add new-call.sh
expect_blocked new-call.sh
git rm --cached -q new-call.sh
printf '#!/bin/sh\n./helper.%s\n' "$suffix" >direct-helper.sh
git add direct-helper.sh
expect_blocked direct-helper.sh
git rm --cached -q direct-helper.sh
printf '/usr/bin/%s -c pass\n' "$interpreter" >'new executable'
chmod +x 'new executable'
git add 'new executable'
expect_blocked 'new executable'
git rm --cached -q 'new executable'
# A comment is not an invocation and must not require an entry.
printf '#!/bin/sh\n# %s is mentioned here\necho ok\n' "$interpreter" >comment.sh
git add comment.sh
bash tools/test-repo-language-guard.sh >/dev/null
# A removal is allowed before or after pruning its old baseline entry.
git rm --cached -q "$legacy"
bash tools/test-repo-language-guard.sh >/dev/null
printf '%s\n' legacy.sh >tools/legacy-py-allowlist.txt
bash tools/test-repo-language-guard.sh >/dev/null
echo 'language guard: additions fail and removals are allowed'
