#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac0}
c_compiler=${CC:-cc}
output_directory=build/native-tests
mkdir -p "$output_directory"

compile_and_expect() {
    local fixture=$1
    local expected=$2
    local memory_mb=${3:-256}
    local generated="$output_directory/$fixture.c"
    local repeated="$output_directory/$fixture.repeated.c"
    local executable="$output_directory/$fixture"

    "$compiler" emit-c "tests/cases/modules/$fixture.ab" > "$generated"
    "$compiler" emit-c "tests/cases/modules/$fixture.ab" > "$repeated"
    cmp "$generated" "$repeated"

    "$c_compiler" \
        -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
        -Iruntime \
        "$generated" runtime/abla_runtime.c runtime/abla_runtime_host.c \
        -o "$executable"

    set +e
    ABLA_MAX_MEMORY_MB=$memory_mb ABLA_MAX_SECONDS=30 \
        tools/run-limited.sh "$executable"
    local actual=$?
    set -e
    if [[ $actual -ne $expected ]]; then
        echo "$fixture: expected exit $expected, got $actual" >&2
        return 1
    fi
    echo "$fixture: VM/native result $actual"
}

compile_and_expect vm 135
compile_and_expect types-valid 7
compile_and_expect compile-time 40
compile_and_expect compile-compound 35
compile_and_expect compile-shared 42
compile_and_expect compiler-reflection 42
compile_and_expect collections 42
compile_and_expect json-subparser 42
compile_and_expect html-subparser 42
compile_and_expect abla-subparser 42
compile_and_expect abla-subparser-import 42
compile_and_expect abla-subparser-builder 42
compile_and_expect bootstrap-lexer 42
compile_and_expect bootstrap-parser 42
compile_and_expect bootstrap-sema 42
compile_and_expect return-control 42
compile_and_expect return-when 42
compile_and_expect bootstrap-ir 42
compile_and_expect bootstrap-block 42
compile_and_expect bootstrap-collections 42
compile_and_expect bootstrap-objects 42
compile_and_expect classes 42
compile_and_expect stdlib 11
compile_and_expect strings-runtime 42
compile_and_expect string-rope 42 64
compile_and_expect host-runtime 42
compile_and_expect filesystem 42
compile_and_expect process-capture 42
compile_and_expect memory-region 42
compile_and_expect bytes 42
compile_and_expect http-router 42

native_generated="$output_directory/native-c.c"
native_executable="$output_directory/native-c"
"$compiler" emit-c tests/cases/modules/native-c.ab > "$native_generated"
"$c_compiler" \
    -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -Iruntime \
    "$native_generated" tests/native/native_test.c \
    runtime/abla_runtime.c runtime/abla_runtime_host.c \
    -o "$native_executable"
set +e
ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=30 \
    tools/run-limited.sh "$native_executable"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "native-c: expected exit 42, got $native_status" >&2
    exit 1
fi
echo "native-c: explicit C ABI adapter result $native_status"
