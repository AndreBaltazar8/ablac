#!/usr/bin/env bash
# A transform's replacement body keeps the grants of the transform (#1139 area 1, round 3). A function's compile-time code (`#` expressions, `$` subparser forms)
# runs with the grants of the file it stands in, so a dependency's transform that replaced a function of the root with a body holding `#compilerRunProcess(...)`
# ran a process with the root's own process.io although the dependency declared and was granted nothing. Now a body with compile-time code is refused
# (E_COMPILER_TRANSFORM_GRANTS) when the function's file has grants the transform's handler has not; a body without it, and a transform changing its own
# file's functions, are unaffected:
#   - inject: the dependency's transform puts `#compilerRunProcess` into the root's function: refused, nothing runs;
#   - plain: the same transform with an ordinary body: the root's function is replaced (the control);
#   - own: the root's own transform with the same body: allowed, the process runs (the grants are the same).
# A `$name` subparser handler of a dependency is likewise judged by the dependency's grants, not by the file that uses its syntax (handler-undeclared, handler-declared),
# and so is a `#` site the handler builds (syntaxCompile) into the using file (site-undeclared, site-nested, site-declared), and the finalizer of an
# extension request it records, within the grants of the recording handler and of the file that declares the finalizer (finalizer-undeclared,
# finalizer-declared; finalizer-package, finalizer-handler-package, finalizer-package-declared: a handler that passes another
# package's finalizer).
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
# A `#` site a handler builds (syntaxCompile) is a node of the using file, but the handler's package made it: it runs within the handler's grants too.
site_handler='import "abla/compiler"
import "abla/compiler/parser"
compile fun wordParse(cursor: ParserCursor): SyntaxExpression {
    parserRawSkipWhitespace(cursor)
    val origin = parserParseAblaExpression(cursor)
    parserRawExpect(cursor, ";")
    syntaxCompile(syntaxCall("compilerEnvironment", [syntaxString("ABLA_GRANT_PROBE")]), origin)
}
#compilerRegisterSubparser("word", wordParse)
fun dependencyValue: string = "ok"'
use_site() { # use_site <case> <the expression that uses the word>
    cat > "$out/$1/application/src/main.ab" <<EOT
import "abla/io"
import "abla/compiler"
import "provider.ab"
import dependencySource()
#compilerGrant("environment")
fun main { println("dependency value: '\${dependencyValue()}' \${$2}") }
EOT
}
# site-undeclared: the dependency declares nothing; the root authorizes environment for its own file: the site the handler built is refused.
repository "$out/site-undeclared/quiet-dep" quiet-dep '' "$site_handler"
commit "$out/site-undeclared/quiet-dep" dependency
application site-undeclared '"environment"' quiet-dep
use_site site-undeclared '$word 1;'
build site-undeclared
[[ $status != 0 ]] && ! grep -q "$ABLA_GRANT_PROBE" "$out/site-undeclared.log" ||
    fail "site-undeclared: a `#` site the dependency's handler built read the root's environment (status $status): $(grep -m3 'error\|value' "$out/site-undeclared.log")"
# site-nested: the root's own `#` holds the handler's form: the site inside it is still the handler's.
repository "$out/site-nested/quiet-dep" quiet-dep '' "$site_handler"
commit "$out/site-nested/quiet-dep" dependency
application site-nested '"environment"' quiet-dep
use_site site-nested '#($word 1;)'
build site-nested
[[ $status != 0 ]] && ! grep -q "$ABLA_GRANT_PROBE" "$out/site-nested.log" ||
    fail "site-nested: a handler's site inside the root's own `#` read the root's environment (status $status): $(grep -m3 'error\|value' "$out/site-nested.log")"
# site-declared: the dependency declares environment and the root authorizes it: the site reads it (the control).
repository "$out/site-declared/quiet-dep" quiet-dep '"environment"' "$site_handler"$'\n#compilerGrant("environment")'
commit "$out/site-declared/quiet-dep" dependency
application site-declared '"environment"' quiet-dep
use_site site-declared '$word 1;'
build site-declared
[[ $status == 0 ]] && grep -q "$ABLA_GRANT_PROBE" "$out/site-declared.log" ||
    fail "site-declared: the declared handler's site did not read it (status $status): $(grep -m3 'error\|value' "$out/site-declared.log")"
