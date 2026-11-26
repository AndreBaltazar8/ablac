#!/usr/bin/env bash
# A transform of a dependency rewrites only functions of its own package (#1139 area 1, decision #145 A). `#compiler.transform` handlers change
# functions by name (`compiler.replaceFunctionBody`, `addFunctionAnnotation`, ...), and a dependency's handler could change the root's own functions,
# which the root's `#` sites then run with the root's grants. Now a change to a function of another package is E_COMPILER_TRANSFORM_PROGRAM, naming the
# `transform.program` grant, unless the root gives it: in the root's `compileCapabilities`, named for the dependency in `[dependencyCompileCapabilities]`
# (a pinned, named-only grant, like trusted.native) and requested by the transform's module. The root's own transforms, a transform's changes in its own
# package and the standard library (`transform.library`) are unchanged.
#   - refused: the dependency's transform replaces a body of the root's function: refused, the root's body stands;
#   - annotation: the same for `compiler.addFunctionAnnotation`;
#   - own: the dependency's transform replaces its own package's function: allowed (the control);
#   - granted: the root grants transform.program to the dependency (named, pinned, requested): the root's function is replaced;
#   - registered: the root names the dependency's handler in its own `#compiler.transform`: allowed (the root vouches for it);
#   - root: the root's own transform on its own function: allowed;
#   - generated-*: a module the dependency's transform generates (compilerGenerateModule) may not add an extension function, field or conformance to a type of
#     the root either, by the name of a class or of a named type (generated-function, generated-field, generated-named, generated-extend); its own package's type
#     (generated-own) and a granted one (generated-granted) are allowed.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/transform-program"
rm -rf "$out"
mkdir -p "$out"
export ABLA_PACKAGE_CACHE="$out/cache"
fail() { echo "transform program: $1" >&2; exit 1; }
# repository <directory> <name> <declared capabilities, a TOML array's inside> <source of src/<name>.ab>
repository() {
    local directory=$1 name=$2 declared=$3 source=$4
    mkdir -p "$directory/src"
    git -C "$directory" init --quiet --initial-branch=main
    git -C "$directory" config user.name 'Abla package test'
    git -C "$directory" config user.email 'abla-package-test@example.invalid'
    printf 'name = "%s"\nversion = "0.1.0"\nentry = "src/%s.ab"\n' "$name" "$name" > "$directory/abla.toml"
    [[ -z $declared ]] || printf 'compileCapabilities = [%s]\n' "$declared" >> "$directory/abla.toml"
    printf '%s\n' "$source" > "$directory/src/$name.ab"
}
commit() { git -C "$1" add -A && git -C "$1" commit --quiet -m "$2"; }
# provider <file> <function> <name> <repository>: a compile function naming the git dependency.
provider() {
    printf 'compile fun %s(): ImportSource = gitImportSource("%s", "%s", "branch", "main")\n' "$2" "$3" "$4" > "$1"
}
# application <case> <compileCapabilities inside> <dependency name> <extra manifest lines>: the root project, whose main
# prints what the dependency's `dependencyValue()` holds.
application() {
    local case=$1 capabilities=$2 dependency=$3 extra=${4:-}
    local project="$out/$case/application"
    mkdir -p "$project/src"
    printf 'name = "grants-app"\nversion = "0.1.0"\nentry = "src/main.ab"\ncompileCapabilities = [%s]\n%s\n' \
        "$capabilities" "$extra" > "$project/abla.toml"
    provider "$project/src/provider.ab" dependencySource "$dependency" "$out/$case/$dependency"
    cat > "$project/src/main.ab" <<'EOF'
import "abla/io"
import "provider.ab"
import dependencySource()
fun main { println("dependency value: '${dependencyValue()}'") }
EOF
}
# build <case>: package update, then the build, its status in $status and everything they printed in $out/<case>.log.
build() {
    local project="$out/$1/application"
    status=0
    { "$compiler" package update --project "$project" &&
      "$compiler" build --project "$project" --fast --no-cache --offline &&
      "$project/build/grants-app"; } > "$out/$1.log" 2>&1 || status=$?
}

