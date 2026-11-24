#!/usr/bin/env bash
# The release artifacts, one directory each (actions/download-artifact without merge-multiple), into one directory for the
# signer. A file name that two artifacts share is refused: merging them would let the later overwrite the earlier without a
# trace (#1139 area 6, round 2). tools/release-flatten-artifacts.sh PARTS DEST   (DEST is created and must not exist)
set -euo pipefail
parts=${1:?usage: release-flatten-artifacts.sh PARTS DEST}
dest=${2:?usage: release-flatten-artifacts.sh PARTS DEST}
[[ -d $parts ]] || { echo "release-flatten-artifacts: $parts is not a directory" >&2; exit 1; }
[[ ! -e $dest ]] || { echo "release-flatten-artifacts: $dest exists" >&2; exit 1; }
shared=$(find "$parts" -type f -printf '%f\n' | sort | uniq -d)
if [[ -n $shared ]]; then
    printf 'release-flatten-artifacts: the same file name in two artifacts: %s\n' "$(tr '\n' ' ' <<< "$shared")" >&2
    exit 1
fi
mkdir -p "$dest"
find "$parts" -type f -exec mv -t "$dest" {} +
echo "release-flatten-artifacts: $(find "$dest" -type f | wc -l) files in $dest"
