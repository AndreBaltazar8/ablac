#!/usr/bin/env bash
# A clean build from a compiler that predates typed instances goes through a
# copy of the standard library whose runtime also keeps the older layout
# (tools/build-self-hosted-current.sh, docs/bootstrap.md): the patch that makes
# that copy still applies to this standard library, and the probe that decides
# whether the step runs exits 42 when built by this compiler, against either
# runtime.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/bootstrap-untyped-objects"
rm -rf "$output_directory"
mkdir -p "$output_directory"

cp -R "$project_root/stdlib" "$output_directory/stdlib"
patch -p1 -s -d "$output_directory" < "$project_root/tools/bootstrap-untyped-objects.patch" ||
    { echo "bootstrap untyped objects: the patch no longer applies to stdlib/" >&2; exit 1; }

probe() { # name [environment...]
    local name=$1 status=0
    shift
    env "$@" "$compiler" build "$project_root/tools/bootstrap-typed-instances.ab" \
        -o "$output_directory/$name" --no-cache > "$output_directory/$name.log" 2>&1 ||
        { cat "$output_directory/$name.log" >&2; exit 1; }
    ABLA_MAX_SECONDS=60 "$project_root/tools/run-limited.sh" "$output_directory/$name" > /dev/null 2>&1 ||
        status=$?
    [[ $status -eq 42 ]] ||
        { echo "bootstrap untyped objects: the $name probe exited $status, expected 42" >&2; exit 1; }
}
probe typed
probe untyped ABLA_STDLIB="$output_directory/stdlib"
echo "bootstrap untyped objects: the patch applies and the probe sees typed instances"
