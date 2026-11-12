#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
program=$("$project_root/tools/compiler-api-test-program.sh" "$compiler")

set +e
ABLA_COMPILER_API_CASE=native-address "$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    exit 1
fi

echo 'Native function address lowering passed'

# Keep both the broad compatibility import and the narrow runtime import
# usable under strict visibility through the compatibility re-export.
imports_directory="$project_root/build/native-function-address-imports"
mkdir -p "$imports_directory"
cat > "$imports_directory/facade.ab" <<'ABLA'
export import "abla/unsafe/native"
fun exportedProbe(): i32 = i32(42)
ABLA
cat > "$imports_directory/ordinary.ab" <<'ABLA'
// This is an ordinary function, despite sharing an intrinsic's source name.
fun nativeFunctionAddress(function: any): int = 42
ABLA
for form in old narrow old-alias narrow-alias re-export re-export-alias ordinary-alias; do
    source_file="$imports_directory/$form.ab"
    case $form in
        old)
            imported='import "abla/unsafe/native"'
            address='nativeFunctionAddress(probe)'
            result='callNativeI32Zero(address) == 42'
            ;;
        narrow)
            imported='import "abla/unsafe/native/function-address"'
            address='nativeFunctionAddress(probe)'
            result='address != 0'
            ;;
        old-alias)
            imported='import "abla/unsafe/native" as native'
            address='native.nativeFunctionAddress(probe)'
            result='native.callNativeI32Zero(address) == 42'
            ;;
        narrow-alias)
            imported='import "abla/unsafe/native/function-address" as addressApi
import "abla/unsafe/native"'
            address='addressApi.nativeFunctionAddress(probe)'
            result='callNativeI32Zero(address) == 42'
            ;;
        re-export)
            imported='import "facade.ab"'
            address='nativeFunctionAddress(exportedProbe)'
            result='callNativeI32Zero(address) == 42'
            ;;
        re-export-alias)
            imported='import "facade.ab" as facade'
            address='facade.nativeFunctionAddress(facade.exportedProbe)'
            result='facade.callNativeI32Zero(address) == 42'
            ;;
        ordinary-alias)
            imported='import "ordinary.ab" as ordinary'
            address='ordinary.nativeFunctionAddress(probe)'
            result='address == 42'
            ;;
    esac
    cat > "$source_file" <<EOF
$imported
fun probe(): i32 = i32(42)
trusted fun main: int {
    val address = $address
    if ($result) 42 else 1
}
EOF
    "$compiler" build "$source_file" -o "$imports_directory/program" \
        --fast --strict-imports --no-cache
    status=0
    "$imports_directory/program" || status=$?
    [[ $status == 42 ]] || { echo "native function address imports: $form exited $status" >&2; exit 1; }
done
# Qualification must preserve the intrinsic's checked operand contract too.
for invalid in managed local-alias; do
    if [[ $invalid == managed ]]; then
        target='fun probe(value: string): int = value.size'
        argument=probe
        setup=''
    else
        target='fun probe(): i32 = i32(42)'
        argument=alias
        setup='val alias = probe'
    fi
    cat > "$imports_directory/invalid-$invalid.ab" <<EOF
import "abla/unsafe/native/function-address" as addressApi
$target
trusted fun main: int {
    $setup
    addressApi.nativeFunctionAddress($argument)
}
EOF
    if "$compiler" --emit-llvm "$imports_directory/invalid-$invalid.ab" \
        > "$imports_directory/invalid-$invalid.ll" \
        2> "$imports_directory/invalid-$invalid.log"; then
        echo "native function address imports: accepted invalid $invalid operand" >&2
        exit 1
    fi
    grep -qF 'error[E_IR_EMISSION]' "$imports_directory/invalid-$invalid.log"
done
cat > "$imports_directory/missing.ab" <<'ABLA'
fun probe(): i32 = i32(42)
fun main: int = if (nativeFunctionAddress(probe) != 0) 42 else 1
ABLA
if "$compiler" build "$imports_directory/missing.ab" -o "$imports_directory/missing" \
    --fast --strict-imports --visibility-report "$imports_directory/missing.tsv" \
    --no-cache > "$imports_directory/missing.log" 2>&1; then
    echo 'native function address imports: strict code without the import was accepted' >&2
    exit 1
fi
grep -qF 'error[E_NAME_NOT_IMPORTED]' "$imports_directory/missing.log"
grep -qF 'nativeFunctionAddress' "$imports_directory/missing.log"
grep -qF 'abla/unsafe/native/function-address' "$imports_directory/missing.log"
grep -qF 'nativeFunctionAddress' "$imports_directory/missing.tsv"
grep -qF 'abla/unsafe/native/function-address' "$imports_directory/missing.tsv"
echo 'native function address imports: old/narrow paths, aliases, re-exports and strict visibility diagnostics'
