#!/usr/bin/env bash
# Shared by the real toolchain packagers and the installed-toolchain CI probe.
set -euo pipefail
if [[ $# != 1 || ! -f $1/libexec/ablac.bin ]]; then
    echo "usage: package-xtensa-installer.sh TOOLCHAIN_ROOT (needs libexec/ablac.bin)" >&2
    exit 2
fi
bundle=$1
installer_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$bundle/bin" "$bundle/libexec/abla" "$bundle/share/abla"
cp "$installer_source/tools/install-xtensa-llvm.py" "$bundle/bin/abla-install-xtensa"
cp "$installer_source/tools/xtensa_companions.py" "$bundle/libexec/abla/xtensa_companions.py"
cp "$installer_source/tools/xtensa-companions.json" "$bundle/share/abla/xtensa-companions.json"
chmod 0755 "$bundle/bin/abla-install-xtensa"
chmod 0644 "$bundle/libexec/abla/xtensa_companions.py" "$bundle/share/abla/xtensa-companions.json"
