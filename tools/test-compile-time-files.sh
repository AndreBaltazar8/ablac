#!/usr/bin/env bash
# Under `#`, file writes, directories, moves and removals are staged and
# published only when the build succeeds; compile-time code sees the disk with
# the staging laid over it, so the same operations agree at run time and under
# `#`, and a failed build leaves the disk as it was. Both tiers: the native
# tier (jit) leaves a site that reaches a capability provider to the evaluator,
# which stages and journals it.
set -euo pipefail

compiler=${1:-build/ablac.bin}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/compile-time-files"
work="$project_root/build/compile-time-files-test"
rm -rf "$work"
mkdir -p "$work"
cp "$cases"/*.ab "$cases/abla.toml" "$work/"
cd "$work"

for mode in interp jit; do
    export ABLA_COMPILE_EVAL=$mode
    rm -rf build/compile-time-files

    "$compiler" build view.ab -o view --no-cache
    output=$(./view)
    runtime=$(sed -n 1p <<<"$output")
    staged=$(sed -n 2p <<<"$output")
    expected='true true true true true 2 true true true one two false:2 true true false'
    [[ $runtime == "$expected" && $staged == "$expected" ]] || {
        echo "compile-time files ($mode): run time and \`#\` disagree:"; echo "$output"; exit 1
    }
    [[ ! -e build/compile-time-files/view ]] || {
        echo "compile-time files ($mode): the view case left files behind"; exit 1
    }

    mkdir -p build/compile-time-files/publish build/compile-time-files/failed
    printf 'old' > build/compile-time-files/publish/old.txt
    printf 'gone' > build/compile-time-files/publish/gone.txt
    printf 'kept' > build/compile-time-files/failed/old.txt
    "$compiler" build publish.ab -o publish --no-cache
    ./publish && status=0 || status=$?
    [[ $status -eq 4 ]] || { echo "compile-time files ($mode): publish staged $status of 4"; exit 1; }
    [[ $(cat build/compile-time-files/publish/written.txt) == written ]]
    [[ -d build/compile-time-files/publish/made ]]
    [[ ! -e build/compile-time-files/publish/old.txt ]]
    [[ $(cat build/compile-time-files/publish/moved.txt) == old ]]
    [[ ! -e build/compile-time-files/publish/gone.txt ]]

    # A build failing in analysis, and one failing after its staging ran.
    for failing in publish-failed late-fail; do
        printf 'kept' > build/compile-time-files/failed/old.txt
        if ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build $failing.ab -o failed --no-cache \
            > $failing.err 2>&1; then
            echo "compile-time files ($mode): $failing built"; exit 1
        fi
        [[ ! -e build/compile-time-files/failed/written.txt ]] || {
            echo "compile-time files ($mode): the failed $failing build wrote to the disk"; exit 1
        }
        [[ $(cat build/compile-time-files/failed/old.txt) == kept ]] || {
            echo "compile-time files ($mode): the failed $failing build removed a file"; exit 1
        }
    done
    if [[ $mode == jit ]]; then
        grep -q 'interpreted at .*: reaches provider Path\.' late-fail.err || {
            echo "compile-time files: the provider site ran natively"; cat late-fail.err; exit 1
        }
    fi

    # A file read under `#` is journaled: a cached build sees it change.
    printf 'first' > build/compile-time-files/input.txt
    "$compiler" build read-input.ab -o read-input
    [[ $(./read-input) == first ]]
    printf 'second' > build/compile-time-files/input.txt
    "$compiler" build read-input.ab -o read-input
    [[ $(./read-input) == second ]] || {
        echo "compile-time files ($mode): a cached build missed a changed input"; exit 1
    }
done
echo "compile-time files: staged writes, moves and removals agree with run time and publish on success, in both tiers"
