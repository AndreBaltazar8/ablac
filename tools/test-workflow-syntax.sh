#!/usr/bin/env bash
# Every GitHub workflow parses as YAML (.github/workflows/*.yml and *.yaml). An invalid one runs no job at all, and GitHub
# reports it only on the run's page: on 2673261d a step name holding ": " unquoted left ci.yml unparsed (fixed in
# 472a8b68). The control, tests/cases/workflow-syntax/bad-step-name.yml (that line), must be refused at its column.
# Usage: tools/test-workflow-syntax.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/workflow-syntax
mkdir -p "$out"
cd "$root"
"$compiler" build tests/cases/workflow-syntax/check.ab --fast -o "$out/check" > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
control=tests/cases/workflow-syntax/bad-step-name.yml
status=0
"$out/check" "$control" > "$out/control.log" 2>&1 || status=$?
if [[ $status -ne 1 ]] || ! grep -q "^$control: line 8, column " "$out/control.log"; then
    echo "workflow syntax: the control was not refused at its line (exit $status):" >&2
    cat "$out/control.log" >&2
    exit 1
fi
shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
[[ ${#workflows[@]} -gt 0 ]] || { echo 'workflow syntax: no workflow found' >&2; exit 1; }
if ! "$out/check" "${workflows[@]}" > "$out/workflows.log" 2>&1; then
    echo 'workflow syntax: a workflow is not valid YAML (GitHub would run none of its jobs):' >&2
    cat "$out/workflows.log" >&2
    exit 1
fi
echo "workflow syntax: ${#workflows[@]} workflows parse; the control is refused"
