#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
compiler="$(cd -- "$(dirname -- "$compiler")" && pwd)/$(basename -- "$compiler")"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/app" "$work/tmp"
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$work/gitconfig"
export TMPDIR="$work/tmp" ABLA_PACKAGE_CACHE="$work/cache"
git config --global uploadpack.allowFilter true

init() {
    git init -q --initial-branch=main "$1"
    git -C "$1" config user.name fixture
    git -C "$1" config user.email fixture@example.invalid
}
commit() {
    printf 'name = "fixture"\n%s\n' "$2" > "$1/abla.toml"
    git -C "$1" add abla.toml
    git -C "$1" commit -qm fixture
}
record() {
    local name=$1 repo=$2 revision=$3
    cat <<LOCK
[[package]]
name = "$name"
provider = "git"
identity = "fixture:$name"
source = "../$(basename "$repo")"
selector-kind = "head"
selector = "HEAD"
revision = "$revision"
digest = "$(git -C "$repo" rev-parse "$revision^{tree}")"
entry = "main.ab"
LOCK
}

dep="$work/dep"
plain="$work/plain"
init "$dep"
init "$plain"
commit "$dep" 'compiler = ">=0.2.50"'
git -C "$dep" tag v0.9.0
git -C "$dep" branch maintenance
commit "$dep" 'compiler = ">=0.2.60"'
locked=$(git -C "$dep" rev-parse HEAD)
git -C "$dep" tag -am locked v1.0.0
commit "$dep" 'compiler = ">=0.2.61"'
git -C "$dep" tag v1.2.0
commit "$dep" 'compiler = ">=0.2.63, <0.3.0"'
git -C "$dep" tag -am latest v1.10.0
commit "$dep" 'compiler = "HEAD must not be used"'
git -C "$dep" tag v0.8.0
git -C "$dep" switch -q maintenance
commit "$dep" 'compiler = "unrelated tag must not be used"'
git -C "$dep" tag v9.0.0
git -C "$dep" switch -q main

commit "$plain" 'version = "0.1.0"'
plain_locked=$(git -C "$plain" rev-parse HEAD)
commit "$plain" 'version = "0.2.0"'
git -C "$plain" tag v0.2.0
git -C "$plain" rev-parse HEAD > "$work/plain-latest"
commit "$plain" 'version = "0.3.0"' # untagged HEAD

app="$work/app"
{
    printf 'version = 2\n'
    record dep "$dep" "$locked"
    record plain "$plain" "$plain_locked"
} > "$app/abla.lock"
cp "$app/abla.lock" "$work/before"
"$compiler" package outdated --project "$app" > "$work/actual" 2> "$work/errors"
cat > "$work/expected" <<EXPECTED
dep: v1.0.0 -> v1.10.0
  v1.10.0  compiler: >=0.2.63, <0.3.0
  v1.2.0  compiler: >=0.2.61
plain: $plain_locked -> v0.2.0
  v0.2.0  compiler: (not declared)
EXPECTED
diff -u "$work/expected" "$work/actual"
[[ ! -s "$work/errors" ]]
cmp "$work/before" "$app/abla.lock"
[[ ! -e "$app/.abla" && ! -e "$ABLA_PACKAGE_CACHE" && -z $(ls -A "$TMPDIR") ]]

{
    printf 'version = 2\n'
    record plain "$plain" "$(cat "$work/plain-latest")"
} > "$app/abla.lock"
(cd "$app" && "$compiler" package outdated) > "$work/actual"
grep -Fx 'No newer Git tags found.' "$work/actual"

if "$compiler" package outdated --project "$work" > "$work/actual" 2> "$work/errors"; then exit 1; fi
grep -F 'E_PACKAGE_LOCK_MISSING' "$work/errors"
