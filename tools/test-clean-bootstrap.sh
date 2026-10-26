#!/usr/bin/env bash
# Clean bootstrap: the pinned release compiler (tools/bootstrap-compiler.sh)
# builds a stage-1 compiler from these sources, as `make ablac` does on a
# fresh clone, and that stage-1 builds and runs a program. Prints whether it
# passes, and the errors that stop it when it doesn't.
#
# Not part of `make test`: sources that use something newer than the pinned
# release can't be built by it until the pin moves. ABLA_BOOTSTRAP_URL and
# ABLA_BOOTSTRAP_SHA256 try a candidate release instead.
#
#     tools/test-clean-bootstrap.sh [directory]    (default build/clean-bootstrap)
set -uo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
directory=${1:-$project_root/build/clean-bootstrap}
mkdir -p -- "$directory"
directory=$(cd -- "$directory" && pwd)
version=$(sed -n 's/^version=//p' "$project_root/tools/bootstrap-compiler.sh")
if [[ -n ${ABLA_BOOTSTRAP_URL:-} ]]; then version="candidate ${ABLA_BOOTSTRAP_URL##*/}"; fi

report() {
    printf 'clean bootstrap (%s): %s\n' "$version" "$1"
}

if ! "$project_root/tools/bootstrap-compiler.sh" "$directory/bootstrap.bin" \
    > "$directory/fetch.log" 2>&1; then
    report "FAIL: the pinned compiler couldn't be fetched"
    tail -3 "$directory/fetch.log"
    exit 1
fi

if ! "$project_root/tools/build-self-hosted-current.sh" "$directory/bootstrap.bin" \
    "$directory/stage1" > "$directory/build.log" 2>&1; then
    report "FAIL: it can't build the compiler from these sources ($(grep -c '^error' "$directory/build.log") errors, log: $directory/build.log)"
    # Each kind of error, most frequent first, with its first instance.
    grep -oE '^error\[[A-Z_]+\]' "$directory/build.log" | sort | uniq -c | sort -rn | head -5 |
        while read -r count kind; do
            printf '%6d %s\n' "$count" "$kind"
            grep -m1 -F -A2 -- "$kind" "$directory/build.log" | sed 's/^/         /'
        done
    exit 1
fi

printf 'import "abla/io"\n\nfun main: int {\n    println("clean bootstrap")\n    42\n}\n' \
    > "$directory/probe.ab"
if ! (cd "$project_root" && ABLA_SYSROOT=$project_root \
    ABLA_COMPILER_PAYLOAD=$directory/stage1 "$project_root/tools/run-limited-compiler.sh" \
    build "$directory/probe.ab" -o "$directory/probe" --no-cache) \
    > "$directory/probe.log" 2>&1; then
    report "FAIL: the stage-1 compiler can't build a program (log: $directory/probe.log)"
    tail -5 "$directory/probe.log"
    exit 1
fi
output=$("$directory/probe")
status=$?
if [[ $status != 42 || $output != "clean bootstrap" ]]; then
    report "FAIL: the stage-1 compiler's program exited $status, printing: $output"
    exit 1
fi
report "pass: it builds a stage-1 compiler from these sources, which builds and runs a program"
