#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
ir=$project_root/build/native-initialize-globals-test.ll

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/native-initialize-globals.ab" > "$ir"

boot_symbol=$(sed -n \
    's/^@firmware_boot = alias i64 (), ptr @\(abla_fn_[^ ]*_direct\)$/\1/p' \
    "$ir")
test -n "$boot_symbol"

boot_body=$(sed -n "/^define internal i64 @$boot_symbol(/,/^}/p" "$ir")
test "$(printf '%s\n' "$boot_body" |
    rg -c 'call void @abla_export_ensure_initialized\(\)')" -eq 1

rg -q '^@firmware_boot = alias i64 \(\), ptr @' "$ir"

printf '%s\n' 'explicit freestanding global initialization lowering passed'
