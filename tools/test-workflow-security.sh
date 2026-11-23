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
    echo 'workflow security controls: every rule refuses a workflow that breaks it'
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
((failed == 0)) || exit 1
printf 'workflow security: %d workflows: no dangerous trigger, least-privilege permissions, pinned actions, no injected inputs, no cache or self-hosted runner\n' "${#files[@]}"
