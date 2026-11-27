#!/usr/bin/env bash
# The steps after a release is published (see the release process notes), in one place:
#
#   tools/release-after.sh <tag> [options]
#
#   1. tools/release-pin.sh <tag>: the bootstrap pin (tools/bootstrap-compiler.sh, README.md, docs/bootstrap.md);
#   2. <tag>'s convergence lineage (it gates the next release): a LINEAGES entry in tools/test-bootstrap-convergence.mjs
#      (route A: <tag>'s pinned Linux seed, route B: the release before it, historical: <tag>'s commit) and <tag> as the first
#      option and the default of the lineage input of .github/workflows/bootstrap-convergence.yml. Only those lines change;
#   3. with --times FILE, tools/test-times.tsv: the results.tsv of a whole suite run (the order the gate starts tests in);
#   4. with --release-times DIR, tools/test-times-release.tsv (the release-mode shard split of the static suite): the shards'
#      results.tsv files of <tag>'s release run, merged. DIR is what `gh run download <run> -p 'static-suite-logs-*' -D DIR`
#      writes (static-suite-logs-N/suite/results.tsv); every shard must have passed every command, each command once.
# With --commit each step is committed on its own (the pin; the lineage; the times; the release times). Without it nothing is committed and the
# diff stat is printed. Nothing is written when a check fails (no pinned <tag>, the lineage exists already, no commit for <tag>).
# Needs bash, awk, git and what release-pin.sh needs.
#
# Options:
#   --historical SHA   the commit <tag> was made from (default: what the tag <tag> names in the checkout)
#   --previous TAG     the release before <tag> (default: the highest lineage below <tag>); route B's seed is that lineage's route A
#   --times FILE       a results.tsv of a whole suite run to become tools/test-times.tsv
#   --release-times DIR  the release run's static-suite shard logs to become tools/test-times-release.tsv
#   --commit          commit each step
#   --skip-pin         the pin is already done (release-pin.sh was run, or committed): start at the lineage
#   --repo, --dir, --no-binaries, --root   as release-pin.sh (--root also names the checkout to edit)
set -uo pipefail

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}
fail() { echo "release-after: $*" >&2; exit 1; }

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
historical=
previous=
times=
release_times=
commit=0
skip_pin=0
pin_args=()
positional=()
while (($#)); do
    case $1 in
        --historical) historical=${2:?}; shift 2 ;;
        --previous) previous=${2:?}; shift 2 ;;
        --times) times=${2:?}; shift 2 ;;
        --release-times) release_times=${2:?}; shift 2 ;;
        --commit) commit=1; shift ;;
        --skip-pin) skip_pin=1; shift ;;
        --repo | --dir) pin_args+=("$1" "${2:?}"); shift 2 ;;
        --no-binaries) pin_args+=("$1"); shift ;;
        --root) root=$(cd -- "${2:?}" && pwd) || exit 2; pin_args+=(--root "$root"); shift 2 ;;
        -h | --help) usage ;;
        -*) echo "release-after: unknown option $1" >&2; usage ;;
        *) positional+=("$1"); shift ;;
    esac
