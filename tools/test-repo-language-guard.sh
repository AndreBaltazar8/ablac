#!/usr/bin/env bash
# The checked-in baseline may shrink; any newly tracked use fails.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
allow=tools/legacy-py-allowlist.txt
[[ -f $allow ]] || { echo "language guard: missing $allow" >&2; exit 1; }
if ! sort -cu "$allow"; then
    echo "language guard: $allow must be sorted and unique" >&2
    exit 1
fi
actual=$(mktemp "${TMPDIR:-/tmp}/abla-lang-actual.XXXXXXXX")
trap 'rm -f "$actual"' EXIT
bash tools/repo-language-inventory.sh | sort -u >"$actual"
unexpected=$(comm -23 "$actual" "$allow")
if [[ -n $unexpected ]]; then
    printf 'language guard: new interpreter files or calls are not allowed:\n%s\n' "$unexpected" >&2
    exit 1
fi
printf 'language guard: tracked interpreter inventory is within the baseline\n'
