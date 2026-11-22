#!/usr/bin/env bash
# Select argument promotion for a release build with branching class recursion.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || exit 0

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/recursive-argument-test"
source="$project_root/tests/cases/bootstrap/recursive-argument.ab"
mkdir -p "$out"
marker='!abla.recursive_class_argument = '

for profile in release text fast; do
    export ABLA_KEEP_LLVM_TEXT=0
    flags=()
    case $profile in
        text) export ABLA_KEEP_LLVM_TEXT=1 ;;
        fast) export ABLA_KEEP_LLVM_TEXT=1; flags=(--fast) ;;
    esac
    "$compiler" build "$source" --no-cache -o "$out/$profile" "${flags[@]}"
    if [[ $profile == text ]]; then
        grep -qF "$marker" "$out/$profile.ll"
    elif [[ $profile == fast ]]; then
        test -s "$out/$profile.ll"
        if grep -qF "$marker" "$out/$profile.ll"; then
            echo "recursive argument: fast build requested release argument promotion" >&2
            exit 1
        fi
    fi
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$out/$profile" || status=$?
        [[ $status == 42 ]] || { echo "recursive argument: $profile/$stress exited $status" >&2; exit 1; }
    done
done
echo "recursive argument: release and fast traversal agree, including under GC stress"
