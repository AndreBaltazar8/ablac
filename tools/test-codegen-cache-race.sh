#!/usr/bin/env bash
# A unit's reported cache name may disappear before its parent uses the part.
# Includes a real concurrent sweeper and the 4x8 zero-limit reproducer.
set -euo pipefail
compiler=${1:-build/ablac.bin}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
# Absolute, not resolved: build/ablac is a symlink to a launcher that finds
# its payload beside the name it was run as.
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/codegen-cache-race
out=$(mktemp -d "$root/build/codegen-cache-race/run-XXXXXX")
a="$root/tests/cases/codegen-cache/concurrent-a.ab"
b="$root/tests/cases/codegen-cache/concurrent-b.ab"
export ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0 ABLA_CODEGEN_JOBS=1 ABLA_NATIVE_JOBS=1 \
    ABLA_CODEGEN_UNITS_TRACE=1 ABLA_MAX_MEMORY_MB=2048
unset ABLA_CODEGEN_TEST_BARRIER ABLA_CODEGEN_TEST_COPY_HITS ABLA_CODEGEN_TEST_EVICT_BEFORE_PIN \
    ABLA_CODEGEN_CACHE ABLA_KEEP_LLVM_TEXT ABLA_COMPILE_EVAL
victim_pid=
cleanup_dirs=()
cleanup() {
    local status=$?
    if [[ -n $victim_pid ]]; then kill "$victim_pid" 2> /dev/null || true; wait "$victim_pid" 2> /dev/null || true; fi
    chmod 755 "$out/readonly-cache/codegen" 2> /dev/null || true
    local d
    for d in ${cleanup_dirs[@]+"${cleanup_dirs[@]}"}; do rm -rf "$d"; done
    if [[ $status -ne 0 ]]; then echo "codegen cache race: artifacts and logs: $out" >&2; fi
    return $status
}
trap cleanup EXIT
fail() { echo "codegen cache race: $1" >&2; exit 1; }

# Portable stat helpers: device:inode and mtime in seconds.
if stat -c %i / > /dev/null 2>&1; then
    file_id() { stat -c '%d:%i' "$1"; }
    file_mtime() { stat -c %Y "$1"; }
    file_device() { stat -c %d "$1"; }
else
    file_id() { stat -f '%d:%i' "$1"; }
    file_mtime() { stat -f %m "$1"; }
    file_device() { stat -f %d "$1"; }
fi

# build SOURCE OUTPUT CACHE LABEL [VAR=VALUE...]: a --fast build with its own cache
# directory; the archive it wrote is copied to $out/LABEL.bin.
build() {
    local source=$1 output=$2 cache=$3 label=$4 status=0
    shift 4
    (cd "$root" && env ABLA_CODEGEN_CACHE_MB=2048 "$@" "$compiler" build "$source" -o "$output" --fast \
        --no-cache --cache-dir "$cache" > "$out/$label.log" 2>&1) || status=$?
    [[ $status -eq 0 ]] || fail "$label returned $status"
    cp "$output.o" "$out/$label.bin"
}
execute() {
    local status=0
    "$1" > /dev/null 2>&1 || status=$?
    [[ $status -eq 42 ]] || fail "$1 returned $status"
}
# members ARCHIVE: the member names, which must all be unitN.o and more than one.
members() {
    local names
    names=$(llvm-ar t "$1")
    [[ $(printf '%s\n' "$names" | wc -l) -gt 1 ]] || fail "$1 has one member"
    [[ -z $(printf '%s\n' "$names" | grep -vE '^unit[0-9]+\.o$') ]] || fail "$1 has unexpected members: $names"
    printf '%s\n' "$names"
}

