#!/usr/bin/env bash
# A dependency may define trusted or extern code only when the root names it (decision #122 A, step 1; module.ab,
# bootstrapPlanCompilePackageGrants and bootstrapPackageTrustedDefinitions). The root project and the standard library
# define it freely. A dependency's `trusted` function, and any `extern:"c"` declaration (callable from ordinary code, so
# a way to raw memory and system calls without `trusted`), is E_PACKAGE_TRUSTED_DENIED unless the root's
# [dependencyCompileCapabilities] has `name = ["trusted.native"]` and abla.lock pins the package by digest. The line
# needs no trusted.native in the root's own compileCapabilities: that one governs compile-time native code only.
#   - root: the root defines a trusted function and an extern:"c" declaration itself: built (every case does);
#   - trusted, extern: a dependency's definition without the line is refused naming dependency, function, line and
#     the line to add; with the line it builds and runs;
#   - transitive: a leaf's definition needs the root's line for the leaf, the middle package's line is not enough;
#   - contract: the `#contract` twin of an out-of-tree module is the root's code (module.ab, bootstrapCompilePackageOwners), no line needed;
#   - mutation: the check is what refuses (no line, no refusal is a failure of the test, see the final case).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/package-trusted-grants"
rm -rf "$out"
mkdir -p "$out"
export ABLA_PACKAGE_CACHE="$out/cache"
fail() { echo "package-trusted-grants: $1" >&2; exit 1; }

repository() {
    local directory=$1 name=$2 source=$3
    mkdir -p "$directory/src"
    git -C "$directory" init --quiet --initial-branch=main
    git -C "$directory" config user.name 'Abla package test'
    git -C "$directory" config user.email 'abla-package-test@example.invalid'
    printf 'name = "%s"\nversion = "0.1.0"\nentry = "src/%s.ab"\n' "$name" "$name" > "$directory/abla.toml"
    printf '%s\n' "$source" > "$directory/src/$name.ab"
}
commit() { git -C "$1" add -A && git -C "$1" commit --quiet -m "$2"; }
provider() {
    printf 'compile fun %s(): ImportSource = gitImportSource("%s", "%s", "branch", "main")\n' "$2" "$3" "$4" > "$1"
}
# application <case> <dependency> <extra manifest lines>: a root with no compileCapabilities that defines trusted and
# extern code itself and prints what the dependency's `dependencyValue()` holds.
application() {
    local case=$1 dependency=$2 extra=${3:-}
    local project="$out/$case/application"
    mkdir -p "$project/src"
    printf 'name = "trusted-app"\nversion = "0.1.0"\nentry = "src/main.ab"\n%s\n' "$extra" > "$project/abla.toml"
    provider "$project/src/provider.ab" dependencySource "$dependency" "$out/$case/$dependency"
    cat > "$project/src/main.ab" <<'EOT'
import "abla/io"
import "provider.ab"
import dependencySource()
extern:"c" fun labs(value: int): int
trusted fun rootTrusted(value: int): int = value + 1
fun main { println("dependency value: '${dependencyValue()}' root: ${rootTrusted(labs(-2))}") }
EOT
}
build() {
    local project="$out/$1/application"
    status=0
    { "$compiler" package update --project "$project" &&
      "$compiler" build --project "$project" --fast --no-cache --offline &&
      "$project/build/trusted-app"; } > "$out/$1.log" 2>&1 || status=$?
}
refused() {
    local case=$1
    build "$case"
    [[ $status != 0 ]] && grep -q E_PACKAGE_TRUSTED_DENIED "$out/$case.log" ||
        fail "$case: not refused with E_PACKAGE_TRUSTED_DENIED (status $status): $(grep -m3 'error\|value' "$out/$case.log")"
}
granted() {
    local case=$1 expected=$2
    build "$case"
    [[ $status == 0 ]] || fail "$case: refused (status $status): $(grep -m3 'error' "$out/$case.log")"
    grep -q "dependency value: '$expected' root: 3" "$out/$case.log" ||
        fail "$case: not '$expected': $(grep -m2 'value' "$out/$case.log")"
}
named() { printf '[dependencyCompileCapabilities]\n'; for each in "$@"; do printf '%s = ["trusted.native"]\n' "$each"; done; }

trusted_source='private trusted fun hidden(value: int): int = value + 0
trusted fun doubled(value: int): int = hidden(value) * 2
fun dependencyValue(): string = "${doubled(21)}"'
extern_source='extern:"c" fun labs(value: int): int
fun dependencyValue(): string = "${labs(-42)}"'

