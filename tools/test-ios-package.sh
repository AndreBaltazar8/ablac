#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) == Darwin ]]; then
    echo 'iOS package host refusal: not applicable on macOS; Simulator CI covers packaging'
    exit 0
fi
cd "$project_root"
directory="$project_root/build/ios-target-test"
mkdir -p "$directory"
if "$compiler" build tests/cases/ios-target/package-host-refusal.ab \
    -o "$directory/package-host-refusal" --fast --no-cache \
    >"$directory/package-host-refusal.log" 2>&1; then
    echo 'iOS package: accepted XCFramework packaging away from macOS' >&2
    exit 1
fi
grep -Fq 'error[E_IOS_XCFRAMEWORK_HOST]' "$directory/package-host-refusal.log"
[[ ! -e "$directory/unavailable.xcframework" ]]
echo 'iOS package: named unsupported-host refusal passed'