# eviction_gate MODE [CACHE]: hold a victim build at a barrier after its unit children
# reported their cache names, sweep the cache with a real second compiler, release it.
eviction_gate() {
    local mode=$1 directory="$out/$1" cache output warm=0 gate configured log
    mkdir -p "$directory"
    cache=${2:-$directory/cache}
    output="$directory/victim"
    build "$a" "$output" "$cache" "$mode-cacheless" ABLA_CODEGEN_CACHE=0
    cp "$out/$mode-cacheless.bin" "$directory/expected.bin"
    local expected_members
    expected_members=$(members "$output.o")
    execute "$output"
    [[ $mode == cold ]] || warm=1
    if [[ $warm -eq 1 ]]; then
        build "$a" "$output" "$cache" "$mode-prime"
        cmp -s "$out/$mode-prime.bin" "$directory/expected.bin" || fail "$mode: the primed archive differs"
        local entry
        for entry in "$cache"/codegen/*.o; do
            [[ -e $entry ]] && TZ=UTC touch -t 197001010000.01 "$entry"
        done
        [[ $(file_mtime "$(ls "$cache"/codegen/*.o | head -n 1)") -le 1 ]] || fail "$mode: could not age the cache entries"
    fi
    gate="$directory/gate"
    mkdir -p "$gate"
    local extra=()
    if [[ $mode == copy ]]; then
        extra+=(ABLA_CODEGEN_TEST_COPY_HITS=1)
        if [[ $(uname -s) == Darwin ]]; then
            # Prove the fallback when cp -c/clonefile is unsupported too.
            mkdir -p "$directory/shim"
            printf '#!/bin/sh\nif [ "$1" = "-c" ]; then exit 1; fi\nexec "$ABLA_TEST_REAL_CP" "$@"\n' > "$directory/shim/cp"
            chmod 755 "$directory/shim/cp"
            extra+=("ABLA_TEST_REAL_CP=$(command -v cp)" "PATH=$directory/shim:$PATH")
        fi
    fi
    log="$out/$mode-victim.log"
    (cd "$root" && env ABLA_CODEGEN_CACHE_MB=2048 ABLA_CODEGEN_TEST_BARRIER="$gate" ${extra[@]+"${extra[@]}"} \
        "$compiler" build "$a" -o "$output" --fast --no-cache --cache-dir "$cache" > "$log" 2>&1) &
    victim_pid=$!
    local waited=0
    while [[ ! -e $gate/ready ]]; do
        waited=$((waited + 1))
        [[ $waited -lt 6000 ]] || fail "$mode: barrier timeout (the victim may have stopped; see $log)"
        sleep 0.01
    done
    # The driver emits to a PID-qualified temporary object, and on
    # Darwin also uses a private publication directory.
    local reports
    reports=$(find "$directory" -name 'unit*.o.path' | sort)
    [[ -n $reports ]] || fail "$mode: no child reports"
    local report entry_path reused part private shared count=0
    : > "$directory/protected"
    for report in $reports; do
        entry_path=$(sed -n 1p "$report")
        reused=$(sed -n 2p "$report")
        part=${report%.path}
        [[ -f $part && -f $entry_path ]] || fail "$mode: missing $part or $entry_path"
        cmp -s "$part" "$entry_path" || fail "$mode: part bytes differ"
        if [[ $warm -eq 1 ]]; then [[ $reused == 1 ]] || fail "$mode: reused flag $reused"
        else [[ $reused == 0 ]] || fail "$mode: reused flag $reused"; fi
        private=$(file_id "$part")
        shared=$(file_id "$entry_path")
        if [[ $mode == copy || $mode == xdev ]]; then
            [[ $private != "$shared" ]] || fail "$mode: must own independent copied bytes"
        else
            [[ $private == "$shared" ]] || fail "$mode: same-filesystem acquisition/publication should hard-link"
        fi
        if [[ $warm -eq 1 ]]; then
            [[ $(file_mtime "$entry_path") -gt 1 ]] || fail "$mode: hit did not refresh LRU"
        fi
        count=$((count + 1))
        cp "$part" "$directory/protected-$count"
        printf '%s\t%s\t%s\n' "$entry_path" "$part" "$directory/protected-$count" >> "$directory/protected"
    done
    # A separate real compiler protects only its own entries; zero limit
    # removes at least the victim's distinct data/function entry.
    build "$b" "$directory/sweeper" "$cache" "$mode-sweeper" ABLA_CODEGEN_CACHE_MB=0
    local deleted=0 saved tab
    tab=$(printf '\t')
    while IFS="$tab" read -r entry_path part saved; do
        [[ -e $entry_path ]] || deleted=$((deleted + 1))
        cmp -s "$part" "$saved" || fail "$mode: sweep damaged private bytes"
    done < "$directory/protected"
    [[ $deleted -gt 0 ]] || fail "$mode: real sweep did not evict a victim entry"
    touch "$gate/release"
    local status=0
    wait "$victim_pid" || status=$?
    victim_pid=
    [[ $status -eq 0 ]] || fail "$mode: victim failed ($status; see $log)"
    cmp -s "$output.o" "$directory/expected.bin" || fail "$mode: archive changed"
    [[ $(members "$output.o") == "$expected_members" ]] || fail "$mode: archive members changed"
    execute "$output"
    echo "codegen cache race: $mode survived a real concurrent sweep"
}

for mode in cold hit copy; do eviction_gate "$mode"; done

# Exercise an actual cross-device link failure when a separate temporary
# filesystem is available. Darwin's copy gate also tests clonefile failure.
if [[ -d /dev/shm && $(file_device /dev/shm) != "$(file_device "$out")" ]] \
    && [[ $(df -k /dev/shm | awk 'NR == 2 { print $4 }') -gt 16384 ]]; then
    shm_cache=$(mktemp -d /dev/shm/abla-codegen-race-XXXXXX)
    cleanup_dirs+=("$shm_cache")
    eviction_gate xdev "$shm_cache"
fi

# A hit that loses its name before link/open must regenerate, not report a
# successful hit or leave a partial destination behind.
build "$a" "$out/vanish" "$out/vanish-cache" vanish-prime
cp "$out/vanish-prime.bin" "$out/expected.bin"
build "$a" "$out/vanish" "$out/vanish-cache" vanish-rebuild ABLA_CODEGEN_TEST_EVICT_BEFORE_PIN=1
cmp -s "$out/vanish-rebuild.bin" "$out/expected.bin" || fail 'a vanished hit changed the archive'
grep -qE ', 0 reused$' "$out/vanish-rebuild.log" || fail 'a vanished hit was reported as reused'
execute "$out/vanish"

# Publication failures must not turn a completed private part into a failed
# build. Actual permissions (not a hook) refuse both link and copy publication.
mkdir -p "$out/readonly-cache/codegen"
chmod 555 "$out/readonly-cache/codegen"
[[ ! -w $out/readonly-cache/codegen ]] || fail 'the read-only regression needs an unprivileged user'
build "$a" "$out/readonly" "$out/readonly-cache" readonly
cmp -s "$out/readonly.bin" "$out/expected.bin" || fail 'a read-only cache changed the archive'
[[ -z $(ls "$out/readonly-cache/codegen") ]] || fail 'a read-only cache unexpectedly published'
execute "$out/readonly"
chmod 755 "$out/readonly-cache/codegen"

# An unusable optional cache directory must also retain the generated parts.
mkdir -p "$out/blocked-cache"
printf 'not a directory' > "$out/blocked-cache/codegen"
build "$a" "$out/blocked" "$out/blocked-cache" blocked
cmp -s "$out/blocked.bin" "$out/expected.bin" || fail 'an unusable cache changed the archive'
execute "$out/blocked"

# The real application's original shape: four workers, eight builds each,
# one shared zero-limit cache, one unit child per worker (at most four jobs).
cache="$out/concurrent-cache"
build "$a" "$out/reference-concurrent-a" "$cache" reference-concurrent-a ABLA_CODEGEN_CACHE=0
build "$b" "$out/reference-concurrent-b" "$cache" reference-concurrent-b ABLA_CODEGEN_CACHE=0
worker() {
    local index=$1 run source reference label
    if [[ $((index % 2)) -eq 1 ]]; then source=$a reference=concurrent-a; else source=$b reference=concurrent-b; fi
    for run in 1 2 3 4 5 6 7 8; do
        label="worker-$index-$run"
        build "$source" "$out/$label" "$cache" "$label" ABLA_CODEGEN_CACHE_MB=0
        cmp -s "$out/$label.bin" "$out/reference-$reference.bin" || fail "$label: archive differs from cacheless build"
        execute "$out/$label"
        : > "$out/$label.ok"
    done
}
pids=()
for index in 1 2 3 4; do worker "$index" & pids+=($!); done
for pid in "${pids[@]}"; do wait "$pid" || fail 'a concurrent worker failed'; done
[[ $(ls "$out"/worker-*.ok | wc -l | tr -d ' ') -eq 32 ]] || fail 'not all 32 concurrent builds finished'
echo "codegen cache race: 4x8 concurrent zero-limit builds, 0/32 failures; $out"
trap - EXIT
rm -rf "$out" ${cleanup_dirs[@]+"${cleanup_dirs[@]}"}
