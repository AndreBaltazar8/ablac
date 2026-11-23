#!/usr/bin/env bash
# A dependency vendored with `ablac package vendor` is imported like the same dependency before vendoring: with strict
# imports (the default) `import github("owner/dep")` makes the dependency's names visible, from the cache or prepared copy
# and from vendor/dep alike. The dependency is a local repository standing in for the GitHub one.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-vendor-strict.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
git config --file "$GIT_CONFIG_GLOBAL" url."$test_root/dep".insteadOf https://github.com/owner/dep.git
fail() { printf 'package vendor strict: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

dep=$test_root/dep
mkdir -p "$dep"
git -C "$dep" init --quiet --initial-branch=main
printf 'name = "dep"\nversion = "0.1.0"\nentry = "dep.ab"\n' > "$dep/abla.toml"
echo 'fun depValue(): int = 7' > "$dep/dep.ab"
git -C "$dep" add -A && git -C "$dep" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c

app=$test_root/app
mkdir -p "$app"
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$app/abla.toml"
printf 'import github("owner/dep")\nfun main: int = depValue()\n' > "$app/main.ab"
export ABLA_PACKAGE_CACHE=$test_root/cache
"$compiler" package update --project "$app" > "$test_root/update.log" 2>&1 || fail 'update failed' "$test_root/update.log"

run() { (cd "$app" && rm -rf .abla && ABLA_PACKAGE_CACHE=$test_root/cache-$1 "$compiler" run main.ab > "$test_root/$1.log" 2>&1; echo $?); }
[ "$(run fetched)" = 7 ] || fail 'the fetched dependency does not build strictly' "$test_root/fetched.log"
"$compiler" package vendor --project "$app" > "$test_root/vendor.log" 2>&1 || fail 'vendor failed' "$test_root/vendor.log"
[ -f "$app/vendor/dep/.abla-digest" ] || fail 'no vendored copy'
[ "$(run vendored)" = 7 ] || fail 'the vendored dependency does not build strictly' "$test_root/vendored.log"

echo "package vendor strict: a vendored dependency's names are visible through its import, as before vendoring"
