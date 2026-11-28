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
has '| Linux x86-64 | T1 |'
has '| Linux AArch64 | T2 |'
has '| Windows x86-64 | T2 |'
! has 'Published v0.2.64 assets'
has 'Missing: saved CI run outcomes'
has 'Missing: published asset snapshot'
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
[{"revision":"fuzz-revision","recordedAt":"recorded-time","command":"fuzz --seeds 1-4","agree":3,"disagree":1,"exitStatus":1},
 {"id":"7","revision":"recorded-revision","revisionDirty":true,"recordedAt":"t2","command":"tools/fuzz/run --seeds 5-9 --record x","compiler":"/c","compilerSha256":"abc123","compilerVersion":"ablac 9.9.9","campaign":"default","families":["plain_check","json_check"],"checksPerSeed":24,"plannedSeeds":"5-9","seeds":"5-7","seedCount":3,"modes":["fast","release"],"agree":2,"disagree":1,"disagreeingSeeds":[6],"finishedAt":null,"exitStatus":124,"complete":false}]
JSON
cat > "$work/data/coverage.json" <<'JSON'
{"schemaVersion":1,"modules":[],"totals":{"documented":3,"undocumented":1,"total":4}}
JSON
printf 'would print stage2 == stage3\n' > "$work/data/gate.log"
printf 'repository programs regressions unused xfail tests\nfixture 1/1 0 0 0/0 -\n' > "$work/data/siblings.txt"
printf 'sample site\tv1.0.0\tverified endpoint\t2026-11-23\n' > "$work/data/deployments.tsv"
revision=$(git rev-parse HEAD)
jq -n --arg revision "$revision" '{
    headSha: $revision, url: "https://example.test/run", status: "completed", conclusion: "success",
    jobs: [
        {name: "Linux suite", status: "completed", conclusion: "success"},
        {name: "Optional board", status: "completed", conclusion: "skipped"}
    ]
}' > "$work/data/ci.json"
generate
has '| v1.0.0 | 2 |'
has '| v1.0.1 | 0 |'
has '| v1.0.2 | Missing |'
! has '| v2.0.0 |'
has 'Agreeing seeds: 3; disagreeing seeds: 1; exit status: 1'
has 'Revision: recorded-revision (checkout had changes)'
has 'Campaign: default; seeds run 5-7 (3; planned 5-9), 24 checks each'
has 'Modes: fast, release'
has 'Families: 2 (plain_check, json_check)'
has 'Compiler: ablac 9.9.9, SHA-256 abc123'
has 'Agreeing seeds: 2; disagreeing seeds: 1 (6); exit status: 124 (not finished)'
has '**3/4** (75%)'
has 'Fixed point: Missing'
has 'Gate completion: Missing (unfinished)'
has 'fixture 1/1 0 0 0/0 -'
has '| sample site | v1.0.0 | verified endpoint | 2026-11-23 |'
has 'Hosted CI for this revision: [run](https://example.test/run) · completed / success'
has 'Optional board · completed / skipped'
! has 'Missing: saved CI run outcomes'
jq '.headSha = "different-revision"' "$work/data/ci.json" > "$work/other-ci.json"
mv "$work/other-ci.json" "$work/data/ci.json"
printf 'stage2 == stage3 (bitcode)\n544 passed, 1 failed in 10s\nexit=1\n' > "$work/data/gate.log"
generate
has 'Fixed point: stage2 == stage3 (bitcode)'
has 'Suite: 544 passed, 1 failed'
has 'Gate completion: exit=1'
has 'Saved CI describes `different-revision`'
has 'Missing: saved CI run outcomes'
! has 'Hosted CI for this revision'
printf 'stage2 == stage3\n601 passed, 0 failed\n[exited with code 0]\n' > "$work/data/gate.log"
printf '# Historical run\n## Benchmark numbers\n' > "$work/data/benchmarks.md"
generate
has 'Gate completion: [exited with code 0]'
has '### Historical run'
has '### Benchmark numbers'
[[ $(grep -c '^## ' "$work/report.md") == 8 ]]

# Render a release snapshot without relying on the checkout's local tags.
mkdir -p "$work/source/tests/cases"
git -C "$work/source" init -q
git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit -qm fixture --allow-empty
git -C "$work/source" tag v1.2.3
printf 'test-serial:\n\t@echo fixture\n' > "$work/source/Makefile"
touch "$work/source/TODO.md"
cat > "$work/data/release.json" <<'JSON'
{"tag_name":"v1.2.3","draft":false,"prerelease":false,"html_url":"https://example.test/release","assets":[{"name":"ablac-static-aarch64-linux"}]}
JSON
tools/readiness.sh --source "$work/source" --out "$work/source-report.md" --data "$work/data" --fuzz-notes "$work/absent" >/dev/null
grep -F 'Published assets for [v1.2.3](https://example.test/release) (1)' "$work/source-report.md" >/dev/null
grep -F 'ablac-static-aarch64-linux' "$work/source-report.md" >/dev/null
generate
has 'Saved asset snapshot describes release `v1.2.3`'
! has 'Published assets for'
cp "$work/report.md" "$work/before.md"
printf '{malformed' > "$work/data/coverage.json"
if generate 2> "$work/error"; then echo 'readiness: malformed evidence accepted' >&2; exit 1; fi
cmp "$work/report.md" "$work/before.md"
printf '{"schemaVersion":1,"modules":[],"totals":{"documented":5,"undocumented":0,"total":4}}' > "$work/data/coverage.json"
if generate 2> "$work/error"; then echo 'readiness: inconsistent coverage accepted' >&2; exit 1; fi
cmp "$work/report.md" "$work/before.md"
echo 'readiness: missing evidence, migration scope, failures, incomplete gates and atomic errors passed'
