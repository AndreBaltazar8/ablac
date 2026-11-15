#!/usr/bin/env bash
# No tracked file may be a Python script or call the interpreter: there is no baseline to shrink.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
found=$(bash tools/repo-language-inventory.sh | sort -u)
if [[ -n $found ]]; then
    printf 'language guard: interpreter files or calls are not allowed (#807):\n%s\n' "$found" >&2
    exit 1
fi
printf 'language guard: no tracked interpreter files or calls\n'
