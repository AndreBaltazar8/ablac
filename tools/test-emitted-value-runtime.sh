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
"$compiler" build \
    "$project_root/tests/cases/bootstrap/emitted-value-runtime.ab" \
    -o "$output_directory/value-runtime"

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

legacy='abla_(as_cstring|divide|equal|not_equal|to_string|string_data|array_|object_|cell_|closure|string_(static|concat|length|get|slice))'
if rg -q "^define .*@${legacy}" "$output_directory/runtime.ll"; then
    echo "generated LLVM duplicated the portable value runtime" >&2
    rg "^define .*@${legacy}" "$output_directory/runtime.ll" >&2
    exit 1
fi
rg -q '^declare .*@abla_string_concat' "$output_directory/runtime.ll"
rg -q '^declare .*@abla_to_string' "$output_directory/runtime.ll"
rg -q '^declare .*@abla_equal' "$output_directory/runtime.ll"
[[ -s $output_directory/value-runtime.o ]]
[[ ! -e $output_directory/value-runtime.value-runtime.o ]]
[[ ! -e $output_directory/value-runtime.host.o ]]
nm --defined-only "$output_directory/value-runtime.o" |
    rg ' [Tt] abla_string_data$' >/dev/null

echo "portable value runtime: strings, ropes, formatting, equality, and one linked implementation"
