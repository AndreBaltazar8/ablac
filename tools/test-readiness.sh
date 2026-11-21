#!/usr/bin/env bash
# Evidence parsing and missing-data controls; no compiler or network required.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work=$(mktemp -d "${TMPDIR:-/tmp}/readiness-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/data"
generate() { tools/readiness.sh --out "$work/report.md" --data "$work/data" --fuzz-notes "$work/absent" >/dev/null; }
has() { grep -F -- "$1" "$work/report.md" >/dev/null; }
generate
has 'Missing: release-note archive'
has 'Missing: structured campaign totals'
has '| Runtime / RSS / compile time / size | Missing |'
has '### `.github/workflows/ci.yml`'
has 'runner: macos-15-intel'
[[ $(grep -c '^## ' "$work/report.md") == 8 ]]
cat > "$work/data/releases.json" <<'JSON'
[
 {"tag_name":"v1.0.0","body":"## Migration\n- One\n  - Nested detail\n### Details\n- Two\n## Features\n- Not a break"},
 {"tag_name":"v1.0.1","body":"## Migration\nNothing to migrate."},
 {"tag_name":"v1.0.2","body":"## Features\n- One"},
 {"tag_name":"v2.0.0","body":"## Breaking changes\n1. Change","draft":true}
]
JSON
cat > "$work/data/fuzz.json" <<'JSON'
[{"revision":"fuzz-revision","recordedAt":"recorded-time","command":"fuzz --seeds 1-4","agree":3,"disagree":1,"exitStatus":1}]
JSON
cat > "$work/data/coverage.json" <<'JSON'
{"schemaVersion":1,"modules":[],"totals":{"documented":3,"undocumented":1,"total":4}}
JSON
printf 'would print stage2 == stage3\n' > "$work/data/gate.log"
printf 'repository programs regressions unused xfail tests\nfixture 1/1 0 0 0/0 -\n' > "$work/data/siblings.txt"
generate
has '| v1.0.0 | 2 |'
has '| v1.0.1 | 0 |'
has '| v1.0.2 | Missing |'
! has '| v2.0.0 |'
has 'Agreeing seeds: 3; disagreeing seeds: 1; exit status: 1'
has '**3/4** (75%)'
has 'Fixed point: Missing'
has 'Gate completion: Missing (unfinished)'
has 'fixture 1/1 0 0 0/0 -'
printf 'stage2 == stage3 (bitcode)\n544 passed, 1 failed in 10s\nexit=1\n' > "$work/data/gate.log"
generate
has 'Fixed point: stage2 == stage3 (bitcode)'
has 'Suite: 544 passed, 1 failed'
has 'Gate completion: exit=1'
cp "$work/report.md" "$work/before.md"
printf '{malformed' > "$work/data/coverage.json"
if generate 2> "$work/error"; then echo 'readiness: malformed evidence accepted' >&2; exit 1; fi
cmp "$work/report.md" "$work/before.md"
printf '{"schemaVersion":1,"modules":[],"totals":{"documented":5,"undocumented":0,"total":4}}' > "$work/data/coverage.json"
if generate 2> "$work/error"; then echo 'readiness: inconsistent coverage accepted' >&2; exit 1; fi
cmp "$work/report.md" "$work/before.md"
echo 'readiness: missing evidence, migration scope, failures, incomplete gates and atomic errors passed'
