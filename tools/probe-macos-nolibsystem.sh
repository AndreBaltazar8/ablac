#!/usr/bin/env bash
# Feasibility probe for a libSystem-free macOS executable (#811): does a program
# that makes write and exit (and a thread) by direct system calls start, and
# under which link forms. Runs on the macOS runner (arm64 or x86-64, the host
# architecture), prints one RESULT line per variant and a summary, and exits 0
# whenever the probe itself ran: a refusal by the linker or dyld is the finding.
# Usage: tools/probe-macos-nolibsystem.sh [output-directory]
set -uo pipefail
ulimit -c 0
[[ $(uname -s) == Darwin ]] || { echo 'macos nolibsystem probe: Darwin only' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-$root/build/macos-nolibsystem-probe}
src=$root/tools/macos-nolibsystem-probe
rm -rf "$out"; mkdir -p "$out"
case $(uname -m) in
    arm64) arch=arm64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac
echo "host: $(sw_vers -productVersion) $(uname -m); $(xcrun clang --version | head -1); ld: $(xcrun ld -v 2>&1 | head -1)"
summary=$out/summary.txt
: > "$summary"

# name|link flags
variants=(
    'nostdlib-e|-nostdlib -Wl,-e,_start'
    'nostdlib-static-e|-nostdlib -static -Wl,-e,_start'
    'nostdlib-nopie-e|-nostdlib -Wl,-e,_start -Wl,-no_pie'
    'nostdlib-nodyld-e|-nostdlib -Wl,-e,_start -Wl,-no_dyld_env_vars'
    'libsystem-listed-main|-nostdlib -lSystem'
    'libsystem-listed-e|-nostdlib -lSystem -Wl,-e,_start'
)

report() { # variant program line
    echo "RESULT [$arch] $1 $2: $3" | tee -a "$summary"
}

try() { # variant program flags
    local name=$1 program=$2 flags=$3 dir=$out/$1-$2
    mkdir -p "$dir"
    echo "---- $arch $name $program: clang -arch $arch $flags"
    if ! xcrun clang -arch "$arch" -c "$src/$program-$arch.s" -o "$dir/$program.o" > "$dir/assemble.log" 2>&1; then
        cat "$dir/assemble.log"; report "$name" "$program" "assembler failed"; return
    fi
    # shellcheck disable=SC2086
    if ! xcrun clang -arch "$arch" $flags "$dir/$program.o" -o "$dir/$program" > "$dir/link.log" 2>&1; then
        cat "$dir/link.log"
        report "$name" "$program" "link refused: $(grep -m1 -i 'error\|ld:' "$dir/link.log" | cut -c1-200)"
        return
    fi
    [[ -s $dir/link.log ]] && { echo "linker said:"; cat "$dir/link.log"; }
    echo "load commands:"
    otool -l "$dir/$program" | grep -E 'cmd LC_|^ *name |dylib|entryoff' | grep -v 'LC_BUILD_VERSION' | head -30
    echo "dyld info:"; otool -L "$dir/$program" 2>&1 | head -5
    echo "signature:"; codesign -dv "$dir/$program" 2>&1 | grep -E 'Signature|flags|Identifier|not signed' | head -4
    "$dir/$program" > "$dir/run.out" 2> "$dir/run.err" &
    local pid=$! waited=0 status
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 20 ]]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; echo "(killed after 20 s)" >> "$dir/run.err"; fi
    wait "$pid" 2>/dev/null; status=$?
    echo "run: status $status"; echo "stdout:"; cat "$dir/run.out"; echo "stderr:"; head -5 "$dir/run.err"
    local lc
    lc=$(otool -l "$dir/$program" | grep -oE 'LC_MAIN|LC_UNIXTHREAD|LC_LOAD_DYLINKER|LC_LOAD_DYLIB' | sort -u | tr '\n' ' ')
    report "$name" "$program" "linked ($lc), status $status, output: $(tr '\n' '|' < "$dir/run.out" | cut -c1-120), stderr: $(head -c 120 "$dir/run.err" | tr '\n' '|')"
}

for entry in "${variants[@]}"; do
    name=${entry%%|*}
    flags=${entry#*|}
    for program in hello thread; do
        try "$name" "$program" "$flags"
    done
done

echo
echo "==== summary"
cat "$summary"
# Status 137 or 9 on a run is SIGKILL: dyld or the kernel refusing the image.
exit 0
