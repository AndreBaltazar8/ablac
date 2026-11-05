#!/usr/bin/env bash
# Shared compiler frontend: overlays, typed analysis, no-evaluation graph policy,
# and structured locations. Legacy protocol parity has its own independent test.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$project_root"
out=build/frontend-analysis
mkdir -p "$out"
rm -f "$out/forbidden"
printf '%s\n' 'import "dep.ab"' 'fun answer: int = value()' > "$out/main.ab"
printf '%s\n' 'fun value: int = 7' > "$out/dep.ab"
cat > "$out/abla.toml" <<'TOML'
name = "frontend-analysis"
compileCapabilities = ["filesystem.write"]
TOML
cat > "$out/ct.ab" <<'AB'
import "abla/compiler"
#compilerGrant("filesystem.write")
val wrote = #compilerWriteFile("build/frontend-analysis/forbidden", "wrong")
fun main: int = 0
AB
cat > "$out/handler.ab" <<'AB'
import "abla/compiler"
import "abla/compiler/parser"
compile fun parseProbe(cursor: ParserCursor): SyntaxExpression {
    val divisor = 0
    syntaxInteger(1 / divisor)
}
#compilerRegisterSubparser("probe", parseProbe)
fun main: int = $probe{}
AB
"$compiler" build tests/cases/frontend-analysis/main.ab --fast --no-cache -o "$out/check"
"$out/check"
[[ ! -e $out/forbidden ]]
echo 'frontend analysis: overlays, disk restore, unsaved import, no-evaluation policy, type query and locations passed'
