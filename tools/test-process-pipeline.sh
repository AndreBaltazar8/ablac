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
timeout 20 python3 -c 'import os, signal; signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGPIPE}); os.execv("build/process-pipeline-test/main", ["main"])'
"$compiler" build tests/cases/process-pipeline/groups.ab -o build/process-pipeline-test/groups --fast --no-cache
ABLA_GROUP_TEST_FILE="$root/build/process-pipeline-test/group.txt" timeout 20 build/process-pipeline-test/groups
"$compiler" build tests/cases/process-pipeline/pipe-failure.ab -o build/process-pipeline-test/pipe-failure --fast --no-cache
(ulimit -n 12; timeout 20 build/process-pipeline-test/pipe-failure)
if [[ $(uname -s) == Linux ]]; then
    "$compiler" build tests/cases/process-pipeline/fork-failure.ab -o build/process-pipeline-test/fork-failure --fast --no-cache
    cc -shared -fPIC tests/cases/process-pipeline/fail-second-fork.c -o build/process-pipeline-test/fail-second-fork.so -ldl
    LD_PRELOAD="$root/build/process-pipeline-test/fail-second-fork.so" timeout 20 build/process-pipeline-test/fork-failure
fi
echo 'process pipeline: captures, status, snapshots, SIGPIPE, failures and group stop'
