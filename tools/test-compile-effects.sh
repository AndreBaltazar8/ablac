#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/compile-effects-test"
mkdir -p "$output_directory"
input="$project_root/tests/cases/capabilities/input.txt"
manifest="$project_root/tests/cases/capabilities/abla.toml"
input_original=$(<"$input")
manifest_original=$(<"$manifest")
network_server_pid=''
restore_inputs() {
    printf '%s\n' "$input_original" > "$input"
    printf '%s\n' "$manifest_original" > "$manifest"
}
cleanup() {
    if [[ -n $network_server_pid ]]; then
        kill "$network_server_pid" 2>/dev/null || true
        wait "$network_server_pid" 2>/dev/null || true
    fi
    restore_inputs
}
trap cleanup EXIT

set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-effect-filesystem.ab" \
    > "$output_directory/denied.ll" \
    2> "$output_directory/denied.err"
denied_status=$?
set -e
[[ $denied_status -ne 0 ]]
grep -q 'compile.effect-denied:filesystem.read:loadBuildInput->readBuildInput->ablaHostReadFile' \
    "$output_directory/denied.err"

set +e
ABLA_COMPILE_TEST_INPUT=denied \
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-effect-environment.ab" \
    > "$output_directory/environment-denied.ll" \
    2> "$output_directory/environment-denied.err"
environment_denied_status=$?
set -e
[[ $environment_denied_status -ne 0 ]]
grep -q 'compile.effect-denied:environment:readBuildEnvironment->compilerEnvironment' \
    "$output_directory/environment-denied.err"

set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-effect-clock.ab" \
    > "$output_directory/clock-denied.ll" \
    2> "$output_directory/clock-denied.err"
clock_denied_status=$?
set -e
[[ $clock_denied_status -ne 0 ]]
grep -q 'compile.effect-denied:clock:currentBuildClock->compilerClockMilliseconds' \
    "$output_directory/clock-denied.err"

set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-effect-write.ab" \
    > "$output_directory/write-denied.ll" \
    2> "$output_directory/write-denied.err"
write_denied_status=$?
set -e
[[ $write_denied_status -ne 0 ]]
grep -q 'compile.effect-denied:filesystem.write:compilerWriteFile' \
    "$output_directory/write-denied.err"

set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-effect-network.ab" \
    > "$output_directory/network-denied.ll" \
    2> "$output_directory/network-denied.err"
network_denied_status=$?
set -e
[[ $network_denied_status -ne 0 ]]
grep -q 'compile.effect-denied:network:compilerTcpExchange' \
    "$output_directory/network-denied.err"

set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-capability-authorization.ab" \
    > "$output_directory/unauthorized.ll" \
    2> "$output_directory/unauthorized.err"
unauthorized_status=$?
set -e
[[ $unauthorized_status -ne 0 ]]
grep -q 'compile.capability-not-authorized:filesystem.read' \
    "$output_directory/unauthorized.err"

set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" --emit-llvm \
    "$project_root/tests/cases/capabilities/subparser-input-denied.ab" \
    > "$output_directory/subparser-denied.ll" \
    2> "$output_directory/subparser-denied.err"
subparser_denied_status=$?
set -e
[[ $subparser_denied_status -ne 0 ]]
grep -q 'LLVM compilation failed:' \
    "$output_directory/subparser-denied.err"

# Historical compiler identities may each have a record for this fixture.
# Remove only those recoverable input sidecars so the corruption assertion
# below targets the record published by this exact compiler invocation.
cache_directory="$project_root/build/.abla-cache"
if [[ -d $cache_directory ]]; then
    while IFS= read -r -d '' input_record; do
        if grep -q 'tests/cases/capabilities/input.txt' "$input_record"; then
            rm -f -- "$input_record"
        fi
    done < <(find "$cache_directory" -type f -name '*.inputs' -print0)
fi

"$compiler" build \
    "$project_root/tests/cases/capabilities/entry.ab" \
    -o "$output_directory/granted"
printf '%s\n' 'compile-input-cache-hit' > "$output_directory/granted.ll"
"$compiler" build \
    "$project_root/tests/cases/capabilities/entry.ab" \
    -o "$output_directory/granted"
grep -q '^compile-input-cache-hit$' "$output_directory/granted.ll"
set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/granted"
granted_status=$?
set -e
[[ $granted_status -eq 42 ]]

input_cache=''
while IFS= read -r -d '' input_record; do
    if grep -q 'tests/cases/capabilities/input.txt' "$input_record"; then
        input_cache=$input_record
        break
    fi
done < <(find "$project_root/build/.abla-cache" -type f \
    -name '*.inputs' -print0)
[[ -n $input_cache ]]
printf '%s\n' 'corrupt-input-record' > "$input_cache"
"$compiler" build \
    "$project_root/tests/cases/capabilities/entry.ab" \
    -o "$output_directory/granted"
if grep -q '^compile-input-cache-hit$' "$output_directory/granted.ll"; then
    echo 'corrupt compile-input record was reused' >&2
    exit 1
fi

printf '%s\n' 'compile-input-cache-hit' > "$output_directory/granted.ll"
printf '%s\n' second > "$input"
"$compiler" build \
    "$project_root/tests/cases/capabilities/entry.ab" \
    -o "$output_directory/granted"
if grep -q '^compile-input-cache-hit$' "$output_directory/granted.ll"; then
    echo 'compile input content change reused a stale object' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/granted"
changed_status=$?
set -e
[[ $changed_status -eq 7 ]]

# Parser handlers execute before ordinary lowering, but their filesystem
# journal is still part of the final artifact identity.
printf '%s\n' first > "$input"
"$compiler" build \
    "$project_root/tests/cases/capabilities/subparser-input.ab" \
    -o "$output_directory/subparser-input"
