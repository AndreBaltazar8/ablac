#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/process-pipeline-test
"$compiler" build tests/cases/process-pipeline/main.ab -o build/process-pipeline-test/main --fast --no-cache
timeout 20 build/process-pipeline-test/main
timeout 20 build/process-pipeline-test/main >&- 2>&-
(ulimit -n 24; timeout 20 build/process-pipeline-test/main)
(trap '' PIPE; timeout 20 build/process-pipeline-test/main)
# A blocked SIGPIPE (in the signal mask, inherited through exec) is not the ignored
# SIGPIPE of the line above; the shell cannot set a mask, so a small Abla program
# blocks it with rt_sigprocmask and execs the test. Control: the mask must really
# reach the executed program (SigBlk in /proc/self/status has bit 12, 0x1000).
"$compiler" build tests/cases/process-pipeline/block-sigpipe.ab -o build/process-pipeline-test/block-sigpipe --fast --no-cache
shell=$(command -v sh)
blocked=$(timeout 20 build/process-pipeline-test/block-sigpipe "$shell" sh -c 'grep "^SigBlk:" /proc/self/status' | awk '{ print $2 }')
(( 0x$blocked & 0x1000 )) || { echo "process pipeline: SIGPIPE was not blocked (SigBlk $blocked)" >&2; exit 1; }
timeout 20 build/process-pipeline-test/block-sigpipe build/process-pipeline-test/main main
"$compiler" build tests/cases/process-pipeline/groups.ab -o build/process-pipeline-test/groups --fast --no-cache
ABLA_GROUP_TEST_FILE="$root/build/process-pipeline-test/group.txt" timeout 20 build/process-pipeline-test/groups
"$compiler" build tests/cases/process-pipeline/pipe-failure.ab -o build/process-pipeline-test/pipe-failure --fast --no-cache
(ulimit -n 12; timeout 20 build/process-pipeline-test/pipe-failure)
if [[ $(uname -s) == Linux ]]; then
    # A --fast build does not inline, so the choice of fork must be folded away before code is
    # emitted: on x86-64 Linux the program must not import libc fork or signal at all.
    "$compiler" build tests/cases/process-pipeline/main.ab -o build/process-pipeline-test/main-fast --fast --no-cache
    if [[ $(uname -m) == x86_64 ]] && nm -D --undefined-only build/process-pipeline-test/main-fast 2>/dev/null | awk '{ print $NF }' | grep -qE '^(fork|signal)(@|$)'; then
        echo 'process pipeline: a --fast program still imports libc fork or signal' >&2
        exit 1
    fi
    "$compiler" build tests/cases/process-pipeline/fork-failure.ab -o build/process-pipeline-test/fork-failure --fast --no-cache
    timeout 20 build/process-pipeline-test/fork-failure
fi
echo 'process pipeline: captures, status, snapshots, SIGPIPE, failures and group stop'
