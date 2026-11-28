#!/usr/bin/env bash
# Generate the internal scorecard from local source and saved evidence. No builds or network calls.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=docs/readiness.md
data=build/readiness
notes=${HOME}/agents-memory/abla/ablac-differential-fuzzer.md
usage() {
    echo 'usage: tools/readiness.sh [--source CHECKOUT] [--out FILE] [--data DIR] [--fuzz-notes FILE]' >&2
    echo 'See docs/readiness-data/README.md for evidence formats and refresh commands.' >&2
}
while (($#)); do
    case $1 in
        --source) root=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        --data) data=${2:?}; shift 2 ;;
        --fuzz-notes) notes=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
cd "$root"
revision=$(git rev-parse HEAD)
command -v jq >/dev/null || { echo 'readiness: jq is required (use nix-shell)' >&2; exit 2; }
mkdir -p -- "$(dirname -- "$out")"
tmp=$(mktemp "${out}.XXXXXXXX")
trap 'rm -f -- "$tmp"' EXIT
missing() { printf 'Missing: %s.\n\n' "$*"; }
evidence() {
    local path=$1 name=$1
    if [[ $path == "$data/"* ]]; then name="saved evidence/${path#"$data/"}"; fi
    printf 'Evidence: `%s`; SHA-256 `%s`.\n\n' "$name" "$(sha256sum < "$path" | awk '{print $1}')"
}
literal() {
    # Indented Markdown keeps arbitrary evidence (including backtick fences) inert.
    sed 's/^/    /' "$1"
    printf '\n'
}
json_check() { jq -e "$2" "$1" >/dev/null || { echo "readiness: invalid evidence: $1" >&2; exit 2; }; }
hosted_ci() {
    local ci=$data/ci.json
    if [[ ! -s $ci ]]; then
        missing 'saved CI run outcomes for the source revision'
        return
    fi
    json_check "$ci" '
        (.headSha | type == "string") and (.url | type == "string") and
        (.status | type == "string") and (.conclusion | type == "string") and
        (.jobs | type == "array" and all(.[];
            (.name | type == "string") and (.status | type == "string") and
            (.conclusion | type == "string")))'
    evidence "$ci"
    local tested
    tested=$(jq -r .headSha "$ci")
    if [[ $tested != "$revision" ]]; then
        printf 'Saved CI describes `%s`.\n\n' "$tested"
        missing 'saved CI run outcomes for the source revision'
        return
    fi
    jq -r '
        def outcome: .status + (if .conclusion == "" then "" else " / " + .conclusion end);
        "Hosted CI for this revision: [run](\(.url)) · \(outcome)\n",
        (.jobs[] | "- \(.name) · \(outcome)")' "$ci"
    printf '\n'
}
release_assets() {
    local release=$data/release.json tag
    if [[ ! -s $release ]]; then
        missing 'published asset snapshot for the source revision (release.json)'
        return
    fi
    json_check "$release" '
        (.tag_name | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        .draft == false and .prerelease == false and (.html_url | type == "string") and
        (.assets | type == "array" and all(.[]; .name | type == "string"))'
    evidence "$release"
    tag=$(jq -r .tag_name "$release")
    if [[ $(git rev-parse --verify --quiet "refs/tags/$tag^{commit}") != "$revision" ]]; then
        printf 'Saved asset snapshot describes release `%s`.\n\n' "$tag"
        missing 'published asset snapshot for the source revision'
        return
    fi
    jq -r '
        "Published assets for [\(.tag_name)](\(.html_url)) (\(.assets | length)):\n",
        (.assets[] | "- `\(.name)`")' "$release"
    printf '\n'
}
{
    printf '# Internal production readiness\n\n'
    printf 'Internal only. Regenerate with `tools/readiness.sh`; this is an evidence inventory, not a production approval or stability policy.\n\n'
    printf 'Source revision: `%s`. Source counts describe this working tree. Saved results may describe older revisions; only explicitly recorded revisions identify what was tested.\n\n' "$revision"
    printf '## Stability\n\n'
    if [[ -s $data/releases.json ]]; then
        json_check "$data/releases.json" 'type == "array" and all(.[]; (.tag_name | type == "string") and (.body | type == "string"))'
        evidence "$data/releases.json"
        if [[ $(jq 'length' "$data/releases.json") == 0 ]]; then missing 'published release entries'; fi
        printf '| Release | Migration bullets |\n|---|---:|\n'
        # Count top-level list items within Migration/Breaking changes headings. No section means unknown, not zero.
        jq -r '.[] | select(.draft != true and .prerelease != true) | [.tag_name, (.body | @base64)] | @tsv' "$data/releases.json" |
        while IFS=$'\t' read -r tag body; do
            count=$(printf '%s' "$body" | base64 --decode | awk '
                /^#+ / {
                    match($0, /^#+/); level = RLENGTH
                    if (active && level <= depth) active = 0
                    if (tolower($0) ~ /migration|breaking changes/) { active = 1; seen = 1; depth = level }
                }
                active && /^([-*+] |[0-9]+[.)] )/ { n++ }
                END { if (seen) print n + 0; else print "Missing" }')
            tag=${tag//|/\\|}
            printf '| %s | %s |\n' "$tag" "$count"
        done
        printf '\nCounts are top-level migration bullets, a proxy for breaking changes. A present section with prose but no bullets counts zero bullets; it does not prove zero breaks. Releases without a migration section are missing.\n\n'
    else
        missing 'release-note archive (releases.json)'
    fi
    printf '## Correctness\n\n'
    cases=$(find tests/cases -type d -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    commands=$(make -s -n -o ablac -o build/ablac test-serial COMPILER=build/ablac | awk 'NF { n++ } END {print n+0}')
    printf 'Suite inventory: **%s recipe commands**, **%s case directories**. These are source inventory counts, not passing checks.\n\n' "$commands" "$cases"
    gate=$data/gate.log
    [[ -f $gate ]] || gate=build/gate/gate.log
    if [[ -s $gate ]]; then
        evidence "$gate"
        # The marker alone is not a completed gate. Keep the final exit and suite summary alongside it.
        awk '/^stage2 == stage3( \(|$)/ {fixed=$0} /[0-9]+ passed, [0-9]+ failed/ {suite=$0}
            /^exit=[0-9]+$|^\[exited with code [0-9]+\]$/ {status=$0}
            END { print "    Fixed point: " (fixed != "" ? fixed : "Missing")
                  print "    Suite: " (suite != "" ? suite : "Missing")
                  print "    Gate completion: " (status != "" ? status : "Missing (unfinished)") }' "$gate"
        printf '\nGate source revision: see the optional `gate-revision.txt`; absent provenance means the result cannot establish this revision passed.\n\n'
        if [[ -s $data/gate-revision.txt ]]; then literal "$data/gate-revision.txt"; fi
    else
        missing 'completed gate, stage2 == stage3 result and suite pass/fail totals'
    fi
    if [[ -s $data/release-check.log ]]; then
        printf '### Published release checks\n\n'
        evidence "$data/release-check.log"
        literal "$data/release-check.log"
    fi
    printf '### Fuzz campaigns and disagreements\n\n'
    printf 'Harness: `tools/fuzz/run`; `tools/test-fuzz-abla.sh` checks the harness and planted disagreement controls. Scratch seed directories are not campaign results.\n\n'
    if [[ -s $data/fuzz.json ]]; then
        json_check "$data/fuzz.json" 'type == "array" and all(.[]; (.command | type == "string") and (.revision | type == "string") and (.recordedAt | type == "string") and (.agree | type == "number" and . >= 0 and floor == .) and (.disagree | type == "number" and . >= 0 and floor == .) and (.exitStatus | type == "number" and floor == .))'
        evidence "$data/fuzz.json"
        if [[ $(jq 'length' "$data/fuzz.json") == 0 ]]; then missing 'recorded fuzz campaigns'; fi
        # Records from tools/fuzz/run --record also carry the campaign, families, seeds, modes and the compiler hash.
        jq -r '.[] | "Revision: \(.revision)\(if .revisionDirty == true then " (checkout had changes)" else "" end)\nRecorded: \(.recordedAt)\nCommand: \(.command)\n" + (if .campaign then "Campaign: \(.campaign); seeds run \(.seeds) (\(.seedCount); planned \(.plannedSeeds)), \(.checksPerSeed) checks each\nModes: \(.modes | join(", "))\nFamilies: \(.families | length) (\(.families | join(", ")))\nCompiler: \(.compilerVersion), SHA-256 \(.compilerSha256)\n" else "" end) + "Agreeing seeds: \(.agree); disagreeing seeds: \(.disagree)\(if (.disagreeingSeeds // []) != [] then " (\(.disagreeingSeeds | map(tostring) | join(", ")))" else "" end); exit status: \(.exitStatus)\(if .complete == false then " (not finished)" else "" end)\n"' "$data/fuzz.json" | sed 's/^/    /'
        printf '\nExit status 124 means timeout (a recorded campaign that never finished keeps 124); a partial campaign with zero disagreements is not a completed clean campaign.\n\n'
    else
        missing 'structured campaign totals and disagreement counts (fuzz.json)'
    fi
    if [[ -s $notes ]]; then
        evidence "$notes"
        printf 'Historical campaign narrative, final 24 lines (may be stale; no aggregate inferred; consult the full source above):\n\n'
        tail -n 24 "$notes" | sed 's/^/    /'
        printf '\n'
    else
        missing 'shared historical fuzzer note'
    fi
    printf '### Open wrong-code bug candidates\n\n'
    printf 'Heuristic scan of open TODO list items for wrong code, miscompiles, wrong results, or mode disagreements. Candidate titles and source lines follow; inspect the full items to distinguish resolved findings inside an open tracking item. This is not a bug count; unlabelled bugs can be missed. Completed items are excluded.\n\n'
    awk '
        function emit() { if (open && tolower(item) ~ /wrong[- ]code|miscompil|wrong (result|value|output)|incorrect (result|value|output)|disagree|double.free|use.after.free/) {print "    TODO.md:" line " " title; found++} }
        /^## / { emit(); item=""; open=0 }
        /^- / { emit(); item=$0; title=$0; line=NR; open=($0 ~ /^- \[ \]/); next }
        open {item=item "\n    " $0}
        END {emit(); if (!found) print "Missing: no explicitly matching open items; this is not proof of zero wrong-code bugs."}
    ' TODO.md
    printf '\n## Security\n\n'
    printf 'Security mechanisms and limits: `docs/reliability-roadmap.md`, `docs/constant-time.md`, `docs/ownership.md`. Declared tests are inventory, not security audit results:\n\n'
    git ls-files 'tools/test-*' | awk '/security|secret|constant-time|bounds|malformed|compile-effects|tls|x509|parser/ {print "    " $0}'
    printf '\n'
    if [[ -s $data/security.md ]]; then evidence "$data/security.md"; literal "$data/security.md"; else missing 'independent audit, vulnerability inventory and security fuzz campaign evidence (security.md)'; fi
    printf '## Performance\n\n'
    if [[ -s $data/benchmarks.md ]]; then evidence "$data/benchmarks.md"; sed -E 's/^#{1,2} /### /' "$data/benchmarks.md"; printf '\n'; else
        printf '| Benchmark | Abla | C | Rust | Go | Zig |\n|---|---|---|---|---|---|\n| Runtime / RSS / compile time / size | Missing | Missing | Missing | Missing | Missing | Missing |\n\n'
        printf 'Awaiting `tools/bench-languages` measurements. Archive its report as `benchmarks.md` with revision, toolchains and host metadata.\n\n'
    fi
    printf '## Platforms\n\n'
    release_assets
    hosted_ci
    if [[ -s docs/platforms.md ]]; then
        printf 'Coverage tiers recorded in the source checkout’s platform matrix.\n\n'
        awk '
            /^<!-- readiness-platforms:start -->$/ {inside=1; next}
            /^<!-- readiness-platforms:end -->$/ {inside=0}
            inside && /^\| Platform \|/ {historical = /\| Published .* assets \|$/}
            inside && historical && /^\|/ {sub(/[^|]+\|$/, "")}
            inside {print}
        ' docs/platforms.md
        printf '\n'
    else missing 'platform coverage tiers (docs/platforms.md)'; fi
    printf 'Declared workflow jobs and matrices, extracted from `.github/workflows`. This configuration does not establish passing CI or hardware coverage; conditional/manual jobs remain conditional/manual.\n\n'
    for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
        [[ -f $workflow ]] || continue
        printf '### `%s`\n\n' "$workflow"
        awk '
            /^jobs:/ {jobs=1}
            jobs && /^  [[:alnum:]_-]+:/ {print "    " $0}
            jobs && /^    (name|if|runs-on):/ {print "    " $0}
            /^      matrix:/ {matrix=1; print "    " $0; next}
            matrix && /^        / {print "    " $0; next}
            matrix && NF && $0 !~ /^ *#/ {matrix=0}
        ' "$workflow"
        printf '\n'
    done
    printf '## Ecosystem\n\n'
    siblings=$data/siblings.txt
    [[ -f $siblings ]] || siblings=build/siblings/summary.txt
    if [[ -s $siblings ]]; then evidence "$siblings"; literal "$siblings"; printf 'A dash in tests means not run. Record the compiler revision and command in `siblings-context.md`; this summary alone does not identify its compiler.\n\n'; else missing 'tools/test-siblings.sh summary'; fi
    if [[ -s $data/siblings-context.md ]]; then literal "$data/siblings-context.md"; fi
    printf '## Docs\n\n'
    coverage=$data/coverage.json
    [[ -f $coverage ]] || coverage=build/docs/coverage.json
    if [[ -s $coverage ]]; then
        json_check "$coverage" '.schemaVersion == 1 and (.totals | all(.documented, .undocumented, .total; type == "number" and . >= 0 and floor == .)) and (.totals.documented + .totals.undocumented == .totals.total) and (.modules | type == "array")'
        evidence "$coverage"
        jq -r '.totals | "Public declarations documented: **\(.documented)/\(.total)** (\(if .total > 0 then ((.documented * 10000 / .total | floor) / 100 | tostring) + "%" else "Missing: no declarations" end)); undocumented: **\(.undocumented)**."' "$coverage"
        printf '\nCoverage measures declared API documentation, not documentation quality or example execution.\n\n'
    else missing 'stdlib public declaration documentation coverage (ablac doc coverage.json)'; fi
    printf '## Real-world deployments\n\n'
    deployments=$data/deployments.tsv
    [[ -f $deployments ]] || deployments=docs/readiness-data/deployments.tsv
    if [[ -s $deployments ]] && awk '!/^#/ && NF {found=1} END {exit !found}' "$deployments"; then
        evidence "$deployments"
        printf '| Deployment | Revision/version | Evidence | Last verified |\n|---|---|---|---|\n'
        awk -F '\t' '!/^#/ && NF {if (NF != 4) {print "readiness: deployment rows need four tab-separated columns" > "/dev/stderr"; exit 2} gsub(/\|/, "\\|"); print "| " $1 " | " $2 " | " $3 " | " $4 " |"}' "$deployments"
        printf '\nHand-maintained reports; inclusion does not establish a support or stability promise.\n'
    else missing 'verified, hand-maintained deployments'; fi
    if [[ -s $data/deployments-context.md ]]; then evidence "$data/deployments-context.md"; literal "$data/deployments-context.md"; fi
} > "$tmp"
clean=$(sed 's/[[:blank:]]*$//' "$tmp")
printf '%s\n' "$clean" > "$tmp"
mv -- "$tmp" "$out"
printf '%s\n' "$out"
