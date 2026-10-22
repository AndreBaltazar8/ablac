#!/usr/bin/env bash
# Compile-time parity: a computation evaluated under `#` must print exactly what
# the same computation prints at run time, in every compile-time evaluation mode.
#
#   tools/test-compile-time-parity.sh [compiler]
#
# Cases:
#   probes   tests/cases/parity/<name>.ab or <name>/main.ab, each defining
#            parityValue(): T and, unless T is string, parityShow(value: T): string.
#            runtime:      print(parityShow(parityValue()))
#            compile time: val staged = #parityValue(); print(parityShow(staged))
#   modules  every tests/cases/modules program whose main returns int: the program
#            as is, against its main renamed and evaluated under `#`
#            (fun main: int = #parityMainBody()). Exit codes and output must match.
#
# Environment:
#   PARITY_MODES    ABLA_COMPILE_EVAL modes to run (default "interp")
#   PARITY_SET      probes | modules | all (default all)
#   PARITY_FILTER   extended regex on case names (default: every case)
#   PARITY_JOBS     cases built at once (default 4)
#   PARITY_SECONDS  wall limit per compile and per run (default 120)
#   PARITY_EXPECT   a file of "<mode> <case> [<status>]" lines that must end with
#                   that status, `pass` when there is none (default
#                   tests/cases/parity/expected-pass.txt); the script fails when
#                   one of them doesn't, and lists cases that newly pass.
#
# Results: build/compile-time-parity/results.tsv (case, mode, status, detail),
# one directory per case and mode with both programs, their output and the logs.
# Status: pass | mismatch | compile-failed | runtime-skipped (the program itself
# doesn't build here or doesn't finish) | timeout | interp-threads (a timeout
# under the interpreter in a program that starts a thread: its body runs only
# when awaited, docs/compile-time.md#threads-at-compile-time) | interp-memory
# (the program measures or resets its heap, which the interpreter doesn't have) |
# interp-steps (the interpreter ran past its step limit; the same `#` code
# under ABLA_COMPILE_EVAL=jit finishes and matches) | host-dependent and
# staged-writes and interp-timing (listed below with the reason, differing by
# design: what the case reports is the process it runs in, which under `#` is
# the compiler; another process reads a file the case wrote, which under `#`
# stays staged until the build succeeds; or the case keeps real-time deadlines
# the interpreter can't meet) | same-panic (the program panics at run time and
# its `#` evaluation stops with the same panic: E_CT_PANIC, or the evaluator's
# own code for it, with the same message).
set -uo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
modes=${PARITY_MODES:-interp}
set_name=${PARITY_SET:-all}
filter=${PARITY_FILTER:-}
jobs=${PARITY_JOBS:-4}
seconds=${PARITY_SECONDS:-120}
expect=${PARITY_EXPECT:-$project_root/tests/cases/parity/expected-pass.txt}
output=$project_root/build/compile-time-parity
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}

rm -rf "$output"
mkdir -p "$output/cases"

