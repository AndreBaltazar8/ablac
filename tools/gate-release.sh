#!/usr/bin/env bash
# The release gate for one worktree: tools/gate.sh --release (stages 1-3 from the pinned bootstrap compiler with stage 3 built whole,
# make self-rebuild, the FULL suite, the reproducible-elsewhere check). See tools/gate.sh for the slots, the log and the options.
#
#   tools/gate-release.sh <worktree> [slot] [--dry-run]
exec "$(dirname -- "${BASH_SOURCE[0]}")/gate.sh" --release "$@"
