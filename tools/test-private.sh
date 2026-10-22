#!/usr/bin/env bash
# `private` top-level declarations: visible only in their module, so two
# modules' private names never clash; `#` code and a transform's generated
# members see their module's private names; the compiler API finds them; and
# using one from another module (directly, through an alias, or as an
# extension member) is reported.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/private"
output_directory="$project_root/build/private"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/main.ab" \
        -o "$output_directory/main-$mode" --no-cache
    set +e
    output=$("$output_directory/main-$mode")
    status=$?
    set -e
    [[ $status == 42 ]] || { echo "private: main ($mode) exited with $status"; exit 1; }
    [[ $output == "hello 6 101 9 42 true hello 6" ]] ||
        { echo "private: main ($mode) printed:"; echo "$output"; exit 1; }
done

rejected() { # $1 = case, then the texts its diagnostics must contain
    local name=$1; shift
    if "$compiler" build "$cases/$name.ab" -o "$output_directory/invalid" \
        --no-cache > "$output_directory/$name.err" 2>&1; then
        echo "private: $name compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/$name.err" ||
            { echo "private: $name lacks '$text'"; cat "$output_directory/$name.err"; exit 1; }
    done
}
rejected use-function 'name.private:helper:' 'use-function.ab:3:17'
rejected use-class 'name.private:Node:'
rejected use-alias 'E_NAME_PRIVATE' '`helper` is private to'
rejected use-extension 'name.private:Point.secret:'
rejected use-field 'name.private:Point.tag:'
rejected export 'private.export:twice'
echo "private: module-only names, no clashes, # (both tiers), generated members, compiler API, diagnostics"
