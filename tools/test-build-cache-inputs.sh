#!/usr/bin/env bash
# Compare a changed-input warm build with an isolated no-cache build.
set -euo pipefail
export LC_ALL=C
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
cd "$root"
source tools/compiler-binary.sh
compiler=$(abla_compiler_binary "$compiler")
export ABLA_SYSROOT="$root" ABLA_DEBUG=0 ABLA_TEST_FAST_BUILDS=0
out=$(mktemp -d "${TMPDIR:-/tmp}/abla-cache-inputs.XXXXXXXX")
if [[ ${CACHE_INPUTS_KEEP:-} == 1 ]]; then
    printf 'cache inputs: artifacts in %s\n' "$out"
else
    trap 'rm -rf "$out"' EXIT
fi
ledger=tools/build-cache-inputs.tsv

# Catch new literal controls in compiler code, including the names passed to
# indirect readers (SDK selection, codegen counts and Xtensa options).
{
    rg --no-filename -o '"ABLA_[A-Z0-9_]+"' src -g '*.ab' | tr -d '"' | sed 's/^/env\t/'
    awk '/if .*argument0 == "build"/ {inside=1} inside && /if .*argument0 == "test"/ {exit} inside' src/orc_main.ab |
        rg -o '"(--[a-z][a-z0-9-]*|-g|-o|-v)"' | tr -d '"' | sed 's/^/flag\t/'
    sed -n '/^fun bootstrapStrictImportsOption(/,/^}/p' src/orc_main.ab |
        rg -o '"--[a-z][a-z0-9=-]*"' | tr -d '"' | sed 's/^/flag\t/'
    rg --no-filename -o 'ABLA_[A-Z0-9_]+' tools/run-limited-compiler.sh tools/run-limited.sh |
        sed 's/^/launcher\t/'
    sed -n '/^fun bootstrapLinkReadsEnvironment(/,/^$/p' src/toolchain.ab |
        rg -o '"[A-Z_]+=?"' | tr -d '"=' | sed 's/^/linker-env\t/'
} | sort -u > "$out/discovered"
awk -F '\t' '!/^#/ && NF {print $1 "\t" $2}' "$ledger" | sort -u > "$out/classified"
diff -u "$out/classified" "$out/discovered"
awk -F '\t' '!/^#/ && NF {
    if (NF != 4 || seen[$1 FS $2]++ ||
        ($3 ~ /^(key|bypass|link)$/ && $4 == "-") ||
        $3 !~ /^(key|bypass|link|observe|schedule|select|outside)$/)
        exit 1
}' "$ledger"
if [[ ${CACHE_INPUTS_AUDIT_ONLY:-} == 1 ]]; then
    printf 'cache inputs: all compiler controls classified\n'
    exit 0
fi

cat > "$out/unused.ab" <<'ABLA'
import "abla/text"
fun main: int = 42
ABLA
cat > "$out/staged.ab" <<'ABLA'
fun total(): int {
    var value = 0
    for (n in 0 until 1200) value += n
    value
}
fun descend(level: int): int = if (level == 0) 0 else descend(level - 1) + 1
val value = #total()
val depth = #descend(16)
fun main: int = if (value == 719400 && depth == 16) 42 else 1
ABLA
cat > "$out/flat-provider.ab" <<'ABLA'
fun answer(): int = 42
ABLA
cat > "$out/flat-mid.ab" <<'ABLA'
import "flat-provider.ab"
fun unused(): int = 1
ABLA
cat > "$out/flat.ab" <<'ABLA'
import "flat-mid.ab"
fun main: int = answer()
ABLA
cat > "$out/internals.ab" <<'ABLA'
import "abla/crypto/aes/raw.ab"
fun main: int {
    aesWipe(0, 0)
    42
}
ABLA
cat > "$out/warnings.ab" <<'ABLA'
private fun unused(): int = 1
fun answer(ignored: int): int {
    val dead = 2
    42
}
fun main: int = answer(0)
ABLA
cp tests/cases/regex-construction/main.ab "$out/regex-construction.ab"
cp tests/cases/json-construction/main.ab "$out/json-construction.ab"

run_build() {
    local arm=$1
    shift
    local status=0
    (cd "$case_cwd" && env "$@") > "$directory/$arm.stdout" 2> "$directory/$arm.stderr" || status=$?
    printf '%s\n' "$status" > "$directory/$arm.status"
}

