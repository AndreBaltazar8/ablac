#!/usr/bin/env bash
# Record raw perf counters for cold native builds or a compiler self-build.
# Run under the pinned toolchain shell, with taskset and the shared build slot.
set -euo pipefail

if (( $# != 6 )); then
    echo 'usage: bench-compile-speed.sh apps|self COMPILER SYSROOT SOURCE FIXTURES NEW-OUTPUT-DIR' >&2
    exit 2
fi
mode=$1
compiler=$(realpath "$2")
sysroot=$(realpath "$3")
source=$(realpath "$4")
fixtures=$(realpath "$5")
out=$(realpath -m "$6")
rounds=${ABLA_SPEED_ROUNDS:-3}
perf=${ABLA_SPEED_PERF:-perf}
instructions=${ABLA_SPEED_INSTRUCTIONS:-instructions:u}
[[ $mode == apps || $mode == self ]] || { echo "unknown benchmark mode: $mode" >&2; exit 2; }
[[ $rounds =~ ^[1-9][0-9]*$ ]] || { echo 'ABLA_SPEED_ROUNDS must be positive' >&2; exit 2; }
mkdir "$out"
mkdir "$out/home"
ulimit -Ss 131072

# Keep the host LLVM toolchain's environment for the compiler's dynamic link.
# Fix build/GC settings explicitly and use a fresh Abla cache for every build.
unset ABLA_GC_BACKGROUND ABLA_GC_WORKERS ABLA_GC_STRESS ABLA_COMPILER_GC_STRESS \
    ABLA_COMPILER_MEMORY_TRACE ABLA_TEST_FAST_BUILDS ABLA_KEEP_LLVM_TEXT
export LC_ALL=C ABLA_SYSROOT="$sysroot" HOME="$out/home"
export ABLA_DEBUG=0 ABLA_NATIVE_JOBS=2 ABLA_CODEGEN_JOBS=2 ABLA_RELEASE_COLLECTOR_OBJECT=1
sha256sum "$compiler" > "$out/compiler.sha256"
"$compiler" --version > "$out/compiler.version"

measure() {
    local sample=$1
    shift
    "$perf" stat -x, -e "$instructions,duration_time" -o "$out/$sample.stat" -- \
        "$@" > "$out/$sample.stdout" 2> "$out/$sample.stderr"
    awk -F, -v event="$instructions" '
        $3 == event && $1 ~ /^[0-9]+$/ && $1 > 0 { instructions = 1 }
        $3 == "duration_time" && $1 ~ /^[0-9]+$/ && $1 > 0 { wall = 1 }
        END { exit !(instructions && wall) }
    ' "$out/$sample.stat"
}

build() {
    local sample=$1 entry=$2 path=$3
    measure "$sample" env ABLA_CACHE_DIR="$out/$sample.cache" \
        "$compiler" build "$entry" -o "$path" --no-cache
}

if [[ $mode == self ]]; then
    cd "$source"
    for ((round=1; round<=rounds; round++)); do
        build "self.$round" src/orc_main.ab "$out/ablac"
        sha256sum "$out/ablac" >> "$out/self.sha256"
        "$out/ablac" --version | cmp "$out/compiler.version" -
    done
    exit
fi

cd "$fixtures"
for program in hello json binary-trees fannkuch; do
    case $program in
        hello) arguments=() ;;
        json) arguments=(100 "$fixtures/input.json") ;;
        binary-trees) arguments=(18) ;;
        fannkuch) arguments=(11) ;;
    esac
    env ABLA_CACHE_DIR="$out/$program.trace.cache" ABLA_COMPILER_MEMORY_TRACE=1 \
        "$compiler" build "$program.ab" -o "$out/program" --no-cache > "$out/$program.trace" 2>&1
    cp "$out/program" "$out/$program.bin"
    collector=unavailable
    if [[ -f $sysroot/release-collector-v1/record ]]; then
        collector=miss
        if grep -q 'release-collector.hit' "$out/$program.trace"; then collector=hit; fi
    fi
    printf '%s\t%s\n' "$program" "$collector" >> "$out/collector.tsv"
    if [[ $program == hello || $program == json ]]; then
        for ((round=1; round<=rounds; round++)); do
            build "cold-$program.$round" "$program.ab" "$out/program"
            cmp "$out/$program.bin" "$out/program"
        done
    fi
    "$out/program" "${arguments[@]}" > "$out/$program.reference"
    [[ $program != hello ]] || continue
    for ((round=1; round<=rounds; round++)); do
        measure "run-$program.$round" "$out/program" "${arguments[@]}"
        cmp "$out/$program.reference" "$out/run-$program.$round.stdout"
    done
done
