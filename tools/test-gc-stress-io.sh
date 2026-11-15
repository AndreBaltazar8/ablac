#!/usr/bin/env bash
# Programs that hand addresses of collected memory to the system (#829): process, file and loopback-network cases,
# built once and run twice, as they are and under ABLA_GC_STRESS=1, which collects at every safe point and fills
# what it frees with 0xDB bytes. An address kept only as an integer across a safe point (a nativeCStringAddress
# copy in a table, a field or a local) then points at poison, not at the bytes a freed block keeps until it is
# reused, so the program fails at once instead of under rare pressure. Each must exit 42 both ways. The list is
# fixed so the step stays short. tests/cases/gc-stress-io/ct-process.ab is the compiler's own process capture,
# which every `#` site with process.io runs; native-argv.ab is the argv it hands LLVM's in-process option parser.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/gc-stress-io"
rm -rf "$output_directory"
mkdir -p "$output_directory/run/build/process-exec-strings"

case $(uname -s) in
    Linux) ;;
    *) echo "gc stress io: not Linux, skipped"; exit 0 ;;
esac

cases=(
    tests/cases/process-exec-strings/main.ab
    tests/cases/gc-stress-io/ct-process.ab
    tests/cases/gc-stress-io/native-argv.ab
    tests/cases/modules/process-capture.ab
    tests/cases/modules/linux-process.ab
    tests/cases/modules/host-process-configured.ab
    tests/cases/modules/filesystem.ab
    tests/cases/modules/linux-filesystem.ab
    tests/cases/modules/linux-net.ab
    tests/cases/modules/udp-ephemeral.ab
    tests/cases/modules/http-event.ab
    tests/cases/modules/websocket-live.ab
)

name_of() { # source
    local source=$1
    echo "$(basename "$(dirname "$source")")-$(basename "$source" .ab)"
}

jobs=${GC_STRESS_IO_JOBS:-4}
for source in "${cases[@]}"; do
    while (( $(jobs -rp | wc -l) >= jobs )); do wait -n || true; done
    name=$(name_of "$source")
    ( "$compiler" build "$project_root/$source" -o "$output_directory/$name" --no-cache \
        > "$output_directory/$name.build.log" 2>&1 || echo failed > "$output_directory/$name.build-failed" ) &
done
wait

failures=0
for source in "${cases[@]}"; do
    name=$(name_of "$source")
    if [[ -e $output_directory/$name.build-failed ]]; then
        echo "gc stress io: $source did not build" >&2
        cat "$output_directory/$name.build.log" >&2
        failures=$((failures + 1))
        continue
    fi
    # From a directory of their own: the cases write under build/ relative to where they run.
    plain=0
    (cd "$output_directory/run" && "$project_root/tools/run-limited.sh" "$output_directory/$name" \
        > "$output_directory/$name.plain.out" 2>&1 < /dev/null) || plain=$?
    stressed=0
    (cd "$output_directory/run" && ABLA_GC_STRESS=1 "$project_root/tools/run-limited.sh" \
        "$output_directory/$name" > "$output_directory/$name.stress.out" 2>&1 < /dev/null) || stressed=$?
    if [[ $plain != 42 || $stressed != 42 ]]; then
        echo "gc stress io: $source exited $plain, and $stressed under ABLA_GC_STRESS=1 (42 both ways expected)" >&2
        tail -n 5 "$output_directory/$name.stress.out" >&2
        failures=$((failures + 1))
    fi
done
(( failures == 0 )) || exit 1
echo "gc stress io: ${#cases[@]} programs exit 42 with a collection at every safe point and poisoned frees"
