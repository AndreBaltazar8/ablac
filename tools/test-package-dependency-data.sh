#!/usr/bin/env bash
# compilerReadDependencyFile (#1175): compile-time code reads a file of a locked dependency's tree by the dependency's
# manifest name and a package-relative path, under `filesystem.read`, and only the bytes the lock's digest covers.
#   - read: from the prepared copy and from vendor/ alike, in the interpreter and the native tier, with the build
#     cache on and off, from two working directories: the same bytes, and the build output has no tree path in it;
#   - site: the `#` site's own package decides. A project site calling a dependency's helper that reads a dependency
#     only that helper's package declares is refused; the helper's own site reads it;
#   - grant: without `filesystem.read` it is refused; undeclared names, invalid paths (absolute, `..`, backslash, empty,
#     `.git`), a missing file, a directory, a symbolic link (leaf or on the way) and a nested repository too;
#   - pin: a new commit of the dependency changes nothing until `package update`; a cached build with the old pin is
#     rebuilt after it; a vendored copy or a prepared copy that no longer matches the lock is repaired first, never read.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-dependency-data.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_CACHE_DIR=$test_root/abla-cache ABLA_PACKAGE_CACHE=$test_root/cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig GIT_CONFIG_NOSYSTEM=1
touch "$GIT_CONFIG_GLOBAL"
fail() { printf 'package dependency data: %s\n' "$1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit --quiet -m "$2"; }

data=$test_root/data
mkdir -p "$data/data" "$data/real" "$data/nested"
git -C "$data" init --quiet --initial-branch=main
printf 'name = "data"\nversion = "0.1.0"\nentry = "data.ab"\n' > "$data/abla.toml"
echo 'fun dataValue(): int = 1' > "$data/data.ab"
printf 'locked bytes one\n' > "$data/data/hello.txt"
printf 'in a subdirectory\n' > "$data/real/inner.txt"
ln -s hello.txt "$data/data/leaf-link.txt"
ln -s real "$data/dir-link"
printf 'secret\n' > "$test_root/outside.txt"
ln -s "$test_root/outside.txt" "$data/escape.txt"
commit "$data" one

# consumer: a dependency that declares `data` itself and reads it from its own `#` site and through a helper.
consumer=$test_root/consumer
mkdir -p "$consumer"
git -C "$consumer" init --quiet --initial-branch=main
printf 'name = "consumer"\nversion = "0.1.0"\nentry = "consumer.ab"\ncompileCapabilities = ["filesystem.read"]\n\n[dependencies]\ndata = { git = "%s", branch = "main" }\n' "$data" > "$consumer/abla.toml"
cat > "$consumer/consumer.ab" <<'AB'
import "abla/compiler"
#compilerGrant("filesystem.read")
val own = #compilerReadDependencyFile("data", "data/hello.txt")
fun consumerOwn(): string = own
compile fun readThrough(path: string): string = compilerReadDependencyFile("data", path)
AB
commit "$consumer" one

app=$test_root/app
manifest() { # extra manifest text after the dependencies
    printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\ncompileCapabilities = ["filesystem.read"]\n\n[dependencies]\ndata = { git = "%s", branch = "main" }\nconsumer = { git = "%s", branch = "main" }\n%s' \
        "$data" "$consumer" "${1:-}" > "$app/abla.toml"
}
mkdir -p "$app"
manifest
cat > "$app/main.ab" <<'AB'
import "abla/io"
import "abla/compiler"
#compilerGrant("filesystem.read")
val lockedBytes = #compilerReadDependencyFile("data", "data/hello.txt")
fun main { print(lockedBytes) }
AB
build() { # label [mode [cache flag]] -> status, output in $test_root/<label>.log, the program's output in <label>.out
    local label=$1 mode=${2:-interp} cache=${3:---no-cache} directory=${4:-$app}
    status=0
    rm -f "$app/build/app"
    ( cd "$directory" && ABLA_COMPILE_EVAL=$mode "$compiler" build --project "$app" --fast $([[ $cache == --cache ]] || echo "$cache") --offline ) > "$test_root/$label.log" 2>&1 || status=$?
    if [[ $status == 0 ]]; then "$app/build/app" > "$test_root/$label.out" 2>&1 || status=$?; fi
}
good() { # label expected [mode cache directory]
    build "$1" "${3:-interp}" "${4:---no-cache}" "${5:-$app}"
    [[ $status == 0 ]] || fail "$1: the build failed" "$test_root/$1.log"
    [[ "$(cat "$test_root/$1.out")" == "$2" ]] || fail "$1: expected '$2', got '$(cat "$test_root/$1.out")'"
}
refused() { # label code text
    build "$1" "${4:-interp}"
    [[ $status != 0 ]] || fail "$1: the build was not refused"
    grep -q "$2" "$test_root/$1.log" || fail "$1: no $2" "$test_root/$1.log"
    [[ -z ${3:-} ]] || grep -q "$3" "$test_root/$1.log" || fail "$1: the refusal does not say '$3'" "$test_root/$1.log"
    ! grep -rq 'secret' "$test_root/$1.log" || fail "$1: the outside file was read"
}

"$compiler" package update --project "$app" > "$test_root/update.log" 2>&1 || fail 'update failed' "$test_root/update.log"
grep -q '^name = "data"' "$app/abla.lock" || fail 'the lock does not pin data'

# read: the prepared copy, interpreter and native tier, cache off and on, two working directories.
good prepared-interp 'locked bytes one' interp --no-cache
good prepared-native 'locked bytes one' native --no-cache
good prepared-cache-1 'locked bytes one' interp --cache
good prepared-cache-2 'locked bytes one' interp --cache
good elsewhere 'locked bytes one' interp --no-cache "$test_root"
! grep -rq "$app/.abla/packages/data" "$app/build/app" || fail 'the build output names the prepared copy'

# vendor: the same bytes, and the same from either tree.
"$compiler" package vendor --project "$app" > "$test_root/vendor.log" 2>&1 || fail 'vendor failed' "$test_root/vendor.log"
[ -f "$app/vendor/data/.abla-digest" ] || fail 'no vendored copy'
rm -rf "$app/.abla"
good vendored-interp 'locked bytes one' interp --no-cache
good vendored-native 'locked bytes one' native --no-cache
good vendored-elsewhere 'locked bytes one' interp --no-cache "$test_root"
! grep -rq "$app/vendor/data" "$app/build/app" || fail 'the build output names the vendored copy'

# A vendored copy that claims the pin but differs is an error, never read.
printf 'tampered\n' > "$app/vendor/data/data/hello.txt"
refused vendor-tampered E_PACKAGE_VENDOR_DIGEST_MISMATCH
printf 'locked bytes one\n' > "$app/vendor/data/data/hello.txt"
good vendor-restored 'locked bytes one'
rm -rf "$app/vendor"
"$compiler" package update --project "$app" > "$test_root/update2.log" 2>&1 || fail 'update failed' "$test_root/update2.log"
good prepared-again 'locked bytes one'

# A prepared copy that no longer matches its lock is never read: the build prepares it again from the cache first.
printf 'tampered\n' > "$app/.abla/packages/data/source/data/hello.txt"
good prepared-tampered 'locked bytes one'

# site: the `#` site's own package. The project's site calls the consumer's helper, which reads `data`.
printf 'compile fun consumerSource(): ImportSource = gitImportSource("consumer", "%s", "branch", "main")\n' "$consumer" > "$app/consumer-provider.ab"
read_through() { # the project's main, reading `data/hello.txt` through consumer's helper
    cat > "$app/main.ab" <<AB
import "abla/io"
import "abla/compiler"
import "consumer-provider.ab"
import consumerSource()
#compilerGrant("filesystem.read")
val lockedBytes = #readThrough("$1")
fun main { print(lockedBytes) }
AB
}
# The project declares `data` itself, so its site may read it through the helper: the site's edges are what count.
read_through data/hello.txt
rm -rf "$app/.abla"
good helper-site-declares 'locked bytes one'

# Without its own direct edge, the project's site is refused although the consumer (whose helper runs) declares it.
manifest_no_data() {
    printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\ncompileCapabilities = ["filesystem.read"]\n\n[dependencies]\nconsumer = { git = "%s", branch = "main" }\n' "$consumer" > "$app/abla.toml"
}
manifest_no_data
"$compiler" package update --project "$app" > "$test_root/update3.log" 2>&1 || fail 'update (no direct data) failed' "$test_root/update3.log"
refused helper-site-undeclared E_PACKAGE_FILE_UNDECLARED "dependency 'data' file 'data/hello.txt'"
refused helper-site-undeclared-native E_PACKAGE_FILE_UNDECLARED "" native
# The consumer's own `#` site reads it (its manifest declares data): the project's main only prints consumerOwn().
cat > "$app/main.ab" <<'AB'
import "abla/io"
import "consumer-provider.ab"
import consumerSource()
fun main { print(consumerOwn()) }
AB
good consumer-own 'locked bytes one'
good consumer-own-native 'locked bytes one' native
manifest

# grant: without filesystem.read.
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndata = { git = "%s", branch = "main" }\n' "$data" > "$app/abla.toml"
cat > "$app/main.ab" <<'AB'
import "abla/io"
import "abla/compiler"
#compilerGrant("filesystem.read")
val lockedBytes = #compilerReadDependencyFile("data", "data/hello.txt")
fun main { print(lockedBytes) }
AB
"$compiler" package update --project "$app" > "$test_root/update4.log" 2>&1 || fail 'update failed' "$test_root/update4.log"
refused no-grant 'filesystem.read'
manifest
"$compiler" package update --project "$app" > "$test_root/update5.log" 2>&1 || fail 'update failed' "$test_root/update5.log"

# Invalid and unreadable paths, each naming the dependency and path.
try_path() { # label code path
    cat > "$app/main.ab" <<AB
import "abla/io"
import "abla/compiler"
#compilerGrant("filesystem.read")
val lockedBytes = #compilerReadDependencyFile("data", "$3")
fun main { print(lockedBytes) }
AB
    refused "$1" "$2" "file '$3'"
}
try_path absolute E_PACKAGE_FILE_INVALID /etc/passwd
try_path parent E_PACKAGE_FILE_INVALID ../outside.txt
try_path dotdot E_PACKAGE_FILE_INVALID data/../data/hello.txt
try_path dot E_PACKAGE_FILE_INVALID ./data/hello.txt
try_path backslash E_PACKAGE_FILE_INVALID 'data\\\\hello.txt'
try_path git-dir E_PACKAGE_FILE_INVALID .git/config
try_path empty-component E_PACKAGE_FILE_INVALID data//hello.txt
try_path drive E_PACKAGE_FILE_INVALID C:/x
try_path missing E_PACKAGE_FILE_INVALID data/nothing.txt
try_path directory E_PACKAGE_FILE_INVALID data
try_path leaf-link E_PACKAGE_FILE_INVALID data/leaf-link.txt
try_path dir-link E_PACKAGE_FILE_INVALID dir-link/inner.txt
try_path escape-link E_PACKAGE_FILE_INVALID escape.txt
# An undeclared dependency name.
cat > "$app/main.ab" <<'AB'
import "abla/io"
import "abla/compiler"
#compilerGrant("filesystem.read")
val lockedBytes = #compilerReadDependencyFile("nothere", "data/hello.txt")
fun main { print(lockedBytes) }
AB
refused undeclared E_PACKAGE_FILE_UNDECLARED "dependency 'nothere'"

# pin: a new commit changes nothing until `package update`; a cached build is rebuilt after it.
cat > "$app/main.ab" <<'AB'
import "abla/io"
import "abla/compiler"
#compilerGrant("filesystem.read")
val lockedBytes = #compilerReadDependencyFile("data", "data/hello.txt")
fun main { print(lockedBytes) }
AB
rm -rf "$app/.abla"
good pin-cached-old 'locked bytes one' interp --cache
printf 'locked bytes two\n' > "$data/data/hello.txt"
commit "$data" two
good pin-after-commit 'locked bytes one' interp --cache
"$compiler" package update --project "$app" > "$test_root/update6.log" 2>&1 || fail 'update failed' "$test_root/update6.log"
good pin-updated 'locked bytes two' interp --cache

echo "package dependency data: a locked dependency's file is read by the site's own manifest edge, from the prepared copy and vendor alike, only as the lock covers it"
