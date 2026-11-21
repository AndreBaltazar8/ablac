#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
compiler="$(cd -- "$(dirname -- "$compiler")" && pwd)/$(basename -- "$compiler")"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$work/gitconfig"
export ABLA_PACKAGE_CACHE="$work/cache"
git config --global uploadpack.allowFilter true

repo() {
    local name=$1
    mkdir -p "$work/$name"
    git -C "$work/$name" init -q --initial-branch=main
    git -C "$work/$name" config user.name fixture
    git -C "$work/$name" config user.email fixture@example.invalid
    git config --global "url.file://$work/$name.insteadOf" "https://github.com/owner/$name.git"
    printf 'name = "%s"\nentry = "lib.ab"\n' "$name" > "$work/$name/abla.toml"
}
commit() {
    local name=$1
    printf '%s\n' "$2" > "$work/$name/lib.ab"
    git -C "$work/$name" add abla.toml lib.ab
    git -C "$work/$name" commit -qm fixture
}
record() {
    awk -v package="$1" '
        /^\[\[package\]\]/ { match_record=0 }
        $0=="name = \"" package "\"" { match_record=1 }
        match_record && ($1=="revision" || $1=="selector") { print $3 }
    ' "$work/app/abla.lock"
}

mkdir -p "$work/no-manifest" "$work/app/src"
if "$compiler" package add owner/first --project "$work/no-manifest" > "$work/out" 2> "$work/err"; then exit 1; fi
grep -F 'missing package manifest' "$work/err"
[[ -z $(ls -A "$work/no-manifest") && ! -s "$work/out" ]]

repo first
commit first 'fun firstValue(): int = 40'
first_pin=$(git -C "$work/first" rev-parse HEAD)
repo second
commit second $'import github("owner/first")\nfun secondValue(): int = firstValue() / 20'
second_pin=$(git -C "$work/second" rev-parse HEAD)
git -C "$work/second" tag -am release v1.2.0
commit second 'fun secondValue(): int = 99'
git -C "$work/second" branch v1.2.0 # A branch of the same name must not win.

app="$work/app"
printf 'name = "app"\nentry = "src/main.ab"\n' > "$app/abla.toml"
printf 'import "deps.ab"\nfun main: int = 0\n' > "$app/src/main.ab"
printf '// Keep this source.\n' > "$app/src/deps.ab"
printf '// Outside the entry graph.\n' > "$app/src/unused.ab"
(cd "$app" && "$compiler" package add owner/first) > "$work/out"
grep -Fx 'Name: first' "$work/out"
grep -Fx 'import github("owner/first")' "$app/src/main.ab"
diff -u <(printf '"HEAD"\n"%s"\n' "$first_pin") <(record first)

# The old default branch has moved, and the new package depends on it.
# Adding the new Git package must reuse the lock's old first revision.
commit first 'fun firstValue(): int = 60'
cp "$app/abla.lock" "$work/lock.before"
cp "$app/src/deps.ab" "$work/deps.before"
if "$compiler" package add owner/second --project "$app" --tag absent --module src/deps.ab > "$work/out" 2> "$work/err"; then exit 1; fi
grep -F "could not fetch tag 'absent'" "$work/err"
cmp "$work/lock.before" "$app/abla.lock"
cmp "$work/deps.before" "$app/src/deps.ab"
if "$compiler" package add owner/second --project "$app" --tag v1.2.0 --module src/unused.ab > "$work/out" 2> "$work/err"; then exit 1; fi
grep -F 'is not imported by the project entry' "$work/err"
cmp "$work/lock.before" "$app/abla.lock"
grep -Fx '// Outside the entry graph.' "$app/src/unused.ab"

"$compiler" package add owner/second --project "$app" --tag v1.2.0 --module src/deps.ab > "$work/out"
grep -Fx "Metadata: tag v1.2.0 at $second_pin" "$work/out"
grep -Fx 'import gitImportSource("second", "https://github.com/owner/second.git", "tag", "v1.2.0")' "$app/src/deps.ab"
grep -Fx '// Keep this source.' "$app/src/deps.ab"
diff -u <(printf '"v1.2.0"\n"%s"\n' "$second_pin") <(record second)
diff -u <(printf '"HEAD"\n"%s"\n' "$first_pin") <(record first)
cp "$app/abla.lock" "$work/lock.after"
cp "$app/src/deps.ab" "$work/deps.after"
if "$compiler" package add owner/second --project "$app" --tag v1.2.0 --module src/deps.ab > "$work/out" 2> "$work/err"; then exit 1; fi
grep -F 'already a dependency' "$work/err"
cmp "$work/lock.after" "$app/abla.lock"
cmp "$work/deps.after" "$app/src/deps.ab"

# Use both imports from the generated project and build without network fallback.
printf 'fun answer(): int = secondValue()\n' >> "$app/src/deps.ab"
sed "s/^fun main.*/fun main: int = firstValue() + answer()/" "$app/src/main.ab" > "$work/main.ab"
mv "$work/main.ab" "$app/src/main.ab"
"$compiler" build --project "$app" --offline --fast
set +e
"$app/build/app"
status=$?
set -e
[[ $status == 42 ]]
cmp "$work/lock.after" "$app/abla.lock"
