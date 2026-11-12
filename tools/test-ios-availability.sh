#!/usr/bin/env bash
# Cross-codegen availability checks; no Apple SDK or target execution needed.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
directory=build/ios-availability-test
mkdir -p "$directory"
fail() { echo "iOS availability: $1" >&2; exit 1; }
# name:category (an empty category means the case must build).
cases='command:process creation/execution
signals:signals
signal-callback:signals
device:device I/O
serial:serial I/O
execute:process creation/execution
native-fork:process creation/execution
native-signal:signals
host-extern:runtime compiler-host evaluation
orc:runtime LLVM/JIT
host-only:
ct-callback:
unused-imports:'
for pair in device:iosDeviceTarget simulator:iosSimulatorTarget; do
    target=${pair%%:*}
    helper=${pair#*:}
    while IFS=: read -r name category; do
        entry="tests/cases/ios-target/availability/$name.ab"
        object="$directory/$target-$name.o"
        rm -f "$object"
        driver="$directory/$target-$name.ab"
        cat > "$driver" <<AB
import "abla/build"
import "abla/ios/build"
compile fun checkAvailability(): bool {
    val target = $helper()
    buildProgram("availability-$name", "$entry", "$object", target, "object", true, false)
}
val accepted = #checkAvailability()
fun main(): int = if (accepted) 0 else 1
AB
        status=0
        timeout 180 "$compiler" build "$driver" -o "$directory/$target-$name-driver" --fast --no-cache \
            > "$directory/$target-$name.log" 2>&1 || status=$?
        if [[ -z $category ]]; then
            [[ $status -eq 0 && -f $object ]] || { cat "$directory/$target-$name.log" >&2; fail "$target $name did not build ($status)"; }
            # No LLVM or LLJIT symbol may stay undefined in the object.
            if llvm-nm --undefined-only "$object" | awk 'NF { s = $NF; sub(/^_+/, "", s); if (s ~ /^(LLVM|LLJIT)/) found = 1 } END { exit !found }'; then
                fail "$target $name references LLVM/LLJIT symbols"
            fi
        else
            [[ $status -ne 0 && ! -e $object ]] || fail "$target $name was accepted ($status)"
            grep -qF 'error[E_TARGET_IOS_UNSUPPORTED]' "$directory/$target-$name.log" || fail "$target $name: no unsupported error"
            grep -qF "$category" "$directory/$target-$name.log" && grep -qF 'source[target]:' "$directory/$target-$name.log" \
                || fail "$target $name: missing '$category' or the target source"
        fi
        echo "iOS availability: $target $name passed"
    done <<< "$cases"
done
echo 'iOS availability: typed runtime refusals, unused imports and compile-time host work passed'
