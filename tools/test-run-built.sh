#!/usr/bin/env bash
# `ablac run` builds the entry through the build cache (--o1 unless told
# otherwise) and execs it: the program gets its arguments, the caller's
# environment, working directory and standard input, and its exit status. A
# second run reuses the cached object, --fast keeps a cache entry of its own,
# and --jit (compiled in process) runs the same program.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
source=tests/cases/modules/run-built.ab
executable=build/.abla-run/tests_cases_modules_run-built.ab
expected=$'argument a\nargument b c\nenvironment probe\ndirectory '"${project_root##*/}"$'\ninput line'

check() {
    set +e
    output=$(printf 'line\n' |
        ABLA_RUN_PROBE=probe "$compiler" run "$@" "$source" -- a "b c")
    status=$?
    set -e
    [[ $status -eq 42 && $output == "$expected" ]] || {
        printf 'run %s: exit %s, output:\n%s\n' "$*" "$status" "$output" >&2
        exit 1
    }
}

entries() {
    find build/.abla-cache -name "*-$1-*.inputs" 2>/dev/null | sort
}

rm -f "$executable"
check
[[ -x $executable ]] || exit 1
before=$(entries inprocess-o1)
[[ -n $before ]] || exit 1
check
[[ $(entries inprocess-o1) == "$before" ]] || exit 1
check --fast
[[ -n $(entries inprocess-fast) ]] || exit 1
check --jit
# Nothing staged is left behind.
[[ -z $(find build/.abla-run -name 'tests_cases_modules_run-built.ab.*') ]] || exit 1
# An unannotated main exits 0 through run as well.
"$compiler" run tests/cases/modules/main-unannotated.ab > /dev/null
echo "run built: cached build, exec'd with arguments, environment, directory and input"
