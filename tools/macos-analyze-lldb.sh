#!/usr/bin/env bash
# Runs `<compiler> analyze --stdio` on a recorded session under lldb (macOS) and prints, when it stops on a signal, every
# thread's backtrace, the stopped thread's registers and frame, the faulting address's region and the thread's stack bounds:
# what tells a stack guard page from a misaligned or unmapped access. Used by .github/workflows/macos-analyze-session.yml.
# Usage: tools/macos-analyze-lldb.sh <compiler> <session.jsonl>
set -uo pipefail
compiler=$1
session=$2
lldb --batch \
    -o 'settings set target.process.stop-on-exec false' \
    -o "process launch -i $session -o /dev/null -- analyze --stdio" \
    -k 'thread backtrace all' \
    -k 'register read' \
    -k 'frame variable' \
    -k 'disassemble --pc --count 12' \
    -k 'memory region $sp' \
    -k 'thread info' \
    -k 'image list -o -f ablac' \
    -k 'quit' \
    -- "$compiler"
