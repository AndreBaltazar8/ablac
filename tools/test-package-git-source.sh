#!/usr/bin/env bash
# A dependency's git source and selector are data for git, never options or transports: a manifest (or an abla.lock)
# whose source or selector begins with `-`, names a `<transport>::` helper, or uses a revision expression is refused
# with a package diagnostic before any git call, and nothing it names runs. Each shape is tried through the manifest
# (`package update`) and, for sources, through a lock (`build`). A normal local repository still resolves.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-git-source.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
fail() { printf 'package git source: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
marker=$test_root/ran

app=$test_root/app
mkdir -p "$app"
printf 'fun main: int = 0\n' > "$app/main.ab"

# Manifest shapes: source and selector.
n=0
try_manifest() {
    n=$((n + 1))
    local source=$1 selector_key=$2 selector=$3
    rm -f "$marker" "$app/abla.lock"
    printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\nevil = { git = "%s", %s = "%s" }\n' \
        "$source" "$selector_key" "$selector" > "$app/abla.toml"
    if ABLA_PACKAGE_CACHE=$test_root/cache-$n "$compiler" package update --project "$app" > "$test_root/m$n.log" 2>&1; then
        fail "update accepted source '$source' with $selector_key '$selector'" "$test_root/m$n.log"
    fi
    [ ! -e "$marker" ] || fail "source '$source' with $selector_key '$selector' ran a command" "$test_root/m$n.log"
    grep -q 'E_PACKAGE' "$test_root/m$n.log" || fail "no package diagnostic for source '$source' with $selector_key '$selector'" "$test_root/m$n.log"
}
try_manifest "--upload-pack=touch $marker" tag v1
try_manifest "--upload-pack=touch $marker" branch main
try_manifest "--upload-pack=touch $marker" rev 0123456789abcdef0123456789abcdef01234567
try_manifest "-u" tag v1
try_manifest "ext::sh -c touch% $marker" tag v1
try_manifest "ext::sh -c touch% $marker" branch main
try_manifest "https://example.invalid/x.git" tag "--upload-pack=touch $marker"
try_manifest "https://example.invalid/x.git" tag "../other"
try_manifest "https://example.invalid/x.git" branch "-x"

# Lock shapes: a committed abla.lock is as untrusted as a manifest.
m=0
try_lock() {
    m=$((m + 1))
    local source=$1 revision=$2 selector=$3
    rm -f "$marker"
    printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\nevil = { git = "https://example.invalid/x.git", tag = "v1" }\n' > "$app/abla.toml"
    printf 'version = 2\n\n[[package]]\nname = "evil"\nprovider = "git"\nidentity = "git:https://example.invalid/x.git"\nsource = "%s"\nselector-kind = "tag"\nselector = "%s"\nrevision = "%s"\ndigest = "0123456789abcdef0123456789abcdef01234567"\nentry = "entry.ab"\n' \
        "$source" "$selector" "$revision" > "$app/abla.lock"
    printf 'import github("owner/evil")\nfun main: int = 0\n' > "$app/main.ab"
    if ABLA_PACKAGE_CACHE=$test_root/lcache-$m "$compiler" build "$app/main.ab" -o "$test_root/out$m" > "$test_root/l$m.log" 2>&1; then
        fail "a lock with source '$source' was accepted" "$test_root/l$m.log"
    fi
    [ ! -e "$marker" ] || fail "a lock with source '$source' ran a command" "$test_root/l$m.log"
}
good=0123456789abcdef0123456789abcdef01234567
try_lock "--upload-pack=touch $marker" "$good" v1
try_lock "ext::sh -c touch% $marker" "$good" v1
try_lock "https://example.invalid/x.git" "../../../../tmp/x" v1
try_lock "https://example.invalid/x.git" "$good" "-x"

# A normal local repository still resolves.
dep=$test_root/dep
mkdir -p "$dep"
git -C "$dep" init --quiet --initial-branch=main
printf 'name = "dep"\nversion = "0.1.0"\nentry = "dep.ab"\n' > "$dep/abla.toml"
echo 'fun depValue(): int = 1' > "$dep/dep.ab"
git -C "$dep" add -A && git -C "$dep" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", branch = "main" }\n' "$dep" > "$app/abla.toml"
rm -f "$app/abla.lock"
printf 'fun main: int = 0\n' > "$app/main.ab"
ABLA_PACKAGE_CACHE=$test_root/cache-ok "$compiler" package update --project "$app" > "$test_root/ok.log" 2>&1 ||
    fail 'a local repository dependency no longer resolves' "$test_root/ok.log"
grep -q '^name = "dep"' "$app/abla.lock" || fail 'the lock lacks the local dependency' "$app/abla.lock"

echo "package git source: options, transports and revision expressions in a source or selector are refused; a local repository still resolves"
