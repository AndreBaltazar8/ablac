#!/usr/bin/env bash
# A prepared copy (.abla/packages/<name>) is what an import of the package reads, so a build checks that its files are
# the locked tree, not only that its revision and digest marker files say so. Here the copy's source is changed after
# it was prepared (as a restored CI cache, a stray commit of .abla or another package's compile-time write could) and
# its markers are left alone: a single-file build, a project build of a vendored project and a single-file build of a
# vendored project all run the locked code, never the changed copy. Git fetches go to a local repository.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-prepared.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1 ABLA_PACKAGE_CACHE=$test_root/cache
fail() { printf 'package prepared copy: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
touch "$GIT_CONFIG_GLOBAL"

dep=$test_root/dep
mkdir -p "$dep/src"
git -C "$dep" init --quiet --initial-branch=main
printf 'name = "dep"\nversion = "0.1.0"\nentry = "src/dep.ab"\n' > "$dep/abla.toml"
echo 'fun depValue(): int = 1' > "$dep/src/dep.ab"
git -C "$dep" add -A && git -C "$dep" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c

app=$test_root/app
mkdir -p "$app"
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", branch = "main" }\n' "$dep" > "$app/abla.toml"
cat > "$app/main.ab" <<'T'
import "package/dep"
fun main: int = depValue() + 41
T
"$compiler" package update --project "$app" > "$test_root/update.log" 2>&1 || fail 'update failed' "$test_root/update.log"

tamper() { echo 'fun depValue(): int = 2' > "$app/.abla/packages/dep/source/src/dep.ab"; }
# $1 names the case; the rest are the build's arguments. The locked code exits 42, the changed copy 43.
check() {
    local name=$1
    shift
    (cd "$app" && "$compiler" build "$@" -o "$test_root/$name" --fast) > "$test_root/$name.log" 2>&1 ||
        fail "the $name build failed" "$test_root/$name.log"
    set +e; "$test_root/$name"; local status=$?; set -e
    [ "$status" = 42 ] || fail "the $name build read the changed prepared copy (exit $status, want 42)"
}

# The copy is compared with the lock's digest, never with its own markers: a digest marker rewritten to the changed
# files' tree does not make them the locked ones.
tamper_marker() {
    tamper
    local scratch=$test_root/scratch.git
    rm -rf "$scratch" && git init --quiet --bare "$scratch"
    git --git-dir="$scratch" --work-tree="$app/.abla/packages/dep/source" add --all --force -- . ':(exclude).abla-revision' ':(exclude).abla-digest'
    git --git-dir="$scratch" write-tree > "$app/.abla/packages/dep/digest"
}

# A copy that hashed to the digest is recorded by its files' status-change times, so later builds need not hash it (a copy younger
# than two seconds is not recorded). An edit of the same size with the modification time set back is still a change.
check fresh main.ab
sleep 3
check settled main.ab
ls "$ABLA_PACKAGE_CACHE"/verified/* > /dev/null 2>&1 || fail 'a settled prepared copy left no fingerprint record'
file=$app/.abla/packages/dep/source/src/dep.ab
old=$(stat -c %y "$file")
sleep 1
echo 'fun depValue(): int = 2' > "$file"
touch -d "$old" "$file"
[ "$(stat -c %y "$file")" = "$old" ] || fail 'touch -d did not restore the modification time'
# Older than the two seconds a fingerprint ignores: only the status-change time tells this copy from the recorded one.
sleep 3
check same-size-touched main.ab

tamper; check single main.ab
tamper; check project --project .
tamper_marker; check single-marker main.ab
tamper_marker; check project-marker --project .
"$compiler" package vendor --project "$app" > "$test_root/vendor.log" 2>&1 || fail 'vendor failed' "$test_root/vendor.log"
[ -f "$app/vendor/dep/.abla-revision" ] || fail 'vendor wrote no vendor/dep'
tamper; check vendored-project --project .
tamper; check vendored-single main.ab
# That build dropped the changed copy (the import read vendor/); a project build prepares it again from vendor/.
[ ! -e "$app/.abla/packages/dep" ] || fail 'the single-file build of a vendored project kept a changed prepared copy'
check vendored-prepare --project .
tamper_marker; check vendored-single-marker main.ab

# A changed vendored tree is refused by both build kinds, whatever the prepared copy holds.
echo 'fun depValue(): int = 3' > "$app/vendor/dep/src/dep.ab"
for kind in single project; do
    if [ $kind = single ]; then set -- main.ab; else set -- --project .; fi
    if (cd "$app" && "$compiler" build "$@" -o "$test_root/vendor-$kind" --fast) > "$test_root/vendor-$kind.log" 2>&1; then
        fail "the $kind build took a changed vendor/dep" "$test_root/vendor-$kind.log"
    fi
    grep -q E_PACKAGE_VENDOR_DIGEST_MISMATCH "$test_root/vendor-$kind.log" ||
        fail "the $kind build's refusal of a changed vendor/dep is not E_PACKAGE_VENDOR_DIGEST_MISMATCH" "$test_root/vendor-$kind.log"
done
echo "package prepared copy: a changed .abla/packages copy is not built (also with its digest marker rewritten), in single-file, project and vendored builds; a changed vendor/ is refused by both"
