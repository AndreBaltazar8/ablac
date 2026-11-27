#!/usr/bin/env bash
# The CI workflows' security rules (#1139 area 6), checked on every file of .github/workflows (bash and awk only):
#   1. no pull_request_target, workflow_run, issue_comment or pull_request_review trigger (untrusted code with secrets);
#   2. a top-level `permissions:` that grants `contents: read` and nothing else;
#   3. a job grants a write permission only in release.yml, and there only contents, id-token and attestations;
#   4. every `uses:` is a local workflow or an action pinned to a full 40-hex commit; third-party actions (not
#      actions/*) must be in the allow list below;
#   5. every actions/checkout sets persist-credentials: false;
#   6. secrets are used only by release.yml, and only the release signing key;
#   7. no `${{ inputs.* }}`, `github.event.*` or `github.head_ref` inside a `run:` script (pass it through env: so a
#      value is data, never shell code);
#   8. no actions/cache, no `cache:` key of a setup action and no self-hosted runner (nothing a pull request could
#      poison for a release to consume).
#   9. release.yml's `publish` job and release-compiler.yml's `compiler` job (release.yml calls it per platform) refuse `source_ref` (a branch or commit built to test the workflow) with
#      `publish_release` on, as their first step: a published release is built from its tag only;
#   3b. in release.yml only the bridge job (a draft release is visible to a push token only; it checks nothing out) and the publish job
#      hold a write permission: the build jobs run the scripts of the tree they check out (the tag, or source_ref when testing);
#  11. release.yml and release-compiler.yml download their artifacts without merge-multiple (a file name two artifacts share would be overwritten silently);
#  10. a Nix installer is fetched and checked against a pinned sha256 (the local action .github/actions/install-nix) in the
#      workflows that build release assets (release.yml, release-compiler.yml, static-suite.yml, windows-x64-toolchain.yml, windows-arm64-toolchain.yml),
#      never by cachix/install-nix-action alone.
# tools/test-workflow-security.sh [workflow-directory]
# tools/test-workflow-security.sh --controls   each rule is shown to fail on a workflow that breaks it
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} == --controls ]]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/workflow-security.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    # A workflow with every slot at its good value; a control changes one slot.
    pin=d23441a48e516b6c34aea4fa41551a30e30af803
    workflow() { # trigger permissions jobperms action ref persist envvalue runline runson
        printf 'name: t\non:\n  %s:\npermissions:\n%s\njobs:\n  j:\n%s    runs-on: %s\n    steps:\n      - uses: %s@%s\n        with:\n          persist-credentials: %s\n      - env:\n          X: %s\n        run: %s\n' \
            "$1" "$2" "$3" "$9" "$4" "$5" "$6" "$7" "$8"
    }
    good_args=(workflow_dispatch '  contents: read' '' actions/checkout "$pin" false '${{ inputs.x }}' 'echo "$X"' ubuntu-24.04)
    control() { # name expected-message-fragment (or OK) slot=value...
        local name=$1 expected=$2 args=("${good_args[@]}") assignment
        shift 2
        for assignment in "$@"; do args[${assignment%%=*}]=${assignment#*=}; done
        rm -rf "$work/w"; mkdir "$work/w"
        workflow "${args[@]}" > "$work/w/t.yml"
        if "$0" "$work/w" > "$work/out" 2>&1; then
            [[ $expected == OK ]] && return 0
            echo "workflow security control '$name': accepted" >&2; exit 1
        fi
        [[ $expected != OK ]] || { cat "$work/out" >&2; echo "workflow security: the control workflow is refused" >&2; exit 1; }
        grep -q -- "$expected" "$work/out" || { cat "$work/out" >&2; echo "workflow security control '$name': wrong refusal" >&2; exit 1; }
    }
    control good OK
    control pull_request_target 'trigger' 0=pull_request_target
    control workflow_run 'trigger' 0=workflow_run
    control no-permissions 'top-level permissions' 1='  actions: read'
    control broad-permissions 'top-level permissions' 1='  contents: write'
    control job-write 'write permission outside release.yml' '2=    permissions:
      packages: write
'
    control unpinned 'not pinned' 4=v6
    control short-pin 'not pinned' 4=d23441a48e516b6c34aea4fa41551a30e3af803
    control third-party 'not in the allow list' 3=evil/action
    control persist 'persist-credentials' 5=true
    control secret 'secrets used' '6=${{ secrets.TOKEN }}'
    control injection 'untrusted expression' '7=echo ${{ inputs.x }}'
    control event-injection 'untrusted expression' '7=echo ${{ github.event.pull_request.title }}'
    control self-hosted 'self-hosted' 8=self-hosted
    cp_dir=$work/direct; rm -rf "$cp_dir"; mkdir "$cp_dir"
    workflow workflow_dispatch '  contents: read' '' cachix/install-nix-action "$pin" false '${{ inputs.x }}' 'echo "$X"' ubuntu-24.04 > "$cp_dir/windows-x64-toolchain.yml"
    if "$0" "$cp_dir" > "$work/out" 2>&1; then echo "workflow security control 'direct nix action': accepted" >&2; exit 1; fi
    grep -q 'used directly' "$work/out" || { cat "$work/out" >&2; echo "workflow security control 'direct nix action': wrong refusal" >&2; exit 1; }
    rm -rf "$work/w"; mkdir "$work/w"
    printf 'name: r\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  compiler:\n    permissions:\n      contents: write\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@%s\n        with:\n          persist-credentials: false\n' "$pin" > "$work/w/release.yml"
    if "$0" "$work/w" > "$work/out" 2>&1; then echo "workflow security control 'compiler write': accepted" >&2; exit 1; fi
    grep -q 'only the bridge and publish jobs' "$work/out" || { cat "$work/out" >&2; echo "workflow security control 'compiler write': wrong refusal" >&2; exit 1; }
    printf 'name: r\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  publish:\n    runs-on: ubuntu-24.04\n    steps:\n      - env:\n          SOURCE_REF: ${{ inputs.source_ref }}\n        run: test -z "$SOURCE_REF"\n      - uses: actions/download-artifact@%s\n        with:\n          merge-multiple: true\n' "$pin" > "$work/w/release.yml"
    if "$0" "$work/w" > "$work/out" 2>&1; then echo "workflow security control 'merge-multiple': accepted" >&2; exit 1; fi
    grep -q 'merge-multiple hides' "$work/out" || { cat "$work/out" >&2; echo "workflow security control 'merge-multiple': wrong refusal" >&2; exit 1; }
    # The release environment rule: the signing key's job names it.
    release_workflow() { # environment-line
        printf 'name: r\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  publish:\n    runs-on: ubuntu-24.04\n%s    steps:\n      - env:\n          SOURCE_REF: ${{ inputs.source_ref }}\n        run: test -z "$SOURCE_REF"\n      - uses: actions/checkout@%s\n        with:\n          persist-credentials: false\n      - env:\n          ABLA_RELEASE_SIGNING_KEY: ${{ secrets.ABLA_RELEASE_SIGNING_KEY }}\n        run: test -n "$ABLA_RELEASE_SIGNING_KEY"\n' "$1" "$pin"
    }
    rm -rf "$work/w"; mkdir "$work/w"; release_workflow '    environment: release
' > "$work/w/release.yml"
    "$0" "$work/w" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "workflow security: release.yml with the environment is refused" >&2; exit 1; }
    rm -rf "$work/w"; mkdir "$work/w"; release_workflow '' > "$work/w/release.yml"
    if "$0" "$work/w" > "$work/out" 2>&1; then echo "workflow security control 'release environment': accepted" >&2; exit 1; fi
    grep -q 'without environment: release' "$work/out" || { cat "$work/out" >&2; echo "workflow security control 'release environment': wrong refusal" >&2; exit 1; }
    rm -rf "$work/w"; mkdir "$work/w"; release_workflow '    environment: release
