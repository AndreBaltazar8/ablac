#!/usr/bin/env bash
# The "check before release" step of a release (see the release process notes): the
# artifacts of a publish-off Release workflow run, checked before anything is published.
#
#   tools/release-check.sh <tag> <run-id> <local-stage2> [options]
#
# Downloads the run's artifacts (gh), flattens them into one directory and prints one line per
# check, PASS or FAIL, then exits 1 when any failed:
#   assets      every asset name of the previous release is here, and no other
#   sha256      every `.sha256` file matches its asset, and every asset has one
#   version     the Linux binary's --version prints `ablac <tag without v>`
#   stage2      the Linux binary is byte for byte the local stage 2 (cmp)
#   convergence a green bootstrap-convergence run exists for the release's source commit (tools/release-convergence.sh);
#               required: without --source-ref (or the tag) and a run, this check fails
#   static      (when the run built ablac-static-x86_64-linux, #806 step C) it has no PT_INTERP or DT_NEEDED, prints the version, builds and
#               runs a smoke program and, with ABLA_STATIC_LLVM_LIB set, reaches the fixpoint (tools/test-static-artifact.sh)
#   siblings    (with --siblings) the downstream repositories build and pass their tests with the candidate
#               (tools/test-siblings.sh over tools/siblings.txt)
#
# Options:
#   --repo OWNER/REPO     (default AndreBaltazar8/ablac)
#   --out DIR             where the flattened artifacts go (default build/release-<tag>)
#   --artifacts DIR       use artifacts already downloaded (any folder layout) instead of `gh run download`
#   --previous TAG        the release whose asset names to compare (default: the highest published
#                         release below <tag>)
#   --assets-from FILE    the expected asset names, one per line, instead of asking GitHub
#   --source-ref SHA      the commit the release is made from, for the convergence check (default: the commit
#                         <tag> already names; while the tag does not exist yet, the head sha of the run <run-id>)
#   --convergence-run ID  the bootstrap-convergence workflow run to check (default: the newest green one that matches)
#   --convergence-comparison FILE
#                         a downloaded comparison.json to check instead (with --lineage, no gh is needed)
#   --lineage TAG         the convergence lineage to expect (default: the highest published release below <tag>)
#   --siblings TREE       the downstream step: check 6, siblings, runs tools/test-siblings.sh with TREE (the candidate's
#                         tree, build/ablac built) over tools/siblings.txt; its summary goes to <out>/siblings
#   --siblings-baseline COMPILER
#                         the compiler a sibling program must also fail with to be no regression (the previous
#                         release's); without it every program the candidate can't build counts
set -uo pipefail

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

repo=AndreBaltazar8/ablac
out=
artifacts=
previous=
assets_from=
source_ref=
convergence_run=
convergence_comparison=
lineage=
siblings=
siblings_baseline=
positional=()
while (($#)); do
    case $1 in
        --repo) repo=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        --artifacts) artifacts=${2:?}; shift 2 ;;
        --previous) previous=${2:?}; shift 2 ;;
        --assets-from) assets_from=${2:?}; shift 2 ;;
        --source-ref) source_ref=${2:?}; shift 2 ;;
        --convergence-run) convergence_run=${2:?}; shift 2 ;;
        --convergence-comparison) convergence_comparison=${2:?}; shift 2 ;;
        --lineage) lineage=${2:?}; shift 2 ;;
        --siblings) siblings=${2:?}; shift 2 ;;
        --siblings-baseline) siblings_baseline=${2:?}; shift 2 ;;
        -h | --help) usage ;;
        -*) echo "release-check: unknown option $1" >&2; usage ;;
        *) positional+=("$1"); shift ;;
    esac
