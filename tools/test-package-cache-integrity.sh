#!/usr/bin/env bash
# The package cache is shared by every project and build of a user, and by parallel CI jobs when ABLA_PACKAGE_CACHE says so (#1139 area 2, round 2, item 4):
#   1. many builds filling one empty cache at once all succeed and leave one valid entry (the publish used to remove an existing entry first, so a build that
#      lost the race failed, or read an entry another build was removing);
#   2. an entry whose file was changed is not used, even when its own index says the file is unchanged (assume-unchanged);
#   3. nothing in an entry's .git/config is run by validating it (core.fsmonitor is a command);
#   4. an entry made under umask 000 is not writable by group or others.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
t=$(mktemp -d "$project_root/build/package-cache-integrity.XXXXXX")
trap 'rm -rf -- "$t"' EXIT
export ABLA_SYSROOT=$project_root GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$t/gitconfig
: > "$GIT_CONFIG_GLOBAL"
failures=0
fail() { printf 'package cache integrity: %s\n' "$1" >&2; [ -n "${2:-}" ] && sed 's/^/    /' "$2" >&2; failures=$((failures + 1)); }
repo=$t/dep
git init -q --initial-branch=main "$repo"
printf 'name = "dep"\nversion = "0.1.0"\nentry = "lib.ab"\n' > "$repo/abla.toml"
printf 'fun depAnswer(): int = 42\n' > "$repo/lib.ab"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m dep
revision=$(git -C "$repo" rev-parse HEAD)
newapp() { # newapp NAME: an application locked to the dependency
    mkdir -p "$t/$1"
    printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", rev = "%s" }\n' "$repo" "$revision" > "$t/$1/abla.toml"
    printf 'fun main: int = 0\n' > "$t/$1/main.ab"
}
newapp seed
ABLA_PACKAGE_CACHE=$t/seedcache "$compiler" package update --project "$t/seed" > "$t/seed.log" 2>&1 || { fail "the seed lock failed" "$t/seed.log"; exit 1; }
install() { ABLA_PACKAGE_CACHE=$1 "$compiler" package install --project "$2" > "$3" 2>&1; }

# 1. Parallel installs into one empty cache.
for round in 1 2 3 4; do
    cache=$t/shared$round
    pids=()
    for k in 1 2 3 4 5 6 7 8; do
        mkdir -p "$t/p$round-$k"; cp "$t/seed/abla.toml" "$t/seed/main.ab" "$t/seed/abla.lock" "$t/p$round-$k/"
        install "$cache" "$t/p$round-$k" "$t/p$round-$k.log" & pids+=($!)
    done
    bad=0
    for pid in "${pids[@]}"; do wait "$pid" || bad=$((bad + 1)); done
    [ "$bad" = 0 ] || { fail "round $round: $bad of 8 parallel installs failed"; for k in 1 2 3 4 5 6 7 8; do [ -s "$t/p$round-$k.log" ] && { sed -n '1,3s/^/    /p' "$t/p$round-$k.log"; break; }; done; }
    leftovers=$(find "$cache" -name '*.tmp.*' | wc -l)
    ((leftovers == 0)) || fail "round $round: $leftovers temporary entries left in the cache"
    entries=$(find "$cache/git" -mindepth 2 -maxdepth 2 -type d | wc -l)
    ((entries == 1)) || fail "round $round: $entries cache entries for one revision"
    mkdir -p "$t/o$round"; cp "$t/seed/abla.toml" "$t/seed/main.ab" "$t/seed/abla.lock" "$t/o$round/"
    ABLA_PACKAGE_CACHE=$cache "$compiler" package install --offline --project "$t/o$round" > "$t/o$round.log" 2>&1 || fail "round $round: the entry left is not valid offline" "$t/o$round.log"
done

# 2. A changed file in an entry whose own index says it is unchanged (git update-index --assume-unchanged: no stat, no content is looked at).
cache=$t/tamper
mkdir -p "$t/a2"; cp "$t/seed/abla.toml" "$t/seed/main.ab" "$t/seed/abla.lock" "$t/a2/"
install "$cache" "$t/a2" "$t/a2.log" || fail "the first install failed" "$t/a2.log"
entry=$(find "$cache/git" -mindepth 2 -maxdepth 2 -type d -print -quit)
git -C "$entry/source" update-index --assume-unchanged lib.ab
printf 'fun depAnswer(): int = 43\n' > "$entry/source/lib.ab"
rm -rf "$t/a2/.abla"
install "$cache" "$t/a2" "$t/a2b.log" || true
if grep -q '= 43' "$t/a2/.abla/packages/dep/source/lib.ab" 2>/dev/null; then fail "a changed file of the cache entry was used (its index said unchanged)"; fi
grep -q '= 42' "$entry/source/lib.ab" 2>/dev/null || [ "$(grep -c '= 42' "$t/a2/.abla/packages/dep/source/lib.ab" 2>/dev/null || echo 0)" = 1 ] || fail "the changed entry was neither repaired nor refused" "$t/a2b.log"

# 3. core.fsmonitor in an entry's config is a command.
cache=$t/fsmonitor
mkdir -p "$t/a3"; cp "$t/seed/abla.toml" "$t/seed/main.ab" "$t/seed/abla.lock" "$t/a3/"
install "$cache" "$t/a3" "$t/a3.log" || fail "the first install failed" "$t/a3.log"
entry=$(find "$cache/git" -mindepth 2 -maxdepth 2 -type d -print -quit)
printf '#!/bin/sh\ntouch %s\n' "$t/ran-fsmonitor" > "$t/hook.sh"; chmod +x "$t/hook.sh"
printf '[core]\n\tfsmonitor = %s\n' "$t/hook.sh" >> "$entry/source/.git/config"
rm -rf "$t/a3/.abla"
install "$cache" "$t/a3" "$t/a3b.log" || true
[ ! -e "$t/ran-fsmonitor" ] || fail "validating a cache entry ran the command in its .git/config (core.fsmonitor)"

# 4. Publish a fresh cache entry under umask 000. Use the system BSD chmod
# on macOS and reject its incompatible argument order on GNU hosts too.
cache=$t/umask
mkdir -p "$t/a4"; cp "$t/seed/abla.toml" "$t/seed/main.ab" "$t/seed/abla.lock" "$t/a4/"
chmod_tool=$(command -v chmod)
if [[ $(uname -s) == Darwin ]]; then chmod_tool=/bin/chmod; fi
mkdir -p "$t/bin"
cat > "$t/bin/chmod" <<'EOF'
#!/usr/bin/env bash
if [[ ${1-} == -R && ${2-} == go-w && ${3-} == -- ]]; then
    echo "BSD chmod treats -- after the mode as a filename" >&2
    exit 1
fi
exec "$PACKAGE_TEST_CHMOD" "$@"
EOF
chmod +x "$t/bin/chmod"
( umask 000; PATH="$t/bin:$PATH" PACKAGE_TEST_CHMOD="$chmod_tool" install "$cache" "$t/a4" "$t/a4.log" ) ||
    fail "the install under umask 000 failed" "$t/a4.log"
writable=$(find "$cache" ! -type l \( -perm -020 -o -perm -002 \) -print -quit)
[ -z "$writable" ] || fail "the cache entry is writable by group or others under umask 000 ($writable)"

[ "$failures" = 0 ] || { printf 'package cache integrity: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "package cache integrity: parallel installs share one valid entry, a changed or reconfigured entry is not trusted, and entries are not writable by others"
