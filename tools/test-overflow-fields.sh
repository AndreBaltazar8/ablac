#!/usr/bin/env bash
# Fields added by name to a class instance beyond its declared ones live in
# its overflow (stdlib/abla/runtime/self/entry.ab): they survive collections
# while it grows, natively when every safe point collects (ABLA_GC_STRESS=1)
# and in a WebAssembly module. Declared fields keep their inline slots. The
# class, field and resource programs give the same results with and without
# collection stress.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/overflow-fields"
mkdir -p "$output_directory"

run() { # program [environment...]
    local program=$1 status
    shift
    set +e
    env "$@" ABLA_MAX_SECONDS=120 "$project_root/tools/run-limited.sh" "$program" 2>&1
    status=$?
    set -e
    echo "status $status"
}

"$compiler" build "$project_root/tests/cases/overflow-fields/main.ab" \
    -o "$output_directory/overflow" --no-cache > "$output_directory/overflow.log" 2>&1 ||
    { cat "$output_directory/overflow.log" >&2; exit 1; }
for stress in 0 1; do
    output=$(run "$output_directory/overflow" ABLA_GC_STRESS=$stress)
    [[ $output == $'overflow fields: 0 failed\nstatus 42' ]] ||
        { echo "overflow fields (ABLA_GC_STRESS=$stress): $output" >&2; exit 1; }
done

# Built at compile time (natively: the interpreter doesn't run the runtime's raw
# memory) and lifted into the program with its overflow.
(cd "$project_root/tests/cases/overflow-fields/lift" && ABLA_COMPILE_EVAL=jit "$compiler" build \
    main.ab -o "$output_directory/lift" --no-cache > "$output_directory/lift.log" 2>&1) ||
    { cat "$output_directory/lift.log" >&2; exit 1; }
for stress in 0 1; do
    output=$(run "$output_directory/lift" ABLA_GC_STRESS=$stress)
    [[ $output == $'lifted 4 5 360 12\nstatus 42' ]] ||
        { echo "overflow fields, lifted (ABLA_GC_STRESS=$stress): $output" >&2; exit 1; }
done

if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
(cd "$project_root" && "$compiler" build tests/cases/overflow-fields/build.ab \
    -o "$output_directory/wasm-driver" --no-cache > "$output_directory/wasm-driver.log" 2>&1) ||
    { cat "$output_directory/wasm-driver.log" >&2; exit 1; }
(cd "$project_root" && "$output_directory/wasm-driver")
wasm_output=$("$wasm_runner" "$project_root/tests/cases/overflow-fields/run.mjs" \
    "$output_directory/overflow-fields.wasm")
[[ $wasm_output == 0 ]] || { echo "overflow fields (WebAssembly): $wasm_output failed" >&2; exit 1; }

cases=(
    modules/classes modules/resource-drop modules/resource-structural-drop
    modules/map-resources modules/array-resource-drop-order
    field-places/main field-shadowing/main
)
for case in "${cases[@]}"; do
    name=${case//\//-}
    "$compiler" build "$project_root/tests/cases/$case.ab" \
        -o "$output_directory/$name" --no-cache > "$output_directory/$name.log" 2>&1 ||
        { cat "$output_directory/$name.log" >&2; exit 1; }
    plain=$(run "$output_directory/$name")
    stressed=$(run "$output_directory/$name" ABLA_GC_STRESS=1)
    if [[ $plain != "$stressed" ]]; then
        echo "overflow fields: $case differs under ABLA_GC_STRESS=1" >&2
        diff <(echo "$plain") <(echo "$stressed") >&2 || true
        exit 1
    fi
done
echo "overflow fields: fields added by name survive growth, collections and the compile-time lift (native, stressed, WebAssembly); declared fields stay inline; field programs agree under collection stress"
