#!/usr/bin/env bash
# Decision #85: builds use the committed abla.lock. A single-file build (and run, and test) installs the project's
# locked packages itself, at the locked revision, never the selector's head: here the dependency's HEAD moves after
# the lock is written, the package cache is empty and .abla is gone, and the build still gets the locked one, with
# abla.lock untouched. `ablac package install` does the same explicitly; `--offline` with an empty cache refuses.
# Git fetches go to a local repository.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-install.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
fail() { printf 'package install: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c; }

dep=$test_root/dep
mkdir -p "$dep/src"
git -C "$dep" init --quiet --initial-branch=main
printf 'name = "dep"\nversion = "0.1.0"\nentry = "src/dep.ab"\n' > "$dep/abla.toml"
echo 'fun depValue(): int = 1' > "$dep/src/dep.ab"
commit "$dep"
locked=$(git -C "$dep" rev-parse HEAD)
touch "$GIT_CONFIG_GLOBAL"
git config --file "$GIT_CONFIG_GLOBAL" url."$dep".insteadOf https://github.com/owner/dep.git

app=$test_root/app
mkdir -p "$app"
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$app/abla.toml"
cat > "$app/main.ab" <<'T'
import github("owner/dep")
fun main: int = depValue() + 41
T
ABLA_PACKAGE_CACHE=$test_root/cache-update "$compiler" package update --project "$app" > "$test_root/update.log" 2>&1 ||
    fail 'update failed' "$test_root/update.log"
grep -q "revision = \"$locked\"" "$app/abla.lock" || fail 'the lock does not name the first revision' "$app/abla.lock"
cp "$app/abla.lock" "$test_root/lock.before"

# The dependency moves on: its head now gives 2, the lock still says 1.
echo 'fun depValue(): int = 2' > "$dep/src/dep.ab"
commit "$dep"

# A fresh checkout: no .abla, an empty cache. A single-file build installs the locked revision.
rm -rf "$app/.abla"
(cd "$app" && ABLA_PACKAGE_CACHE=$test_root/cache-1 "$compiler" build main.ab -o "$test_root/program" --fast) \
    > "$test_root/build.log" 2>&1 || fail 'the single-file build failed' "$test_root/build.log"
set +e; "$test_root/program"; status=$?; set -e
[ "$status" = 42 ] || fail "the build used another revision than the locked one (exit $status, want 42)"
[ "$(cat "$app/.abla/packages/dep/revision")" = "$locked" ] || fail '.abla holds another revision'
cmp -s "$app/abla.lock" "$test_root/lock.before" || fail 'the build changed abla.lock'

# The explicit form.
rm -rf "$app/.abla"
ABLA_PACKAGE_CACHE=$test_root/cache-2 "$compiler" package install --project "$app" > "$test_root/install.log" 2>&1 ||
    fail 'package install failed' "$test_root/install.log"
[ "$(cat "$app/.abla/packages/dep/revision")" = "$locked" ] || fail 'package install installed another revision'
cmp -s "$app/abla.lock" "$test_root/lock.before" || fail 'package install changed abla.lock'

# Offline with nothing cached: refused, by name.
rm -rf "$app/.abla"
if ABLA_PACKAGE_CACHE=$test_root/cache-3 "$compiler" package install --project "$app" --offline > "$test_root/offline.log" 2>&1; then
    fail 'an offline install with an empty cache succeeded' "$test_root/offline.log"
fi
grep -q 'E_PACKAGE_OFFLINE_MISS' "$test_root/offline.log" || fail 'the offline refusal is not E_PACKAGE_OFFLINE_MISS' "$test_root/offline.log"
echo "package install: a single-file build and package install take the locked revision with the head moved on, leave abla.lock alone, and offline refuses an empty cache"
