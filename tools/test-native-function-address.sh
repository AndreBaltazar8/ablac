#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
program=$project_root/build/native-function-address-test

"$compiler" build \
    "$project_root/tests/cases/modules/native-function-address.ab" \
    -o "$program" --fast
set +e
"$program"
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
for form in old narrow; do
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
echo 'native function address imports: old/narrow paths, re-export and strict visibility diagnostics'
