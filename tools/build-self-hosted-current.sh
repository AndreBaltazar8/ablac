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
"$project_root/tools/build-self-hosted-release.sh" \
    "$compiler" "$output" "$entry"
