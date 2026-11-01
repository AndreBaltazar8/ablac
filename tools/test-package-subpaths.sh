#!/usr/bin/env bash
# `import github("owner/repository/path")`: a module inside a package. One locked
# revision and module identity across subpaths, nothing else of the package compiled,
# bad paths refused, vendoring. Git fetches go to a local repository.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-subpaths.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_PACKAGE_CACHE=$test_root/cache
export ABLA_CACHE_DIR=$project_root/build/.abla-cache

fail() { printf 'package subpaths: %s\n' "$1" >&2; exit 1; }
commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c; }

chain=$test_root/chain
leaf=$test_root/leaf
mkdir -p "$chain/src/evm" "$chain/src/bitcoin" "$chain/src/broken" "$leaf/src"
git -C "$chain" init --quiet --initial-branch=main
git -C "$leaf" init --quiet --initial-branch=main
cat > "$leaf/abla.toml" <<'T'
name = "leaf"
version = "0.1.0"
entry = "src/leaf.ab"
T
echo 'fun leafValue: int = 2' > "$leaf/src/leaf.ab"
commit "$leaf"
cat > "$chain/abla.toml" <<'T'
name = "chain"
version = "0.1.0"
entry = "src/chain.ab"
T
# The entry and `broken` don't parse: importing a subpath must not reach them.
echo 'this is not abla (' > "$chain/src/chain.ab"
echo 'this is not abla (' > "$chain/src/broken/entry.ab"
# What the two subpaths share: one copy, or a duplicate name and two counters.
cat > "$chain/src/shared.ab" <<'T'
var sharedCount: int = 0
fun sharedBump(): int {
    sharedCount = sharedCount + 1
    sharedCount
}
T
cat > "$chain/src/evm/entry.ab" <<'T'
import "../shared.ab"
fun evmValue(): int = sharedBump() * 10
T
cat > "$chain/src/bitcoin/script.ab" <<'T'
import "../shared.ab"
import github("owner/leaf")
fun scriptValue(): int = sharedBump() * 10 + leafValue()
T
ln -s /etc "$chain/src/outside"
commit "$chain"

# github() goes to these two.
export GIT_CONFIG_GLOBAL=$test_root/gitconfig
git config --file "$GIT_CONFIG_GLOBAL" url."$chain".insteadOf https://github.com/owner/chain.git
git config --file "$GIT_CONFIG_GLOBAL" --add url."$leaf".insteadOf https://github.com/owner/leaf.git

new_app() { # name, main.ab on stdin
    mkdir -p "$test_root/$1/src"
    printf 'name = "%s"\nversion = "0.1.0"\nentry = "src/main.ab"\n' "$1" > "$test_root/$1/abla.toml"
    cat > "$test_root/$1/src/main.ab"
}
expect_refused() { # name, code, then its import
    new_app "$1" <<AB
import $3
fun main: int = 0
AB
    local log=$test_root/$1.log
    if "$compiler" package update --project "$test_root/$1" > "$log" 2>&1 &&
        "$compiler" build --project "$test_root/$1" -o "$test_root/$1/out" >> "$log" 2>&1; then
        fail "$1 wasn't refused"
    fi
    grep -qF "$2" "$log" || { cat "$log" >&2; fail "$1 didn't report $2"; }
}

# Two subpaths, one revision, one module identity.
new_app app <<'AB'
import github("owner/chain/evm")
import github("owner/chain/bitcoin/script")
fun main: int = evmValue() + scriptValue()
AB
"$compiler" package update --project "$test_root/app" || fail 'update failed'
[[ $(grep -c '^name = "chain"\|"chain"' "$test_root/app/abla.lock") -eq 1 ]] ||
    { cat "$test_root/app/abla.lock" >&2; fail 'not one lock record for the package'; }
grep -q 'leaf' "$test_root/app/abla.lock" || fail "a subpath's own provider isn't locked"
"$compiler" build --project "$test_root/app" -o "$test_root/app/out" || fail 'build failed'
status=0
"$test_root/app/out" || status=$?
# 1 * 10 + 2 * 10 + 2: both bump one counter.
[[ $status -eq 32 ]] || fail "two subpaths don't share a module: exit $status"

# Only what is imported is compiled: `script` isn't in this one either.
new_app one <<'AB'
import github("owner/chain/evm")
fun main: int = evmValue()
AB
"$compiler" package update --project "$test_root/one" || fail 'update of one subpath failed'
grep -q leaf "$test_root/one/abla.lock" && fail "a subpath nobody imports was followed"
"$compiler" --emit-llvm "$test_root/one/src/main.ab" > "$test_root/one.ll" || fail 'emit failed'
grep -q 'evmValue' "$test_root/one.ll" || fail 'the subpath is not in the program'
grep -q 'scriptValue' "$test_root/one.ll" && fail 'another subpath was compiled'

# Vendored: no cache, no prepared copy, a single-file build.
"$compiler" package vendor --project "$test_root/app" || fail 'vendor failed'
[[ -f $test_root/app/vendor/chain/src/evm/entry.ab && -f $test_root/app/vendor/leaf/src/leaf.ab ]] ||
    fail 'vendor lacks a subpath or what it needs'
rm -rf "$test_root/app/.abla" "$ABLA_PACKAGE_CACHE"
"$compiler" build "$test_root/app/src/main.ab" -o "$test_root/app/vendored" --no-cache || fail 'vendored build failed'
status=0
"$test_root/app/vendored" || status=$?
[[ $status -eq 32 ]] || fail "vendored program exited $status"

# Refused.
expect_refused escape E_PACKAGE_SUBPATH_INVALID 'github("owner/chain/../../etc")'
expect_refused trailing E_PACKAGE_SUBPATH_INVALID 'github("owner/chain/")'
expect_refused missing E_PACKAGE_SUBPATH_MISSING 'github("owner/chain/nothing")'
expect_refused link E_PACKAGE_SUBPATH_INVALID 'github("owner/chain/outside/passwd")'
grep -q 'looked for src/nothing/entry.ab, src/nothing.ab' "$test_root/missing.log" ||
    fail 'a missing path does not say where it looked'

# [exports], and importSubpath on a source of any kind.
cat >> "$chain/abla.toml" <<'T'

[exports]
"public" = "src/evm/entry.ab"
T
commit "$chain"
new_app exported <<EOF
compile fun chainSource(): ImportSource = gitImportSource("chain", "$chain", "branch", "main")
compile fun publicChain(): ImportSource = importSubpath(chainSource(), "public")
import publicChain()
fun main: int = evmValue() + 1
EOF
"$compiler" package update --project "$test_root/exported" || fail 'exports update failed'
"$compiler" build --project "$test_root/exported" -o "$test_root/exported/out" || fail 'exports build failed'
status=0
"$test_root/exported/out" || status=$?
[[ $status -eq 11 ]] || fail "an exported subpath exited $status"
expect_refused private E_PACKAGE_SUBPATH_PRIVATE 'github("owner/chain/evm")'
grep -q 'public' "$test_root/private.log" || fail "a private path doesn't list what is public"

echo 'package subpaths: one lock record and module identity, the rest not compiled, bad paths refused'
