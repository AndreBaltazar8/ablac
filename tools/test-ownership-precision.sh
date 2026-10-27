#!/usr/bin/env bash
# Places the ownership and null checks were stricter than their rules, each
# with the violation still refused:
# - a method that mutates its receiver only through an element of an array
#   field is a mutating method (a read-only caller is refused);
# - a branch ending in a call of type `never` narrows what follows its `if`
#   (a call that returns, an overload that returns, or a local named like a
#   `never` function doesn't);
# - a method that builds its result is fresh on a local read as a function's
#   last expression and on an element (a method returning its receiver,
#   reached from a parameter, is still a view of it);
# - an entry of a global Map, also through `?? panic(…)`, and a
#   `borrow(name)` result of a global argument are rooted in the global (an
#   entry of a parameter's Map needs `borrow(name)`, which the help names);
# - a method returning a nullable field is a view of its receiver, like one
#   returning a non-null field, and a view of a global is held in a local
#   like a read of the global (a view of a local still conflicts with
#   changing it, and can't be held in a `var`).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/ownership-precision"
output_directory="$project_root/build/ownership-precision"
rm -rf "$output_directory"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}

runs() { # $1 = case, $2 = the output it must print (exit 42)
    "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache
    set +e
    output=$("$output_directory/$1")
    status=$?
    set -e
    [[ $status == 42 && $output == "$2" ]] ||
        { echo "ownership-precision: $1 exited $status and printed:"; echo "$output"; exit 1; }
    # The same at compile time and in the JIT.
    set +e
    output=$("$compiler" run "$cases/$1.ab")
    status=$?
    set -e
    [[ $status == 42 && $output == "$2" ]] ||
        { echo "ownership-precision: run $1 exited $status and printed:"; echo "$output"; exit 1; }
}

rejected() { # $1 = case, $2 = how many errors, then the texts its diagnostics must contain
    local case=$1 count=$2; shift 2
    if "$compiler" build "$cases/$case.ab" -o "$output_directory/invalid" --no-cache \
        > "$output_directory/$case.err" 2>&1; then
        echo "ownership-precision: $case compiled"; exit 1
    fi
    [[ $(grep -c '^error' "$output_directory/$case.err") == "$count" ]] ||
        { echo "ownership-precision: $case should have $count errors"; cat "$output_directory/$case.err"; exit 1; }
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/$case.err" ||
            { echo "ownership-precision: $case lacks '$text'"; cat "$output_directory/$case.err"; exit 1; }
    done
}

runs element "2 4 1 12"
rejected element-refused 1 "ownership.mutable-borrow:receiver.Geometry.clearFirst"
runs never "4 7"
rejected never-refused 3 "method.unknown:nullable:Mesh.add"
runs fresh "2321 2321"
rejected fresh-refused 2 "ownership.borrow-escape:function.viewAsTail" \
    "ownership.borrow-escape:return"
runs rooted "1 2 3"
rejected rooted-refused 2 "ownership.managed-return-borrow-contract:function.cached:cache" \
    'help: the result is a view of `cache`: declare it so, `: borrow(cache) Item`' \
    "ownership.managed-return-borrow-contract:function.orOther:other"
runs getter "0 1 2 3 4 5"
rejected getter-refused 1 '`holder` is changed while `account`, which borrows it'
rejected getter-mutable 1 "ownership.borrow-mutable-local:account"

echo "ownership precision: ok"
