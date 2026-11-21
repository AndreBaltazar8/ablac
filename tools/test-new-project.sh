#!/usr/bin/env bash
set -euo pipefail
absolute() {
    printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
}
compiler=$(absolute "${1:-build/ablac}")
# A second compiler can verify the workflow’s pinned release against the generated sources.
builder=$(absolute "${2:-${1:-build/ablac}}")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"

"$compiler" new hello-app
"$compiler" new hello-lib --lib --github
[[ ! -e hello-app/.github ]]
for project in hello-app hello-lib; do
    grep -Fx "name = \"$project\"" "$project/abla.toml"
    test -s "$project/.gitignore"
    test -s "$project/README.md"
done
grep -Fx 'entry = "src/main.ab"' hello-app/abla.toml
grep -Fx 'entry = "src/lib.ab"' hello-lib/abla.toml
grep -F 'AndreBaltazar8/setup-abla@v1' hello-lib/.github/workflows/ci.yml
compiler_version=$("$compiler" --version)
grep -Fx "          version: '${compiler_version#ablac }'" hello-lib/.github/workflows/ci.yml
grep -Fx '      - run: ablac build --project . --emit object -o build/lib.o' hello-lib/.github/workflows/ci.yml
grep -Fx '      - run: ablac test tests/greeting.ab' hello-lib/.github/workflows/ci.yml

(
    cd hello-app
    "$builder" build --project .
    [[ $(build/hello-app) == 'Hello, Abla!' ]]
    [[ $("$builder" run --project .) == 'Hello, Abla!' ]]
    "$builder" test tests/greeting.ab
)
(
    cd hello-lib
    "$builder" build --project . --emit object -o build/lib.o
    test -s build/lib.o
    [[ $("$builder" run examples/hello.ab) == 'Hello, Abla!' ]]
    "$builder" test tests/greeting.ab
)

cp hello-app/abla.toml before
mkdir existing
ln -s absent symlink
for occupied in hello-app existing symlink; do
    if "$compiler" new "$occupied" > out 2> err; then exit 1; fi
    grep -F "'$occupied' already exists" err
done
cmp before hello-app/abla.toml
[[ -z $(ls -A existing) && -L symlink && ! -e absent ]]
if "$compiler" new './bad' > out 2> err; then exit 1; fi
grep -F 'E_NEW_PROJECT_NAME' err
if "$compiler" new bad-option --bogus > out 2> err; then exit 1; fi
grep -F 'usage: ablac new' err
[[ ! -e bad-option && ! -e bad ]]
shopt -s nullglob
stages=(.ablac-new-*)
[[ ${#stages[@]} -eq 0 ]]
