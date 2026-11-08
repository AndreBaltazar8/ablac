#!/usr/bin/env bash
# The "pin the bootstrap compiler" step of a release (see the release process notes): moves the
# checksum-pinned bootstrap compiler to a published release.
#
#   tools/release-pin.sh <tag> [options]
#
# Reads the release's three `ablac-*.sha256` assets, checks each against the release's binary,
# then rewrites
#   tools/bootstrap-compiler.sh   the version and the Linux, Intel macOS and Apple Silicon sha256s
#   README.md                     every mention of the version being replaced
#   docs/bootstrap.md             every mention of the version being replaced
# and prints the diff stat. Nothing is committed. Writes nothing when a check fails.
# Needs bash, curl (or --dir), python3 and perl (a minimal CI image may lack the last two).
# Afterwards verify the pin the way the release process says: build master from the pinned
# bootstrap (tools/bootstrap-compiler.sh build/bootstrap-ablac, then the stages) and cmp.
#
# Options:
#   --repo OWNER/REPO   (default AndreBaltazar8/ablac)
#   --dir DIR           the release's .sha256 files (and binaries) are in DIR instead of on GitHub
#   --no-binaries       do not download the binaries to check them against their .sha256
#                       (with --dir this is implied unless the binaries are in DIR)
#   --root DIR          the checkout to rewrite (default: the one this script is in)
set -uo pipefail

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

repo=AndreBaltazar8/ablac
dir=
check_binaries=1
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root_given=0
positional=()
while (($#)); do
    case $1 in
        --repo) repo=${2:?}; shift 2 ;;
        --dir) dir=${2:?}; shift 2 ;;
        --no-binaries) check_binaries=0; shift ;;
        --root) root=${2:?}; root_given=1; shift 2 ;;
        -h | --help) usage ;;
        -*) echo "release-pin: unknown option $1" >&2; usage ;;
        *) positional+=("$1"); shift ;;
    esac
done
((${#positional[@]} == 1)) || usage
tag=${positional[0]}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-pin: tag must look like v0.2.51, got $tag" >&2; exit 2; }

# The default checkout is the one this script is in: not the main checkout while it is on master (that one
# stays clean; pin in a worktree on a branch, or name the checkout with --root).
if ((!root_given)) && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)
    if [[ $branch == master || $branch == main ]] &&
        [[ $(git -C "$root" rev-parse --absolute-git-dir) == "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]]; then
        echo "release-pin: $root is the main checkout, on $branch: pin in a worktree on a branch (or pass --root)" >&2
        exit 2
    fi
fi

script=$root/tools/bootstrap-compiler.sh
[[ -f $script ]] || { echo "release-pin: no $script" >&2; exit 2; }
old=$(sed -n 's/^version=\(v[0-9.]*\)$/\1/p' "$script" | head -n 1)
[[ -n $old ]] || { echo "release-pin: no version= line in $script" >&2; exit 2; }
echo "pinning $old -> $tag"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
artifacts=(ablac-x86_64-linux ablac-x86_64-macos ablac-arm64-macos)

# The release's .sha256 assets (and the binaries, to check them).
fetch() { # name destination
    if [[ -n $dir ]]; then
        [[ -f $dir/$1 ]] || return 1
        cp -f "$dir/$1" "$2"
    else
        curl --fail --silent --show-error --location --retry 3 \
            --output "$2" "https://github.com/$repo/releases/download/$tag/$1"
    fi
}
sum_linux=
sum_intel=
sum_arm=
for artifact in "${artifacts[@]}"; do
    if ! fetch "$artifact.sha256" "$work/$artifact.sha256"; then
        echo "release-pin: cannot get $artifact.sha256 for $tag" >&2
        exit 1
    fi
    line=$(head -n 1 "$work/$artifact.sha256")
    sum=${line%% *}
    named=${line##* }
    if [[ ! $sum =~ ^[0-9a-f]{64}$ || $named != "$artifact" ]]; then
        echo "release-pin: $artifact.sha256 is not '<sha256>  $artifact': $line" >&2
        exit 1
    fi
    case $artifact in
        ablac-x86_64-linux) sum_linux=$sum ;;
        ablac-x86_64-macos) sum_intel=$sum ;;
        ablac-arm64-macos) sum_arm=$sum ;;
    esac
    if ((check_binaries)); then
        if [[ -n $dir && ! -f $dir/$artifact ]]; then
            echo "  $artifact: binary not in $dir, not checked"
        elif ! fetch "$artifact" "$work/$artifact"; then
            echo "release-pin: cannot get $artifact for $tag" >&2
            exit 1
        elif [[ $(sha256 "$work/$artifact") != "$sum" ]]; then
            echo "release-pin: $artifact does not match its $artifact.sha256 ($sum)" >&2
            exit 1
        else
            echo "  $artifact: ${sum:0:12} matches the binary"
        fi
    else
        echo "  $artifact: ${sum:0:12} (binary not checked)"
    fi
done

# Rewrite bootstrap-compiler.sh: the version and, in each platform's case block, its sha256.
python3 - "$script" "$tag" "$sum_linux" "$sum_intel" "$sum_arm" <<'PY' || exit 1
import re, sys
path, tag, linux, intel, arm = sys.argv[1:]
text = open(path).read()
text, n = re.subn(r'^version=v[0-9.]+$', 'version=' + tag, text, count=1, flags=re.M)
if n != 1:
    sys.exit('release-pin: no version= line')
for artifact, sha in (('ablac-x86_64-linux', linux), ('ablac-x86_64-macos', intel), ('ablac-arm64-macos', arm)):
    pattern = r'(artifact=%s\n\s*platform_sha256=)[0-9a-f]{64}' % re.escape(artifact)
    text, n = re.subn(pattern, r'\g<1>' + sha, text, count=1)
    if n != 1:
        sys.exit('release-pin: no platform_sha256 for ' + artifact)
open(path, 'w').write(text)
PY

# README.md and docs/bootstrap.md: every mention of the version being replaced.
# (A mention is the version followed by neither a letter, a digit nor `.digit`, so v0.2.49 leaves v0.2.490 alone.)
for file in README.md docs/bootstrap.md; do
    path=$root/$file
    [[ -f $path ]] || continue
    count=$(OLD=$old perl -ne '$c++ while /(?<![0-9A-Za-z])\Q$ENV{OLD}\E(?![0-9A-Za-z]|\.[0-9])/g; END { print $c + 0 }' "$path")
    OLD=$old NEW=$tag perl -pi -e 's/(?<![0-9A-Za-z])\Q$ENV{OLD}\E(?![0-9A-Za-z]|\.[0-9])/$ENV{NEW}/g' "$path"
    echo "  $file: $count mention(s) of $old now $tag"
done
# The setup-abla version in README.md (`version: '0.2.51'`, no `v`) is the Prepare commit's, not the pin's.
old_plain=${old#v}
if grep -q "'$old_plain'" "$root/README.md" 2>/dev/null; then
    echo "note: README.md still has '$old_plain' (setup-abla version): the Prepare commit bumps that, not the pin"
fi
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$root" diff --stat -- tools/bootstrap-compiler.sh README.md docs/bootstrap.md
    git -C "$root" diff -U0 -- tools/bootstrap-compiler.sh README.md docs/bootstrap.md | grep '^[-+][^-+]' | head -40
    echo "review 'git diff': a mention of $old that is history, not the pin, should stay"
fi
echo "pinned to $tag (not committed)"
