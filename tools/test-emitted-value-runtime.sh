#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/emitted-value-runtime-test"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/bootstrap/string-rope-small.ab" \
    -o "$output_directory/nested-string"
"$compiler" build \
    "$project_root/tests/cases/modules/strings-runtime.ab" \
    -o "$output_directory/string-runtime"
# (--sidecar: the packaged object is checked below.)
"$compiler" build \
    "$project_root/tests/cases/bootstrap/emitted-value-runtime.ab" \
    -o "$output_directory/value-runtime" --sidecar

for executable in nested-string string-runtime value-runtime; do
    set +e
    ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
        "$project_root/tools/run-limited.sh" "$output_directory/$executable"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        echo "$executable: expected 42, got $status" >&2
        exit 1
    fi
done

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/vm.ab" \
    > "$output_directory/runtime.ll"

# The value runtime is Abla compiled into each module: every function of it
# is defined there once, internal, and never left for another object to
# supply (the packaging is test-native-platform-boundary.sh's).
ir=$output_directory/runtime.ll
for function in abla_string_concat abla_to_string abla_equal abla_string_data; do
    definitions=$(rg -c "^define .*@${function}\\(" "$ir" || true)
    internal=$(rg -c "^define internal .*@${function}\\(" "$ir" || true)
    declarations=$(rg -c "^declare .*@${function}\\(" "$ir" || true)
    if [[ $definitions != 1 || $internal != 1 || -n $declarations ]]; then
        echo "generated LLVM: $function is not one internal definition" >&2
        exit 1
    fi
done
[[ -s $output_directory/value-runtime.o ]] || exit 1
[[ ! -e $output_directory/value-runtime.value-runtime.o ]] || exit 1

echo "portable value runtime: strings, ropes, formatting, equality, and one internal implementation per module"
