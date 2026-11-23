#!/usr/bin/env bash
# A git package whose tree holds two paths that differ only in case (`Foo.ab` and `foo.ab`) cannot be checked out as
# that tree on a file system that folds case (macOS's default): they collapse to one file. The fetch must fail closed with
# E_PACKAGE_DIGEST_MISMATCH, not lock the tree's digest and build with one of the files. The repository is made with git
# plumbing (a working tree cannot hold both on such a file system). On a case-sensitive file system (Linux) the two
# files check out as they are: this checks the setup (both files fetched, the package locks) and skips the collision
# check with a message; macOS's CI runs it for real (tools/test-macos-host.sh).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
test_root=$(mktemp -d "$project_root/build/package-case-fold.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_PACKAGE_CACHE=$test_root/cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
fail() { printf 'package case fold: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
git_dep() { git -C "$test_root/dep" -c user.name=t -c user.email=t@example.invalid "$@"; }

mkdir -p "$test_root/dep" "$test_root/app"
git -C "$test_root/dep" init --quiet --initial-branch=main
upper=$(printf 'fun fromUpper(): int = 1\n' | git_dep hash-object -w --stdin)
lower=$(printf 'fun fromLower(): int = 2\n' | git_dep hash-object -w --stdin)
manifest=$(printf 'name = "dep"\nversion = "0.1.0"\nentry = "Foo.ab"\n' | git_dep hash-object -w --stdin)
tree=$(printf '100644 blob %s\tFoo.ab\n100644 blob %s\tabla.toml\n100644 blob %s\tfoo.ab\n' "$upper" "$manifest" "$lower" | git_dep mktree)
commit=$(git_dep commit-tree "$tree" -m "two names that differ only in case")
git_dep update-ref refs/heads/main "$commit"
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", branch = "main" }\n' "$test_root/dep" > "$test_root/app/abla.toml"
printf 'fun main: int = 0\n' > "$test_root/app/main.ab"

touch "$test_root/probe-a"
if [ -e "$test_root/probe-A" ]; then folds=1; else folds=0; fi

status=0
"$compiler" package update --project "$test_root/app" > "$test_root/update.log" 2>&1 || status=$?
if [ "$folds" = 1 ]; then
    [ "$status" != 0 ] || fail 'the fetch accepted a tree whose two paths collapse on this file system' "$test_root/update.log"
    grep -q 'E_PACKAGE_DIGEST_MISMATCH' "$test_root/update.log" || fail 'no E_PACKAGE_DIGEST_MISMATCH' "$test_root/update.log"
    [ ! -f "$test_root/app/abla.lock" ] || fail 'a lock was written for the collapsed checkout'
    echo "package case fold: a tree with Foo.ab and foo.ab is refused on a case-folding file system (E_PACKAGE_DIGEST_MISMATCH)"
else
    [ "$status" = 0 ] || fail 'update failed on a case-sensitive file system' "$test_root/update.log"
    [ -f "$test_root/app/abla.lock" ] || fail 'no lock'
    source=$(find "$test_root/cache" -type d -name source -print -quit)
    [ -f "$source/Foo.ab" ] && [ -f "$source/foo.ab" ] || fail 'the fetched checkout lacks one of the two files'
    echo "package case fold: skipped the collision check (this file system is case-sensitive); setup checked: both files fetched and locked"
fi
