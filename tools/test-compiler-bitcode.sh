#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$project_root"
output="$project_root/build/compiler-bitcode"
mkdir -p "$output"
program=$("$project_root/tools/compiler-api-test-program.sh" "$compiler")
ABLA_COMPILER_API_CASE=prune "$program" tests/cases/compiler-bitcode/prune.ll "$output/text.ll" "$output/direct.bc"
llvm-as "$output/text.ll" -o "$output/text.bc"
# ModuleID is a display-only input filename assigned by llvm-dis.
llvm-dis "$output/text.bc" -o - | tail -n +2 > "$output/text.normalized.ll"
llvm-dis "$output/direct.bc" -o - | tail -n +2 > "$output/direct.normalized.ll"
cmp "$output/text.normalized.ll" "$output/direct.normalized.ll"
! grep -q 'define .*@abla_fn_dead\|define .*@dead_helper' "$output/direct.normalized.ll"
echo 'compiler bitcode: direct pruning matches text for calls, globals, aliases, literal names, assembly and dead recursive functions'
