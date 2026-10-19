#!/usr/bin/env bash
# The runtime's address intrinsics and field-slot accessors are callable only
# from abla/runtime (and the compile-time support the compiler generates):
# a program's call, trusted or not, or its use of one as a function value is
# native.runtime-internal. A function value's id stays public.
set -euo pipefail

compiler=${1:-build/ablac.bin}
# The allowed cases build from inside the output directory: keep a relative
# compiler path pointing where it did.
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/runtime-internal"
output_directory="$project_root/build/runtime-internal"
mkdir -p "$output_directory"

if "$compiler" build "$cases/refused.ab" -o "$output_directory/refused" \
    --no-cache > "$output_directory/refused.err" 2>&1; then
    echo "runtime internal: refused.ab compiled"; exit 1
fi
for name in ablaRuntimeValueAddress ablaRuntimeValueWord0 __ablaRuntimeWord0 \
    __ablaRuntimeWord1 __ablaRuntimeObjectAddress __ablaRuntimeFieldAddressScan \
    __ablaRuntimeFieldAddress __ablaRuntimeFieldAddressIndexed \
    __ablaRuntimeCellAddress __ablaRuntimeArrayAddress ablaRuntimeLoadSlotI32 \
    ablaRuntimeLoadSlotI64 ablaRuntimeStoreSlotI32 ablaRuntimeStoreSlotI64; do
    grep -qF "error[E_SEMANTIC]: native.runtime-internal:$name" \
        "$output_directory/refused.err" ||
        { echo "runtime internal: $name not refused"; cat "$output_directory/refused.err"; exit 1; }
done
# The trusted call, the untrusted one and the function value.
[[ $(grep -c 'native.runtime-internal:ablaRuntimeValueWord0' \
    "$output_directory/refused.err") == 2 ]] ||
    { echo "runtime internal: an ablaRuntimeValueWord0 call not refused"; exit 1; }
[[ $(grep -c 'native.runtime-internal:__ablaRuntimeObjectAddress' \
    "$output_directory/refused.err") == 2 ]] ||
    { echo "runtime internal: the function value not refused"; exit 1; }
grep -qF 'help: this intrinsic exposes the runtime' "$output_directory/refused.err" ||
    { echo "runtime internal: no help line"; exit 1; }

# A program can't declare one either: the runtime's name is taken (checked once
# the runtime declares the slot accessors).
if grep -q 'fun ablaRuntimeLoadSlotI32' \
    "${ABLA_STDLIB:-$project_root/stdlib}/abla/runtime/self/entry.ab"; then
    if "$compiler" build "$cases/declared-slot.ab" -o "$output_directory/declared-slot" \
        --no-cache > "$output_directory/declared-slot.err" 2>&1; then
        echo "runtime internal: declared-slot.ab compiled"; exit 1
    fi
    grep -qF 'symbol.duplicate:ablaRuntimeLoadSlotI32' "$output_directory/declared-slot.err" ||
        { echo "runtime internal: declared-slot.ab not a duplicate"; cat "$output_directory/declared-slot.err"; exit 1; }
fi

"$compiler" build "$cases/function-id.ab" -o "$output_directory/function-id" --no-cache
set +e
"$output_directory/function-id"
status=$?
set -e
[[ $status == 42 ]] || { echo "runtime internal: function-id exited with $status"; exit 1; }

# The runtime's own modules may call them, however the standard library's root
# is spelled: as copied, through a symlink, relative to the working directory.
fixture=$("$project_root/tools/runtime-fixture.sh" "$cases/allowed.ab" "$output_directory/allowed")
ln -sfn "$output_directory/allowed" "$output_directory/allowed-link"
allowed() { # $1 = label, $2 = standard library root, $3 = program
    (cd "$output_directory" && ABLA_STDLIB="$2" "$compiler" build "$3" \
        -o "$output_directory/allowed-program-$1" --no-cache) ||
        { echo "runtime internal: allowed ($1) refused"; exit 1; }
    set +e
    "$output_directory/allowed-program-$1"
    local status=$?
    set -e
    [[ $status == 42 ]] || { echo "runtime internal: allowed ($1) exited with $status"; exit 1; }
}
allowed copy "$output_directory/allowed/stdlib" "$fixture"
allowed link "$output_directory/allowed-link/stdlib" "$output_directory/allowed-link/allowed.ab"
allowed relative allowed/stdlib allowed/allowed.ab
# A root written with `//`, `.` or `..` names the same modules.
allowed doubled "$output_directory/allowed//stdlib" "$fixture"
allowed dotted "$output_directory/allowed/./stdlib/" "$fixture"
allowed parent "$output_directory/allowed-link/../allowed/stdlib" "$fixture"

# A generated module named abla/runtime/… is the program's code.
refused_route() { # $1 = label, $2 = program
    if (cd "$output_directory" && ABLA_STDLIB="$output_directory/allowed/stdlib" \
        "$compiler" build "$2" -o "$output_directory/route-$1" --no-cache \
        > "$output_directory/route-$1.err" 2>&1); then
        echo "runtime internal: route $1 compiled"; exit 1
    fi
    grep -qF 'native.runtime-internal:' "$output_directory/route-$1.err" ||
        { echo "runtime internal: route $1 not refused"; cat "$output_directory/route-$1.err"; exit 1; }
}
refused_route generated "$cases/generated-module.ab"
echo "runtime internal: address intrinsics and slot accessors refused outside abla/runtime; function ids public"
