#!/usr/bin/env bash
# The compiler bridge (src/ct_bridge.ab) gives native compile-time code the
# interpreter's own compiler API.
#
# 1. Loopback: every compile-time case compiles to identical output, status
#    and diagnostics whether the interpreter performs compiler, parser and
#    host externs directly or through the bridge's C entry points
#    (ABLA_COMPILE_EVAL=bridge).
# 2. Native: the generated shims, compiled as native code and run in the
#    compiler process inside a bridge frame, observe the compiler API with
#    the frame's grants and journal its inputs.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi
output_directory="$project_root/build/ct-bridge-test"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-2048}
export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-120}

compare_case() {
    local source=$1
    local name
    name=$(printf '%s' "${source#tests/cases/}" | tr '/' '_')
    local base="$output_directory/loopback/$name"
    mkdir -p "$output_directory/loopback"
    local interp_status=0 bridge_status=0
    ABLA_COMPILE_EVAL=interp "$project_root/tools/run-limited.sh" \
        "$compiler" --emit-llvm "$source" \
        > "$base.interp.ll" 2> "$base.interp.err" || interp_status=$?
    ABLA_COMPILE_EVAL=bridge "$project_root/tools/run-limited.sh" \
        "$compiler" --emit-llvm "$source" \
        > "$base.bridge.ll" 2> "$base.bridge.err" || bridge_status=$?
    if [[ $interp_status -ne $bridge_status ]] ||
        ! cmp -s "$base.interp.ll" "$base.bridge.ll" ||
        ! cmp -s "$base.interp.err" "$base.bridge.err"; then
        printf 'loopback mismatch: %s (status %s vs %s)\n' \
            "$source" "$interp_status" "$bridge_status" >&2
        diff "$base.interp.err" "$base.bridge.err" >&2 || true
        return 1
    fi
}

# Every case using the compiler API, parser extensions or compile grants.
cases=()
while IFS= read -r source; do
    cases+=("$source")
done < <(grep -rlE 'import "abla/compiler|compilerGrant|compileCapabilities' \
    tests/cases --include='*.ab' | sort)
