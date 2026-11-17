#!/usr/bin/env bash
# The bootstrap-convergence gate of a release (docs/bootstrap.md, "Historical-seed convergence"): the manual
# `bootstrap-convergence.yml` workflow, run on the release's source commit, must be green before the release is published.
# tools/release-check.sh requires it; this script runs it and reads its result.
#
#   tools/release-convergence.sh run <tag> [options]      dispatch the workflow for the tag's source, wait, verify,
#                                                         write the release-notes text, print PASS or FAIL
#   tools/release-convergence.sh verify <tag> [options]   read an existing run's comparison, print PASS or FAIL
#
# The lineage is the release before <tag> (route A starts from that release's binary, route B from the one before it,
# rebuilding that release's sources): both seeds exist and are pinned in LINEAGES (tools/test-bootstrap-convergence.mjs)
# before <tag> is made, and the candidate they build is <tag>'s source. A release's own entry is added after it
# publishes, and gates the next release.
#
# Options:
#   --repo OWNER/REPO       (default AndreBaltazar8/ablac)
#   --source-ref SHA        the commit the release is made from (default: the commit the tag <tag> already names)
#   --lineage TAG           the lineage to expect (default: the highest published release below <tag>)
#   --ref BRANCH            the ref the workflow is dispatched on (run only; default master)
#   --run ID                verify (or, with `run`, wait for and verify) this workflow run instead of dispatching
#   --comparison FILE       verify a comparison.json already downloaded (verify only; with --lineage and
#                           --source-ref no gh is needed)
#   --notes FILE            where `run` writes the release-notes text (default build/release-<tag>.notes.md); give it to
#                           `gh release create --notes-file`
# Without --run or --comparison, `verify` takes the newest green run of the workflow whose comparison matches.
set -uo pipefail

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

repo=AndreBaltazar8/ablac
source_ref=
lineage=
dispatch_ref=master
run_id=
comparison=
notes=
positional=()
while (($#)); do
    case $1 in
        --repo) repo=${2:?}; shift 2 ;;
        --source-ref) source_ref=${2:?}; shift 2 ;;
        --lineage) lineage=${2:?}; shift 2 ;;
        --ref) dispatch_ref=${2:?}; shift 2 ;;
        --run) run_id=${2:?}; shift 2 ;;
        --comparison) comparison=${2:?}; shift 2 ;;
        --notes) notes=${2:?}; shift 2 ;;
        -h | --help) usage ;;
        -*) echo "release-convergence: unknown option $1" >&2; usage ;;
        *) positional+=("$1"); shift ;;
    esac
