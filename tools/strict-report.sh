#!/usr/bin/env bash
# The compiler's own sources against strict imports: builds src/orc_main.ab
# with --visibility-report (a fast build, kept nowhere) and prints how many
# names its modules use from modules they don't import. src/ is a flat
# package until src/abla.toml makes it strict (docs/bootstrap.md); the count
# must stay 0 until then, or making it strict fails. Exits 0 when it is, 1
# when there are findings (the modules, and the first few), 2 when the build
# itself fails. A report, not a test: it isn't part of `make test`.
#
#     tools/strict-report.sh [compiler] [directory]    (build/ablac, build/strict-report)
set -uo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
directory=${2:-$project_root/build/strict-report}
mkdir -p -- "$directory"
report="$directory/report.tsv"
rm -f -- "$report"

if ! (cd "$project_root" && "$compiler" build src/orc_main.ab -o "$directory/ablac" \
    --fast --no-cache --visibility-report "$report") > "$directory/build.log" 2>&1; then
    echo "strict report: the compiler didn't build (log: $directory/build.log)"
    grep -m3 -A2 '^error' "$directory/build.log"
    exit 2
fi
# The compiler's modules only: a strict library's findings are errors, not lines.
findings=$(awk -F'\t' '$1 ~ /(^|\/)src\//' "$report" 2>/dev/null)
count=$(printf '%s' "$findings" | grep -c . || true)
if [[ $count == 0 ]]; then
    echo "strict report: 0 names the compiler's modules use without importing them"
    exit 0
fi
modules=$(printf '%s\n' "$findings" | cut -f1 | sort -u | wc -l | tr -d ' ')
noun=modules; [[ $modules == 1 ]] && noun=module
echo "strict report: $count names in $modules compiler $noun are used without importing them (report: $report)"
printf '%s\n' "$findings" | cut -f1,6 | sort | uniq -c | sort -rn | head -10 |
    sed 's/^/  /'
echo "  apply: ablac run tools/fix-imports.ab -- $report"
exit 1
