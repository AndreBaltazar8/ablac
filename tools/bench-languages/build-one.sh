#!/usr/bin/env bash
# Called inside the pinned shell, with a fresh target/cache for each sample.
set -euo pipefail
lang=$1 name=$2 target=$3 compiler=$4
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
src=$root/tests/benchmarks/languages/$lang/$name
export ABLA_SYSROOT=$root ABLA_NATIVE_JOBS=2 ABLA_CODEGEN_JOBS=2
export ABLA_CACHE_DIR=$target.abla-cache
unset ABLA_TEST_COMPILER ABLA_COMPILE_EVAL ABLA_COMPILER_PAYLOAD
case $lang in
c)
    extra=()
    [[ $name == json ]] && extra=(-I "$BENCH_JSON_INCLUDE" -L "$BENCH_JSON_LIB" -ljson-c "-Wl,-rpath,$BENCH_JSON_LIB")
    [[ $name == regex-redux ]] && extra=(-I "$BENCH_PCRE_INCLUDE" -L "$BENCH_PCRE_LIB" -lpcre2-8 "-Wl,-rpath,$BENCH_PCRE_LIB")
    exec gcc -O3 -ffp-contract=off "$src.c" -lm -o "$target" "${extra[@]}" ;;
rust)
    extra=()
    [[ $name == json ]] && extra=(-L "$BENCH_JSON_LIB" -C "link-arg=-Wl,-rpath,$BENCH_JSON_LIB")
    [[ $name == regex-redux ]] && extra=(-L "$BENCH_PCRE_LIB" -C "link-arg=-Wl,-rpath,$BENCH_PCRE_LIB")
    exec rustc --crate-name bench -C opt-level=3 -C codegen-units=1 -C target-cpu=generic "$src.rs" -o "$target" "${extra[@]}" ;;
go)
    export GOCACHE=$target.go-cache GOMAXPROCS=2 GO111MODULE=off CGO_ENABLED=0 GOAMD64=v1
    sources=("$src.go")
    case $name in binary-trees|fannkuch|n-body|spectral-norm|mandelbrot|fasta) sources+=("$root/tests/benchmarks/languages/go/cpu.go");; esac
    exec go build -trimpath -buildvcs=false -o "$target" "${sources[@]}" ;;
zig)
    extra=()
    [[ $name == json ]] && extra=(-L "$BENCH_JSON_LIB" -ljson-c -rpath "$BENCH_JSON_LIB")
    [[ $name == regex-redux ]] && extra=(-L "$BENCH_PCRE_LIB" -lpcre2-8 -rpath "$BENCH_PCRE_LIB")
    exec zig build-exe "$src.zig" -O ReleaseFast -mcpu baseline -lc -fno-strip -femit-bin="$target" --cache-dir "$target.zig-cache" --global-cache-dir "$target.zig-global" "${extra[@]}" ;;
abla)
    exec "$compiler" build "$src.ab" -o "$target" --no-cache ;;
*) echo "unknown language $lang" >&2; exit 2 ;;
esac
