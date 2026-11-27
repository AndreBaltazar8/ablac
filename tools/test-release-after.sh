#!/usr/bin/env bash
# tools/release-after.sh on a copy of this checkout's release files (no network, no gh): the pin, the new lineage and the
# workflow's lineage input change and nothing else does, the workflow still parses as YAML, the convergence unit test passes on
# the result, and each way it must refuse leaves the copy as it was. Usage: tools/test-release-after.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
command -v node > /dev/null || { echo "release-after: node is needed (the convergence unit test)" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "release-after: $*" >&2; exit 1; }
expect_fail() { # description command...
    local description=$1
    shift
    if "$@" > "$work/out.txt" 2>&1; then cat "$work/out.txt" >&2; fail "$description: accepted"; fi
}

# The YAML checker of tools/test-workflow-syntax.sh.
"$compiler" build tests/cases/workflow-syntax/check.ab --fast -o "$work/yamlcheck" > "$work/build.log" 2>&1 || { cat "$work/build.log" >&2; fail "could not build the YAML checker"; }

# A copy of the files the script edits, as a git repository with the next release's tag on its only commit.
make_root() { # directory
    local root=$1 file
    mkdir -p "$root/tools" "$root/.github/workflows" "$root/docs"
    for file in tools/release-pin.sh tools/release-after.sh tools/bootstrap-compiler.sh tools/test-bootstrap-convergence.mjs \
        tools/test-bootstrap-convergence-unit.mjs .github/workflows/bootstrap-convergence.yml README.md docs/bootstrap.md; do
        cp "$file" "$root/$file"
    done
    # None of the fixture's releases is signed (release-pin.sh reads tools/first-signed-release).
    printf 'v99.0.0\n' > "$root/tools/first-signed-release"
    git -C "$root" init -q -b master
    git -C "$root" add -A
    git -C "$root" -c user.name=t -c user.email=t@t commit -q -m start
    git -C "$root" tag v8.8.8
}
snapshot() { (cd "$1" && { cat tools/bootstrap-compiler.sh tools/test-bootstrap-convergence.mjs .github/workflows/bootstrap-convergence.yml README.md docs/bootstrap.md; cat tools/test-times.tsv 2> /dev/null || true; } | sha256sum); }

# The release's three binaries and .sha256 files.
release=$work/release
mkdir -p "$release"
for platform in x86_64-linux x86_64-macos arm64-macos; do
    printf 'binary %s\n' "$platform" > "$release/ablac-$platform"
    printf '%s  ablac-%s\n' "$(sha256sum "$release/ablac-$platform" | cut -d' ' -f1)" "$platform" > "$release/ablac-$platform.sha256"
done
linux_sha=$(sha256sum "$release/ablac-x86_64-linux" | cut -d' ' -f1)
latest=$(grep -o "^    'v[0-9.]*': {" tools/test-bootstrap-convergence.mjs | tr -d " ':{" | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -n 1)
latest_seed=$(awk -v lineage="$latest" -v q="'" '$0 ~ "^    " q lineage q ": " { on = 1 } on && /a: \[/ { match($0, /[0-9a-f]{64}/); print substr($0, RSTART, RLENGTH); exit }' tools/test-bootstrap-convergence.mjs)
[[ -n $latest && $latest_seed =~ ^[0-9a-f]{64}$ ]] || fail "could not read the newest lineage of this checkout"

