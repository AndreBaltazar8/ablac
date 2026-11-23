#!/usr/bin/env bash
# Compile-time file operations hold their paths inside the project by where they lead (tools/test-compile-path-symlinks.sh), and used to open the
# path they had checked: a directory swapped for a link to somewhere else between the check and the open led out of the project (#1139 area 1).
# The operations now open the real path they checked by walking it from the root with O_NOFOLLOW (AnchoredPath, abla/sys/linux/fs), so a swapped
# link fails the operation. Here a Node process swaps the project's `data` directory for a link to `../outside` and back in a loop, and a
# compile-time loop reads or writes data/f.txt: a read must never return the outside file's contents, and a write must never create a file outside.
# Each build ends at its first refused operation (the swap is seen at the check) or at a leak; the test runs builds until one leaks or the bound is
# reached, and requires that operations went through, so that the path was exercised.
# Needs node (shell.nix has it). Usage: tools/test-compile-path-race.sh [compiler] [builds]
set -euo pipefail
compiler=${1:-build/ablac}
builds=${2:-8}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node=${COMPILE_PATH_RACE_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then echo "compile-path-race: skipped (no node: the swapping process)"; exit 0; fi
case "$(uname -s)" in Linux) ;; *) echo "compile-path-race: skipped on this host"; exit 0 ;; esac
out="${root:?}/build/compile-path-race"
rm -rf "${out:?}"
mkdir -p "$out"
fail() { echo "compile-path-race: $1" >&2; exit 1; }

cat > "$out/swap.mjs" <<'JS'
// Swaps `data` (a directory) for a link to ../outside and back, until the stop file exists; the link is there for about one system call of each turn.
import fs from "node:fs";
const [directory, stop] = process.argv.slice(2);
process.chdir(directory);
const wait = (nanoseconds) => { const end = process.hrtime.bigint() + BigInt(nanoseconds); while (process.hrtime.bigint() < end); };
let turns = 0;
while (!fs.existsSync(stop)) {
    try {
        fs.renameSync("data", "data.real");
        fs.symlinkSync("../outside", "data");
        fs.renameSync("data", "data.link");
        fs.renameSync("data.real", "data");
        fs.unlinkSync("data.link");
    } catch (error) { /* a turn the build disturbed */ }
    turns += 1;
    wait(60000);
}
console.log(`swap turns ${turns}`);
JS

# project <name> <loop body>: a project whose compile-time code repeats the body on data/ until it ends.
project() {
    local name=$1 body=$2
    local dir="${out:?}/${name:?}"
    mkdir -p "$dir/project/src" "$dir/project/data" "$dir/outside"
    printf 'inside' > "$dir/project/data/f.txt"
    printf 'secret' > "$dir/outside/f.txt"
    cat > "$dir/project/abla.toml" <<'TOML'
name = "race-case"
version = "0.1.0"
entry = "src/main.ab"
compileCapabilities = ["filesystem.read", "filesystem.write"]
TOML
    cat > "$dir/project/src/main.ab" <<EOF
import "abla/io"
import "abla/fs"
import "abla/compiler"
#compilerGrant("filesystem.read")
#compilerGrant("filesystem.write")
fun hammer(turns: int): int {
    var reads = 0
    var leaks = 0
    for (i in 0 until turns) {
$body
    }
    println("DONE reads \${reads} leaks \${leaks}")
    leaks
}
val leaks = #hammer(8000)
fun main { println("leaks \$leaks") }
EOF
}
project read '        val text = path("../data/f.txt").readText()
        if (text == "secret") {
            println("LEAK")
            leaks = leaks + 1
        } else if (text == "inside") reads = reads + 1'
project write '        val written = path("../data/w.txt").writeText("x")
        if (path("../../outside/w.txt").exists()) {
            println("LEAK")
            leaks = leaks + 1
        } else if (written) reads = reads + 1'

# run_case <name> <tier>: sets RACE_LEAKS and RACE_READS over up to $builds builds.
run_case() {
    local name=$1 tier=$2 leaked=0 reads=0 made=0
    local project_dir="${out:?}/${name:?}/project"
    : > "$out/$name-$tier.log"
    for ((i = 1; i <= builds; i++)); do
        rm -f "${out:?}/stop"
        rm -rf "${project_dir:?}/data.real" "${project_dir:?}/data.link"
        if [[ ! -d $project_dir/data ]]; then rm -f "${project_dir:?}/data"; mkdir -p "$project_dir/data"; fi
        printf 'inside' > "$project_dir/data/f.txt"
        rm -f "${out:?}/$name/outside/w.txt" "${project_dir:?}/data/w.txt"
        "$node" "$out/swap.mjs" "$project_dir" "$out/stop" > "$out/swap.log" 2>&1 &
        local swapper=$!
        ABLA_COMPILE_EVAL=$tier "$compiler" build --project "$project_dir" --fast --no-cache > "$out/build.log" 2>&1 || true
        touch "$out/stop"
        wait "$swapper" || true
        cat "$out/build.log" >> "$out/$name-$tier.log"
        made=$((made + 1))
        leaked=$((leaked + $(grep -c '^LEAK' "$out/build.log" || true)))
        reads=$((reads + $(sed -n 's/^DONE reads \([0-9]*\) .*/\1/p' "$out/build.log" | head -1 | grep . || echo 0)))
        # A write that reached the outside directory is a leak too, whatever the loop saw.
        if [[ -e $out/$name/outside/w.txt ]]; then leaked=$((leaked + 1)); fi
        if ((leaked > 0)); then break; fi
    done
    echo "$name ($tier): $made builds, $reads operations that went through, $leaked leaks"
    RACE_LEAKS=$leaked
    RACE_READS=$reads
}

for tier in jit interp; do
    for name in read write; do
        run_case "$name" "$tier"
        ((RACE_LEAKS == 0)) || fail "$name ($tier): the swapped directory led out of the project ($RACE_LEAKS time(s)); see $out/$name-$tier.log"
        ((RACE_READS > 0)) || fail "$name ($tier): no operation went through (the test did not exercise the path): $(head -c 400 "$out/build.log")"
    done
done
echo "compile-path-race: no compile-time read or write left the project while its directory was being swapped for a link"
