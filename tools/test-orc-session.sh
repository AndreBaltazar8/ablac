#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
runner="$project_root/build/orc-session-runner"
first_ir="$project_root/build/orc-session-first.ll"
second_ir="$project_root/build/orc-session-second.ll"
source="$project_root/tests/cases/bootstrap/return-41.ab"

ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$compiler" build "$project_root/src/orc_session_runner.ab" \
    -o "$runner"
"$compiler" --emit-llvm "$source" > "$first_ir"
"$compiler" --emit-llvm "$source" | cat > "$first_ir.pipe"
cmp "$first_ir" "$first_ir.pipe"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/block.ab" > "$second_ir"

# Use the same dynamically linked compiler the ORC test runs. Inject the bad
# block immediately before verification, after construction of the module.
payload=${ABLA_COMPILER_PAYLOAD:-"${compiler}.bin"}
[[ -f $payload ]] || payload=$compiler
if [[ $(uname -s) == Linux ]] &&
    readelf --dyn-syms --wide "$payload" 2>/dev/null | grep -E 'UND +LLVMVerifyModule(@|$)' >/dev/null; then
    preload="$project_root/build/orc-session-verify-failure.so"
    clang -shared -fPIC "$project_root/tests/cases/orc-session/verify-failure.c" -o "$preload" -ldl
    status=0
    LD_PRELOAD="$preload" "$compiler" --emit-llvm "$source" >"$first_ir.rejected" 2>"$first_ir.diagnostics" ||
        status=$?
    [[ $status -eq 1 && ! -s $first_ir.rejected ]]
    grep -Fq "LLVM verifier: Basic Block in function 'main' does not have terminator!" "$first_ir.diagnostics"
    grep -Fq 'label %emit_llvm_injected_verify_failure' "$first_ir.diagnostics"
    grep -Fq 'error[E_IR_EMISSION]' "$first_ir.diagnostics"
fi

set +e
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" \
    "$runner" "$first_ir" "$second_ir"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

printf '%s\n' 'persistent ORC session: load 41 -> reclaim -> load 42'