# An extension request's finalizer (compilerRecordExtensionRequest) is the code of the package whose handler recorded it: it runs later, while the
# using file is parsed, but within the grants of the handler that recorded it and of the file that declares it.
finalizer_handler='import "abla/compiler"
import "abla/compiler/parser"
compile fun finalize(payload: string, expression: SyntaxExpression): string {
    val seen = compilerEnvironment("ABLA_GRANT_PROBE")
    "fun finalizerProbe(): string = \"[$seen]\"\n"
}
compile fun wordParse(cursor: ParserCursor): SyntaxExpression {
    parserRawSkipWhitespace(cursor)
    val origin = parserParseAblaExpression(cursor)
    parserRawExpect(cursor, ";")
    compilerRecordExtensionRequest("quietdep.word", "", origin, finalize)
    syntaxString("w")
}
#compilerRegisterSubparser("word", wordParse)
fun dependencyValue: string = "ok"'
use_finalizer() { # use_finalizer <case> <the expression that uses the word>
    cat > "$out/$1/application/src/main.ab" <<EOT
import "abla/io"
import "abla/compiler"
import "provider.ab"
import dependencySource()
#compilerGrant("environment")
fun main { println("dependency value: '\${dependencyValue()}' \${$2} \${finalizerProbe()}") }
EOT
}
# finalizer-undeclared: the dependency declares nothing; the root authorizes environment for its own file: the finalizer is refused.
repository "$out/finalizer-undeclared/quiet-dep" quiet-dep '' "$finalizer_handler"
commit "$out/finalizer-undeclared/quiet-dep" dependency
application finalizer-undeclared '"environment"' quiet-dep
use_finalizer finalizer-undeclared '$word 1;'
build finalizer-undeclared
[[ $status != 0 ]] && ! grep -q "$ABLA_GRANT_PROBE" "$out/finalizer-undeclared.log" ||
    fail "finalizer-undeclared: the dependency's extension finalizer read the root's environment (status $status): $(grep -m3 'error\|value' "$out/finalizer-undeclared.log")"
# finalizer-declared: the dependency declares environment and the root authorizes it: the finalizer reads it (the control).
repository "$out/finalizer-declared/quiet-dep" quiet-dep '"environment"' "$finalizer_handler"$'\n#compilerGrant("environment")'
commit "$out/finalizer-declared/quiet-dep" dependency
application finalizer-declared '"environment"' quiet-dep
use_finalizer finalizer-declared '$word 1;'
build finalizer-declared
[[ $status == 0 ]] && grep -q "\[$ABLA_GRANT_PROBE\]" "$out/finalizer-declared.log" ||
    fail "finalizer-declared: the declared finalizer did not read it (status $status): $(grep -m3 'error\|value' "$out/finalizer-declared.log")"
# A handler may pass another package's finalizer: the finalizer runs within that package's grants and within the handler's. The handler is in
# middle-dep, the finalizer in middle-dep's own dependency, deep-dep.
middle_handler='import "abla/compiler"
import "abla/compiler/parser"
import "deep-provider.ab"
import deepSource()
compile fun wordParse(cursor: ParserCursor): SyntaxExpression {
    parserRawSkipWhitespace(cursor)
    val origin = parserParseAblaExpression(cursor)
    parserRawExpect(cursor, ";")
    compilerRecordExtensionRequest("middledep.word", "", origin, deepFinalize)
    syntaxString("w")
}
#compilerRegisterSubparser("word", wordParse)
fun dependencyValue: string = "ok"'
deep_finalizer='import "abla/compiler"
import "abla/compiler/parser"
compile fun deepFinalize(payload: string, expression: SyntaxExpression): string {
    val seen = compilerEnvironment("ABLA_GRANT_PROBE")
    "fun finalizerProbe(): string = \"[$seen]\"\n"
}'
granted='#compilerGrant("environment")'
deep_case() { # deep_case <case> <middle-dep declares environment: yes or no> <deep-dep declares it: yes or no>
    local middle_declared='' middle_grant='' deep_declared='' deep_grant=''
    [[ $2 == no ]] || { middle_declared='"environment"'; middle_grant=$granted; }
    [[ $3 == no ]] || { deep_declared='"environment"'; deep_grant=$granted; }
    repository "$out/$1/deep-dep" deep-dep "$deep_declared" "$deep_finalizer"$'\n'"$deep_grant"
    commit "$out/$1/deep-dep" leaf
    repository "$out/$1/middle-dep" middle-dep "$middle_declared" "$middle_handler"$'\n'"$middle_grant"
    provider "$out/$1/middle-dep/src/deep-provider.ab" deepSource deep-dep "$out/$1/deep-dep"
    commit "$out/$1/middle-dep" middle
    application "$1" '"environment"' middle-dep
    use_finalizer "$1" '$word 1;'
    build "$1"
}
# finalizer-package: the finalizer's package declares nothing: refused, although the handler's package is granted environment.
deep_case finalizer-package yes no
[[ $status != 0 ]] && ! grep -q "$ABLA_GRANT_PROBE" "$out/finalizer-package.log" ||
    fail "finalizer-package: another package's finalizer read the environment with the handler's grants (status $status): $(grep -m3 'error\|value' "$out/finalizer-package.log")"
# finalizer-handler-package: the handler's package declares nothing: refused, although the finalizer's package is granted environment.
deep_case finalizer-handler-package no yes
[[ $status != 0 ]] && ! grep -q "$ABLA_GRANT_PROBE" "$out/finalizer-handler-package.log" ||
    fail "finalizer-handler-package: a finalizer passed by a handler that has no grant read the environment (status $status): $(grep -m3 'error\|value' "$out/finalizer-handler-package.log")"
# finalizer-package-declared: both packages declare and request it: the finalizer reads it (the control).
deep_case finalizer-package-declared yes yes
[[ $status == 0 ]] && grep -q "\[$ABLA_GRANT_PROBE\]" "$out/finalizer-package-declared.log" ||
    fail "finalizer-package-declared: the declared finalizer did not read it (status $status): $(grep -m3 'error\|value' "$out/finalizer-package-declared.log")"
echo "transform grants: a dependency's subparser handler, the sites it builds and its extension finalizers run with the dependency's grants"