for kind in trusted extern; do
    source=$trusted_source
    [[ $kind == trusted ]] || source=$extern_source
    repository "$out/$kind/dep" dep "$source"
    commit "$out/$kind/dep" dependency
    application "$kind" dep
    refused "$kind"
    grep -q "dependency 'dep'" "$out/$kind.log" || fail "$kind: the refusal doesn't name the dependency"
    grep -q "src/dep.ab:" "$out/$kind.log" || fail "$kind: the refusal doesn't give the file and line"
    ! grep -q "__abla_module_" "$out/$kind.log" || fail "$kind: the refusal shows a mangled name"
    grep -q 'dep = \["trusted.native"\]' "$out/$kind.log" || fail "$kind: the refusal doesn't give the line to add"
    # The same, named by the root (which holds no compileCapabilities).
    cp -r "$out/$kind" "$out/$kind-named"
    rm -rf "$out/$kind-named/application/.abla" "$out/$kind-named/application/abla.lock"
    application "$kind-named" dep "$(named dep)"
    granted "$kind-named" 42
done

# A dependency's dependency: the leaf defines trusted code; the middle package's line is not the leaf's.
repository "$out/transitive/leaf" leaf "$trusted_source"
sed -i 's/dependencyValue/leafValue/' "$out/transitive/leaf/src/leaf.ab"
commit "$out/transitive/leaf" leaf
repository "$out/transitive/middle" middle ''
provider "$out/transitive/middle/src/leaf-provider.ab" leafSource leaf "$out/transitive/leaf"
printf '%s\n' 'import "leaf-provider.ab"' 'import leafSource()' 'fun dependencyValue(): string = leafValue()' \
    > "$out/transitive/middle/src/middle.ab"
commit "$out/transitive/middle" middle
application transitive middle
refused transitive
grep -q "dependency 'leaf'" "$out/transitive.log" || fail "transitive: the refusal doesn't name the leaf"
cp -r "$out/transitive" "$out/transitive-middle"
rm -rf "$out/transitive-middle/application/.abla" "$out/transitive-middle/application/abla.lock"
application transitive-middle middle "$(named middle)"
refused transitive-middle
grep -q "dependency 'leaf'" "$out/transitive-middle.log" || fail "transitive-middle: the middle's line stood in for the leaf's"
cp -r "$out/transitive" "$out/transitive-both"
rm -rf "$out/transitive-both/application/.abla" "$out/transitive-both/application/abla.lock"
application transitive-both middle "$(named middle leaf)"
granted transitive-both 42

# The line's second effect keeps the root's ceiling: the dependency declares trusted.native and runs C at compile time,
# but the root's own compileCapabilities don't hold it. Its definition passes (the line), its compile-time site doesn't.
repository "$out/ceiling/dep" dep 'import "abla/compiler"
#compilerGrant("trusted.native")
noescape extern:"c" fun strlen(text: cstring): int
val measured = #strlen("four")
fun dependencyValue(): string = "${measured}"'
printf 'compileCapabilities = ["trusted.native"]\n' >> "$out/ceiling/dep/abla.toml"
commit "$out/ceiling/dep" dependency
application ceiling dep "$(named dep)"
build ceiling
[[ $status != 0 ]] || fail "ceiling: compile-time native code ran without the root's own trusted.native"
! grep -q E_PACKAGE_TRUSTED_DENIED "$out/ceiling.log" || fail "ceiling: the definition was refused despite the line"
! grep -q "dependency value: '4'" "$out/ceiling.log" || fail "ceiling: the dependency's C call ran at compile time"

# A contract twin (`import contract`, module path `<path>#contract`) is generated for a module outside the root's tree, with no import edge of its
# own: it is that module's code, so it is the root's too and needs no line (abla-one's remote tests built before #122 and must still).
mkdir -p "$out/contract/app" "$out/contract/backend"
printf 'name = "contract-app"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$out/contract/app/abla.toml"
printf 'fun increment(value: int): int = value + 1\n' > "$out/contract/backend/counter.ab"
printf 'import contract "../backend/counter.ab" as remote\n\nfun clientUnused: int = 0\n' > "$out/contract/app/client.ab"
printf 'import "abla/io"\nimport "../backend/counter.ab" as backend\nimport "client.ab"\n\nfun main: int {\n    println("local ${backend.increment(41)} ${clientUnused()}")\n    0\n}\n' > "$out/contract/app/main.ab"
status=0
{ (cd "$out/contract/app" && "$compiler" build main.ab -o "$out/contract/app.bin" --fast --no-cache --offline) && "$out/contract/app.bin"; } > "$out/contract.log" 2>&1 || status=$?
[[ $status == 0 ]] || fail "contract: the contract twin of a module outside the root was refused (status $status): $(grep -m2 'error' "$out/contract.log")"
grep -q "local 42 0" "$out/contract.log" || fail "contract: not 'local 42 0': $(head -2 "$out/contract.log")"
echo "package-trusted-grants: a dependency's trusted and extern definitions need the root's line; the root's own do not"
