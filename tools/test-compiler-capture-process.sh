#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compiler-capture-process
mkdir -p "$out/authorized" "$out/denied"
printf 'compileCapabilities = ["process.io"]\n' > "$out/authorized/abla.toml"
printf 'compileCapabilities = []\n' > "$out/denied/abla.toml"
rm -f "$out/timeout-child.pid" "$out/overflow-child.pid" "$out/spawned"

"$compiler" build tests/cases/compiler-capture-process/fd-host.ab \
    -o "$out/fd-host" --fast --no-cache > "$out/fd-host.log" 2>&1
(exec 0<&- 1>&- 2>&-; "$out/fd-host")

for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build tests/cases/compiler-capture-process/main.ab \
        -o "$out/main-$tier" --fast --no-cache > "$out/$tier.log" 2>&1
    status=0
    "$out/main-$tier" || status=$?
    [[ $status == 42 ]] || { echo "capture checks failed: $status ($tier)" >&2; exit 1; }
    # Orphaned grandchildren may briefly remain zombies until init reaps them;
    # require they are no longer executing, on both Linux and Darwin.
    for pidfile in "$out/timeout-child.pid" "$out/overflow-child.pid"; do
        [[ -s $pidfile ]]
        child_pid=$(cat "$pidfile")
        state=''
        for attempt in {1..20}; do
            state=$(ps -o stat= -p "$child_pid" || true)
            [[ -z $state || $state == Z* ]] && break
            sleep 0.05
        done
        [[ -z $state || $state == Z* ]] || { echo "capture left live child $child_pid: $state" >&2; exit 1; }
    done
    rm -f "$out/timeout-child.pid" "$out/overflow-child.pid"
done

# Same source and output path, cache enabled, changed ambient environment:
# neither native-object nor frontend reuse may retain the previous result.
for value in first second; do
    ABLA_CAPTURE_MARKER=$value "$compiler" build tests/cases/compiler-capture-process/environment.ab \
        -o "$out/environment" --fast > "$out/environment-$value.log" 2>&1
    [[ $("$out/environment") == "$value" ]]
done

call='compilerCaptureProcess(["sh", "tests/cases/compiler-capture-process/child.sh", "mark", "build/compiler-capture-process/spawned"]'
prefix='import "abla/compiler"
#compilerGrant("process.io")
'
trailer='fun main: int = 0'
for entry in zero:0:10 negative:-1:10 large:1048577:10 timeout-zero:1:0 timeout-large:1:10001; do
    IFS=: read -r name cap timeout <<< "$entry"
    printf '%sval RESULT = #%s, %s, %s)\n%s\n' "$prefix" "$call" "$cap" "$timeout" "$trailer" \
        > "$out/authorized/$name.ab"
done
printf '%sval RESULT = #%s)\n%s\n' "$prefix" "$call" "$trailer" > "$out/denied/manifest.ab"
printf 'import "abla/compiler"\nval RESULT = #%s)\n%s\n' "$call" "$trailer" > "$out/authorized/grant.ab"
printf '%sval RESULT = #compilerCaptureProcess(["sh", "bad\\u0000argument"])\n%s\n' "$prefix" "$trailer" \
    > "$out/authorized/nul.ab"
printf '%sval RESULT = #compilerCaptureProcess([])\n%s\n' "$prefix" "$trailer" > "$out/authorized/empty.ab"
printf '%sval RESULT = #compilerCaptureProcess(filledArray(129, "true"))\n%s\n' "$prefix" "$trailer" \
    > "$out/authorized/many.ab"
printf '%sval RESULT = #compilerCaptureProcess(["x" * 4097])\n%s\n' "$prefix" "$trailer" \
    > "$out/authorized/long.ab"
printf '%sval RESULT = #%s)\n%s\n' "$prefix" "$call" "$trailer" > "$out/authorized/revoked.ab"
# Revoke the same source's authorization after a successful cached-path build.
"$compiler" build "$out/authorized/revoked.ab" -o "$out/revoked" --fast \
    > "$out/revoked-granted.log" 2>&1
[[ -e $out/spawned ]]
rm "$out/spawned"
printf 'compileCapabilities = []\n' > "$out/authorized/abla.toml"
if "$compiler" build "$out/authorized/revoked.ab" -o "$out/revoked" --fast \
    > "$out/revoked-denied.log" 2>&1; then
    echo 'capture reused revoked process authorization' >&2; exit 1
fi
grep -q 'compile.capability-not-authorized:process.io' "$out/revoked-denied.log"
[[ ! -e $out/spawned ]]
printf 'compileCapabilities = ["process.io"]\n' > "$out/authorized/abla.toml"

for source in "$out/denied/manifest.ab" "$out/authorized/"{grant,zero,negative,large,timeout-zero,timeout-large,nul,empty,many,long}.ab; do
    name=$(basename "$source" .ab)
    if "$compiler" --emit-llvm "$source" > "$out/$name.ll" 2> "$out/$name.err"; then
        echo "capture incorrectly accepted $name" >&2; exit 1
    fi
    [[ ! -e $out/spawned ]] || { echo "capture spawned before validation" >&2; exit 1; }
done
grep -q 'compile.capability-not-authorized:process.io' "$out/manifest.err"
grep -q 'compile.effect-denied:process.io:compilerCaptureProcess' "$out/grant.err"
echo 'compiler capture: bounded bytes, deadlines, tree cleanup, authorization and ambient cache checks passed'
