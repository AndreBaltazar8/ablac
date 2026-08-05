#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
test_root=$(mktemp -d "$project_root/build/generated-package.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

repository="$test_root/action-package"
application="$test_root/application"
cache="$test_root/cache"
mkdir -p -- "$repository/src" "$application/src"

git -C "$repository" init --quiet --initial-branch=main
git -C "$repository" config user.name 'Abla generated-reference test'
git -C "$repository" config user.email \
    'abla-generated-reference@example.invalid'
cat > "$repository/abla.toml" <<'EOF'
name = "cross-late-action"
version = "0.1.0"
entry = "src/action.ab"
EOF
cat > "$repository/src/action.ab" <<'EOF'
class PackageActionResult(val value: int)

@client
fun packageAction(value: int): PackageActionResult =
    PackageActionResult(value)
EOF
git -C "$repository" add abla.toml src/action.ab
git -C "$repository" commit --quiet -m 'package action declaration'
revision=$(git -C "$repository" rev-parse HEAD)

cat > "$application/abla.toml" <<'EOF'
name = "generated-package-app"
version = "0.1.0"
entry = "src/main.ab"
compileCapabilities = ["network"]
EOF
cat > "$application/src/package-provider.ab" <<EOF
compile fun actionDependency(): ImportSource = gitImportSource(
    "cross-late-action",
    "$repository",
    "rev",
    "$revision"
)
EOF
cat > "$application/src/generated-provider.ab" <<'EOF'
import "abla/compiler"
import "abla/compiler/parser"
compile fun finalizePackageAction(
    generatedName: string,
    expression: SyntaxExpression
): GeneratedModuleBuilder {
    val target = typedCallTarget(expression)
    val module = compilerGeneratedModule("package.action", expression)
    val valid = compilerFunctionName(target) == "packageAction" &&
        compilerFunctionCanonicalIdentity(target) != "packageAction" &&
        compilerFunctionModuleIdentity(target).size > 0 &&
        compilerFunctionParameterType(target, 0) == "i64" &&
        compilerFunctionResultType(target) == "PackageActionResult" &&
        compilerFunctionAnnotationCount(target) == 1 &&
        compilerFunctionAnnotation(target, 0) == "client"
    val parameterNames: array<string> = ["argument"]
    val parameterTypes: array<int> = [compilerFindType("i64")]
    val arguments: array<SyntaxExpression> = [syntaxIdentifier("argument")]
    compilerGeneratedFunction(
        module,
        "adapter",
        parameterNames,
        parameterTypes,
        compilerFunctionResultTypeHandle(target),
        syntaxCallTarget(target, arguments)
    )
    compilerGeneratedExportFunction(
        module,
        generatedName,
        parameterNames,
        parameterTypes,
        compilerFunctionResultTypeHandle(target),
        compilerGeneratedDeclarationCall(module, 0, arguments)
    )
    if (!valid) {
        val invalidNames: array<string> = []
        val invalidTypes: array<int> = []
        compilerGeneratedFunction(
            module,
            "invalidPackageAdapter",
            invalidNames,
            invalidTypes,
            compilerFindType("MissingType"),
            syntaxInteger(0)
        )
    }
    module
}

compile fun parsePackageAction(cursor: ParserCursor): SyntaxExpression {
    parserExpect(cursor, "(")
    val expression = parserParseAblaExpression(cursor)
    parserExpect(cursor, ")")
    compilerRecordGeneratedExtensionRequest(
        "package.action",
        "generatedPackageAction",
        expression,
        finalizePackageAction
    )
    expression
}

#compilerRegisterSubparser("packageAction", parsePackageAction)
EOF
cat > "$application/src/main.ab" <<'EOF'
import "package-provider.ab"
import actionDependency() as actions
import "generated-provider.ab"

val directPackageAction = $packageAction(actions.packageAction(1))

fun main: int =
    generatedPackageAction(41).value + directPackageAction.value
EOF

ABLA_PACKAGE_CACHE="$cache" "$compiler" package update \
    --project "$application"
grep -q "revision = \"$revision\"" "$application/abla.lock"
ABLA_PACKAGE_CACHE="$cache" "$compiler" build --project "$application" \
    --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" \
    "$application/build/generated-package-app"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' \
    'generated references: locked package + @client annotation + canonical target identity passed'
