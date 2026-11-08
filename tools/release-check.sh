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
#
# Options:
#   --repo OWNER/REPO     (default AndreBaltazar8/ablac)
#   --out DIR             where the flattened artifacts go (default build/release-<tag>)
#   --artifacts DIR       use artifacts already downloaded (any folder layout) instead of `gh run download`
#   --previous TAG        the release whose asset names to compare (default: the highest published
#                         release below <tag>)
#   --assets-from FILE    the expected asset names, one per line, instead of asking GitHub
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
positional=()
while (($#)); do
    case $1 in
        --repo) repo=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        --artifacts) artifacts=${2:?}; shift 2 ;;
        --previous) previous=${2:?}; shift 2 ;;
        --assets-from) assets_from=${2:?}; shift 2 ;;
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

# Collect the artifacts in one flat directory.
rm -rf -- "$out"
mkdir -p -- "$out"
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
find "$source_dir" -type f -exec cp -f {} "$out"/ \;
count=$(find "$out" -type f | wc -l | tr -d ' ')

results=()
failed=0
report() { # PASS|FAIL name detail
    results+=("$(printf '%-5s %-8s %s' "$1" "$2" "$3")")
    [[ $1 == PASS ]] || failed=1
}

# 1. assets: the previous release's names.
expected=$(mktemp)
actual=$(mktemp)
trap 'rm -f -- "$expected" "$actual"; [[ -z ${source_dir:-} || -n $artifacts ]] || rm -rf -- "$source_dir"' EXIT
( cd "$out" && ls ) | sort >"$actual"
if [[ -n $assets_from ]]; then
    sort "$assets_from" >"$expected"
    basis="$assets_from"
else
    if [[ -z $previous ]]; then
        previous=$(gh release list -R "$repo" -L 100 --exclude-drafts --json tagName --jq '.[].tagName' 2>/dev/null |
            grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V |
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
if [[ ! -s $expected ]]; then
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

printf 'release-check %s  run %s  %s\n' "$tag" "$run_id" "$out"
printf '%s\n' "${results[@]}"
if ((failed)); then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS (nothing is published by this script)"