done
((${#positional[@]} == 3)) || usage
tag=${positional[0]}
run_id=${positional[1]}
stage2=${positional[2]}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-check: tag must look like v0.2.51, got $tag" >&2; exit 2; }
version=${tag#v}
[[ -f $stage2 ]] || { echo "release-check: no local stage 2 at $stage2" >&2; exit 2; }
out=${out:-build/release-$tag}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Where the flattened artifacts go: refuse a directory this script could wipe by mistake. An existing
# one is only emptied if it is empty or this script made it (it holds the .release-check marker).
physical() { # directory that exists -> its physical path
    (cd -P -- "$1" 2>/dev/null && pwd -P)
}
mkdir -p -- "$(dirname -- "$out")"
out_parent=$(physical "$(dirname -- "$out")") || { echo "release-check: cannot use --out $out" >&2; exit 2; }
out_physical=$out_parent/$(basename -- "$out")
project_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case $out_physical in
    / | "$HOME" | "$project_root" | "$out_parent" | */. | */..)
        echo "release-check: refusing --out $out (it resolves to $out_physical)" >&2
        exit 2 ;;
esac
if [[ -n $artifacts ]]; then
    artifacts_physical=$(physical "$artifacts") || { echo "release-check: no artifacts directory $artifacts" >&2; exit 2; }
    case $out_physical/ in
        "$artifacts_physical"/* ) echo "release-check: --out $out is inside --artifacts $artifacts" >&2; exit 2 ;;
    esac
    case $artifacts_physical/ in
        "$out_physical"/* ) echo "release-check: --out $out contains --artifacts $artifacts" >&2; exit 2 ;;
    esac
fi
if [[ -e $out ]]; then
    if [[ ! -d $out ]]; then
        echo "release-check: --out $out exists and is not a directory" >&2
        exit 2
    fi
    if [[ -n $(ls -A -- "$out") && ! -f $out/.release-check ]]; then
        echo "release-check: --out $out is not empty and was not made by this script (no .release-check marker)" >&2
        exit 2
    fi
    rm -rf -- "$out"
fi
mkdir -p -- "$out"
: >"$out/.release-check"

# Collect the artifacts in one flat directory.
if [[ -n $artifacts ]]; then
    source_dir=$artifacts
else
    source_dir=$(mktemp -d)
    trap 'rm -rf -- "$source_dir"' EXIT
    if ! gh run download "$run_id" -R "$repo" -D "$source_dir" >/dev/null 2>&1; then
        echo "release-check: gh run download $run_id -R $repo failed" >&2
        exit 2
    fi
fi
# Two artifacts holding a file of the same name would overwrite each other in the flat directory:
# list the names first and report a repeat.
duplicates=$(find "$source_dir" -type f -exec basename {} \; | sort | uniq -d | tr '\n' ' ')
find "$source_dir" -type f -exec cp -f {} "$out"/ \;
count=$(find "$out" -type f ! -name .release-check | wc -l | tr -d ' ')

results=()
failed=0
report() { # PASS|FAIL name detail
    results+=("$(printf '%-5s %-8s %s' "$1" "$2" "$3")")
    [[ $1 == PASS ]] || failed=1
}

# 1. assets: the previous release's names.
expected=$(mktemp)
actual=$(mktemp)
# (This trap replaces the earlier one on purpose: it repeats that cleanup of the download directory, which
# only exists when nothing was given with --artifacts, and also removes the two temporary lists.)
trap 'rm -f -- "$expected" "$actual"; [[ -z ${source_dir:-} || -n $artifacts ]] || rm -rf -- "$source_dir"' EXIT
( cd "$out" && ls ) | sort >"$actual"   # (ls leaves out the .release-check marker)
# The static compiler (#806 step C) is an optional extra next to the dynamic one: its names are neither expected nor an extra; check 7 judges it.
static_names=$(grep -E "^ablac-static-x86_64-linux(\.sha256)?\$" "$actual" || true)
grep -vE "^ablac-static-x86_64-linux(\.sha256)?\$" "$actual" > "$actual.filtered" || true
mv -f "$actual.filtered" "$actual"
if [[ -n $assets_from ]]; then
    sort "$assets_from" >"$expected"
    basis="$assets_from"
else
    if [[ -z $previous ]]; then
        previous=$(gh release list -R "$repo" -L 100 --exclude-drafts --json tagName --jq '.[].tagName' 2>/dev/null |
            grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | sed 's/^/v/' |
            awk -v tag="$tag" 'BEGIN { prior = "" } $0 == tag { print prior; found = 1; exit } { prior = $0 }
                END { if (!found) print prior }')
    fi
    if [[ -n $previous ]] && gh release view "$previous" -R "$repo" --json assets --jq '.assets[].name' 2>/dev/null | sort >"$expected" &&
        [[ -s $expected ]]; then
        basis="$previous"
    else
        : >"$expected"
        basis="(no previous release found)"
    fi
fi
grep -vE "^ablac-static-x86_64-linux(\.sha256)?\$" "$expected" > "$expected.filtered" || true
mv -f "$expected.filtered" "$expected"
if ((count == 0)); then
    report FAIL assets "no files in the artifacts"
elif [[ -n $duplicates ]]; then
    report FAIL assets "the same file name in more than one artifact: ${duplicates% }"
elif [[ ! -s $expected ]]; then
    report FAIL assets "no expected asset names ($basis)"
elif diff -q "$expected" "$actual" >/dev/null; then
    report PASS assets "$count files, the names of $basis"
else
    missing=$(comm -23 "$expected" "$actual" | tr '\n' ' ')
    extra=$(comm -13 "$expected" "$actual" | tr '\n' ' ')
    report FAIL assets "against $basis: missing [${missing% }] extra [${extra% }]"
fi

# 2. sha256: every .sha256 file against its asset, and every asset has one.
bad=
checked=0
for file in "$out"/*; do
    [[ -e $file ]] || continue
    name=$(basename "$file")
    if [[ $name == *.sha256 ]]; then
        asset=${name%.sha256}
        line=$(head -n 1 "$file")
        want=${line%% *}
        named=${line##* }
        if [[ ! -f $out/$asset ]]; then
            bad="$bad $name(no $asset)"
        elif [[ $named != "$asset" ]]; then
            bad="$bad $name(names $named)"
        elif [[ $(sha256 "$out/$asset") != "$want" ]]; then
            bad="$bad $name(differs)"
        else
            checked=$((checked + 1))
        fi
    elif [[ ! -f $out/$name.sha256 ]]; then
        bad="$bad $name(no .sha256)"
    fi
done
if [[ -z $bad ]]; then
    report PASS sha256 "$checked files match their .sha256"
else
    report FAIL sha256 "${bad# }"
fi

# 3. version: the Linux binary prints the tag's version.
linux=$out/ablac-x86_64-linux
if [[ ! -f $linux ]]; then
    report FAIL version "no ablac-x86_64-linux in $out"
elif [[ $(uname -s)/$(uname -m) != Linux/x86_64 ]]; then
    report FAIL version "this host cannot run ablac-x86_64-linux"
else
    chmod +x "$linux"
    printed=$("$linux" --version 2>&1 | head -n 1)
    if [[ $printed == "ablac $version" ]]; then
        report PASS version "prints '$printed'"
    else
        report FAIL version "prints '$printed', wanted 'ablac $version'"
    fi
fi

# 4. stage2: the Linux binary is the local stage 2.
if [[ ! -f $linux ]]; then
    report FAIL stage2 "no ablac-x86_64-linux in $out"
elif cmp -s "$linux" "$stage2"; then
    report PASS stage2 "cmp equal to $stage2 ($(sha256 "$stage2" | cut -c1-12))"
else
    report FAIL stage2 "differs from $stage2 ($(sha256 "$linux" | cut -c1-12) against $(sha256 "$stage2" | cut -c1-12))"
fi

# 5. convergence: the historical-seed bootstrap routes agree on this release's source (required).
# The source commit: --source-ref, else the commit the tag names (release-convergence.sh reads it), else, while the tag
# does not exist yet, the commit the publish-off run built (its head sha; the run is dispatched on the ref the Prepare
# commit is on), else release-convergence.sh fails with a message that names --source-ref.
source_note=
if [[ -z $source_ref ]] && ! gh api "repos/$repo/commits/$tag" --jq .sha >/dev/null 2>&1; then
    run_sha=$(gh run view "$run_id" -R "$repo" --json headSha --jq .headSha 2>/dev/null || true)
    if [[ $run_sha =~ ^[0-9a-f]{40}$ ]]; then
        source_ref=$run_sha
        source_note=" [source $run_sha: run $run_id's head, $tag does not exist yet]"
    fi
fi
convergence_args=(verify "$tag" --repo "$repo")
[[ -z $source_ref ]] || convergence_args+=(--source-ref "$source_ref")
[[ -z $lineage ]] || convergence_args+=(--lineage "$lineage")
[[ -z $convergence_run ]] || convergence_args+=(--run "$convergence_run")
[[ -z $convergence_comparison ]] || convergence_args+=(--comparison "$convergence_comparison")
convergence=$("$(dirname -- "${BASH_SOURCE[0]}")/release-convergence.sh" "${convergence_args[@]}" 2>&1 | tail -n 1)
if [[ $convergence == PASS* ]]; then
    report PASS convergence "${convergence#PASS  convergence }$source_note"
else
    report FAIL convergence "${convergence#FAIL  convergence }$source_note"
fi

# 6. siblings (with --siblings): the downstream repositories against the candidate, one list (tools/siblings.txt).
if [[ -n $siblings ]]; then
    sibling_args=("$siblings" --out "$out/siblings")
    [[ -z $siblings_baseline ]] || sibling_args+=(--baseline "$siblings_baseline")
    if "$(dirname -- "${BASH_SOURCE[0]}")/test-siblings.sh" "${sibling_args[@]}" > "$out/siblings.log" 2>&1; then
        report PASS siblings "$(($(wc -l < "$out/siblings/summary.txt") - 1)) repositories, no regression ($out/siblings/summary.txt)"
    else
        bad=$(awk 'NR > 1 && ($3 != "0" || $4 == "FAIL") {printf "%s ", $1}' "$out/siblings/summary.txt" 2>/dev/null)
        report FAIL siblings "${bad:-see $out/siblings.log}"
    fi
fi

# 7. static: the statically linked compiler, when the run built one (#806 step C; an extra next to the dynamic default).
if [[ -n $static_names ]]; then
    static=$out/ablac-static-x86_64-linux
    if [[ ! -f $static ]]; then
        report FAIL static "the static compiler's checksum is here but not the compiler"
    elif [[ $(uname -s)/$(uname -m) != Linux/x86_64 ]]; then
        report FAIL static "this host cannot run ablac-static-x86_64-linux"
    else
        chmod +x "$static"
        static_args=("$static" "$version")
        [[ -n ${ABLA_STATIC_LLVM_LIB:-} ]] || static_args+=(--no-fixpoint)
        if (cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && STATIC_ARTIFACT_OUTPUT="$out/static-check" tools/test-static-artifact.sh "${static_args[@]}") > "$out/static.log" 2>&1; then
            report PASS static "no PT_INTERP, no DT_NEEDED, smoke compile$([[ -n ${ABLA_STATIC_LLVM_LIB:-} ]] && echo ', fixpoint' || echo ' (no fixpoint: ABLA_STATIC_LLVM_LIB unset)')"
        else
            report FAIL static "$(tail -n 1 "$out/static.log") ($out/static.log)"
        fi
    fi
fi

printf 'release-check %s  run %s  %s\n' "$tag" "$run_id" "$out"
printf '%s\n' "${results[@]}"
if ((failed)); then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS (nothing is published by this script)"
