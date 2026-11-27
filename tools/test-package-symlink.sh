#!/usr/bin/env bash
# An import inside a fetched dependency must not follow a symbolic link out of the dependency: `leak.ab -> /abs/file` or
# `-> ../../file` would read a file of the developer's machine as source. The fetch keeps the link (the checkout is the
# tree that was locked) but the build refuses to read through it, naming it; a link that stays inside the package
# (`alias.ab -> real.ab`) works. Links are judged by where they really lead: a chain of links that each stay inside by their text is refused too.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-symlink.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
git config --file "$GIT_CONFIG_GLOBAL" url."$test_root/dep".insteadOf https://github.com/owner/dep.git
fail() { printf 'package symlink: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

echo 'fun outside(): int = 1' > "$test_root/outside.ab"
dep=$test_root/dep
app=$test_root/app
mkdir -p "$app"
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$app/abla.toml"
printf 'import github("owner/dep")\nfun main: int = depValue()\n' > "$app/main.ab"

new_dep() { # name of the link's target, link written as given
    rm -rf "$dep" "$app/abla.lock" "$app/.abla"
    mkdir -p "$dep/sub"
    git -C "$dep" init --quiet --initial-branch=main
    printf 'name = "dep"\nversion = "0.1.0"\nentry = "dep.ab"\n' > "$dep/abla.toml"
    printf 'import "alias.ab"\nfun depValue(): int = real()\n' > "$dep/dep.ab"
    echo 'fun real(): int = 7' > "$dep/real.ab"
    : > "$dep/sub/keep"
    ln -s "$1" "$dep/$2"
}
commit() { git -C "$dep" add -A && git -C "$dep" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c; }
update() { ABLA_PACKAGE_CACHE=$test_root/cache-$1 "$compiler" package update --project "$app" > "$test_root/$1.log" 2>&1; }

run() { (cd "$app" && ABLA_PACKAGE_CACHE=$test_root/cache-$1 "$compiler" run main.ab > "$test_root/run-$1.log" 2>&1; echo $?); }
# The cache holds a checkout five levels below the test root, so these relative targets reach `outside.ab` there.
for case in "absolute|$test_root/outside.ab|alias.ab" "up|../../../../../outside.ab|alias.ab" "dot|sub/../../../../../../outside.ab|alias.ab"; do
    IFS='|' read -r name target link <<< "$case"
    new_dep "$target" "$link"
    commit
    update "out-$name" || fail "update failed ($name)" "$test_root/out-$name.log"
    [ "$(run "out-$name")" != 7 ] || fail "the import went through a symbolic link ($name: $link -> $target) out of the package"
    grep -q "alias.ab (a symbolic link out of its package)" "$test_root/run-out-$name.log" || fail "no diagnostic naming the link ($name)" "$test_root/run-out-$name.log"
done

# A chain of links that each stay inside the package by their own text but together climb out of it (a lexical check let it through):
# a/b -> .. (the package root), up1 -> a/b/.. (its parent), up(k+1) -> up(k)/.. up to the file system root, alias.ab -> up31/<the file>.
# The file outside defines real(), so reading it would build and run 99.
echo 'fun real(): int = 99' > "$test_root/outside-real.ab"
new_dep "up31$test_root/outside-real.ab" alias.ab
(cd "$dep" && mkdir a && ln -s .. a/b && ln -s a/b/.. up1 && for k in $(seq 1 30); do ln -s "up$k/.." "up$((k + 1))"; done)
commit
update out-chain || fail 'update failed (chain)' "$test_root/out-chain.log"
status=$(run out-chain)
[ "$status" != 99 ] || fail 'the import went through a chain of in-package links out of the package (it read the file outside)'
grep -q "alias.ab (a symbolic link out of its package)" "$test_root/run-out-chain.log" || fail "no diagnostic naming the link (chain)" "$test_root/run-out-chain.log"

new_dep real.ab alias.ab
commit
update inside || fail 'a link inside the package was refused' "$test_root/inside.log"
[ "$(run inside)" = 7 ] || fail 'the package with an inner link does not build' "$test_root/run-inside.log"

echo "package symlink: an import through a link leaving a fetched package, also by a chain of links, is refused naming it; a link inside the package works"
