#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}

actual=$($compiler --version)
if [[ $actual != "ablac 0.2.12" ]]; then
    printf 'unexpected compiler version: %s\n' "$actual" >&2
    exit 1
fi
printf '%s\n' 'compiler version: ablac 0.2.12'