' | sed 's/run: test -z "$SOURCE_REF"/run: true/' > "$work/w/release.yml"
    if "$0" "$work/w" > "$work/out" 2>&1; then echo "workflow security control 'source_ref': accepted" >&2; exit 1; fi
    grep -q 'do not refuse source_ref' "$work/out" || { cat "$work/out" >&2; echo "workflow security control 'source_ref': wrong refusal" >&2; exit 1; }
    # The compiler job lives in release-compiler.yml (called once per platform): the same rule there.
    rm -rf "$work/w"; mkdir "$work/w"
    printf 'name: r\non:\n  workflow_call:\npermissions:\n  contents: read\njobs:\n  compiler:\n    runs-on: ubuntu-24.04\n    steps:\n      - env:\n          SOURCE_REF: ${{ inputs.source_ref }}\n        run: true\n      - uses: actions/checkout@%s\n        with:\n          persist-credentials: false\n' "$pin" > "$work/w/release-compiler.yml"
    if "$0" "$work/w" > "$work/out" 2>&1; then echo "workflow security control 'release-compiler source_ref': accepted" >&2; exit 1; fi
    grep -q 'release-compiler.yml: job(s) compiler *do not refuse source_ref' "$work/out" || { cat "$work/out" >&2; echo "workflow security control 'release-compiler source_ref': wrong refusal" >&2; exit 1; }
    sed -i 's/run: true/run: test -z "$SOURCE_REF"/' "$work/w/release-compiler.yml"
    "$0" "$work/w" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "workflow security: a release-compiler.yml that refuses source_ref is refused" >&2; exit 1; }
    release_route() {
        local name=$1 windows=$2 arm64=$3 ancestor=$4 route syntax literal
        local operators='^[[:space:]()&|=!]+$'
        route=$(awk -v name="$name" '
            $0 == "  " name ":" { job=1; next }
            job && /^    if:/ { sub(/^    if: \$\{\{ /, ""); sub(/ \}\}$/, ""); print; exit }
            job && /^  [^ ]/ { exit }
        ' "$root/.github/workflows/release.yml")
        # GitHub inserts success() when the predicate has no status function.
        if [[ $route != *'cancelled()'* && $route != *'failure()'* && $ancestor != success ]]; then
            return 1
        fi
        route=${route//inputs.windows_arm64/"'$arm64'"}
        route=${route//inputs.windows/"'$windows'"}
        route=${route//'!cancelled()'/"('$ancestor' != 'cancelled')"}
        route=${route//'!failure()'/"('$ancestor' != 'failure')"}
        # Only known literals and comparison/boolean operators can reach eval.
        syntax=$route
        for literal in off with only fixpoint skipped success cancelled failure; do
            syntax=${syntax//\'$literal\'/}
        done
        [[ $syntax =~ $operators ]] && eval "[[ $route ]]"
    }
    if ! release_route windows-arm64 with fixpoint success; then
        echo 'workflow control: windows_arm64=fixpoint did not select windows-arm64' >&2
        exit 1
    fi
    if ! release_route static-suite with with skipped; then
        echo 'workflow control: a skipped bridge suppressed the static suite for a full release' >&2
        exit 1
    fi
    for job in compiler-linux compiler-macos; do
        if ! release_route "$job" with with skipped; then
            echo "workflow control: a skipped bridge suppressed $job for a full release" >&2
            exit 1
        fi
        if release_route "$job" only with success; then
            echo "workflow control: windows=only selected $job" >&2
            exit 1
        fi
    done
    echo 'workflow controls: security rules and release routing passed'
    exit 0
fi
dir=${1:-$root/.github/workflows}
allowed_third_party='^(cachix/install-nix-action)$'
failed=0
fail() { printf 'workflow security: %s\n' "$*" >&2; failed=1; }

shopt -s nullglob
files=("$dir"/*.yml)
((${#files[@]})) || { echo "workflow security: no workflows in $dir" >&2; exit 1; }
for file in "${files[@]}"; do
    name=$(basename "$file")
    # 1. dangerous triggers
    if grep -n -E '^[[:space:]]*(pull_request_target|workflow_run|issue_comment|pull_request_review|pull_request_review_comment)[[:space:]]*:' "$file" > /dev/null; then
        fail "$name: a trigger that runs with secrets on untrusted input (pull_request_target, workflow_run, issue_comment, pull_request_review)"
    fi
    # 2. top-level permissions: contents: read only
    top=$(awk '/^permissions:/ { p = 1; next } p && /^  [a-z-]+:/ { gsub(/^ +/, ""); print; next } p { exit }' "$file")
    [[ $top == 'contents: read' ]] || fail "$name: the top-level permissions must be exactly 'contents: read' (found: ${top:-none})"
    # 3. write grants
    writes=$(grep -n -E '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$' "$file" || true)
    if [[ -n $writes ]]; then
        if [[ $name != release.yml ]]; then
            fail "$name: a write permission outside release.yml: $(tr '\n' ' ' <<< "$writes")"
        else
            bad=$(grep -v -E '(contents|id-token|attestations):[[:space:]]*write' <<< "$writes" || true)
            [[ -z $bad ]] || fail "$name: a write permission other than contents, id-token, attestations: $bad"
            wide=$(awk '
                /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); next }
                /^      [a-z-]+:[[:space:]]*write[[:space:]]*$/ { if (job != "bridge" && job != "publish") printf "%s ", job }
            ' "$file")
            [[ -z $wide ]] || fail "$name: job(s) $wide hold a write permission (only the bridge and publish jobs may)"
        fi
    fi
    # 4. pinned actions
    while IFS= read -r line; do
        use=${line#*uses:}
        use=$(sed 's/^[[:space:]]*//; s/[[:space:]]*#.*$//' <<< "$use")
        [[ $use == ./* ]] && continue
        repo=${use%%@*}
        ref=${use#*@}
        if [[ ! $ref =~ ^[0-9a-f]{40}$ ]]; then
            fail "$name: '$use' is not pinned to a full 40-hex commit"
        fi
        if [[ $repo != actions/* && ! $repo =~ $allowed_third_party ]]; then
            fail "$name: third-party action $repo is not in the allow list"
        fi
    done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$file" || true)
    # 5. checkout without persisted credentials
    checkouts=$(grep -c 'uses: actions/checkout@' "$file" || true)
    persisted=$(grep -c 'persist-credentials: false' "$file" || true)
    ((checkouts == persisted)) || fail "$name: $checkouts actions/checkout steps but $persisted persist-credentials: false"
    # 6. secrets
    if grep -n 'secrets\.' "$file" > /dev/null; then
        uses=$(grep -o 'secrets\.[A-Za-z_]*' "$file" | sort -u | tr '\n' ' ')
        if [[ $name != release.yml || $uses != 'secrets.ABLA_RELEASE_SIGNING_KEY ' ]]; then
            fail "$name: secrets used: $uses (only release.yml may use secrets.ABLA_RELEASE_SIGNING_KEY)"
        fi
    fi
    # 6b. the signing key is only reachable through the `release` environment (master-only, with a required reviewer)
    if [[ $name == release.yml ]]; then
        unguarded=$(awk '
            /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; next }
            /^    environment:[[:space:]]*release[[:space:]]*$/ { guarded[job] = 1 }
            /secrets\.ABLA_RELEASE_SIGNING_KEY/ { used[job] = 1 }
            END { for (j in used) if (!(j in guarded)) printf "%s ", j }
        ' "$file")
        [[ -z $unguarded ]] || fail "$name: job(s) $unguarded read secrets.ABLA_RELEASE_SIGNING_KEY without environment: release"
    fi
    # 9. a published release is built from its tag, never from source_ref (the build jobs run the checked-out tree's scripts)
    # (release-compiler.yml is release.yml's compiler job, called once per platform.)
    if [[ $name == release.yml || $name == release-compiler.yml ]]; then
        unchecked=$(awk '
            /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); seen[job] = 1; next }
            /test -z "\$SOURCE_REF"|-n "\$SOURCE_REF"/ { checked[job] = 1 }
            END { n = split("compiler publish", want, " "); for (i = 1; i <= n; i++) if ((want[i] in seen) && !(want[i] in checked)) printf "%s ", want[i] }
        ' "$file")
        [[ -z $unchecked ]] || fail "$name: job(s) $unchecked do not refuse source_ref with publish_release on"
    fi
    # 11. no merge-multiple in release.yml
    if [[ $name == release.yml || $name == release-compiler.yml ]] && grep -n -E '^[[:space:]]+merge-multiple:' "$file" > /dev/null; then
        fail "$name: merge-multiple hides a file name that two artifacts share"
    fi
    # 10. the workflows that build release assets install Nix through the hash-pinned local action
    case $name in
        release.yml|release-compiler.yml|static-suite.yml|windows-x64-toolchain.yml|windows-arm64-toolchain.yml)
            if grep -n 'uses:[[:space:]]*cachix/install-nix-action' "$file" > /dev/null; then
                fail "$name: cachix/install-nix-action used directly; use ./.github/actions/install-nix (the Nix installer is hash-pinned there)"
            fi ;;
    esac
    # 7. untrusted expressions inside run scripts
    injected=$(awk '
        function indent(s) { match(s, /^ */); return RLENGTH }
        {
            line = $0
            if (inrun) {
                if (line ~ /^[[:space:]]*$/ || indent(line) > keyindent) {
                    if (line ~ /\$\{\{[^}]*(inputs\.|github\.event\.|github\.head_ref)/) printf "%d: %s\n", NR, line
                    next
                }
                inrun = 0
            }
            if (match(line, /^[[:space:]]*(- )?run:[[:space:]]*/)) {
                rest = substr(line, RLENGTH + 1)
                key = line; sub(/run:.*$/, "", key); keyindent = length(key)
                if (rest ~ /^[|>][-+]?$/) { inrun = 1 }
                else if (rest ~ /\$\{\{[^}]*(inputs\.|github\.event\.|github\.head_ref)/) printf "%d: %s\n", NR, line
            }
        }' "$file")
    [[ -z $injected ]] || fail "$name: an untrusted expression inside a run script (use env:): $(tr '\n' ' ' <<< "$injected")"
    # 8. caches and runners
    if grep -n -E 'uses:[[:space:]]*actions/cache|^[[:space:]]*cache:[[:space:]]|runs-on:[[:space:]]*(\[?[[:space:]]*)?self-hosted' "$file" > /dev/null; then
        fail "$name: a cache or a self-hosted runner"
    fi
done
if [[ $dir == "$root/.github/workflows" ]]; then
    for action in "$root"/.github/actions/*/action.yml; do
        [[ -f $action ]] || continue
        while IFS= read -r line; do
            use=$(sed 's/^.*uses:[[:space:]]*//; s/[[:space:]]*#.*$//' <<< "$line")
            [[ $use == ./* ]] && continue
            repo=${use%%@*}; ref=${use#*@}
            [[ $ref =~ ^[0-9a-f]{40}$ ]] || fail "${action#"$root"/}: '$use' is not pinned to a full 40-hex commit"
            [[ $repo =~ $allowed_third_party || $repo == actions/* ]] || fail "${action#"$root"/}: third-party action $repo is not in the allow list"
        done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$action" || true)
    done
    nix_action=$root/.github/actions/install-nix/action.yml
    if [[ -f $nix_action ]]; then
        grep -E 'echo "[0-9a-f]{64}  \$installer" \| sha256sum -c -' "$nix_action" > /dev/null || fail "install-nix: the installer is not checked against a pinned sha256"
        grep -F 'install_url: file://' "$nix_action" > /dev/null || fail "install-nix: the checked installer is not the one the action runs (install_url)"
    else
        fail "install-nix: .github/actions/install-nix/action.yml is missing"
    fi
fi
((failed == 0)) || exit 1
printf 'workflow security: %d workflows: no dangerous trigger, least-privilege permissions, pinned actions, no injected inputs, no cache or self-hosted runner\n' "${#files[@]}"