transform() { # transform <body of configure>
    printf '%s\n' 'import "abla/compiler"' "${2:-}" 'compile fun configure(): void {' "$1" '    return' '}' '#compiler.transform(configure)' 'fun dependencyValue: string = "ok"'
}
root_main() { # root_main <case> <extra top-level lines>
    cat > "$out/$1/application/src/main.ab" <<EOT
import "abla/io"
import "abla/compiler"
import "provider.ab"
import dependencySource()
$2
fun target(): int = 0
fun main { println("dependency value: '\${dependencyValue()}' \${target()}") }
EOT
}
replace_root='    compiler.replaceFunctionBody(compiler.findFunction("target"), "41 + 1")'
announce='    compiler.addFunctionAnnotation(compiler.findFunction("target"), "marked")'

# refused: a dependency that declared and was granted nothing.
repository "$out/refused/quiet-dep" quiet-dep '' "$(transform "$replace_root")"
commit "$out/refused/quiet-dep" dependency
application refused '' quiet-dep
root_main refused ''
build refused
[[ $status != 0 ]] && grep -q 'E_COMPILER_TRANSFORM_PROGRAM' "$out/refused.log" && grep -q 'transform.program' "$out/refused.log" ||
    fail "refused: a dependency's transform changed the root's function, or the diagnostic does not name the grant (status $status): $(grep -m3 'error\|value' "$out/refused.log")"
! grep -q "' 42" "$out/refused.log" || fail "refused: the root's body was replaced"

# annotation: the same for an annotation.
repository "$out/annotation/quiet-dep" quiet-dep '' "$(transform "$announce")"
commit "$out/annotation/quiet-dep" dependency
application annotation '' quiet-dep
root_main annotation ''
build annotation
[[ $status != 0 ]] && grep -q 'E_COMPILER_TRANSFORM_PROGRAM' "$out/annotation.log" ||
    fail "annotation: a dependency's transform annotated the root's function (status $status): $(grep -m3 'error\|value' "$out/annotation.log")"

# own: a function of the dependency's own package.
own_source=$(printf '%s\n' 'import "abla/compiler"' 'fun ownValue(): int = 0' \
    'compile fun configure(): void {' '    compiler.replaceFunctionBody(compiler.findFunction("ownValue"), "41 + 1")' '    return' '}' \
    '#compiler.transform(configure)' 'fun dependencyValue: string = "own ${ownValue()}"')
repository "$out/own/quiet-dep" quiet-dep '' "$own_source"
commit "$out/own/quiet-dep" dependency
application own '' quiet-dep
root_main own ''
build own
[[ $status == 0 ]] && grep -q "dependency value: 'own 42'" "$out/own.log" ||
    fail "own: a dependency's change to its own function was refused or lost (status $status): $(grep -m3 'error\|value' "$out/own.log")"

# granted: the root gives transform.program to the dependency by name.
repository "$out/granted/quiet-dep" quiet-dep '"transform.program"' "$(transform "$replace_root" '#compilerGrant("transform.program")')"
commit "$out/granted/quiet-dep" dependency
application granted '"transform.program"' quiet-dep "$(printf '[dependencyCompileCapabilities]\nquiet-dep = ["transform.program"]')"
root_main granted ''
build granted
[[ $status == 0 ]] && grep -q "dependency value: 'ok' 42" "$out/granted.log" ||
    fail "granted: the named transform.program grant did not let the transform change the root's function (status $status): $(grep -m3 'error\|value' "$out/granted.log")"

# registered: the root names a dependency's handler in its own `#compiler.transform`: the root vouches for it (the abla-one and NovaKind pattern).
registered_source=$(printf '%s\n' 'import "abla/compiler"' \
    'compile fun libraryHandler(): void {' "$replace_root" '    return' '}' 'fun dependencyValue: string = "ok"')
repository "$out/registered/quiet-dep" quiet-dep '' "$registered_source"
commit "$out/registered/quiet-dep" dependency
application registered '' quiet-dep
root_main registered '#compiler.transform(libraryHandler)'
build registered
[[ $status == 0 ]] && grep -q "dependency value: 'ok' 42" "$out/registered.log" ||
    fail "registered: the root's own registration of a dependency's handler was refused (status $status): $(grep -m3 'error\|value' "$out/registered.log")"

