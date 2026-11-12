#!/usr/bin/env bash
# Verify a fixture directory against its MANIFEST: every listed file must exist with
# the recorded size and sha256, and no unlisted file may sit beside it. MANIFEST
# lines are `sha256<TAB>size<TAB>name<TAB>recipe`; lines starting with # are notes.
# Usage: verify-fixture-manifest.sh DIR
set -euo pipefail
dir=${1:?usage: verify-fixture-manifest.sh DIR}
manifest="$dir/MANIFEST"
[[ -f $manifest ]] || { echo "fixtures: $manifest is missing" >&2; exit 1; }
if command -v sha256sum > /dev/null; then hash() { sha256sum "$1" | cut -d' ' -f1; }
else hash() { shasum -a 256 "$1" | cut -d" " -f1; }; fi
listed=$(mktemp)
trap 'rm -f "$listed"' EXIT
tab=$(printf '\t')
count=0
while IFS="$tab" read -r want_hash want_size name _recipe; do
    case $want_hash in ''|'#'*) continue ;; esac
    file="$dir/$name"
    [[ -f $file ]] || { echo "fixtures: $name is missing from $dir" >&2; exit 1; }
    [[ $(wc -c < "$file" | tr -d ' ') == "$want_size" ]] || { echo "fixtures: $name has the wrong size" >&2; exit 1; }
    [[ $(hash "$file") == "$want_hash" ]] || { echo "fixtures: $name does not match its recorded sha256" >&2; exit 1; }
    echo "$name" >> "$listed"
    count=$((count + 1))
done < "$manifest"
[[ $count -gt 0 ]] || { echo "fixtures: $manifest lists no files" >&2; exit 1; }
while IFS= read -r path; do
    name=${path#"$dir"/}
    [[ $name == MANIFEST ]] || grep -qxF "$name" "$listed" || { echo "fixtures: $name is not in the MANIFEST" >&2; exit 1; }
done < <(find "$dir" -type f)
