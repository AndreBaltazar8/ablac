#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
compiler="$(cd -- "$(dirname -- "$compiler")" && pwd)/$(basename -- "$compiler")"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
repo="$work/source"
mkdir "$repo" "$work/caller" "$work/tmp"
git init --quiet --bare "$work/outer.git"
git -C "$repo" init --quiet --initial-branch=main
git -C "$repo" config user.name 'Abla package test'
git -C "$repo" config user.email 'abla-package-test@example.invalid'
cat > "$repo/abla.toml" <<'TOML'
name = "fixture"
description = "A \"quoted\" description" # a comment
license = 'MPL-2.0'
compiler = ">=0.2.60, <0.3.0"
version = "0.10.0"
[other]
description = "wrong section"
TOML
git -C "$repo" add abla.toml
git -C "$repo" commit --quiet -m fixture
git -C "$repo" tag v0.2.0
git -C "$repo" tag -am release v0.10.0

cd "$work/caller"
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global "url.file://$repo.insteadOf" https://github.com/fixture/metadata.git
git config --global "uploadpack.allowFilter" true
export TMPDIR="$work/tmp" ABLA_PACKAGE_CACHE="$work/cache"
printf 'existing lock\n' > abla.lock
GIT_DIR="$work/outer.git" "$compiler" package info fixture/metadata > "$work/info"
cat > "$work/expected" <<EOF_EXPECT
Name: fixture
Source: https://github.com/fixture/metadata.git
Metadata: default branch at $(git -C "$repo" rev-parse HEAD)
Description: A "quoted" description
Licence: MPL-2.0
Manifest version: 0.10.0
Declared compiler range: >=0.2.60, <0.3.0
Git tags:
  v0.10.0
  v0.2.0
EOF_EXPECT
diff -u "$work/expected" "$work/info"
diff -u <(printf 'existing lock\n') abla.lock
[[ ! -e .abla && ! -e $ABLA_PACKAGE_CACHE && -z $(ls -A "$TMPDIR") ]]
if "$compiler" package info fixture/../metadata > "$work/info" 2> "$work/error"; then exit 1; fi
grep -Fx 'usage: ablac package info <owner/repo>' "$work/error"

git -C "$repo" tag -d v0.2.0 v0.10.0 >/dev/null
printf 'name = "fixture"\n[unrelated]\ncompiler = "incorrect"\n' > "$repo/abla.toml"
git -C "$repo" commit -qam 'minimal metadata'
GIT_DIR="$work/outer.git" "$compiler" package info fixture/metadata > "$work/info"
grep -Fx 'Declared compiler range: (not declared)' "$work/info"
grep -Fx '  (none)' "$work/info"

git -C "$repo" rm -q abla.toml
git -C "$repo" commit -qm 'missing metadata'
if "$compiler" package info fixture/metadata > "$work/info" 2> "$work/error"; then exit 1; fi
grep -F 'has no readable abla.toml' "$work/error"
[[ ! -s $work/info && -z $(ls -A "$TMPDIR") ]]
