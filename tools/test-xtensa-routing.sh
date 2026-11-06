#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
    echo 'usage: test-xtensa-routing.sh COMPILER' >&2
    exit 2
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -z ${ABLA_XTENSA_LLVM_ROOT:-} ]]; then
    echo 'Xtensa routing skipped: no optional cohort configured (the manual stock-parent CI gate installs one)'
    exit 0
fi
python3 "$root/tools/test-xtensa-routing.py" "$1"
