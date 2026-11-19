#!/usr/bin/env bash
# The text of a release's publish notes, from the release notes draft and the convergence notes:
#
#   tools/release-notes.sh <tag> <draft> [options]
#
# The draft (notes-0XX.md) without its header line (the first line, "DRAFT for ..."), without the "## Housekeeping" and
# "## At release time" sections (each runs to the next "## " heading), and with the convergence notes that
# tools/release-convergence.sh writes appended, ready for `gh release create ... --notes-file`. Refuses a draft that
# still has a `[pending]` line, or a first line that is not the header, and a convergence file that is missing or does
# not belong to <tag>.
#
# Options:
#   --convergence FILE   the convergence notes (default build/release-<tag>.notes.md, where release-convergence.sh writes them)
#   --out FILE           where the notes go (default build/release-<tag>.publish.md); the path is printed
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}
fail() { echo "release-notes: $*" >&2; exit 1; }

convergence=
out=
positional=()
while (($#)); do
    case $1 in
        --convergence) convergence=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        -h | --help) usage ;;
        -*) echo "release-notes: unknown option $1" >&2; usage ;;
        *) positional+=("$1"); shift ;;
    esac
done
((${#positional[@]} == 2)) || usage
tag=${positional[0]}
draft=${positional[1]}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-notes: tag must look like v0.2.51, got $tag" >&2; exit 2; }
convergence=${convergence:-build/release-$tag.notes.md}
out=${out:-build/release-$tag.publish.md}
[[ -f $draft ]] || fail "no draft at $draft"
[[ -f $convergence ]] || fail "no convergence notes at $convergence (tools/release-convergence.sh run $tag writes them)"

[[ $(sed -n 1p "$draft") == 'DRAFT for '* ]] || fail "the first line of $draft is not the 'DRAFT for ...' header"
if tail -n +2 "$draft" | grep -n '\[pending\]' >&2; then   # (the header line may say "nothing is [pending]")
    fail "$draft still has [pending] lines (listed above)"
fi
grep -q "^### Bootstrap convergence" "$convergence" || fail "$convergence has no '### Bootstrap convergence' section"
grep -q "bootstrapped the source of $tag (" "$convergence" || fail "$convergence is not the convergence notes of $tag"
grep -q '^## Housekeeping' "$draft" || fail "$draft has no '## Housekeeping' section (is it the right file?)"

mkdir -p -- "$(dirname -- "$out")"
{
    awk '
        NR == 1 { next }
        /^## / { skip = ($0 ~ /^## Housekeeping/ || $0 ~ /^## At release time/) }
        !skip { print }
    ' "$draft" | awk 'NF { started = 1 } started { print }' | awk '{ lines[NR] = $0 } END { n = NR; while (n > 0 && lines[n] == "") n--; for (i = 1; i <= n; i++) print lines[i] }'
    printf '\n'
    cat "$convergence"
} >"$out"
echo "$out"
