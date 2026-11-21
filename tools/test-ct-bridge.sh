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
# Each tier's work directory: links to the project's top-level directories, made once and copied (tools/test-compile-effects.sh works on a copy
# of tests/cases/capabilities, so the tracked case is the same for both tiers of every case).
work_template="$output_directory/work-template"
mkdir -p "$work_template/tests/cases"
for top in "$project_root"/*; do
    [[ ${top##*/} == build || ${top##*/} == tests ]] || ln -s "$top" "$work_template/${top##*/}"
done
for top in "$project_root"/tests/*; do
    [[ ${top##*/} == cases ]] || ln -s "$top" "$work_template/tests/${top##*/}"
done
for top in "$project_root"/tests/cases/*; do
    ln -s "$top" "$work_template/tests/cases/${top##*/}"
done

compare_case() {
    local source=$1
    local name
    name=$(printf '%s' "${source#tests/cases/}" | tr '/' '_')
    local base="$output_directory/loopback/$name"
    mkdir -p "$output_directory/loopback"
    local interp_status=0 bridge_status=0
    # Compile-time writes are real writes (#72) and --emit-llvm honours a case's compileCapabilities (#886), so a case
    # writes its relative paths where it runs (build-fs-write/, build-host-compile/, ...), a failed one too. Each tier
    # runs in the same fresh directory (an output naming the working directory compares equal) that links the
    # project's top-level directories, so the tree is left as it was and one tier's files never meet the other's.
    local work="$output_directory/work/$name"
    fresh_work() {
        rm -rf "$work"
        mkdir -p "$(dirname "$work")"
        cp -a "$work_template" "$work"
        # A case that names a relative build/ directory of its own gets it here, in the tier's own tree: without it
        # tests/cases/compiler-capture-process/main.ab fails its pid-file check in both tiers (the child cannot write
        # build/compiler-capture-process/*.pid) and the tiers agree on the failure, which a directory appearing in one
        # tier only turns into a mismatch. tools/test-compiler-capture-process.sh keeps the project's own build/ for
        # its runs; nothing here touches it.
        mkdir -p "$work/build/compiler-capture-process"
    }
    # A site blocked by design (tests/cases/ct-time-limit) stops at a short compile-time time limit in both tiers, with
    # the same E_CT_TIME_LIMIT, well before the wall limit kills the compiler (whose report differs from run to run).
    # Every other case keeps the default: a heavy one ran past a short limit in one tier only under a loaded suite.
    local limit=${ABLA_COMPILE_EVAL_TIME_LIMIT:-}
    [[ $source != tests/cases/ct-time-limit/* ]] || limit=10
    # A case long by nature (tests/cases/ct-bridge/long-loopback.txt) gets three times the wall limit in each tier.
    local seconds=$ABLA_MAX_SECONDS
    [[ $long_cases != *" $source "* ]] || seconds=$((ABLA_MAX_SECONDS * 3))
    # The bridge tier first: it writes $base.mark at its first routed call (ABLA_COMPILE_EVAL_BRIDGE_MARK). A run that
    # writes none made no such call, and away from them it is the interpreter's own run, so there is nothing to compare
    # (about half of the cases; RUN_TESTS_FULL=1 or CT_BRIDGE_ALL=1 compares them too).
    rm -f "$base.mark"
    fresh_work
    # (Neither tier journals actions: ABLA_ACTION_JOURNAL is the interpreter's alone, which would make them differ.)
    (cd "$work" && env -u ABLA_ACTION_JOURNAL ${limit:+ABLA_COMPILE_EVAL_TIME_LIMIT=$limit} ABLA_MAX_SECONDS=$seconds ABLA_MAX_CPU_SECONDS=$seconds \
        ABLA_COMPILE_EVAL=bridge ABLA_COMPILE_EVAL_BRIDGE_MARK="$base.mark" \
        "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm "$source" \
        > "$base.bridge.ll" 2> "$base.bridge.err") || bridge_status=$?
    if [[ ! -f $base.mark && -z ${CT_BRIDGE_ALL:-${RUN_TESTS_FULL:-}} && $bridge_status -ne 124 && $bridge_status -ne 152 ]]; then
        rm -rf "$work"
        echo "$source" >> "$output_directory/loopback/unrouted.txt"
        return 0
    fi
    fresh_work
    (cd "$work" && env -u ABLA_ACTION_JOURNAL ${limit:+ABLA_COMPILE_EVAL_TIME_LIMIT=$limit} ABLA_MAX_SECONDS=$seconds ABLA_MAX_CPU_SECONDS=$seconds \
        ABLA_COMPILE_EVAL=interp "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm "$source" \
        > "$base.interp.ll" 2> "$base.interp.err") || interp_status=$?
    rm -rf "$work"
    # run-limited's wall (124) or CPU (152) limit stopped a tier: that is no result to compare, whichever tier finished.
    local tier stopped=""
    for tier in interp bridge; do
        local status_of=${tier}_status
        if [[ ${!status_of} -eq 124 || ${!status_of} -eq 152 ]]; then stopped="$stopped $tier (status ${!status_of})"; fi
    done
    if [[ -n $stopped ]]; then
        printf 'loopback timeout: %s: stopped by the %s s limit:%s; not compared (a case long by nature belongs in tests/cases/ct-bridge/long-loopback.txt)\n' \
            "$source" "$seconds" "$stopped" >&2
        return 1
    fi
    for tier in interp bridge; do comparable_err < "$base.$tier.err" > "$base.$tier.cmp"; done
    if [[ $interp_status -ne $bridge_status ]] ||
        ! cmp -s "$base.interp.ll" "$base.bridge.ll" ||
        ! cmp -s "$base.interp.cmp" "$base.bridge.cmp"; then
        printf 'loopback mismatch: %s (status %s vs %s)\n' \
            "$source" "$interp_status" "$bridge_status" >&2
        diff "$base.interp.cmp" "$base.bridge.cmp" >&2 || true
        return 1
    fi
}

# A tier's diagnostics without what depends on its speed: the note on a `#` site that took five seconds or more (its
# time, and whether it is there at all), and the place of a time-limit error, which is wherever the interrupt landed
# (its source[eval] offsets and its --> line). Everything else stays exact.
comparable_err() {
    awk '
        /^note: the `#` site at .* took [0-9.]+ s / { next }
        /^(error|warning)\[/ { limit = ($0 ~ /^error\[E_CT_TIME_LIMIT\]/) }
        limit && /^source\[eval\]:/ { sub(/:[0-9]+:[0-9]+$/, ":<at>:<end>") }
        limit && /^  --> / { sub(/:[0-9]+:[0-9]+/, ":<line>:<column>") }
        { print }
    '
}

# Every case using the compiler API, parser extensions or compile grants. (Not capabilities/ambient.ab: the compile-time clock and
# random number it embeds differ from one evaluation to the next.)
cases=()
while IFS= read -r source; do
    cases+=("$source")
done < <(grep -rlE 'import "abla/compiler|compilerGrant|compileCapabilities' \
    tests/cases --include='*.ab' | grep -v '^tests/cases/capabilities/ambient\.ab$' | sort)
(( ${#cases[@]} >= 40 ))
# The cases are independent: CT_BRIDGE_JOBS of them at a time (default: the
# number of CPUs); xargs exits nonzero when any of them mismatches.
long_cases=" $(sed 's/#.*//' tests/cases/ct-bridge/long-loopback.txt | awk 'NF { print $1 }' | tr '\n' ' ') "
for long_case in $long_cases; do
    [[ -f $long_case ]] || { echo "tests/cases/ct-bridge/long-loopback.txt names $long_case, which is gone" >&2; exit 1; }
done
export compiler project_root output_directory work_template long_cases
export -f compare_case comparable_err
mkdir -p "$output_directory/loopback"
rm -f "$output_directory/loopback/unrouted.txt"
printf '%s\0' "${cases[@]}" |
    xargs -0 -n1 -P "${CT_BRIDGE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}" \
        bash -c 'compare_case "$1"' compare_case
# The capture case must pass in both tiers, not merely agree: a failed check's text ("check 11: failure=...") is in the output.
# (A case that makes no routed call has only the bridge tier's output, which is the interpreter's run.)
for tier in interp bridge; do
    [[ -f $output_directory/loopback/compiler-capture-process_main.ab.$tier.ll ]] || continue
    if grep -q 'check [0-9]*: failure=' "$output_directory/loopback/compiler-capture-process_main.ab.$tier.ll"; then
        grep -o 'check [0-9]*: failure=[^"]*' "$output_directory/loopback/compiler-capture-process_main.ab.$tier.ll" >&2
        echo "ct-bridge: tests/cases/compiler-capture-process/main.ab failed one of its checks under $tier" >&2
        exit 1
    fi
done
# Every case routed means no unrouted.txt: count it as none (a failing cat would end the script under pipefail).
unrouted=0
[[ -f $output_directory/loopback/unrouted.txt ]] && unrouted=$(wc -l < "$output_directory/loopback/unrouted.txt")
compared=$(( ${#cases[@]} - unrouted ))
# The routed cases are the ones the loopback is for: a mark that is never written would leave none compared.
if (( compared < 100 )); then
    echo "ct-bridge: only $compared of ${#cases[@]} cases crossed the bridge (100 expected at least; 166 did on 2026-11-19): is ABLA_COMPILE_EVAL_BRIDGE_MARK written?" >&2
    exit 1
fi

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

# Retry remains control flow, not a new invalid-value diagnostic. The
# loopback comparison above also checks this source's direct/bridge IR.
"$compiler" build tests/cases/ct-bridge/retry-argument.ab --fast --no-cache \
    -o "$output_directory/retry-argument"
retry_status=0
"$output_directory/retry-argument" || retry_status=$?
[[ $retry_status == 42 ]]

# Invalid native values have no earlier evaluator error. Each is rejected
# once at dispatch, before its zero payload can become syntaxInteger(0).
ABLA_CT_BRIDGE_RUN_FRAME=2 "$compiler" run \
    tests/cases/ct-bridge/invalid-arguments.ab \
    > "$output_directory/invalid-arguments.out" \
    2> "$output_directory/invalid-arguments.err"
cat > "$output_directory/invalid-arguments.expected" <<EOF
function 1 0
handle 1 0
array 1 0
EOF
diff "$output_directory/invalid-arguments.expected" \
    "$output_directory/invalid-arguments.out"
grep -q '^ct-bridge: errors=3 ' "$output_directory/invalid-arguments.err"
if grep -q 'while evaluating `bridge.value`' "$output_directory/invalid-arguments.err"; then
    echo 'a bridge argument was counted again after its reported failure' >&2
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

printf 'ct-bridge: %s loopback cases (%s cross the bridge and match the interpreter; %s make no routed call), native shims ok\n' \
    "${#cases[@]}" "$compared" "$unrouted"
