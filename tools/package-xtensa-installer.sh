#!/usr/bin/env bash
# Install the catalog used by the packaged native Xtensa companion installer.
set -euo pipefail
if [[ $# != 1 || ! -f $1/libexec/ablac.bin ]]; then
    echo "usage: package-xtensa-installer.sh TOOLCHAIN_ROOT (needs libexec/ablac.bin)" >&2
    exit 2
fi
bundle=$1
installer_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$bundle/share/abla"
cp "$installer_source/tools/xtensa-companions.json" "$bundle/share/abla/xtensa-companions.json"
chmod 0644 "$bundle/share/abla/xtensa-companions.json"