(( ${#cases[@]} >= 40 ))
# The cases are independent: CT_BRIDGE_JOBS of them at a time (default: the
# number of CPUs); xargs exits nonzero when any of them mismatches.
export compiler project_root output_directory
export -f compare_case
printf '%s\0' "${cases[@]}" |
    xargs -0 -n1 -P "${CT_BRIDGE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}" \
        bash -c 'compare_case "$1"' compare_case

# Native: shims for the whole compiler API, then a program calling them.
ABLA_CT_BRIDGE_SHIMS_OUT="$output_directory/shims.ab" \
    "$compiler" run tests/cases/ct-bridge/shim-source.ab
grep -q '^trusted fun compilerFindFunction(name: string): int {' \
    "$output_directory/shims.ab"
grep -q '^class SyntaxExpression(val ctHandle: int)' \
    "$output_directory/shims.ab"
grep -q '^fun ablaAtCompileTime(): bool = true' "$output_directory/shims.ab" ||
    true
cat "$output_directory/shims.ab" tests/cases/ct-bridge/native-body.ab \
    > "$output_directory/native.ab"

# filesystem.read (4) + environment (16) + the compiler surface (2).
ABLA_CT_BRIDGE_PROBE=probe-value ABLA_CT_BRIDGE_RUN_FRAME=22 \
    "$compiler" run "$output_directory/native.ab" \
    > "$output_directory/native.out" 2> "$output_directory/native.err"
probe_size=$(wc -c < tests/cases/ct-bridge/shim-source.ab | tr -d ' ')
listing_count=$(ls tests/cases/ct-bridge | wc -l | tr -d ' ')
listing_first=$(ls tests/cases/ct-bridge | LC_ALL=C sort | head -1)
cat > "$output_directory/native.expected" <<EOF
find true
name probeTarget
parameters 2 label:string
annotation 2 marker
route 1 string /probe string
missing -1
functions true
call call f 2
child integer 7 first=7
child1 string hi
generated true count=1
read $probe_size
listing $listing_count $listing_first
environment probe-value
done
EOF
diff "$output_directory/native.expected" "$output_directory/native.out"
# The unregistered function value is the one failure; every input is
# journaled.
grep -q '^ct-bridge: errors=1 ' "$output_directory/native.err"
grep -q "^ct-bridge: input tests/cases/ct-bridge/shim-source.ab $probe_size\$" \
    "$output_directory/native.err"
grep -q '^ct-bridge: input abla-input:directory:tests/cases/ct-bridge ' \
    "$output_directory/native.err"
grep -q '^ct-bridge: input abla-input:environment:ABLA_CT_BRIDGE_PROBE 11$' \
    "$output_directory/native.err"

# Without the filesystem.read and environment grants the same calls fail (each
# denied call counts twice, as under the interpreter: the denial and its
# invalid result)
# and observe nothing.
ABLA_CT_BRIDGE_PROBE=probe-value ABLA_CT_BRIDGE_RUN_FRAME=2 \
    "$compiler" run "$output_directory/native.ab" \
    > "$output_directory/denied.out" 2> "$output_directory/denied.err"
grep -q '^read 0$' "$output_directory/denied.out"
grep -q '^listing 0 -$' "$output_directory/denied.out"
grep -q '^environment $' "$output_directory/denied.out"
grep -q '^ct-bridge: errors=7 ' "$output_directory/denied.err"
if grep -q '^ct-bridge: input ' "$output_directory/denied.err"; then
    exit 1
fi

# Literal-only actions: called from compile-time code, a generated module
# joins the program from a transform handler, and every other use fails
# loudly instead of doing nothing.
"$compiler" build tests/cases/ct-bridge/generate-from-transform.ab \
    -o "$output_directory/generated" --no-cache
set +e
"$output_directory/generated"
generated_status=$?
set -e
[[ $generated_status -eq 42 ]]
expect_failure() {
    local source=$1 pattern=$2 status=0
    "$compiler" --emit-llvm "tests/cases/ct-bridge/$source" \
        > "$output_directory/$source.ll" 2> "$output_directory/$source.err" ||
        status=$?
    [[ $status -ne 0 ]]
    grep -q -- "$pattern" "$output_directory/$source.err"
}
"$compiler" build tests/cases/ct-bridge/annotation-arguments.ab \
    -o "$output_directory/annotations" --no-cache
set +e
"$output_directory/annotations"
annotations_status=$?
set -e
[[ $annotations_status -eq 42 ]]
expect_failure invalid-dynamic-grant.ab 'error\[E_COMPILE_GRANT_PHASE\]'
expect_failure invalid-dynamic-subparser.ab \
    'error\[E_EXT_SUBPARSER_REGISTRATION\]: compilerRegisterSubparser registers'
expect_failure invalid-generate-after-analysis.ab \
    'error\[E_EXT_GENERATED_MODULE_PHASE\]'

# Literal subparser registrations keep the object cache usable, and editing
# the handler's body invalidates it.
# (A per-run marker keeps an earlier run's cache entries out of the test.)
cache_nonce="$$-$(date +%s)"
write_subparser_program() {
    cat > "$output_directory/subparser-cache.ab" <<PROGRAM
// $cache_nonce
// (The parser API is declared here: importing abla/compiler makes a graph
// uncacheable on its own, through Compiler.buildProgram.)
compile class ParserCursor
compile class SyntaxExpression
compile extern:"compiler" fun compilerRegisterSubparser(
    name: string,
    parser: (ParserCursor) -> SyntaxExpression
)
compile extern:"parser" fun parserExpect(cursor: ParserCursor, token: string)
compile extern:"parser" fun syntaxInteger(value: int): SyntaxExpression

compile fun parseAnswer(cursor: ParserCursor): SyntaxExpression {
    parserExpect(cursor, "{")
    parserExpect(cursor, "}")
    syntaxInteger($1)
}

#compilerRegisterSubparser("answer", parseAnswer)

fun main: int = \$answer{}
PROGRAM
}
run_status() {
    local status=0
    "$1" || status=$?
    printf '%s' "$status"
}
write_subparser_program 41
"$compiler" build "$output_directory/subparser-cache.ab" \
    -o "$output_directory/subparser-cache" --fast
[[ $(run_status "$output_directory/subparser-cache") -eq 41 ]]
printf '%s\n' 'cache-hit' > "$output_directory/subparser-cache.ll"
"$compiler" build "$output_directory/subparser-cache.ab" \
    -o "$output_directory/subparser-cache" --fast
grep -q '^cache-hit$' "$output_directory/subparser-cache.ll"
write_subparser_program 42
"$compiler" build "$output_directory/subparser-cache.ab" \
    -o "$output_directory/subparser-cache" --fast
if grep -q '^cache-hit$' "$output_directory/subparser-cache.ll"; then
    echo 'an edited subparser handler reused a stale object' >&2
    exit 1
fi
[[ $(run_status "$output_directory/subparser-cache") -eq 42 ]]

printf 'ct-bridge: %s loopback cases, native shims ok\n' "${#cases[@]}"
