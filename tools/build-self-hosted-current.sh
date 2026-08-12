#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'usage: %s <compiler> <output> [entry]\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output=$2
entry=${3:-src/orc_main.ab}
temporary_directory=$(mktemp -d "$project_root/build/.value-abi-bridge.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

probe="$temporary_directory/probe.ll"
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$compiler" --emit-llvm "$project_root/tools/value-abi-probe.ab" > "$probe"

source_abi=24
if grep -Fq '%AblaPayload = type { i64, i64, i64, i64 }' "$probe"; then
    source_abi=40
elif grep -Fq '%AblaPayload = type { i64, i64, i64 }' "$probe"; then
    source_abi=32
fi

if [[ $source_abi != 24 ]]; then
    bridge="$temporary_directory/compiler-abi$source_abi"
    printf '[abla-release] crossing value ABI %s -> 24\n' "$source_abi" >&2
    ABLA_RELEASE_VALUE_ABI=$source_abi \
        "$project_root/tools/build-self-hosted-release.sh" \
        "$compiler" "$bridge" "$entry"
    "$project_root/tools/build-self-hosted-release.sh" \
        "$bridge" "$output" "$entry"
else
    "$project_root/tools/build-self-hosted-release.sh" \
        "$compiler" "$output" "$entry"
fi