# Lists "<kind> <name> <source>" for every selected case.
list_cases() {
    local source name
    if [[ $set_name == all || $set_name == probes ]]; then
        for source in "$project_root"/tests/cases/parity/*.ab \
            "$project_root"/tests/cases/parity/*/main.ab; do
            [[ -f $source ]] || continue
            name=${source#"$project_root"/tests/cases/parity/}
            name=probe/${name%/main.ab}
            name=${name%.ab}
            printf 'probe %s %s\n' "$name" "$source"
        done
    fi
    if [[ $set_name == all || $set_name == modules ]]; then
        for source in "$project_root"/tests/cases/modules/*.ab; do
            name=$(basename "$source" .ab)
            [[ $name == invalid-* ]] && continue
            grep -qE '^fun main(\(\))?: int' "$source" || continue
            printf 'module module/%s %s\n' "$name" "$source"
        done
    fi
}

# The first diagnostic of a failed compile, without positions.
first_error() {
    grep -m1 -E '^error\[' "$1" 2>/dev/null |
        sed -E 's/ at [0-9]+:[0-9]+//g; s/[[:space:]]+$//' | cut -c1-200
}

limited() { # run with the wall/CPU bound; 124 = timed out
    ABLA_MAX_SECONDS=$seconds ABLA_MAX_CPU_SECONDS=$seconds \
        "$project_root/tools/run-limited.sh" "$@"
}

# Builds and runs one program in its case directory; writes <tag>.out (stdout of
# the compiler, then of the program, then the exit status) and <tag>.err.
build_and_run() { # dir tag entry mode
    local dir=$1 tag=$2 entry=$3 mode=$4 status
    (
        cd "$dir" || exit 1
        # Through the runner, whatever $compiler is: a bare compiler binary
        # bounds nothing itself (only the repository launcher does), with the
        # launcher's memory default.
        ABLA_COMPILE_EVAL=$mode ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096} \
            limited "$compiler" build "$entry" -o "$tag.program" --no-cache \
            >"$tag.compiler.out" 2>"$tag.err"
    )
    status=$?
    if [[ $status -ne 0 ]]; then
        # Straight into the case's directory: cases build in parallel, and a
        # status written beside the harness could be taken by another case.
        echo "build $status" >"$dir/$tag.status"
        return
    fi
    (
        cd "$dir" || exit 1
        limited "./$tag.program" >"$tag.program.out" 2>"$tag.program.err" </dev/null
        echo "exit $?" >"$tag.status"
        cat "$tag.compiler.out" "$tag.program.out" "$tag.status" >"$tag.out"
    )
}

# Cases whose two sides differ (or agree) by design, in the modes given ("*"
# for all), with the status they get and why, whether or not the `#` side
# builds ("<case>\t<modes>\t<status>\t<reason>"; docs/compile-time.md).
by_design='module/proc-self-exe	*	host-dependent	reads its own executable (/proc/self/exe): under `#` that is the compiler
module/unsafe-boundary	*	host-dependent	calls its own @export functions through dlsym: they exist only in the running program, not in the compiler
module/http-advanced	*	staged-writes	a child process (gzip) reads a file the case wrote: under `#` writes stay staged until the build succeeds
module/network-advanced	jit	staged-writes	its http-advanced part: a child process (gzip) reads a file the case wrote, which stays staged under `#` (interp: interp-threads)
module/websocket-server-protocol	interp	interp-timing	forks clients with 100 ms ping / 400 ms idle deadlines the interpreter cannot meet (passes under jit)
module/http-async	interp	interp-timing	the interpreted child builds the 200 KB /big body byte by byte and misses the client timeout (passes under jit)'

by_design_status() { # name mode
    awk -F'\t' -v n="$1" -v m="$2" '$1 == n && ($2 == "*" || $2 == m) { print $3 }' <<<"$by_design"
}

by_design_reason() { # name mode
    awk -F'\t' -v n="$1" -v m="$2" '$1 == n && ($2 == "*" || $2 == m) { print $4 }' <<<"$by_design"
}

# Whether `source` or a file it imports by a relative path starts a thread.
starts_thread() { # source
    local pending=("$1") seen="" file
    while ((${#pending[@]} > 0)); do
        file=${pending[0]}
        pending=("${pending[@]:1}")
        [[ -f $file && " $seen " != *" $file "* ]] || continue
        seen="$seen $file"
        grep -q 'thread {' "$file" && return 0
        local imported
        while IFS= read -r imported; do
            pending+=("$(cd "$(dirname "$file")" && pwd)/$imported")
        done < <(sed -n 's/^import "\(\.\{0,2\}\/\{0,1\}[^"]*\.ab\)".*/\1/p' "$file")
    done
    return 1
}

run_case() { # kind name source mode
    local kind=$1 name=$2 source=$3 mode=$4
    local dir=$output/cases/$mode/$name status detail granted=""
    mkdir -p "$dir"
    if [[ $kind == probe ]]; then
        if [[ $(basename "$source") == main.ab ]]; then
            cp -R "$(dirname "$source")/." "$dir/"
        else
            cp "$source" "$dir/"
        fi
        local body
        body=$(cat "$source")
        local show='parityValue()'
        local staged='parityStaged'
        if grep -qE '^fun parityShow' "$source"; then
            show='parityShow(parityValue())'
            staged='parityShow(parityStaged)'
        fi
        printf 'import "abla/io"\n%s\n\nfun main: int {\n    print(%s)\n    0\n}\n' \
            "$body" "$show" >"$dir/runtime.ab"
        printf 'import "abla/io"\n%s\n\nval parityStaged = #parityValue()\n\nfun main: int {\n    print(%s)\n    0\n}\n' \
            "$body" "$staged" >"$dir/staged.ab"
    else
        # Modules import their siblings by relative path, so both variants sit
        # in a copy of the whole directory.
        cp -R "$project_root/tests/cases/modules/." "$dir/"
        local base
        base=$(basename "$source" .ab)
        cp "$source" "$dir/runtime.ab"
        sed -E 's/^fun main(\(\))?: int/fun parityMainBody(): int/' "$source" >"$dir/staged.ab"
        printf '\nfun main: int = #parityMainBody()\n' >>"$dir/staged.ab"
        rm -f "$dir/$base.ab"
    fi
    build_and_run "$dir" runtime runtime.ab "$mode"
    # A program that doesn't build, or doesn't finish (a server waiting for
    # clients), has no run-time result to compare.
    if [[ $(cat "$dir/runtime.status") != "exit 0" && $kind == probe ]] ||
        [[ $(cat "$dir/runtime.status") == build* ]] ||
        [[ $(cat "$dir/runtime.status") == "exit 124" ]]; then
        status=runtime-skipped
        detail="runtime $(cat "$dir/runtime.status"): $(first_error "$dir/runtime.err")"
    else
        build_and_run "$dir" staged staged.ab "$mode"
        # Compile-time code reaches files, the clock, the environment or native
        # code only with a grant (docs/compile-time.md#capabilities-files-
        # environment-processes-network). A module case denied nothing but
        # capabilities asks for those, and again for any the grant uncovers.
        if [[ $kind == module ]]; then
            local capabilities="" round=0
            while [[ $(cat "$dir/staged.status") == build* && $round -lt 8 ]] &&
                grep -q '^error\[E_SEMANTIC\]: compile.effect-denied:' "$dir/staged.err" &&
                ! grep -vq '^error\[E_SEMANTIC\]: compile.effect-denied:' \
                    <<<"$(grep '^error' "$dir/staged.err")"; do
                local denied
                denied=$(sed -n 's/^error\[E_SEMANTIC\]: compile.effect-denied:\([a-z.]*\).*/\1/p' \
                    "$dir/staged.err" | sort -u)
                local added=false capability
                for capability in $denied; do
                    [[ " $capabilities " == *" $capability "* ]] && continue
                    capabilities="${capabilities:+$capabilities }$capability"
                    added=true
                done
                $added || break
                local list="" actions=""
                for capability in $capabilities; do
                    list="${list:+$list, }\"$capability\""
                    actions="$actions#compilerGrant(\"$capability\")\n"
                done
                printf 'compileCapabilities = [%s]\n' "$list" >"$dir/abla.toml"
                [[ -f "$dir/staged.ungranted.ab" ]] || cp "$dir/staged.ab" "$dir/staged.ungranted.ab"
                { printf 'import "abla/compiler"\n%b' "$actions"
                  cat "$dir/staged.ungranted.ab"; } >"$dir/staged.ab"
                granted=" (granted ${capabilities// /, })"
                build_and_run "$dir" staged staged.ab "$mode"
                round=$((round + 1))
            done
        fi
        case $(cat "$dir/staged.status") in
            "build 124" | "build 137" | "build 152")
                status=timeout
                detail="compile-time evaluation exceeded ${seconds}s"
                # The interpreter runs a thread's body when it is awaited, so a
                # program that waits on its own thread first can't finish there.
                if [[ $mode == interp ]] && starts_thread "$source"; then
                    status=interp-threads
                    detail="waits on a thread the interpreter runs only at await"
                fi
                ;;
            build*)
                status=compile-failed
                detail=$(first_error "$dir/staged.err")
                [[ -n $detail ]] || detail=$(tail -n1 "$dir/staged.err" | cut -c1-200)
                if [[ -n $(by_design_status "$name" "$mode") ]]; then
                    status=$(by_design_status "$name" "$mode")
                    detail="$(by_design_reason "$name" "$mode") ($detail)"
                fi
                # The runtime memory API has no heap to measure in the
                # interpreter (docs/compile-time.md).
                if [[ $mode == interp ]] &&
                    grep -q '^error\[E_EVAL_MEMORY_UNAVAILABLE\]' "$dir/staged.err"; then
                    status=interp-memory
                fi
                # A panic at run time is the same panic under `#`.
                if [[ $(cat "$dir/runtime.status") == "exit 101" ]]; then
                    local panic staged_panic
                    panic=$(sed -n 's/^panic: //p' "$dir/runtime.program.err" | head -1)
                    staged_panic=$(sed -E -n 's/^error\[(E_CT_PANIC|E_EVAL_OUT_OF_BOUNDS|E_EVAL_DIVISION_BY_ZERO)\]: //p' \
                        "$dir/staged.err" | head -1)
                    if [[ -n $panic && $panic == "$staged_panic" ]]; then
                        status=same-panic
                        detail="panics at run time and under \`#\`: $panic"
                    fi
                fi
                # Past the interpreter's step limit: the same code natively.
                if [[ $mode == interp ]] &&
                    grep -q '^error\[E_EVAL_STEP_LIMIT\]' "$dir/staged.err"; then
                    build_and_run "$dir" staged-jit staged.ab jit
                    if [[ $(cat "$dir/staged-jit.status") != build* ]] &&
                        cmp -s "$dir/runtime.out" "$dir/staged-jit.out"; then
                        status=interp-steps
                        detail="past the interpreter's step limit; passes with ABLA_COMPILE_EVAL=jit"
                    fi
                fi
                ;;
            *)
                if [[ -n $(by_design_status "$name" "$mode") ]]; then
                    status=$(by_design_status "$name" "$mode")
                    detail="$(by_design_reason "$name" "$mode")${granted:-}"
                elif cmp -s "$dir/runtime.out" "$dir/staged.out"; then
                    status=pass
                    detail="${granted:-}"
                else
                    status=mismatch
                    detail="runtime $(tr '\n' ' ' <"$dir/runtime.out" | cut -c1-90)| staged $(tr '\n' ' ' <"$dir/staged.out" | cut -c1-90)"
                fi
                ;;
        esac
    fi
    # Keep only what a failure needs; the copies of the module tree go.
    if [[ $kind == module ]]; then
        find "$dir" -mindepth 1 -maxdepth 1 ! -name 'runtime*' ! -name 'staged*' \
            ! -name 'abla.toml' \
            -exec rm -rf {} +
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$mode" "$status" "$detail" >"$dir/result.tsv"
    printf '%-14s %-8s %s %s\n' "$status" "$mode" "$name" "${detail:0:120}"
}
export -f run_case build_and_run first_error limited by_design_status by_design_reason starts_thread
export output compiler seconds project_root by_design