printf '%s\n' 'subparser-input-cache-hit' > \
    "$output_directory/subparser-input.ll"
"$compiler" build \
    "$project_root/tests/cases/capabilities/subparser-input.ab" \
    -o "$output_directory/subparser-input"
grep -q '^subparser-input-cache-hit$' \
    "$output_directory/subparser-input.ll"
printf '%s\n' second > "$input"
"$compiler" build \
    "$project_root/tests/cases/capabilities/subparser-input.ab" \
    -o "$output_directory/subparser-input"
if grep -q '^subparser-input-cache-hit$' \
    "$output_directory/subparser-input.ll"; then
    echo 'subparser input change reused a stale object' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/subparser-input"
subparser_changed_status=$?
set -e
[[ $subparser_changed_status -eq 7 ]]

# The environment provider is deterministic: its named observation is
# journaled, cacheable while unchanged, and invalidates on value changes.
ABLA_COMPILE_TEST_INPUT=first "$compiler" build \
    "$project_root/tests/cases/capabilities/environment.ab" \
    -o "$output_directory/environment"
printf '%s\n' 'environment-input-cache-hit' > \
    "$output_directory/environment.ll"
ABLA_COMPILE_TEST_INPUT=first "$compiler" build \
    "$project_root/tests/cases/capabilities/environment.ab" \
    -o "$output_directory/environment"
grep -q '^environment-input-cache-hit$' \
    "$output_directory/environment.ll"
ABLA_COMPILE_TEST_INPUT=second "$compiler" build \
    "$project_root/tests/cases/capabilities/environment.ab" \
    -o "$output_directory/environment"
if grep -q '^environment-input-cache-hit$' \
    "$output_directory/environment.ll"; then
    echo 'environment input change reused a stale object' >&2
    exit 1
fi
set +e
ABLA_COMPILE_TEST_INPUT=second \
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/environment"
environment_status=$?
set -e
[[ $environment_status -eq 7 ]]

# Process, clock, and randomness are deliberately ambient. Even when granted,
# their presence disables native-object reuse/publication.
"$compiler" build \
    "$project_root/tests/cases/capabilities/ambient.ab" \
    -o "$output_directory/ambient"
printf '%s\n' 'ambient-cache-must-not-hit' > "$output_directory/ambient.ll"
"$compiler" build \
    "$project_root/tests/cases/capabilities/ambient.ab" \
    -o "$output_directory/ambient"
if grep -q '^ambient-cache-must-not-hit$' "$output_directory/ambient.ll"; then
    echo 'ambient compile-time effects reused a native object' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-512} ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/ambient"
ambient_status=$?
set -e
[[ $ambient_status -eq 42 ]]

# File outputs stay in memory until the complete compiler/toolchain succeeds.
# A failed compilation must therefore leave no externally visible output.
transaction_output="$output_directory/transaction-output.txt"
rm -f -- "$transaction_output"
set +e
"$compiler" build \
    "$project_root/tests/cases/capabilities/write-output-failure.ab" \
    -o "$output_directory/write-output-failure" \
    > "$output_directory/write-output-failure.out" \
    2> "$output_directory/write-output-failure.err"
write_failure_status=$?
set -e
[[ $write_failure_status -ne 0 ]]
[[ ! -e $transaction_output ]]

"$compiler" build \
    "$project_root/tests/cases/capabilities/write-output.ab" \
    -o "$output_directory/write-output"
grep -q '^published-after-success$' "$transaction_output"

"$compiler" build \
    "$project_root/tests/cases/capabilities/write-output-invalid-path.ab" \
    -o "$output_directory/write-output-invalid-path"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/write-output-invalid-path"
invalid_path_status=$?
set -e
[[ $invalid_path_status -eq 42 ]]
[[ ! -e "$project_root/../outside-project.txt" ]]

"$compiler" build \
    "$project_root/tests/cases/capabilities/network-bounded.ab" \
    -o "$output_directory/network-bounded"
printf '%s\n' 'network-cache-must-not-hit' > \
    "$output_directory/network-bounded.ll"
"$compiler" build \
    "$project_root/tests/cases/capabilities/network-bounded.ab" \
    -o "$output_directory/network-bounded"
if grep -q '^network-cache-must-not-hit$' \
    "$output_directory/network-bounded.ll"; then
    echo 'network compile-time effect reused a native object' >&2
    exit 1
fi

python3 -c 'import socket
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 39091))
s.listen(1)
c,_=s.accept()
if c.recv(4) == b"PING": c.sendall(b"PONG")
c.close()
s.close()' &
network_server_pid=$!
sleep 0.1
"$compiler" build \
    "$project_root/tests/cases/capabilities/network-live.ab" \
    -o "$output_directory/network-live"
wait "$network_server_pid"
network_server_pid=''
set +e
"$project_root/tools/run-limited.sh" "$output_directory/network-live"
network_live_status=$?
set -e
[[ $network_live_status -eq 42 ]]

printf '%s\n' 'compileCapabilities = []' > "$manifest"
set +e
"$compiler" build \
    "$project_root/tests/cases/capabilities/entry.ab" \
    -o "$output_directory/granted" \
    > "$output_directory/manifest-denied.out" \
    2> "$output_directory/manifest-denied.err"
manifest_status=$?
set -e
[[ $manifest_status -ne 0 ]]
grep -q 'compile.capability-not-authorized:filesystem.read' \
    "$output_directory/manifest-denied.err"

printf '%s\n' 'compile effects: denial + full-mask authorization + deterministic input invalidation + ambient non-cacheability passed'