# --- the good run.
root=$work/root
make_root "$root"
historical=$(git -C "$root" rev-parse v8.8.8)
before=$(snapshot "$root")
"$root/tools/release-after.sh" v8.8.8 --dir "$release" --root "$root" > "$work/out.txt" 2>&1 || { cat "$work/out.txt" >&2; fail "release-after refused a good release"; }
[[ $(snapshot "$root") != "$before" ]] || fail "release-after changed nothing"
grep -q "^version=v8.8.8\$" "$root/tools/bootstrap-compiler.sh" || fail "the pin was not moved"
grep -q "platform_sha256=$linux_sha\$" "$root/tools/bootstrap-compiler.sh" || fail "the Linux sha256 was not pinned"
# The lineage: exactly the eight added lines, route A the new Linux seed, route B the previous release's, the tag's commit.
diff <(git -C "$root" show HEAD:tools/test-bootstrap-convergence.mjs) "$root/tools/test-bootstrap-convergence.mjs" > "$work/mjs.diff" || true
[[ $(grep -c '^<' "$work/mjs.diff") -eq 0 && $(grep -c '^>' "$work/mjs.diff") -eq 7 ]] || { cat "$work/mjs.diff" >&2; fail "the lineage edit is not seven added lines"; }
grep -q "^>     'v8.8.8': {" "$work/mjs.diff" || fail "no v8.8.8 lineage"
grep -q "^>         historical: '$historical'," "$work/mjs.diff" || fail "the historical commit is not the tag's"
grep -q "^>             a: \['v8.8.8', '$linux_sha'\]," "$work/mjs.diff" || fail "route A is not the new Linux seed"
grep -q "^>             b: \['$latest', '$latest_seed'\]," "$work/mjs.diff" || fail "route B is not the previous release's seed"
# The workflow: the options line and the default line, nothing else, still valid YAML.
diff <(git -C "$root" show HEAD:.github/workflows/bootstrap-convergence.yml) "$root/.github/workflows/bootstrap-convergence.yml" > "$work/yml.diff" || true
[[ $(grep -c '^[<>]' "$work/yml.diff") -eq 4 && $(grep -c '^<' "$work/yml.diff") -eq 2 ]] || { cat "$work/yml.diff" >&2; fail "the workflow changed more than its two lineage lines"; }
grep -q '^>         options: \["v8.8.8", ' "$work/yml.diff" && grep -q '^>         default: "v8.8.8"$' "$work/yml.diff" || fail "the workflow's options and default are not v8.8.8"
"$work/yamlcheck" "$root/.github/workflows/bootstrap-convergence.yml" > "$work/yaml.log" 2>&1 || { cat "$work/yaml.log" >&2; fail "the edited workflow is not valid YAML"; }
# The convergence gate's own unit test accepts the result (the two lists agree, every lineage is well formed).
(cd "$root" && node tools/test-bootstrap-convergence-unit.mjs > "$work/unit.log" 2>&1) || { tail -20 "$work/unit.log" >&2; fail "the convergence unit test failed on the edited files"; }

# --- refusals leave the copy as it was.
refuse() { # description command...: refused, and the copy unchanged
    local description=$1 directory=$2
    shift 2
    local mark
    mark=$(snapshot "$directory")
    expect_fail "$description" "$@"
    [[ $(snapshot "$directory") == "$mark" ]] || fail "$description: the refused run changed files"
}
refuse "a lineage that exists already" "$root" "$root/tools/release-after.sh" v8.8.8 --skip-pin --root "$root"
root2=$work/root2
make_root "$root2"
refuse "no tag and no --historical" "$root2" "$root2/tools/release-after.sh" v8.8.10 --dir "$release" --root "$root2"
grep -q -- '--historical' "$work/out.txt" || fail "no mention of --historical"
refuse "a short --historical" "$root2" "$root2/tools/release-after.sh" v8.8.8 --historical abc123 --dir "$release" --root "$root2"
refuse "a --previous with no lineage" "$root2" "$root2/tools/release-after.sh" v8.8.8 --previous v1.0.0 --dir "$release" --root "$root2"
refuse "--skip-pin on an unpinned checkout" "$root2" "$root2/tools/release-after.sh" v8.8.8 --skip-pin --root "$root2"
refuse "a doctored .sha256" "$root2" env -i PATH="$PATH" bash -c "cp -r '$release' '$work/bad' && printf '0%s\n' \"\$(cut -c2- '$work/bad/ablac-x86_64-linux.sha256')\" > '$work/bad/ablac-x86_64-linux.sha256' && '$root2/tools/release-after.sh' v8.8.8 --dir '$work/bad' --root '$root2'"
refuse "a bad tag" "$root2" "$root2/tools/release-after.sh" 8.8.8 --dir "$release" --root "$root2"
refuse "a times file with no rows" "$root2" "$root2/tools/release-after.sh" v8.8.8 --times /dev/null --dir "$release" --root "$root2"
# The release run's static-suite shards, as `gh run download -p 'static-suite-logs-*'` writes them: two of 60 commands each.
shard_logs() { # directory
    local n
    for n in $(seq 120); do
        mkdir -p "$1/static-suite-logs-$(( (n - 1) % 2 + 1 ))/suite"
        printf '%s\t0\t%s.5\ttools/test-fake-%s.sh\t1.2\n' "$n" "$n" "$n" >> "$1/static-suite-logs-$(( (n - 1) % 2 + 1 ))/suite/results.tsv"
    done
}
shard_logs "$work/failed-shard"
sed -i '1s/\t0\t/\t1\t/' "$work/failed-shard/static-suite-logs-2/suite/results.tsv"
refuse "release times with a failed command" "$root2" "$root2/tools/release-after.sh" v8.8.8 --release-times "$work/failed-shard" --dir "$release" --root "$root2"
shard_logs "$work/twice"
head -n 1 "$work/twice/static-suite-logs-1/suite/results.tsv" >> "$work/twice/static-suite-logs-2/suite/results.tsv"
refuse "release times with a command in two shards" "$root2" "$root2/tools/release-after.sh" v8.8.8 --release-times "$work/twice" --dir "$release" --root "$root2"
shard_logs "$work/one-shard"
rm -r -- "$work/one-shard/static-suite-logs-2"
refuse "release times from one shard" "$root2" "$root2/tools/release-after.sh" v8.8.8 --release-times "$work/one-shard" --dir "$release" --root "$root2"
# A workflow of another shape is refused before anything is written.
root3=$work/root3
make_root "$root3"
sed -i '/^        default: "v[0-9.]*"$/d' "$root3/.github/workflows/bootstrap-convergence.yml"
git -C "$root3" -c user.name=t -c user.email=t@t commit -q -am "no default"
refuse "a workflow without its default line" "$root3" "$root3/tools/release-after.sh" v8.8.8 --dir "$release" --root "$root3"

