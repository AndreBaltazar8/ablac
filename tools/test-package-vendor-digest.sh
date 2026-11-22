#!/usr/bin/env bash
# A vendored dependency (vendor/<name>, from `ablac package vendor`) is trusted only if its files hash to the digest
# abla.lock records: its two marker files say which revision it claims to be, not that the files are that revision.
# Here a vendored copy is edited (a changed file, then an added file) with its markers and the lock untouched, and
# the build refuses it naming the package; the untouched copy still builds. The dependency is a local repository.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-vendor.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
git config --file "$GIT_CONFIG_GLOBAL" url."$test_root/dep".insteadOf https://github.com/owner/dep.git
fail() { printf 'package vendor digest: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

dep=$test_root/dep
mkdir -p "$dep"
git -C "$dep" init --quiet --initial-branch=main
printf 'name = "dep"\nversion = "0.1.0"\nentry = "dep.ab"\n' > "$dep/abla.toml"
echo 'fun depValue(): int = 7' > "$dep/dep.ab"
git -C "$dep" add -A && git -C "$dep" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c

app=$test_root/app
mkdir -p "$app"
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\nvisibility = "flat"\n' > "$app/abla.toml"
printf 'import github("owner/dep")\nfun main: int = depValue()\n' > "$app/main.ab"
export ABLA_PACKAGE_CACHE=$test_root/cache
"$compiler" package update --project "$app" > "$test_root/update.log" 2>&1 || fail 'update failed' "$test_root/update.log"
"$compiler" package vendor --project "$app" > "$test_root/vendor.log" 2>&1 || fail 'vendor failed' "$test_root/vendor.log"
[ -f "$app/vendor/dep/.abla-digest" ] || fail 'no vendored copy'

build() { (cd "$app" && rm -rf .abla && ABLA_PACKAGE_CACHE=$test_root/cache-$1 "$compiler" run main.ab > "$test_root/$1.log" 2>&1; echo $?); }
[ "$(build clean)" = 7 ] || fail 'the untouched vendored copy no longer builds' "$test_root/clean.log"

echo 'fun depValue(): int = 99' > "$app/vendor/dep/dep.ab"
changed_status=$(build changed)
[ "$changed_status" != 99 ] && [ "$changed_status" != 7 ] || fail 'a vendored file with another content was used' "$test_root/changed.log"
grep -q "E_PACKAGE_VENDOR_DIGEST_MISMATCH.*'dep'" "$test_root/changed.log" || fail 'no mismatch diagnostic naming the package for a changed file' "$test_root/changed.log"

git -C "$dep" show HEAD:dep.ab > "$app/vendor/dep/dep.ab"
echo 'fun extra(): int = 1' > "$app/vendor/dep/extra.ab"
[ "$(build added)" != 7 ] || fail 'a vendored copy with an added file was used' "$test_root/added.log"
grep -q "E_PACKAGE_VENDOR_DIGEST_MISMATCH.*'dep'" "$test_root/added.log" || fail 'no mismatch diagnostic for an added file' "$test_root/added.log"

rm "$app/vendor/dep/extra.ab"
[ "$(build restored)" = 7 ] || fail 'the restored vendored copy no longer builds' "$test_root/restored.log"

echo "package vendor digest: a vendored copy whose files differ from the locked digest is refused naming the package; the untouched and the restored copy build"