for mode in $modes; do
    list_cases | while read -r kind name source; do
        [[ -z $filter || $name =~ $filter ]] || continue
        printf '%s\0%s\0%s\0%s\0' "$kind" "$name" "$source" "$mode"
    done
done | xargs -0 -n4 -P "$jobs" bash -c 'run_case "$@"' run_case

find "$output/cases" -name result.tsv -exec cat {} + | sort >"$output/results.tsv"

echo
for mode in $modes; do
    printf '%s:' "$mode"
    for status in pass mismatch compile-failed timeout interp-threads interp-memory interp-steps interp-timing host-dependent staged-writes same-panic runtime-skipped; do
        printf ' %s %d' "$status" \
            "$(awk -F'\t' -v m="$mode" -v s="$status" '$2 == m && $3 == s' \
                "$output/results.tsv" | wc -l | tr -d ' ')"
    done
    echo
done

failed=0
if [[ -f $expect ]]; then
    while read -r mode name want; do
        [[ -z $mode || $mode == \#* ]] && continue
        want=${want:-pass}
        [[ " $modes " == *" $mode "* ]] || continue
        [[ -z $filter || $name =~ $filter ]] || continue
        # Only the cases this run selected.
        [[ -n $(awk -F'\t' -v m="$mode" -v n="$name" '$1 == n && $2 == m' \
            "$output/results.tsv") ]] || continue
        if [[ -z $(awk -F'\t' -v m="$mode" -v n="$name" -v w="$want" '$1 == n && $2 == m && $3 == w' \
            "$output/results.tsv") ]]; then
            echo "REGRESSED: $mode $name (expected $want)"
            failed=1
        fi
    done <"$expect"
    awk -F'\t' '$3 == "pass" { print $2 " " $1 }' "$output/results.tsv" |
        while read -r line; do
            grep -qE "^$line( pass)?$" "$expect" || echo "newly passing: $line"
        done
fi
echo "results: $output/results.tsv"
exit "$failed"