# --- --commit and --times: three commits, each with only its files.
root4=$work/root4
make_root "$root4"
rows=$work/times.tsv
for n in $(seq 120); do printf '%s\t0\t1.5\ttools/test-fake-%s.sh\t1.2\n' "$n" "$n"; done > "$rows"
shard_logs "$work/release-logs"
# A CI runner has no git identity, and --commit commits: give it one for this copy only.
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
"$root4/tools/release-after.sh" v8.8.8 --dir "$release" --root "$root4" --times "$rows" --release-times "$work/release-logs" --commit > "$work/out.txt" 2>&1 || { cat "$work/out.txt" >&2; fail "release-after --commit refused a good release"; }
[[ $(git -C "$root4" rev-list --count HEAD) -eq 5 ]] || fail "--commit did not make four commits"
[[ -z $(git -C "$root4" status --porcelain) ]] || fail "--commit left changes"
[[ $(git -C "$root4" show --stat --format= HEAD~3 | grep -c '|') -eq 3 ]] || fail "the pin commit holds other files than the pin's"
[[ $(git -C "$root4" show --stat --format= HEAD~2 | grep -c '|') -eq 2 ]] || fail "the lineage commit holds other files than the lineage's"
[[ $(git -C "$root4" show --stat --format= HEAD~1 | grep -c '|') -eq 1 ]] || fail "the times commit holds other files"
[[ $(git -C "$root4" show --stat --format= HEAD | grep -c '|') -eq 1 ]] || fail "the release times commit holds other files"
cmp -s "$rows" "$root4/tools/test-times.tsv" || fail "the times file was not copied"
# The release times: both shards' rows, merged in command order.
sort -n -k1,1 "$work"/release-logs/static-suite-logs-*/suite/results.tsv | cmp -s - "$root4/tools/test-times-release.tsv" || fail "the release times are not the shards' rows in order"
[[ $(cut -f1 "$root4/tools/test-times-release.tsv" | head -n 3 | tr '\n' ' ') == '1 2 3 ' ]] || fail "the release times are not in command order"
[[ $(git -C "$root4" log -1 --format=%s HEAD~3) == 'Pin the bootstrap compiler to verified Abla v8.8.8 artifacts' ]] || fail "the pin commit message"
echo "release after: the pin, the lineage and the workflow's lineage input change and nothing else, the workflow parses, the convergence unit test passes; thirteen refusals leave the files alone; --commit makes the four commits (the release times merged from the static-suite shards)"
