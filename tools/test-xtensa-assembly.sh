#!/usr/bin/env bash
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
    echo 'SKIP Xtensa assembly differential: Python 3 is unavailable'
    exit 0
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 "$root/tools/test-xtensa-assembly.py" "${1:-$root/build/ablac}"
