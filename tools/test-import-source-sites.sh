#!/usr/bin/env bash
# Each `import github(...)` resolves to its own package (the regression of 949aa8b2): the discovery evaluates an import
# source as a `#` expression of no source file, and a `#` site's one-value-per-build key named only its file and place,
# so two import expressions of one length ("owner/pkg-aa", "owner/pkg-bb") shared a key and the second import took the
# first's package. NovaKind lost abla-qr (to abla-s3) and abla-saft (to abla-soap). Git fetches go to local repositories.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/import-source-sites.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
export ABLA_SYSROOT=$project_root ABLA_PACKAGE_CACHE=$test_root/cache
export ABLA_CACHE_DIR=$project_root/build/.abla-cache
export GIT_CONFIG_GLOBAL=$test_root/gitconfig

fail() { printf 'import source sites: %s\n' "$1" >&2; exit 1; }
package() { # name, function, value
    local dir=$test_root/$1
    mkdir -p "$dir/src"
    git -C "$dir" init --quiet --initial-branch=main
    printf 'name = "%s"\nversion = "0.1.0"\nentry = "src/entry.ab"\n' "$1" > "$dir/abla.toml"
    printf 'fun %s(): int = %s\n' "$2" "$3" > "$dir/src/entry.ab"
    git -C "$dir" add -A
    git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c
    git config --file "$GIT_CONFIG_GLOBAL" --add url."$dir".insteadOf "https://github.com/owner/$1.git"
}
package pkg-aa aaValue 40
package pkg-bb bbValue 2

app=$test_root/app
mkdir -p "$app/src"
printf 'name = "app"\nversion = "0.1.0"\nentry = "src/main.ab"\n' > "$app/abla.toml"
cat > "$app/src/main.ab" <<'AB'
import github("owner/pkg-aa")
import github("owner/pkg-bb")
fun main: int = aaValue() + bbValue()
AB
"$compiler" package update --project "$app" > "$test_root/update.log" 2>&1 || { cat "$test_root/update.log" >&2; fail 'update failed'; }
"$compiler" build --project "$app" -o "$app/out" > "$test_root/build.log" 2>&1 ||
    { cat "$test_root/build.log" >&2; fail 'the build failed (an import took another one'"'"'s package?)'; }
status=0
"$app/out" || status=$?
[[ $status -eq 42 ]] || fail "the program exited $status, not 42"
echo "import source sites: two import sources of one length resolve to their own packages"
