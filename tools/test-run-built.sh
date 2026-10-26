#!/usr/bin/env bash
# `ablac run` compiles the program in process with the --o1 IR pipeline (--fast:
# the fast one; --jit names the default) and calls it there; `run --built`
# builds the entry through the build cache and execs it. Either way the program
# gets its arguments, the caller's environment, working directory and standard
# input, and its exit status. A second --built run reuses the cached object,
# and --built --fast keeps a cache entry of its own.
set -euo pipefail
# (These checks read the default cache, build/.abla-cache under the working directory.)
unset ABLA_CACHE_DIR

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
# The checks count entries in the build cache (build/.abla-cache under the
# working directory), so the test runs in a directory of its own, named like
# the project, with copies of its two programs: no other build shares the cache.
work="$project_root/build/run-built-test/${project_root##*/}"
rm -rf -- "$work"
mkdir -p "$work/tests/cases/modules"
cp "$project_root/tests/cases/modules/run-built.ab" \
    "$project_root/tests/cases/modules/main-unannotated.ab" \
    "$work/tests/cases/modules/"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
cd "$work"
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
# In process: nothing is built.
check
check --fast
check --jit
[[ ! -e $executable ]] || exit 1
# Built and exec'd.
check --built
[[ -x $executable ]] || exit 1
before=$(entries inprocess-o1)
[[ -n $before ]] || exit 1
check --built
[[ $(entries inprocess-o1) == "$before" ]] || exit 1
check --built --fast
[[ -n $(entries inprocess-fast) ]] || exit 1
# Nothing staged is left behind.
[[ -z $(find build/.abla-run -name 'tests_cases_modules_run-built.ab.*') ]] || exit 1
# An unannotated main exits 0 either way.
"$compiler" run tests/cases/modules/main-unannotated.ab > /dev/null
"$compiler" run --built tests/cases/modules/main-unannotated.ab > /dev/null
echo "run: in process (--o1, --fast) and built (cached, exec'd), with arguments, environment, directory and input"