done
((${#positional[@]} == 1)) || usage
tag=${positional[0]}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-after: tag must look like v0.2.51, got $tag" >&2; exit 2; }

lineages=$root/tools/test-bootstrap-convergence.mjs
workflow=$root/.github/workflows/bootstrap-convergence.yml
bootstrap=$root/tools/bootstrap-compiler.sh
[[ -f $lineages && -f $workflow && -f $bootstrap ]] || fail "$root is not an ablac checkout"
[[ $times == "" || -f $times ]] || fail "no times file $times"
# The release times are merged and checked now, so a bad directory writes nothing.
release_rows=
if [[ -n $release_times ]]; then
    [[ -d $release_times ]] || fail "no release times directory $release_times"
    shopt -s nullglob
    shard_results=("$release_times"/static-suite-logs-*/suite/results.tsv)
    shopt -u nullglob
    ((${#shard_results[@]} >= 2)) || fail "$release_times has ${#shard_results[@]} static-suite shard results (static-suite-logs-N/suite/results.tsv)"
    release_rows=$(mktemp "${TMPDIR:-/tmp}/release-after-times.XXXXXX")
    trap 'rm -f -- "$release_rows"' EXIT
    sort -n -k1,1 "${shard_results[@]}" > "$release_rows"
    bad=$(awk -F'\t' '!(NF == 5 && $1 ~ /^[0-9]+$/ && $2 == "0" && $3 ~ /^[0-9.]+$/) { n++ } END { print n + 0 }' "$release_rows")
    ((bad == 0)) || fail "$release_times: $bad rows are not a passed command's times (every shard must have passed)"
    twice=$(cut -f1 "$release_rows" | uniq -d | head -n 1)
    [[ -z $twice ]] || fail "$release_times: command $twice is in two shards"
    count=$(wc -l < "$release_rows")
    ((count >= 100)) || fail "$release_times has $count rows (the static suite has hundreds)"
fi

# The checks that need nothing written: the lineage is new, route B's release, the historical commit.
grep -q "^    '$tag': {" "$lineages" && fail "$lineages has a lineage $tag already"
if [[ -z $previous ]]; then
    previous=$(grep -o "^    'v[0-9]*\.[0-9]*\.[0-9]*': {" "$lineages" | tr -d " ':{" |
        sort -t. -k1.2,1n -k2,2n -k3,3n | awk -v tag="$tag" '
            function key(v,  p) { split(substr(v, 2), p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }
            key($0) < key(tag) { prior = $0 } END { print prior }')
    [[ -n $previous ]] || fail "no lineage below $tag (give --previous)"
fi
previous_seed=$(awk -v lineage="$previous" -v q="'" '
    $0 ~ "^    " q lineage q ": \\{" { inside = 1; next }
    inside && /^        seeds: \{/ { seeds = 1; next }
    inside && seeds && /^            a: \[/ { match($0, /[0-9a-f]{64}/); print substr($0, RSTART, RLENGTH); exit }
    inside && /^    \},/ { exit }' "$lineages")
[[ $previous_seed =~ ^[0-9a-f]{64}$ ]] || fail "the lineage $previous in $lineages has no route A seed to be route B (--previous names another release)"
if [[ -z $historical ]]; then
    historical=$(git -C "$root" rev-parse --verify --quiet "refs/tags/$tag^{commit}") ||
        fail "no tag $tag in $root (git fetch --tags, or give --historical with the commit $tag was made from)"
fi
[[ $historical =~ ^[0-9a-f]{40}$ ]] || fail "--historical must be a full 40-digit commit, got $historical"
options_line=$(grep -c '^        options: \[' "$workflow")
default_line=$(awk '/^        options: \[/ { seen = 1; next } seen && /^        default: "v[0-9.]*"$/ { print; exit }' "$workflow")
[[ $options_line -eq 1 && -n $default_line ]] || fail "$workflow has no lineage input of the expected shape (options: [...] then default: \"vX\")"

# 1. the pin
if ((!skip_pin)); then
    "$here/release-pin.sh" "$tag" ${pin_args[@]+"${pin_args[@]}"} || fail "release-pin.sh refused $tag"
fi
grep -q "^version=$tag\$" "$bootstrap" || fail "$bootstrap is not pinned to $tag (run tools/release-pin.sh $tag, or drop --skip-pin)"
seed=$(awk '/^        artifact=ablac-x86_64-linux$/ { want = 1; next } want && /platform_sha256=/ { sub(/.*platform_sha256=/, ""); print; exit }' "$bootstrap")
[[ $seed =~ ^[0-9a-f]{64}$ ]] || fail "no Linux sha256 in $bootstrap"
git_commit() { # message paths...
    local message=$1
    shift
    ((commit)) || return 0
    git -C "$root" add -- "$@" && git -C "$root" commit -q -m "$message" -- "$@" || fail "could not commit: $message"
    echo "release-after: committed: $message"
}
git_commit "Pin the bootstrap compiler to verified Abla $tag artifacts" tools/bootstrap-compiler.sh README.md docs/bootstrap.md

# 2. the lineage
entry=$(printf "    '%s': {\n        historical: '%s',\n        seeds: {\n            a: ['%s', '%s'],\n            b: ['%s', '%s'],\n        },\n    },\n" \
    "$tag" "$historical" "$tag" "$seed" "$previous" "$previous_seed")
temporary=$(mktemp)
trap 'rm -f -- "$temporary" "$temporary.yml" ${release_rows:+"$release_rows"}' EXIT
entry=$entry awk '
    /^export const LINEAGES = \{/ { inside = 1 }
    inside && /^\};/ { printf "%s\n", ENVIRON["entry"]; inside = 0; done = 1 }
    { print }
    END { exit done ? 0 : 1 }' "$lineages" > "$temporary" || fail "no end of LINEAGES in $lineages"
cp "$temporary" "$lineages"
awk -v tag="$tag" '
    /^        options: \[/ { sub(/options: \[/, "options: [\"" tag "\", "); seen = 1 }
    seen && /^        default: "v[0-9.]*"$/ { sub(/"v[0-9.]*"/, "\"" tag "\""); seen = 0 }
    { print }' "$workflow" > "$temporary.yml"
cp "$temporary.yml" "$workflow"
git_commit "Bootstrap convergence: the $tag lineage (route A from $tag, route B from $previous, historical ${historical:0:8}), the workflow's default" \
    tools/test-bootstrap-convergence.mjs .github/workflows/bootstrap-convergence.yml

# 3. the test times
if [[ -n $times ]]; then
    rows=$(awk -F'\t' 'NF == 5 && $1 ~ /^[0-9]+$/ && $3 ~ /^[0-9.]+$/ { n++ } END { print n + 0 }' "$times")
    ((rows >= 100)) || fail "$times has $rows usable rows (a results.tsv of a whole run has hundreds)"
    cp "$times" "$root/tools/test-times.tsv"
    git_commit "tools/test-times.tsv: the times of a whole run at the $tag cut" tools/test-times.tsv
fi
# 4. the release-mode times
if [[ -n $release_rows ]]; then
    cp "$release_rows" "$root/tools/test-times-release.tsv"
    git_commit "tools/test-times-release.tsv: the $tag release run's static-suite times" tools/test-times-release.tsv
fi
((commit)) || git -C "$root" diff --stat
echo "release-after: $tag pinned; lineage $tag added (A $tag ${seed:0:12}, B $previous ${previous_seed:0:12}, historical ${historical:0:12})"