test_case() {
    local name=$1 directory="$out/$1" case_cwd=$root
    local input=tests/cases/modules/collections.ab diagnostic="" expected=0
    local -a before_flags=(--fast) after_flags=(--fast) before_env=() after_env=()
    mkdir "$directory"
    local output="$directory/program" sidecar="" partition_layout=false
    case "$name" in
        profile-fast) before_flags=() ;;
        profile-env) before_flags=(); after_flags=(); after_env=(ABLA_TEST_FAST_BUILDS=1) ;;
        profile-o1) before_flags=(); after_flags=(--o1) ;;
        debug-flag) after_flags+=(-g); sidecar=.o ;;
        debug-env) before_env=(ABLA_DEBUG=0); after_env=(ABLA_DEBUG=1); sidecar=.o ;;
        no-debug) before_flags+=(-g); after_flags+=(--no-debug); sidecar=.o ;;
        backtrace) before_flags=(); after_flags=(--backtrace)
            if [[ $(uname -s) == Linux ]]; then sidecar=.debug; fi ;;
        sidecar) before_flags=(--no-sidecar); after_flags=(--sidecar); sidecar=.o; partition_layout=true ;;
        sidecar-env) before_flags=(); after_flags=(); before_env=(ABLA_SIDECAR=1); after_env=(ABLA_SIDECAR=1 ABLA_NO_SIDECAR=1) ;;
        sidecar-env-on) before_flags=(); after_flags=(); after_env=(ABLA_SIDECAR=1); sidecar=.o; partition_layout=true ;;
        emit-object) after_flags+=(--emit object) ;;
        emit-library) after_flags+=(--emit static-library) ;;
        named-target) after_flags+=(--target wasm32-wasi) ;;
        raw-target) before_flags+=(--target-triple x86_64-unknown-linux-gnu --object-format elf)
            after_flags+=(--target-triple aarch64-unknown-linux-gnu --object-format elf) ;;
        prefix-map) before_flags+=(-g); after_flags+=(-g --path-prefix-map "$root=/cache-inputs"); sidecar=.o ;;
        coverage) after_flags+=(--coverage-functions) ;;
        strict) input="$out/flat.ab"; before_flags+=(--flat-imports); after_flags+=(--strict-imports)
            expected=1; diagnostic=E_NAME_NOT_IMPORTED ;;
        strict-warn) input="$out/flat.ab"; before_flags+=(--flat-imports); after_flags+=(--strict-imports=warn)
            diagnostic='warning[E_NAME_NOT_IMPORTED]' ;;
        # A build with --stdlib-internals is never cached (bypass): the same program built next without the flag, from the same cache, must
        # not find it, and fail as the library's internal file it imports (no program may) does.
        stdlib-internals) input="$out/internals.ab"; before_flags+=(--stdlib-internals)
            expected=1; diagnostic=E_IMPORT_NOT_FOUND ;;
        warnings-env) input="$out/unused.ab"; before_env=(ABLA_WARN_UNUSED_IMPORTS=0); after_env=(ABLA_WARN_UNUSED_IMPORTS=1)
            diagnostic=W_UNUSED_IMPORT ;;
        warnings-flag) input="$out/unused.ab"; before_flags+=(--no-warn-unused-imports)
            after_flags+=(--warn-unused-imports); diagnostic=W_UNUSED_IMPORT ;;
        warning-locals) input="$out/warnings.ab"; after_flags+=(--warn-unused-locals); diagnostic=W_UNUSED_LOCAL ;;
        warning-parameters) input="$out/warnings.ab"; after_flags+=(--warn-unused-parameters); diagnostic=W_UNUSED_PARAMETER ;;
        warning-declarations)
            # Keep the project-wide declaration scan outside the compiler checkout.
            cp tests/cases/unused-declarations/*.ab "$directory/"
            case_cwd=$directory; input=main.ab
            after_flags+=(--warn-unused-declarations); diagnostic=W_UNUSED_DECLARATION ;;
        warning-json) input="$out/json-construction.ab"; after_flags+=(--warn-json-construction)
            diagnostic=W_JSON_CONSTRUCTION ;;
        warning-regex) input="$out/regex-construction.ab"; after_flags+=(--warn-regex-construction)
            diagnostic=W_REGEX_CONSTRUCTION ;;
        visibility) sidecar=.visibility.json; after_flags+=(--visibility-report "$output$sidecar") ;;
        ct-step) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=200000)
            after_env=(ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=100)
            expected=1; diagnostic=E_EVAL_STEP_LIMIT ;;
        ct-depth) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL=interp)
            after_env=(ABLA_COMPILE_EVAL=interp ABLA_EVAL_DEPTH_LIMIT=4)
            expected=1; diagnostic=E_EVAL_STACK_DEPTH ;;
        ct-tier) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL=interp); after_env=(ABLA_COMPILE_EVAL=jit) ;;
        ct-time) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL_TIME_LIMIT=60); after_env=(ABLA_COMPILE_EVAL_TIME_LIMIT=30) ;;
        ct-trial) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL_TRIAL_STEPS=1000); after_env=(ABLA_COMPILE_EVAL_TRIAL_STEPS=0) ;;
        ct-passes) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_PASSES=fast)
            after_env=(ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_PASSES=balanced) ;;
        ct-units) input="$out/staged.ab"; before_env=(ABLA_COMPILE_EVAL_UNITS=0); after_env=(ABLA_COMPILE_EVAL_UNITS=1) ;;
        sysroot|stdlib)
            mkdir "$directory/sysroot"
            ln -s "$root/runtime" "$directory/sysroot/runtime"
            cp -R "$root/stdlib" "$directory/sysroot/stdlib"
            if [[ $name == sysroot ]]; then after_env=("ABLA_SYSROOT=$directory/sysroot")
            else after_env=("ABLA_STDLIB=$directory/sysroot/stdlib"); fi ;;
        fast-prune) after_env=(ABLA_FAST_PRUNE=0) ;;
        valgrind) after_env=(ABLA_VALGRIND=1) ;;
        valgrind-flag) after_flags+=(--valgrind) ;;
        runtime-object) after_env=(ABLA_FAST_RUNTIME_OBJECT=0) ;;
        runtime-hint) after_env=(ABLA_PRUNE_RUNTIME=1) ;;
        keep-text) after_env=(ABLA_KEEP_LLVM_TEXT=1); sidecar=.ll; partition_layout=true ;;
        out-of-process) after_env=(ABLA_LLVM_OUT_OF_PROCESS=1); partition_layout=true ;;
        native-units) before_env=(ABLA_CODEGEN_UNITS=1 ABLA_CODEGEN_UNITS_MINIMUM=0)
            after_env=(ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0); sidecar=.o ;;
        native-minimum) before_env=(ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0)
            after_env=(ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=999999999); sidecar=.o ;;
        direct-link) after_env=(ABLA_LINK_DIRECT=0) ;;
        builtin-link) after_env=(ABLA_LINK_BUILTIN=0) ;;
        inprocess-link) after_env=(ABLA_LINK_INPROCESS=0) ;;
        bundled-codegen) after_env=(ABLA_CODEGEN_INPROCESS=0) ;;
        collector) before_flags=(); after_flags=(); after_env=(ABLA_RELEASE_COLLECTOR_OBJECT=0) ;;
        wasm-units|wasm-minimum|wasm-text|wasm-out-of-process|wasm-names|wasm-names-env|wasm-stack|wasm-imports|inline-threshold|cross-tools)
            before_flags+=(--target wasm32-wasi)
            after_flags+=(--target wasm32-wasi)
            case "$name" in
                wasm-units) before_env=(ABLA_CODEGEN_UNITS=1 ABLA_CODEGEN_UNITS_MINIMUM=0)
                    after_env=(ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0) ;;
                wasm-minimum) before_env=(ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=0)
                    after_env=(ABLA_CODEGEN_UNITS=8 ABLA_CODEGEN_UNITS_MINIMUM=999999999) ;;
                wasm-text) after_env=(ABLA_KEEP_LLVM_TEXT=1); sidecar=.ll ;;
                wasm-out-of-process) after_env=(ABLA_LLVM_OUT_OF_PROCESS=1) ;;
                wasm-names) after_flags+=(--wasm-names) ;;
                wasm-names-env) after_env=(ABLA_WASM_NAMES=1) ;;
                wasm-stack) after_env=(ABLA_WASM_STACK_BYTES=2097152) ;;
                wasm-imports) after_flags+=(--wasm-imports) ;;
                inline-threshold) before_env=(ABLA_FAST_INLINE_THRESHOLD=0)
                    after_env=(ABLA_FAST_INLINE_THRESHOLD=400) ;;
                cross-tools)
                    before_env=(ABLA_CODEGEN_INPROCESS=0 ABLA_LLVM_OUT_OF_PROCESS=1)
                    local opt
                    opt=$(command -v opt)
                    mkdir "$directory/tools"
                    cat > "$directory/tools/opt" <<SH
#!/usr/bin/env bash
if [[ \$1 == --version ]]; then exec "$opt" "\$@"; fi
printf '%s\\n' 'cache-inputs: changed optimizer' >&2
exit 33
SH
                    chmod +x "$directory/tools/opt"
                    after_env=("${before_env[@]}" "PATH=$directory/tools:$PATH")
                    expected=33; diagnostic='cache-inputs: changed optimizer' ;;
            esac ;;
        host-tools)
            before_flags=(--sidecar); after_flags=(--sidecar)
            local opt llc
            opt=$(command -v opt)
            llc=$(command -v llc)
            mkdir "$directory/tools"
            ln -s "$opt" "$directory/tools/opt"
            ln -s "$llc" "$directory/tools/llc"
            after_env=("ABLA_LLVM_TOOLS=$directory/tools") ;;
        *) printf 'No cache case for %s\n' "$name" >&2; return 1 ;;
    esac

    run_build prime "${before_env[@]}" "$compiler" build "$input" "${before_flags[@]}" \
        --cache-dir "$directory/warm-cache" -o "$output"
    if [[ $(<"$directory/prime.status") != 0 ]]; then
        cat "$directory/prime.stderr" >&2
        printf 'cache inputs: %s failed to prime\n' "$name" >&2
        return 1
    fi
    run_build warm "${after_env[@]}" "$compiler" build "$input" "${after_flags[@]}" \
        --cache-dir "$directory/warm-cache" -o "$output"
    case "$name" in
        ct-passes|ct-tier|ct-time|ct-trial|ct-units)
            local cache_entries
            cache_entries=$(find "$directory/warm-cache" -maxdepth 1 -type f -name 'native-*.source' | wc -l)
            [[ $cache_entries -eq 2 ]] ;;
    esac
    if [[ $(<"$directory/warm.status") == 0 ]]; then
        cp "$output" "$directory/warm.bin"
        if [[ $partition_layout == true ]]; then cp "$output.abi.json" "$directory/warm.abi.json"; fi
        if [[ -n $sidecar ]]; then cp "$output$sidecar" "$directory/warm$sidecar"; fi
    fi
    rm -f "$output" "$output".*
    run_build clean "${after_env[@]}" "$compiler" build "$input" "${after_flags[@]}" \
        --no-cache --cache-dir "$directory/clean-cache" -o "$output"
    if [[ $(<"$directory/clean.status") != "$expected" ]] ||
        ! cmp -s "$directory/warm.status" "$directory/clean.status"; then
        printf 'cache inputs: %s expected %s, warm %s, clean %s\n' "$name" "$expected" \
            "$(<"$directory/warm.status")" "$(<"$directory/clean.status")" >&2
        cat "$directory"/{warm,clean}.stderr >&2
        return 1
    fi
    if [[ -n $diagnostic ]]; then
        grep -F "$diagnostic" "$directory/warm.stderr" >/dev/null
        grep -F "$diagnostic" "$directory/clean.stderr" >/dev/null
    fi
    if [[ $expected == 0 ]]; then
        if [[ $partition_layout == true && $(uname -s) == Linux ]]; then
            # Cached native text uses relocatable partitions; --no-cache is
            # a single object. Require exact bytes with an empty cache and
            # compare the public ABI and running program with --no-cache.
            cmp "$directory/warm.abi.json" "$output.abi.json"
            cmp "$directory/warm.bin" "$output" >/dev/null || {
                local binary result
                for binary in "$directory/warm.bin" "$output"; do
                    result=0
                    "$binary" > "$binary.run" || result=$?
                    [[ $result -eq 42 ]] || return 1
                done
                cmp "$directory/warm.bin.run" "$output.run"
            }
            if [[ $sidecar == .ll ]]; then cmp "$directory/warm.ll" "$output.ll"; fi
            rm -f "$output" "$output".*
            run_build fresh "${after_env[@]}" "$compiler" build "$input" "${after_flags[@]}" \
                --cache-dir "$directory/fresh-cache" -o "$output"
            [[ $(<"$directory/fresh.status") == 0 ]]
        fi
        cmp "$directory/warm.bin" "$output"
        if [[ -n $sidecar ]]; then cmp "$directory/warm$sidecar" "$output$sidecar"; fi
    fi
    # The two outputs, line by line when they differ: cmp alone named only the first differing line.
    local stream
    for stream in stdout stderr; do
        diff -u --label "warm $stream" --label "clean $stream" "$directory/warm.$stream" "$directory/clean.$stream" >&2 || {
            printf 'cache inputs: %s: the warm and clean builds printed different %s\n' "$name" "$stream" >&2
            return 1
        }
    done
    printf 'cache inputs: %s matches the clean build\n' "$name"
}

cases=$(awk -F '\t' '!/^#/ && NF && $4 !~ /^(-|platform-|existing-)/ {n=split($4, ids, ","); for (i=1; i<=n; i++) print ids[i]}' "$ledger" | sort -u)
failed=0
for name in $cases; do
    if [[ -n ${CACHE_INPUTS_FILTER:-} && ! $name =~ $CACHE_INPUTS_FILTER ]]; then continue; fi
    set +e
    (set -e; test_case "$name")
    status=$?
    set -e
    if ((status != 0)); then
        printf 'cache inputs: %s failed\n' "$name" >&2
        failed=$((failed + 1))
    fi
done
((failed == 0))
