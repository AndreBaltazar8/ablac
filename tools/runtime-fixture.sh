#!/usr/bin/env bash
# Places a test fixture inside a copy of the standard library, under
# abla/runtime, so it may call the runtime-internal intrinsics (only modules
# under abla/runtime may: native.runtime-internal). Prints the fixture's path in
# the copy; build it with ABLA_STDLIB set to <directory>/stdlib.
#
# Usage: tools/runtime-fixture.sh <fixture.ab> <directory>
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$1
directory=$2
mkdir -p -- "$directory"
directory=$(cd -- "$directory" && pwd -P)
rm -rf -- "$directory/stdlib"
cp -R -- "${ABLA_STDLIB:-$project_root/stdlib}" "$directory/stdlib"
mkdir -p -- "$directory/stdlib/abla/runtime/fixtures"
cp -- "$fixture" "$directory/stdlib/abla/runtime/fixtures/"
printf '%s\n' "$directory/stdlib/abla/runtime/fixtures/$(basename -- "$fixture")"
