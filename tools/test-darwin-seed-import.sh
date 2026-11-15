#!/usr/bin/env bash
# The Darwin system calls live in platform/darwin, which a compiler loads for a Mach-O target (or a macOS host).
# A seed compiler that predates that loader (the pinned bootstrap) loads host.ab only, so the compiler's own
# source must import platform/darwin itself: otherwise the stage-1 Mac compiler built by that seed has no
# dispatcher and panics at its first mmap (ENOSYS). Reproduction on Linux: build src/orc_main.ab with the
# seed for --target arm64-macos (ABLA_MACOS_SDK an empty directory: the link fails, the .ll is written) and look for a define of __ablaRuntimeDarwinSyscall.
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
grep -qx 'import "abla/runtime/platform/darwin"' "$project_root/src/toolchain.ab" || {
    echo "darwin-seed-import: src/toolchain.ab must import abla/runtime/platform/darwin" >&2
    exit 1
}
echo "darwin-seed-import: the compiler's source imports the Darwin system calls itself"
