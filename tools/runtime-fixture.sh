#!/usr/bin/env bash
# Builds a test fixture as one of the runtime's modules, so it may call the
# runtime-internal intrinsics (only modules under abla/runtime may:
# native.runtime-internal). In a copy of the standard library, the fixture
# becomes the module abla/runtime/fixtures/<name> (its `main` renamed
# runtimeFixtureMain), and a program beside the copy imports it and returns
# what that main returns. Prints the program's path; build it with ABLA_STDLIB
# set to <directory>/stdlib.
#
# The module is found through the standard library's root, however that root
# is spelled (a symlink, a relative path), as the runtime's own modules are.
#
# Usage: tools/runtime-fixture.sh <fixture.ab> <directory>
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$1
directory=$2
name=$(basename -- "$fixture" .ab)
mkdir -p -- "$directory"
rm -rf -- "$directory/stdlib"
cp -R -- "${ABLA_STDLIB:-$project_root/stdlib}" "$directory/stdlib"
module="$directory/stdlib/abla/runtime/fixtures/$name"
mkdir -p -- "$module"
sed -E 's/(^|[^A-Za-z0-9_])fun main([^A-Za-z0-9_]|$)/\1fun runtimeFixtureMain\2/' \
    "$fixture" > "$module/entry.ab"
printf 'import "abla/runtime/fixtures/%s"\n\nfun main: int = runtimeFixtureMain()\n' \
    "$name" > "$directory/$name.ab"
printf '%s\n' "$directory/$name.ab"
