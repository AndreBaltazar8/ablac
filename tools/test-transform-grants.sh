#!/usr/bin/env bash
# A transform's replacement body keeps the grants of the transform (#1139 area 1, round 3). A function's compile-time code (`#` expressions, `$` subparser forms)
# runs with the grants of the file it stands in, so a dependency's transform that replaced a function of the root with a body holding `#compilerRunProcess(...)`
# ran a process with the root's own process.io although the dependency declared and was granted nothing. Now a body with compile-time code is refused
# (E_COMPILER_TRANSFORM_GRANTS) when the function's file has grants the transform's handler has not; a body without it, and a transform changing its own
# file's functions, are unaffected:
#   - inject: the dependency's transform puts `#compilerRunProcess` into the root's function: refused, nothing runs;
#   - plain: the same transform with an ordinary body: the root's function is replaced (the control);
#   - own: the root's own transform with the same body: allowed, the process runs (the grants are the same).
# A `$name` subparser handler of a dependency is likewise judged by the dependency's grants, not by the file that uses its syntax (handler-undeclared, handler-declared).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/transform-grants"
rm -rf "$out"
mkdir -p "$out"
export ABLA_PACKAGE_CACHE="$out/cache"
fail() { echo "transform grants: $1" >&2; exit 1; }
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

mark="$out/MARK"
marker_check() { [[ ! -e $mark ]] || fail "$1: the injected process ran"; }
injector() { # injector <body of the replacement, escaped for an Abla string inside a here-string>
    printf '%s\n' 'import "abla/compiler"' "${2:-}" 'compile fun configure(): void {' \
        '    val target = compiler.findFunction("target")' \
        "    compiler.replaceFunctionBody(target, \"$1\")" '    return' '}' '#compiler.transform(configure)' \
        'fun dependencyValue: string = "ok"'
}
main_with() { # main_with <case> <extra lines>: the root's main, which authorizes process.io for itself
    cat > "$out/$1/application/src/main.ab" <<EOT
import "abla/io"
import "abla/compiler"
import "provider.ab"
import dependencySource()
#compilerGrant("process.io")
$2
fun target(): int = 0
fun main { println("dependency value: '\${dependencyValue()}' \${target()}") }
EOT
}
process="{ val r = #compilerRunProcess([\\\"/bin/sh\\\", \\\"-c\\\", \\\"touch $mark\\\"]); r }"

# inject: a dependency that holds transform.program (named, pinned) but not process.io changes the root's function to one with a `#` site.
repository "$out/inject/quiet-dep" quiet-dep '"transform.program"' "$(injector "$process" '#compilerGrant("transform.program")')"
commit "$out/inject/quiet-dep" dependency
application inject '"process.io", "transform.program"' quiet-dep "$(printf '[dependencyCompileCapabilities]\nquiet-dep = ["transform.program"]')"
main_with inject ''
build inject
[[ $status != 0 ]] && grep -q E_COMPILER_TRANSFORM_GRANTS "$out/inject.log" ||
    fail "inject: not refused (status $status): $(grep -m3 'error\|value' "$out/inject.log")"
marker_check inject

# plain: the same transform with an ordinary body replaces the function.
repository "$out/plain/quiet-dep" quiet-dep '"transform.program"' "$(injector '41 + 1' '#compilerGrant("transform.program")')"
commit "$out/plain/quiet-dep" dependency
application plain '"process.io", "transform.program"' quiet-dep "$(printf '[dependencyCompileCapabilities]\nquiet-dep = ["transform.program"]')"
main_with plain ''
build plain
[[ $status == 0 ]] && grep -q "dependency value: 'ok' 42" "$out/plain.log" ||
    fail "plain: the dependency's ordinary body was not applied (status $status): $(grep -m3 'error\|value' "$out/plain.log")"

# own: the root's own transform, same grants: allowed.
repository "$out/own/quiet-dep" quiet-dep '' 'fun dependencyValue: string = "ok"'
commit "$out/own/quiet-dep" dependency
application own '"process.io"' quiet-dep
main_with own "compile fun configure(): void {
    compiler.replaceFunctionBody(compiler.findFunction(\"target\"), \"$process\")
    return
}
#compiler.transform(configure)"
build own
[[ $status == 0 ]] && [[ -e $mark ]] || fail "own: the root's own transform did not run its process (status $status): $(grep -m3 'error\|value' "$out/own.log")"

# A `$word` subparser's handler is the dependency's code: it runs with the dependency's grants, not those of the file that uses the syntax.
export ABLA_GRANT_PROBE=probe-value-7c1
handler='import "abla/compiler"
import "abla/compiler/parser"
compile fun wordParse(cursor: ParserCursor): SyntaxExpression {
    parserRawSkipWhitespace(cursor)
    val word = parserRawTakeUntil(cursor, ";")
    parserRawExpect(cursor, ";")
    syntaxString(compilerEnvironment("ABLA_GRANT_PROBE") + word)
}
#compilerRegisterSubparser("word", wordParse)
fun dependencyValue: string = "ok"'
use_word() {
    cat > "$out/$1/application/src/main.ab" <<'EOT'
import "abla/io"
import "abla/compiler"
import "provider.ab"
import dependencySource()
#compilerGrant("environment")
fun main { println("dependency value: '${dependencyValue()}' ${$word x;}") }
EOT
}
# handler-undeclared: the dependency declares nothing; the root authorizes environment for its own file: the handler is refused.
repository "$out/handler-undeclared/quiet-dep" quiet-dep '' "$handler"
commit "$out/handler-undeclared/quiet-dep" dependency
application handler-undeclared '"environment"' quiet-dep
use_word handler-undeclared
build handler-undeclared
[[ $status != 0 ]] && ! grep -q "$ABLA_GRANT_PROBE" "$out/handler-undeclared.log" ||
    fail "handler-undeclared: the dependency's subparser read the root's environment (status $status): $(grep -m3 'error\|value' "$out/handler-undeclared.log")"
# handler-declared: the dependency declares environment and the root authorizes it: the handler reads it.
repository "$out/handler-declared/quiet-dep" quiet-dep '"environment"' "$handler"$'\n#compilerGrant("environment")'
commit "$out/handler-declared/quiet-dep" dependency
application handler-declared '"environment"' quiet-dep
use_word handler-declared
build handler-declared
[[ $status == 0 ]] && grep -q "${ABLA_GRANT_PROBE}x" "$out/handler-declared.log" ||
    fail "handler-declared: the declared handler did not read it (status $status): $(grep -m3 'error\|value' "$out/handler-declared.log")"
echo "transform grants: a dependency's subparser handler runs with the dependency's grants"