done
((${#positional[@]} == 2)) || usage
mode=${positional[0]}
tag=${positional[1]}
[[ $mode == run || $mode == verify ]] || usage
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-convergence: tag must look like v0.2.62, got $tag" >&2; exit 2; }
workflow=bootstrap-convergence.yml
fail() { printf 'FAIL  convergence %s\n' "$1"; exit 1; }

if [[ -z $lineage ]]; then
    lineage=$(gh release list -R "$repo" -L 100 --exclude-drafts --json tagName --jq '.[].tagName' 2>/dev/null |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | sed 's/^/v/' |
        awk -v tag="$tag" 'BEGIN { prior = "" } $0 == tag { print prior; found = 1; exit } { prior = $0 } END { if (!found) print prior }')
    [[ -n $lineage ]] || fail "no release below $tag found to be the lineage (pass --lineage)"
fi
if [[ -z $source_ref ]]; then
    source_ref=$(gh api "repos/$repo/commits/$tag" --jq .sha 2>/dev/null) ||
        fail "no source commit: $tag does not exist yet (pass --source-ref with the commit it will be made from)"
fi
[[ $source_ref =~ ^[0-9a-f]{40}$ ]] || fail "--source-ref must be a full 40-digit commit, got $source_ref"

# verify_file COMPARISON.JSON [NOTES-FILE [RUN-URL]]: prints the PASS or FAIL line for the comparison against the
# lineage and source commit, and, given a notes file, writes the release-notes text there.
verify_file() {
    node --input-type=module - "$1" "$lineage" "$source_ref" "$tag" "${2:-}" "${3:-}" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
const [file, lineage, source, tag, notes, runUrl] = process.argv.slice(2);
const bad = (why) => { console.log(`FAIL  convergence ${why}`); process.exit(1); };
let c;
try { c = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { bad(`${file} is not a readable comparison.json`); }
if (c.passed !== true) bad(`the run's comparison did not pass${c.error ? `: ${c.error}` : ''}`);
if (c.candidate?.revision !== source) bad(`the run bootstrapped ${c.candidate?.revision}, not the release's source ${source}`);
if (c.lineage !== lineage || c.seeds?.a?.version !== lineage) bad(`the run's lineage is ${c.lineage}, expected ${lineage}`);
for (const key of ['canonical_ir_sha256', 'stage2_binary_sha256', 'stage2_object_sha256']) if (!/^[0-9a-f]{64}$/.test(c[key] ?? '')) bad(`the comparison has no ${key}`);
console.log(`PASS  convergence ${lineage} seeds (A ${c.seeds.a.version}, B ${c.seeds.b.version}) both reach ${c.canonical_ir_sha256.slice(0, 12)} at ${source.slice(0, 12)}${runUrl ? ` (${runUrl})` : ''}`);
if (notes) {
    const lines = [
        '### Bootstrap convergence',
        '',
        `Two fresh Linux builders bootstrapped the source of ${tag} (\`${source}\`) from different seeds and reached the same compiler:`,
        '',
        `- route A: ${c.seeds.a.version} (\`ablac-x86_64-linux\` sha256 \`${c.seeds.a.sha256}\`) -> stage 1, 2, 3`,
        `- route B: ${c.seeds.b.version} (sha256 \`${c.seeds.b.sha256}\`) -> the sources of ${c.lineage} (\`${c.historical_revision}\`), twice -> stage 1, 2, 3`,
        `- canonical IR (raw, non-debug, pre-prune \`--emit-llvm ${c.entry}\` at \`${c.canonical_root}\`): sha256 \`${c.canonical_ir_sha256}\``,
        `- stage 2 executable \`${c.stage2_binary_sha256}\`, object \`${c.stage2_object_sha256}\``,
        `- toolchain: environment \`${c.toolchain?.environment_sha256}\`, closure \`${c.toolchain?.closure_sha256}\``,
        ...(runUrl ? [`- run: ${runUrl}`] : []),
        '',
        'This is route convergence within one compiler lineage: it is not an independent implementation, and it does not exclude a seed compromise shared by both routes (docs/bootstrap.md).',
        '',
    ];
    fs.mkdirSync(path.dirname(path.resolve(notes)), { recursive: true });
    fs.writeFileSync(notes, lines.join('\n'));
}
JS
}

fetch_comparison() { # run id -> prints the path of its comparison.json, or nothing
    local directory keep
    directory=$(mktemp -d)
    if gh run download "$1" -R "$repo" -n convergence-comparison -D "$directory" >/dev/null 2>&1 && [[ -f $directory/comparison.json ]]; then
        keep=$(mktemp)
        cp "$directory/comparison.json" "$keep"
        printf '%s\n' "$keep"
    fi
    rm -rf -- "$directory"
}

check_run() { # run id [notes file]: the PASS or FAIL line for one run
    local conclusion file result
    conclusion=$(gh run view "$1" -R "$repo" --json conclusion,workflowName --jq '.workflowName + " " + .conclusion' 2>/dev/null) ||
        fail "no run $1 in $repo"
    [[ $conclusion == "Historical bootstrap convergence success" ]] || fail "run $1 is '$conclusion', not a green convergence run"
    file=$(fetch_comparison "$1")
    [[ -n $file ]] || fail "run $1 has no convergence-comparison artifact (expired, or still running)"
    result=$(verify_file "$file" "${2:-}" "https://github.com/$repo/actions/runs/$1")
    rm -f -- "$file"
    printf '%s\n' "$result"
    [[ $result == PASS* ]]
}

if [[ $mode == verify ]]; then
    if [[ -n $comparison ]]; then
        result=$(verify_file "$comparison")
        printf '%s\n' "$result"
        [[ $result == PASS* ]]
        exit $?
    fi
    if [[ -n $run_id ]]; then check_run "$run_id"; exit $?; fi
    # The newest green runs, newest first, until one matches this source and lineage.
    for candidate in $(gh run list -w "$workflow" -R "$repo" --status success -L 30 --json databaseId --jq '.[].databaseId' 2>/dev/null); do
        file=$(fetch_comparison "$candidate")
        [[ -n $file ]] || continue
        result=$(verify_file "$file" "" "https://github.com/$repo/actions/runs/$candidate")
        rm -f -- "$file"
        if [[ $result == PASS* ]]; then printf '%s\n' "$result"; exit 0; fi
    done
    fail "no green $workflow run of lineage $lineage for source $source_ref in the last 30 (tools/release-convergence.sh run $tag --source-ref $source_ref)"
fi

# run
notes=${notes:-build/release-$tag.notes.md}
if [[ -z $run_id ]]; then
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    gh workflow run "$workflow" -R "$repo" --ref "$dispatch_ref" -f "lineage=$lineage" -f "source_ref=$source_ref" >/dev/null 2>&1 ||
        fail "could not dispatch $workflow on $dispatch_ref (does that ref's workflow have the lineage $lineage and a source_ref input?)"
    for _ in $(seq 1 30); do
        sleep 4
        run_id=$(gh run list -w "$workflow" -R "$repo" --event workflow_dispatch -L 10 --json databaseId,createdAt \
            --jq "[.[] | select(.createdAt >= \"$started\")] | sort_by(.createdAt) | last | .databaseId // empty" 2>/dev/null)
        [[ -n $run_id ]] && break
    done
    [[ -n $run_id ]] || fail "the dispatched run did not appear"
    echo "release-convergence: run $run_id (https://github.com/$repo/actions/runs/$run_id), lineage $lineage, source $source_ref" >&2
fi
gh run watch "$run_id" -R "$repo" --exit-status >/dev/null 2>&1 || true
check_run "$run_id" "$notes"
status=$?
((status)) || echo "release-convergence: release-notes text in $notes (gh release create ... --notes-file $notes)" >&2
exit $status