# root: the root's own transform on its own function needs nothing.
repository "$out/root/quiet-dep" quiet-dep '' 'fun dependencyValue: string = "ok"'
commit "$out/root/quiet-dep" dependency
application root '' quiet-dep
root_main root "compile fun configure(): void {
$replace_root
    return
}
#compiler.transform(configure)"
build root
[[ $status == 0 ]] && grep -q "dependency value: 'ok' 42" "$out/root.log" ||
    fail "root: the root's own transform was refused (status $status): $(grep -m3 'error\|value' "$out/root.log")"
# A generated module is source the program's modules see as written, so what a transform may not do by compiler.addConformance and compiler.addExtensionField
# it may not do by compilerGenerateModule either: an extension of another package's type is judged on the parsed declarations.
generate() { # generate <module source of the generated code> <dependency's own top-level lines>
    printf '%s\n' 'import "abla/compiler"' "${2:-}" 'compile fun configure(): void {' "    compilerGenerateModule(\"gen\", \"$1\")" '    return' '}' '#compiler.transform(configure)' 'fun dependencyValue: string = "ok"'
}
generated_root() { # generated_root <case> <the use in main's output>
    cat > "$out/$1/application/src/main.ab" <<EOT
import "abla/io"
import "provider.ab"
import dependencySource()
interface Tagged {}
class Item(val n: int)
type Meters = int
fun main { println("dependency value: '\${dependencyValue()}' $2") }
EOT
}
generated_case() { # generated_case <case> <generated source> <use> <wanted output or ""> <capabilities> <dependency lines>
    repository "$out/$1/quiet-dep" quiet-dep "${5:+\"transform.program\"}" "$(generate "$2" "${6:-}")"
    [[ -z ${5:-} ]] || printf '%s\n' '#compilerGrant("transform.program")' >> "$out/$1/quiet-dep/src/quiet-dep.ab"
    commit "$out/$1/quiet-dep" dependency
    application "$1" "${5:+\"transform.program\"}" quiet-dep "${5:+$(printf '[dependencyCompileCapabilities]\nquiet-dep = ["transform.program"]')}"
    generated_root "$1" "$3"
    build "$1"
}
refused_generated() { # refused_generated <case> <generated source> <use>
    generated_case "$1" "$2" "$3" ""
    [[ $status != 0 ]] && grep -q 'E_COMPILER_TRANSFORM_PROGRAM' "$out/$1.log" ||
        fail "$1: a dependency's generated module extended the root's type (status $status): $(grep -m3 'error\|value' "$out/$1.log")"
}
refused_generated generated-function 'fun Item.hello(): int = 77\n' '${Item(1).hello()}'
refused_generated generated-field 'var Item.extra: int = 5\n' '${Item(1).extra}'
refused_generated generated-named 'fun Meters.twice(): int = 2\n' '${Meters(1).twice()}'
refused_generated generated-extend 'extend Item : Tagged\n' '${Item(1).n}'
# generated-own: an extension of the dependency's own class, in the generated module: allowed (the control).
generated_case generated-own 'fun Mine.hello(): int = 77\n' '' "" "" 'class Mine(val n: int)'
[[ $status == 0 ]] && grep -q "dependency value: 'ok'" "$out/generated-own.log" ||
    fail "generated-own: an extension of the dependency's own class was refused (status $status): $(grep -m3 'error\|value' "$out/generated-own.log")"
# generated-granted: the root names transform.program for the dependency: the extension of the root's class is allowed.
generated_case generated-granted 'fun Item.hello(): int = 77\n' '${Item(1).hello()}' '' grant
[[ $status == 0 ]] && grep -q "dependency value: 'ok' 77" "$out/generated-granted.log" ||
    fail "generated-granted: the named transform.program grant did not let the generated extension through (status $status): $(grep -m3 'error\|value' "$out/generated-granted.log")"
echo "transform program: a dependency's transform, and the modules it generates, change only its own package's types and functions unless the root grants transform.program by name; the root's own transforms are unchanged"

